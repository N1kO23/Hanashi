// Hanashi: see pipewire_app_sound.h.
//
// A capture stream of our own, which the session manager leaves unlinked,
// takes the output ports of the apps' playback streams: not Hanashi's (its
// process), nor those of a client that takes in what others play (it has a
// sink of its own, or records one's monitor: EasyEffects, a loopback, a
// filter chain), whose playback carries the call too. The links are passive,
// and go with the stream. Everything here runs on PipeWire's thread, under
// its lock.

#include "pipewire_app_sound.h"

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <spa/pod/builder.h>
#include <unistd.h>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <map>
#include <set>
#include <utility>

#include "pipewire_api.h"
#include "rtc_audio_source.h"

namespace hanashi {

namespace {

void Log(const std::string& line) { std::cerr << "[hanashi screen sound] " << line << std::endl; }

// What libwebrtc takes at a time: 10 ms of 16-bit stereo at 48 kHz.
constexpr int kRate = 48000;
constexpr int kChannels = 2;
constexpr size_t kFrames = kRate / 100;
constexpr size_t kChunk = kFrames * kChannels * sizeof(int16_t);

constexpr char kPlayback[] = "Stream/Output/Audio";
constexpr char kSink[] = "Audio/Sink";

std::string Get(const spa_dict* props, const char* key) {
  const char* value = props == nullptr ? nullptr : spa_dict_lookup(props, key);
  return value == nullptr ? std::string() : std::string(value);
}

uint32_t IdIn(const std::string& value) {
  if (value.empty()) return SPA_ID_INVALID;
  char* end = nullptr;
  const unsigned long id = std::strtoul(value.c_str(), &end, 10);
  return *end == '\0' ? static_cast<uint32_t>(id) : SPA_ID_INVALID;
}

// Our side for an app's channel: left (1), right (2), both (3) or neither.
int SidesOf(const std::string& channel) {
  static const std::set<std::string> left = {"FL", "SL", "RL", "FLC", "FLW", "TFL", "TSL", "TRL", "RLC"};
  static const std::set<std::string> right = {"FR", "SR", "RR", "FRC", "FRW", "TFR", "TSR", "TRR", "RRC"};
  if (left.count(channel) > 0) return 1;
  if (right.count(channel) > 0) return 2;
  if (channel == "LFE" || channel == "LFE2") return 0;
  // Mono, the centres, and what is not known.
  return 3;
}

}  // namespace

struct PipeWireAppSound::State {
  struct Node {
    State* owner = nullptr;
    std::string media_class;
    std::string name;
    std::string app;       // what one app's sharing goes by
    std::string app_name;  // what it calls itself
    uint32_t client = SPA_ID_INVALID;
    int pid = 0;         // in its own properties (PulseAudio's apps)
    bool known = false;  // its own properties came (playback streams)
    pw_proxy* proxy = nullptr;
    spa_hook listener{};
  };
  struct Port {
    uint32_t node = SPA_ID_INVALID;
    bool output = false;
    bool monitor = false;  // a sink's, giving what is played to it
    std::string channel;
  };
  struct Link {
    uint32_t output_port = SPA_ID_INVALID;
    uint32_t input = SPA_ID_INVALID;  // node
  };

  const PipeWireApi* api = nullptr;
  libwebrtc::scoped_refptr<libwebrtc::RTCAudioSource> source;
  pw_thread_loop* loop = nullptr;
  pw_context* context = nullptr;
  pw_core* core = nullptr;
  pw_registry* registry = nullptr;
  pw_stream* stream = nullptr;
  spa_hook core_listener{};
  spa_hook registry_listener{};
  spa_hook stream_listener{};

  std::map<uint32_t, Node> nodes;
  std::map<uint32_t, int> clients;  // their processes, as the kernel tells PipeWire
  std::map<uint32_t, Port> ports;
  std::map<uint32_t, Link> links;
  std::string only;  // the one app, or empty: every app
  uint32_t self = SPA_ID_INVALID;
  // Our links, by (an app's port, our port).
  std::map<std::pair<uint32_t, uint32_t>, pw_proxy*> made;
  std::set<uint32_t> heard;  // the apps' streams linked, for the log
  std::vector<uint8_t> pending;
  const int pid = static_cast<int>(getpid());

  void OnGlobal(uint32_t id, const char* type, const spa_dict* props);
  void OnGlobalRemove(uint32_t id);
  void OnNodeInfo(Node& node, const pw_node_info* info);
  void OnProcess();

  int PidOf(const Node& node) const;
  // The clients that take in what others play: they have a sink of their
  // own, or record one's monitor.
  std::set<uint32_t> Taking() const;
  // An app's own playback: not Hanashi's, nor one of a client `taking`.
  bool Plays(uint32_t node, const std::set<uint32_t>& taking) const;
  // Links what is to be heard, and unlinks what is not.
  void Update();
  pw_proxy* Connect(uint32_t from, uint32_t to);
};

namespace {

const pw_core_events kCoreEvents = [] {
  pw_core_events e{};
  e.version = PW_VERSION_CORE_EVENTS;
  e.error = [](void*, uint32_t id, int, int res, const char* message) {
    Log("PipeWire (" + std::to_string(id) + ", " + std::to_string(res) + "): " + (message != nullptr ? message : "?"));
  };
  return e;
}();

const pw_registry_events kRegistryEvents = [] {
  pw_registry_events e{};
  e.version = PW_VERSION_REGISTRY_EVENTS;
  e.global = [](void* data, uint32_t id, uint32_t, const char* type, uint32_t, const spa_dict* props) {
    static_cast<PipeWireAppSound::State*>(data)->OnGlobal(id, type, props);
  };
  e.global_remove = [](void* data, uint32_t id) { static_cast<PipeWireAppSound::State*>(data)->OnGlobalRemove(id); };
  return e;
}();

const pw_node_events kNodeEvents = [] {
  pw_node_events e{};
  e.version = PW_VERSION_NODE_EVENTS;
  e.info = [](void* data, const pw_node_info* info) {
    auto* node = static_cast<PipeWireAppSound::State::Node*>(data);
    node->owner->OnNodeInfo(*node, info);
  };
  return e;
}();

const pw_stream_events kStreamEvents = [] {
  pw_stream_events e{};
  e.version = PW_VERSION_STREAM_EVENTS;
  e.state_changed = [](void* data, pw_stream_state, pw_stream_state state, const char* error) {
    auto* s = static_cast<PipeWireAppSound::State*>(data);
    if (state == PW_STREAM_STATE_ERROR) Log(std::string("the stream failed: ") + (error != nullptr ? error : "?"));
    if (state != PW_STREAM_STATE_PAUSED && state != PW_STREAM_STATE_STREAMING) return;
    // Our node is there now: its ports come through the registry.
    const uint32_t self = s->api->stream_get_node_id(s->stream);
    if (self == s->self) return;
    s->self = self;
    s->Update();
  };
  e.process = [](void* data) { static_cast<PipeWireAppSound::State*>(data)->OnProcess(); };
  return e;
}();

}  // namespace

void PipeWireAppSound::State::OnGlobal(uint32_t id, const char* type, const spa_dict* props) {
  if (std::strcmp(type, PW_TYPE_INTERFACE_Node) == 0) {
    Node& node = nodes[id];
    node.owner = this;
    node.media_class = Get(props, PW_KEY_MEDIA_CLASS);
    node.name = Get(props, PW_KEY_NODE_NAME);
    node.app_name = Get(props, PW_KEY_APP_NAME);
    node.client = IdIn(Get(props, PW_KEY_CLIENT_ID));
    if (node.media_class == kPlayback) {
      // Who plays it is in its own properties, not in what the registry says.
      node.proxy = static_cast<pw_proxy*>(pw_registry_bind(registry, id, PW_TYPE_INTERFACE_Node, PW_VERSION_NODE, 0));
      if (node.proxy != nullptr) {
        pw_node_add_listener(reinterpret_cast<pw_node*>(node.proxy), &node.listener, &kNodeEvents, &node);
      }
    }
  } else if (std::strcmp(type, PW_TYPE_INTERFACE_Port) == 0) {
    Port& port = ports[id];
    port.node = IdIn(Get(props, PW_KEY_NODE_ID));
    port.output = Get(props, PW_KEY_PORT_DIRECTION) == "out";
    port.monitor = Get(props, PW_KEY_PORT_MONITOR) == "true";
    port.channel = Get(props, PW_KEY_AUDIO_CHANNEL);
  } else if (std::strcmp(type, PW_TYPE_INTERFACE_Link) == 0) {
    links[id] = {IdIn(Get(props, PW_KEY_LINK_OUTPUT_PORT)), IdIn(Get(props, PW_KEY_LINK_INPUT_NODE))};
  } else if (std::strcmp(type, PW_TYPE_INTERFACE_Client) == 0) {
    clients[id] = std::atoi(Get(props, PW_KEY_SEC_PID).c_str());
    return;
  } else {
    return;
  }
  Update();
}

void PipeWireAppSound::State::OnGlobalRemove(uint32_t id) {
  if (auto node = nodes.find(id); node != nodes.end()) {
    if (node->second.proxy != nullptr) {
      spa_hook_remove(&node->second.listener);
      api->proxy_destroy(node->second.proxy);
    }
    nodes.erase(node);
    heard.erase(id);
  }
  if (ports.erase(id) > 0) {
    // Its links went with it.
    for (auto made_link = made.begin(); made_link != made.end();) {
      if (made_link->first.first == id || made_link->first.second == id) {
        api->proxy_destroy(made_link->second);
        made_link = made.erase(made_link);
      } else {
        ++made_link;
      }
    }
  }
  links.erase(id);
  clients.erase(id);
  Update();
}

void PipeWireAppSound::State::OnNodeInfo(Node& node, const pw_node_info* info) {
  if (info == nullptr || info->props == nullptr) return;
  const std::string pid_text = Get(info->props, PW_KEY_APP_PROCESS_ID);
  if (!pid_text.empty()) node.pid = std::atoi(pid_text.c_str());
  const std::string name = Get(info->props, PW_KEY_APP_NAME);
  if (!name.empty()) node.app_name = name;
  const std::string binary = Get(info->props, PW_KEY_APP_PROCESS_BINARY);
  node.app = !binary.empty() ? binary : !node.app_name.empty() ? node.app_name : node.name;
  node.known = true;
  Update();
}

void PipeWireAppSound::State::OnProcess() {
  pw_buffer* buffer = api->stream_dequeue_buffer(stream);
  if (buffer == nullptr) return;
  const spa_buffer* data = buffer->buffer;
  if (data != nullptr && data->n_datas > 0 && data->datas[0].data != nullptr && data->datas[0].chunk != nullptr) {
    const spa_data& d = data->datas[0];
    const uint32_t offset = std::min(d.chunk->offset, d.maxsize);
    const uint32_t size = std::min(d.chunk->size, d.maxsize - offset);
    const auto* bytes = static_cast<const uint8_t*>(d.data) + offset;
    pending.insert(pending.end(), bytes, bytes + size);
    size_t used = 0;
    while (pending.size() - used >= kChunk) {
      source->CaptureFrame(pending.data() + used, 16, kRate, kChannels, kFrames);
      used += kChunk;
    }
    pending.erase(pending.begin(), pending.begin() + static_cast<std::ptrdiff_t>(used));
  }
  api->stream_queue_buffer(stream, buffer);
}

int PipeWireAppSound::State::PidOf(const Node& node) const {
  if (node.pid != 0) return node.pid;
  // An app of PipeWire's own says who it is through its connection.
  const auto client = clients.find(node.client);
  return client != clients.end() ? client->second : 0;
}

std::set<uint32_t> PipeWireAppSound::State::Taking() const {
  std::set<uint32_t> taking;
  for (const auto& [id, node] : nodes) {
    if (node.media_class.rfind(kSink, 0) == 0) taking.insert(node.client);
  }
  for (const auto& [id, link] : links) {
    const auto from = ports.find(link.output_port);
    const auto to = nodes.find(link.input);
    if (from != ports.end() && from->second.monitor && to != nodes.end()) taking.insert(to->second.client);
  }
  return taking;
}

bool PipeWireAppSound::State::Plays(uint32_t id, const std::set<uint32_t>& taking) const {
  const auto node = nodes.find(id);
  // Not before its properties came: it may be Hanashi's own.
  if (node == nodes.end() || node->second.media_class != kPlayback || !node->second.known) return false;
  return PidOf(node->second) != pid && taking.count(node->second.client) == 0;
}

void PipeWireAppSound::State::Update() {
  if (core == nullptr || self == SPA_ID_INVALID) return;
  uint32_t left = SPA_ID_INVALID;
  uint32_t right = SPA_ID_INVALID;
  for (const auto& [id, port] : ports) {
    if (port.node != self || port.output) continue;
    if (port.channel == "FL") left = id;
    if (port.channel == "FR") right = id;
  }
  std::set<std::pair<uint32_t, uint32_t>> wanted;
  std::set<uint32_t> streams;
  if (left != SPA_ID_INVALID && right != SPA_ID_INVALID) {
    const std::set<uint32_t> taking = Taking();
    for (const auto& [id, port] : ports) {
      if (!port.output || port.monitor || !Plays(port.node, taking)) continue;
      if (!only.empty() && nodes.at(port.node).app != only) continue;
      const int sides = SidesOf(port.channel);
      if ((sides & 1) != 0) wanted.insert({id, left});
      if ((sides & 2) != 0) wanted.insert({id, right});
      if (sides != 0) streams.insert(port.node);
    }
  }
  for (auto link = made.begin(); link != made.end();) {
    if (wanted.count(link->first) == 0) {
      api->proxy_destroy(link->second);
      link = made.erase(link);
    } else {
      ++link;
    }
  }
  for (const auto& key : wanted) {
    if (made.count(key) > 0) continue;
    if (pw_proxy* link = Connect(key.first, key.second)) made[key] = link;
  }
  for (const uint32_t id : streams) {
    if (heard.insert(id).second) Log("hearing " + nodes.at(id).app);
  }
  for (auto id = heard.begin(); id != heard.end();) {
    if (streams.count(*id) == 0) {
      if (nodes.count(*id) > 0) Log("no longer hearing " + nodes.at(*id).app);
      id = heard.erase(id);
    } else {
      ++id;
    }
  }
}

pw_proxy* PipeWireAppSound::State::Connect(uint32_t from, uint32_t to) {
  const std::string output_node = std::to_string(ports.at(from).node);
  const std::string output_port = std::to_string(from);
  const std::string input_node = std::to_string(self);
  const std::string input_port = std::to_string(to);
  const spa_dict_item items[] = {
      {PW_KEY_LINK_OUTPUT_NODE, output_node.c_str()},
      {PW_KEY_LINK_OUTPUT_PORT, output_port.c_str()},
      {PW_KEY_LINK_INPUT_NODE, input_node.c_str()},
      {PW_KEY_LINK_INPUT_PORT, input_port.c_str()},
      // Keeps nothing running that would not run anyway; gone with us.
      {PW_KEY_LINK_PASSIVE, "true"},
      {PW_KEY_OBJECT_LINGER, "false"},
  };
  const spa_dict dict{0, static_cast<uint32_t>(sizeof(items) / sizeof(items[0])), items};
  return static_cast<pw_proxy*>(
      pw_core_create_object(core, "link-factory", PW_TYPE_INTERFACE_Link, PW_VERSION_LINK, &dict, 0));
}

bool PipeWireAppSound::Available() { return PipeWireApi::Get() != nullptr; }

PipeWireAppSound::PipeWireAppSound() = default;

PipeWireAppSound::~PipeWireAppSound() { Stop(); }

bool PipeWireAppSound::Start(libwebrtc::scoped_refptr<libwebrtc::RTCAudioSource> source) {
  Stop();
  const PipeWireApi* api = PipeWireApi::Get();
  if (api == nullptr || source.get() == nullptr) return false;
  state_ = std::make_unique<State>();
  State* s = state_.get();
  s->api = api;
  s->source = source;
  s->loop = api->thread_loop_new("hanashi-screen-sound", nullptr);
  if (s->loop != nullptr) s->context = api->context_new(api->thread_loop_get_loop(s->loop), nullptr, 0);
  if (s->context == nullptr || api->thread_loop_start(s->loop) < 0) {
    Log("PipeWire did not start");
    Stop();
    return false;
  }
  api->thread_loop_lock(s->loop);
  s->core = api->context_connect(s->context, nullptr, 0);
  if (s->core == nullptr) {
    api->thread_loop_unlock(s->loop);
    Log("could not connect to PipeWire");
    Stop();
    return false;
  }
  pw_core_add_listener(s->core, &s->core_listener, &kCoreEvents, s);
  s->registry = pw_core_get_registry(s->core, PW_VERSION_REGISTRY, 0);
  pw_registry_add_listener(s->registry, &s->registry_listener, &kRegistryEvents, s);
  s->stream = api->stream_new(s->core, "Hanashi screen sound",
                              api->properties_new(PW_KEY_MEDIA_TYPE, "Audio", PW_KEY_MEDIA_CATEGORY, "Capture",
                                                  PW_KEY_NODE_NAME, "hanashi-screen-sound", PW_KEY_NODE_DESCRIPTION,
                                                  "Hanashi: a shared screen's sound", PW_KEY_APP_NAME, "Hanashi",
                                                  // Linked here, to apps; never by the session manager (to a
                                                  // microphone).
                                                  PW_KEY_NODE_AUTOCONNECT, "false", nullptr));
  int connected = -1;
  if (s->stream != nullptr) {
    api->stream_add_listener(s->stream, &s->stream_listener, &kStreamEvents, s);
    uint8_t buffer[1024];
    spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    spa_audio_info_raw info{};
    info.format = SPA_AUDIO_FORMAT_S16;
    info.rate = kRate;
    info.channels = kChannels;
    info.position[0] = SPA_AUDIO_CHANNEL_FL;
    info.position[1] = SPA_AUDIO_CHANNEL_FR;
    const spa_pod* params[] = {spa_format_audio_raw_build(&b, SPA_PARAM_EnumFormat, &info)};
    connected = api->stream_connect(s->stream, PW_DIRECTION_INPUT, PW_ID_ANY, PW_STREAM_FLAG_MAP_BUFFERS, params, 1);
  }
  api->thread_loop_unlock(s->loop);
  if (connected < 0) {
    Log("could not make the capture stream");
    Stop();
    return false;
  }
  Log("started");
  return true;
}

void PipeWireAppSound::Stop() {
  if (!state_) return;
  State* s = state_.get();
  const PipeWireApi* api = s->api;
  if (s->loop != nullptr) {
    api->thread_loop_lock(s->loop);
    for (auto& link : s->made) api->proxy_destroy(link.second);
    s->made.clear();
    for (auto& node : s->nodes) {
      if (node.second.proxy == nullptr) continue;
      spa_hook_remove(&node.second.listener);
      api->proxy_destroy(node.second.proxy);
      node.second.proxy = nullptr;
    }
    if (s->registry != nullptr) {
      spa_hook_remove(&s->registry_listener);
      api->proxy_destroy(reinterpret_cast<pw_proxy*>(s->registry));
      s->registry = nullptr;
    }
    if (s->stream != nullptr) {
      spa_hook_remove(&s->stream_listener);
      api->stream_disconnect(s->stream);
      api->stream_destroy(s->stream);
      s->stream = nullptr;
    }
    if (s->core != nullptr) {
      spa_hook_remove(&s->core_listener);
      api->core_disconnect(s->core);
      s->core = nullptr;
    }
    api->thread_loop_unlock(s->loop);
    api->thread_loop_stop(s->loop);
  }
  if (s->context != nullptr) api->context_destroy(s->context);
  if (s->loop != nullptr) api->thread_loop_destroy(s->loop);
  const bool started = s->self != SPA_ID_INVALID;
  state_.reset();
  if (started) Log("stopped");
}

std::vector<PipeWireAppSound::App> PipeWireAppSound::Apps() {
  std::vector<App> apps;
  if (!state_ || state_->loop == nullptr) return apps;
  State* s = state_.get();
  s->api->thread_loop_lock(s->loop);
  const std::set<uint32_t> taking = s->Taking();
  std::set<std::string> seen;
  for (const auto& [id, node] : s->nodes) {
    if (!s->Plays(id, taking) || node.app.empty() || !seen.insert(node.app).second) continue;
    apps.push_back({node.app, node.app_name.empty() ? node.app : node.app_name});
  }
  s->api->thread_loop_unlock(s->loop);
  std::sort(apps.begin(), apps.end(), [](const App& a, const App& b) {
    return std::lexicographical_compare(a.name.begin(), a.name.end(), b.name.begin(), b.name.end(),
                                        [](char x, char y) { return std::tolower(x) < std::tolower(y); });
  });
  return apps;
}

void PipeWireAppSound::SetApp(const std::string& app) {
  if (!state_ || state_->loop == nullptr) return;
  State* s = state_.get();
  s->api->thread_loop_lock(s->loop);
  if (s->only != app) {
    s->only = app;
    Log(app.empty() ? "every app's sound" : "only " + app + "'s sound");
    s->Update();
  }
  s->api->thread_loop_unlock(s->loop);
}

}  // namespace hanashi
