// Hanashi: see portal_screen_cast.h.

#include "portal_screen_cast.h"

#include <gio/gunixfdlist.h>
#include <pipewire/pipewire.h>
#include <spa/buffer/meta.h>
#include <spa/param/video/format-utils.h>
#include <spa/pod/builder.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <random>

#include "pipewire_api.h"
#include "rtc_video_frame.h"

namespace hanashi {

namespace {

constexpr char kPortalName[] = "org.freedesktop.portal.Desktop";
constexpr char kPortalPath[] = "/org/freedesktop/portal/desktop";
constexpr char kScreenCast[] = "org.freedesktop.portal.ScreenCast";
constexpr char kRequest[] = "org.freedesktop.portal.Request";
constexpr char kSession[] = "org.freedesktop.portal.Session";

// The portal's source types and cursor modes.
constexpr uint32_t kMonitor = 1;
constexpr uint32_t kWindow = 2;
constexpr uint32_t kCursorHidden = 1;
constexpr uint32_t kCursorEmbedded = 2;

void Log(const std::string& line) { std::cerr << "[hanashi screencast] " << line << std::endl; }

// pw_stream_state_as_string, without linking PipeWire.
const char* StateName(pw_stream_state state) {
  switch (state) {
    case PW_STREAM_STATE_ERROR:
      return "error";
    case PW_STREAM_STATE_UNCONNECTED:
      return "unconnected";
    case PW_STREAM_STATE_CONNECTING:
      return "connecting";
    case PW_STREAM_STATE_PAUSED:
      return "paused";
    case PW_STREAM_STATE_STREAMING:
      return "streaming";
  }
  return "?";
}

int64_t NowUs() {
  return std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

// What a D-Bus callback needs to find its cast again, if it is still there.
template <typename T>
struct Pending {
  std::weak_ptr<PortalScreenCast> cast;
  T next;
};

// The format the stream asks for: raw video with 4 bytes a pixel, in shared
// memory (no DMA-BUF modifiers are offered).
const spa_pod* BuildFormat(spa_pod_builder* b) {
  spa_rectangle size_def{1920, 1080}, size_min{1, 1}, size_max{16384, 16384};
  spa_fraction rate_def{15, 1}, rate_min{0, 1}, rate_max{144, 1};
  return static_cast<const spa_pod*>(spa_pod_builder_add_object(
      b, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,                             //
      SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),                     //
      SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),                 //
      SPA_FORMAT_VIDEO_format,
      SPA_POD_CHOICE_ENUM_Id(7, SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_BGRx, SPA_VIDEO_FORMAT_RGBx,
                             SPA_VIDEO_FORMAT_BGRA, SPA_VIDEO_FORMAT_RGBA, SPA_VIDEO_FORMAT_RGB,
                             SPA_VIDEO_FORMAT_BGR),
      SPA_FORMAT_VIDEO_size, SPA_POD_CHOICE_RANGE_Rectangle(&size_def, &size_min, &size_max),
      SPA_FORMAT_VIDEO_framerate, SPA_POD_CHOICE_RANGE_Fraction(&rate_def, &rate_min, &rate_max)));
}

}  // namespace

struct PortalScreenCast::PipeWire {
  const PipeWireApi* api = nullptr;
  pw_thread_loop* loop = nullptr;
  pw_context* context = nullptr;
  pw_core* core = nullptr;
  pw_stream* stream = nullptr;
  spa_hook listener{};
};

bool PortalScreenCast::Available() {
  const char* session = std::getenv("XDG_SESSION_TYPE");
  if (session == nullptr || std::string(session) != "wayland" || std::getenv("WAYLAND_DISPLAY") == nullptr) {
    return false;
  }
  if (PipeWireApi::Get() == nullptr) return false;
  GError* error = nullptr;
  GDBusConnection* bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (bus == nullptr) {
    g_clear_error(&error);
    return false;
  }
  // The portal's ScreenCast, asked for its version.
  GVariant* reply = g_dbus_connection_call_sync(bus, kPortalName, kPortalPath, "org.freedesktop.DBus.Properties", "Get",
                                                g_variant_new("(ss)", kScreenCast, "version"), G_VARIANT_TYPE("(v)"),
                                                G_DBUS_CALL_FLAGS_NONE, 3000, nullptr, &error);
  g_object_unref(bus);
  if (reply == nullptr) {
    Log(std::string("no ScreenCast portal: ") + (error != nullptr ? error->message : "?"));
    g_clear_error(&error);
    return false;
  }
  g_variant_unref(reply);
  return true;
}

PortalScreenCast::PortalScreenCast(libwebrtc::scoped_refptr<libwebrtc::RTCVideoSource> source, bool cursor,
                                   double max_fps)
    : source_(source), cursor_(cursor), max_fps_(max_fps > 0 ? max_fps : 15) {}

PortalScreenCast::~PortalScreenCast() {
  StopStream();
  if (cancellable_ != nullptr) {
    g_cancellable_cancel(cancellable_);
    g_object_unref(cancellable_);
  }
  if (bus_ != nullptr) {
    if (closed_subscription_ != 0) g_dbus_connection_signal_unsubscribe(bus_, closed_subscription_);
    CloseSession();
    g_object_unref(bus_);
  }
}

void PortalScreenCast::Start(Done done, Ended ended) {
  done_ = std::move(done);
  ended_ = std::move(ended);
  GError* error = nullptr;
  bus_ = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (bus_ == nullptr) {
    Fail(std::string("no session bus: ") + (error != nullptr ? error->message : "?"));
    g_clear_error(&error);
    return;
  }
  cancellable_ = g_cancellable_new();
  // Request paths are made of the caller's unique name: ":1.42" -> "1_42".
  sender_ = g_dbus_connection_get_unique_name(bus_) + 1;
  std::replace(sender_.begin(), sender_.end(), '.', '_');

  // What this portal can share, and whether it draws the cursor in.
  for (const char* property : {"AvailableSourceTypes", "AvailableCursorModes"}) {
    GVariant* reply = g_dbus_connection_call_sync(bus_, kPortalName, kPortalPath, "org.freedesktop.DBus.Properties",
                                                  "Get", g_variant_new("(ss)", kScreenCast, property),
                                                  G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 3000, nullptr, nullptr);
    if (reply == nullptr) continue;
    GVariant* value = nullptr;
    g_variant_get(reply, "(v)", &value);
    const uint32_t available = g_variant_get_uint32(value);
    if (std::string(property) == "AvailableSourceTypes") {
      types_ = available & (kMonitor | kWindow);
      if (types_ == 0) types_ = kMonitor;
    } else {
      cursor_mode_ = cursor_ && (available & kCursorEmbedded) != 0 ? kCursorEmbedded : kCursorHidden;
    }
    g_variant_unref(value);
    g_variant_unref(reply);
  }

  const std::string token = "hanashi" + std::to_string(std::random_device{}() & 0xffffff);
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "handle_token", g_variant_new_string(token.c_str()));
  g_variant_builder_add(&options, "{sv}", "session_handle_token", g_variant_new_string((token + "s").c_str()));
  Call("CreateSession", g_variant_new("(a{sv})", &options), token, [this](uint32_t response, GVariant* results) {
    const char* session = nullptr;
    if (response != 0 || !g_variant_lookup(results, "session_handle", "&s", &session)) {
      Fail(response == 1 ? "cancelled" : "the portal made no session");
      return;
    }
    session_ = session;
    // Ended by the system (its own "Stop sharing").
    closed_subscription_ = g_dbus_connection_signal_subscribe(
        bus_, kPortalName, kSession, "Closed", session_.c_str(), nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
        [](GDBusConnection*, const gchar*, const gchar*, const gchar*, const gchar*, GVariant*, gpointer data) {
          auto cast = static_cast<std::weak_ptr<PortalScreenCast>*>(data)->lock();
          if (cast) {
            Log("the portal closed the session");
            cast->session_.clear();
            cast->TellEnded();
          }
        },
        new std::weak_ptr<PortalScreenCast>(shared_from_this()),
        [](gpointer data) { delete static_cast<std::weak_ptr<PortalScreenCast>*>(data); });
    SelectSources();
  });
}

void PortalScreenCast::Call(const char* method, GVariant* parameters, const std::string& token,
                            std::function<void(uint32_t, GVariant*)> next) {
  // The answer comes as a signal on the request's path, which is known
  // before the call: listened to first (the bus takes the match before the
  // call, in order), so it cannot be missed.
  const std::string request = std::string(kPortalPath) + "/request/" + sender_ + "/" + token;
  struct Answer {
    std::weak_ptr<PortalScreenCast> cast;
    std::function<void(uint32_t, GVariant*)> next;
    guint subscription = 0;
  };
  auto* answer = new Answer{shared_from_this(), std::move(next)};
  answer->subscription = g_dbus_connection_signal_subscribe(
      bus_, kPortalName, kRequest, "Response", request.c_str(), nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
      [](GDBusConnection* bus, const gchar*, const gchar*, const gchar*, const gchar*, GVariant* parameters,
         gpointer data) {
        auto* answer = static_cast<Answer*>(data);
        // Taken before letting go of the subscription, which frees `answer`.
        auto cast = answer->cast.lock();
        auto next = std::move(answer->next);
        g_dbus_connection_signal_unsubscribe(bus, answer->subscription);
        if (!cast) return;
        uint32_t response = 2;
        GVariant* results = nullptr;
        g_variant_get(parameters, "(u@a{sv})", &response, &results);
        next(response, results);
        g_variant_unref(results);
      },
      answer, [](gpointer data) { delete static_cast<Answer*>(data); });

  auto* pending = new Pending<std::string>{shared_from_this(), method};
  g_dbus_connection_call(
      bus_, kPortalName, kPortalPath, kScreenCast, method, parameters, G_VARIANT_TYPE("(o)"),
      G_DBUS_CALL_FLAGS_NONE, -1, cancellable_,
      [](GObject* source, GAsyncResult* result, gpointer data) {
        std::unique_ptr<Pending<std::string>> pending(static_cast<Pending<std::string>*>(data));
        GError* error = nullptr;
        GVariant* reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
        if (reply != nullptr) {
          g_variant_unref(reply);
          return;
        }
        const bool cancelled = g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
        const std::string message = error->message;
        g_error_free(error);
        if (cancelled) return;
        if (auto cast = pending->cast.lock()) cast->Fail(pending->next + ": " + message);
      },
      pending);
}

void PortalScreenCast::SelectSources() {
  const std::string token = "hanashi" + std::to_string(++tokens_);
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "handle_token", g_variant_new_string(token.c_str()));
  // A screen or a window, one; the user picks in the portal's dialog, each
  // time (nothing is remembered).
  g_variant_builder_add(&options, "{sv}", "types", g_variant_new_uint32(types_));
  g_variant_builder_add(&options, "{sv}", "multiple", g_variant_new_boolean(FALSE));
  g_variant_builder_add(&options, "{sv}", "cursor_mode", g_variant_new_uint32(cursor_mode_));
  Call("SelectSources", g_variant_new("(oa{sv})", session_.c_str(), &options), token,
       [this](uint32_t response, GVariant*) {
         if (response != 0) {
           Fail(response == 1 ? "cancelled" : "the portal could not offer sources");
           return;
         }
         StartCast();
       });
}

void PortalScreenCast::StartCast() {
  const std::string token = "hanashi" + std::to_string(++tokens_);
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  g_variant_builder_add(&options, "{sv}", "handle_token", g_variant_new_string(token.c_str()));
  Call("Start", g_variant_new("(osa{sv})", session_.c_str(), "", &options), token,
       [this](uint32_t response, GVariant* results) {
         if (response != 0) {
           Fail(response == 1 ? "cancelled" : "the portal did not start");
           return;
         }
         GVariant* streams = g_variant_lookup_value(results, "streams", G_VARIANT_TYPE("a(ua{sv})"));
         if (streams == nullptr || g_variant_n_children(streams) == 0) {
           if (streams != nullptr) g_variant_unref(streams);
           Fail("the portal gave no stream");
           return;
         }
         GVariant* props = nullptr;
         g_variant_get_child(streams, 0, "(u@a{sv})", &node_, &props);
         g_variant_unref(props);
         g_variant_unref(streams);
         OpenRemote();
       });
}

void PortalScreenCast::OpenRemote() {
  GVariantBuilder options;
  g_variant_builder_init(&options, G_VARIANT_TYPE_VARDICT);
  auto* pending = new Pending<int>{shared_from_this(), 0};
  g_dbus_connection_call_with_unix_fd_list(
      bus_, kPortalName, kPortalPath, kScreenCast, "OpenPipeWireRemote",
      g_variant_new("(oa{sv})", session_.c_str(), &options), G_VARIANT_TYPE("(h)"), G_DBUS_CALL_FLAGS_NONE, -1,
      nullptr, cancellable_,
      [](GObject* source, GAsyncResult* result, gpointer data) {
        std::unique_ptr<Pending<int>> pending(static_cast<Pending<int>*>(data));
        GUnixFDList* fds = nullptr;
        GError* error = nullptr;
        GVariant* reply =
            g_dbus_connection_call_with_unix_fd_list_finish(G_DBUS_CONNECTION(source), &fds, result, &error);
        if (reply == nullptr) {
          const bool cancelled = g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
          const std::string message = error->message;
          g_error_free(error);
          if (auto cast = pending->cast.lock(); cast && !cancelled) cast->Fail("OpenPipeWireRemote: " + message);
          return;
        }
        gint32 index = 0;
        g_variant_get(reply, "(h)", &index);
        g_variant_unref(reply);
        const int fd = g_unix_fd_list_get(fds, index, nullptr);
        g_object_unref(fds);
        auto cast = pending->cast.lock();
        if (!cast) {
          if (fd >= 0) close(fd);
          return;
        }
        if (fd < 0) {
          cast->Fail("the portal gave no PipeWire connection");
          return;
        }
        cast->StartStream(fd);
      },
      pending);
}

void PortalScreenCast::Fail(const std::string& error) {
  if (error != "cancelled") Log("sharing failed: " + error);
  if (auto done = std::move(done_)) {
    done_ = nullptr;
    done(false, error);
  } else {
    // Failing after it started: ended.
    TellEnded();
  }
}

void PortalScreenCast::TellEnded() {
  if (ended_told_.exchange(true)) return;
  if (ended_) ended_();
}

void PortalScreenCast::CloseSession() {
  if (session_.empty() || bus_ == nullptr) return;
  g_dbus_connection_call(bus_, kPortalName, session_.c_str(), kSession, "Close", nullptr, nullptr,
                         G_DBUS_CALL_FLAGS_NONE, -1, nullptr, nullptr, nullptr);
  session_.clear();
}

// PipeWire

void PortalScreenCast::StartStream(int fd) {
  const PipeWireApi* api = PipeWireApi::Get();
  if (api == nullptr) {
    close(fd);
    Fail("PipeWire is not there");
    return;
  }
  pw_ = std::make_unique<PipeWire>();
  pw_->api = api;
  pw_->loop = api->thread_loop_new("hanashi-screencast", nullptr);
  pw_->context = api->context_new(api->thread_loop_get_loop(pw_->loop), nullptr, 0);
  if (pw_->loop == nullptr || pw_->context == nullptr || api->thread_loop_start(pw_->loop) < 0) {
    close(fd);
    Fail("PipeWire did not start");
    return;
  }
  api->thread_loop_lock(pw_->loop);
  pw_->core = api->context_connect_fd(pw_->context, fd, nullptr, 0);
  if (pw_->core == nullptr) {
    api->thread_loop_unlock(pw_->loop);
    Fail("could not connect to PipeWire");
    return;
  }
  pw_->stream = api->stream_new(pw_->core, "Hanashi screen",
                                api->properties_new(PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_CATEGORY, "Capture",
                                                    PW_KEY_MEDIA_ROLE, "Screen", nullptr));
  static const pw_stream_events events = [] {
    pw_stream_events e{};
    e.version = PW_VERSION_STREAM_EVENTS;
    e.state_changed = [](void* data, pw_stream_state, pw_stream_state state, const char* error) {
      auto* cast = static_cast<PortalScreenCast*>(data);
      if (state == PW_STREAM_STATE_ERROR || state == PW_STREAM_STATE_UNCONNECTED) {
        Log(std::string("stream ") + StateName(state) + (error != nullptr ? std::string(": ") + error : ""));
        cast->TellEnded();
      }
    };
    e.param_changed = [](void* data, uint32_t id, const spa_pod* param) {
      if (id == SPA_PARAM_Format) static_cast<PortalScreenCast*>(data)->OnFormat(param);
    };
    e.process = [](void* data) { static_cast<PortalScreenCast*>(data)->OnProcess(); };
    return e;
  }();
  api->stream_add_listener(pw_->stream, &pw_->listener, &events, this);
  uint8_t buffer[1024];
  spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
  const spa_pod* params[] = {BuildFormat(&b)};
  const int connected = api->stream_connect(
      pw_->stream, PW_DIRECTION_INPUT, node_,
      static_cast<pw_stream_flags>(PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS), params, 1);
  api->thread_loop_unlock(pw_->loop);
  if (connected < 0) {
    Fail("could not connect to the shared stream");
    return;
  }
  repeater_ = std::thread([this] { Repeat(); });
  Log("sharing node " + std::to_string(node_));
  if (auto done = std::move(done_)) {
    done_ = nullptr;
    done(true, "");
  }
}

void PortalScreenCast::StopStream() {
  {
    std::lock_guard<std::mutex> lock(last_mutex_);
    stopping_ = true;
  }
  repeat_cv_.notify_all();
  if (repeater_.joinable()) repeater_.join();
  if (!pw_) return;
  const PipeWireApi* api = pw_->api;
  if (pw_->loop != nullptr) api->thread_loop_stop(pw_->loop);
  if (pw_->stream != nullptr) {
    spa_hook_remove(&pw_->listener);
    api->stream_disconnect(pw_->stream);
    api->stream_destroy(pw_->stream);
  }
  if (pw_->core != nullptr) api->core_disconnect(pw_->core);
  if (pw_->context != nullptr) api->context_destroy(pw_->context);
  if (pw_->loop != nullptr) api->thread_loop_destroy(pw_->loop);
  pw_.reset();
}

void PortalScreenCast::OnFormat(const spa_pod* param) {
  if (param == nullptr) return;
  spa_video_info_raw info{};
  if (spa_format_video_raw_parse(param, &info) < 0) return;
  format_ = info.format;
  width_ = static_cast<int>(info.size.width);
  height_ = static_cast<int>(info.size.height);
  Log("format " + std::to_string(format_) + ", " + std::to_string(width_) + "x" + std::to_string(height_));
  uint8_t buffer[1024];
  spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
  const spa_pod* params[] = {
      static_cast<const spa_pod*>(spa_pod_builder_add_object(
          &b, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,  //
          SPA_PARAM_BUFFERS_dataType, SPA_POD_CHOICE_FLAGS_Int((1 << SPA_DATA_MemPtr) | (1 << SPA_DATA_MemFd)))),
      static_cast<const spa_pod*>(spa_pod_builder_add_object(
          &b, SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta,  //
          SPA_PARAM_META_type, SPA_POD_Id(SPA_META_VideoCrop),
          SPA_PARAM_META_size, SPA_POD_Int(sizeof(spa_meta_region)))),
  };
  pw_->api->stream_update_params(pw_->stream, params, 2);
}

void PortalScreenCast::OnProcess() {
  const PipeWireApi* api = pw_->api;
  // The newest only: older ones go back at once.
  pw_buffer* newest = nullptr;
  while (pw_buffer* next = api->stream_dequeue_buffer(pw_->stream)) {
    if (newest != nullptr) api->stream_queue_buffer(pw_->stream, newest);
    newest = next;
  }
  if (newest == nullptr) return;
  spa_buffer* buffer = newest->buffer;
  const spa_data& data = buffer->datas[0];
  const int64_t now = NowUs();
  const bool due = now - last_push_us_ >= static_cast<int64_t>(1e6 / max_fps_) - 2000;
  if (due && data.data != nullptr && data.chunk != nullptr && data.chunk->size > 0 &&
      (data.chunk->flags & SPA_CHUNK_FLAG_CORRUPTED) == 0 && width_ > 0 && height_ > 0) {
    int x = 0, y = 0, width = width_, height = height_;
    auto* crop = static_cast<spa_meta_region*>(
        spa_buffer_find_meta_data(buffer, SPA_META_VideoCrop, sizeof(spa_meta_region)));
    if (crop != nullptr && spa_meta_region_is_valid(crop)) {
      x = crop->region.position.x;
      y = crop->region.position.y;
      width = static_cast<int>(crop->region.size.width);
      height = static_cast<int>(crop->region.size.height);
    }
    const int stride = data.chunk->stride > 0 ? data.chunk->stride : width_ * 4;
    width = std::min(width, width_ - x);
    height = std::min(height, height_ - y);
    if (width >= 2 && height >= 2) {
      Push(static_cast<const uint8_t*>(data.data) + data.chunk->offset, stride, x, y, width, height);
      last_push_us_ = now;
    }
  }
  api->stream_queue_buffer(pw_->stream, newest);
}

void PortalScreenCast::Push(const uint8_t* pixels, int stride, int x0, int y0, int width, int height) {
  // I420 (BT.601, limited range), in even sizes.
  width &= ~1;
  height &= ~1;
  int r = 2, g = 1, b = 0, bytes = 4;  // BGRx, BGRA
  switch (format_) {
    case SPA_VIDEO_FORMAT_RGBx:
    case SPA_VIDEO_FORMAT_RGBA:
      r = 0, g = 1, b = 2;
      break;
    case SPA_VIDEO_FORMAT_RGB:
      r = 0, g = 1, b = 2, bytes = 3;
      break;
    case SPA_VIDEO_FORMAT_BGR:
      bytes = 3;
      break;
    default:
      break;
  }
  std::lock_guard<std::mutex> lock(last_mutex_);
  const int chroma_width = width / 2;
  y_.resize(static_cast<size_t>(width) * height);
  u_.resize(static_cast<size_t>(chroma_width) * (height / 2));
  v_.resize(u_.size());
  for (int row = 0; row < height; row += 2) {
    const uint8_t* line0 = pixels + static_cast<size_t>(y0 + row) * stride + static_cast<size_t>(x0) * bytes;
    const uint8_t* line1 = line0 + stride;
    uint8_t* out0 = &y_[static_cast<size_t>(row) * width];
    uint8_t* out1 = out0 + width;
    uint8_t* out_u = &u_[static_cast<size_t>(row / 2) * chroma_width];
    uint8_t* out_v = &v_[static_cast<size_t>(row / 2) * chroma_width];
    for (int col = 0; col < width; col += 2) {
      int sum_r = 0, sum_g = 0, sum_b = 0;
      for (int dy = 0; dy < 2; dy++) {
        const uint8_t* p = (dy == 0 ? line0 : line1) + static_cast<size_t>(col) * bytes;
        uint8_t* out = (dy == 0 ? out0 : out1) + col;
        for (int dx = 0; dx < 2; dx++, p += bytes) {
          const int pr = p[r], pg = p[g], pb = p[b];
          out[dx] = static_cast<uint8_t>(((66 * pr + 129 * pg + 25 * pb + 128) >> 8) + 16);
          sum_r += pr;
          sum_g += pg;
          sum_b += pb;
        }
      }
      sum_r /= 4;
      sum_g /= 4;
      sum_b /= 4;
      out_u[col / 2] = static_cast<uint8_t>(((-38 * sum_r - 74 * sum_g + 112 * sum_b + 128) >> 8) + 128);
      out_v[col / 2] = static_cast<uint8_t>(((112 * sum_r - 94 * sum_g - 18 * sum_b + 128) >> 8) + 128);
    }
  }
  last_width_ = width;
  last_height_ = height;
  last_frame_us_ = NowUs();
  source_->OnCapturedFrame(libwebrtc::RTCVideoFrame::Create(width, height, y_.data(), width, u_.data(),
                                                             chroma_width, v_.data(), chroma_width));
}

void PortalScreenCast::Repeat() {
  std::unique_lock<std::mutex> lock(last_mutex_);
  while (!stopping_) {
    repeat_cv_.wait_for(lock, std::chrono::milliseconds(500));
    if (stopping_) break;
    // A still screen sends nothing new: the last frame again, for those who
    // join meanwhile (or whose decoder asks for a key frame).
    if (last_width_ > 0 && NowUs() - last_frame_us_ >= 900000) {
      last_frame_us_ = NowUs();
      source_->OnCapturedFrame(libwebrtc::RTCVideoFrame::Create(last_width_, last_height_, y_.data(), last_width_,
                                                                 u_.data(), last_width_ / 2, v_.data(),
                                                                 last_width_ / 2));
    }
  }
}

}  // namespace hanashi
