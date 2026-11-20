// HANASHI: flutter_webrtc 1.6.3's common/cpp/src/flutter_screen_capture.cc,
// built in its place by linux/CMakeLists.txt (which checks the original is
// the same version). Changes are marked HANASHI: on Wayland, a screen or a
// window is shared through one desktop portal session of our own
// (portal_screen_cast.h), and sources are never listed there; a share's
// sound is what apps play, never Hanashi's own (pipewire_app_sound.h). And
// the microphone's voice gate is attached here (voice_gate.h), where the
// plugin's insides can be reached.

#include "flutter_screen_capture.h"
#include "flutter_utf8_sanitize.h"

#ifdef HANASHI_PORTAL_SCREENCAST
#include <cstdlib>
#include <map>
#include <memory>

#include "pipewire_app_sound.h"
#include "portal_screen_cast.h"
#endif

#ifdef HANASHI_VOICE_GATE
#include "voice_gate.h"
#endif

#include "task_runner.h"

#include <chrono>
#include <stdexcept>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace flutter_webrtc_plugin {

namespace {

// Waits, for a bounded time, until `capturer` holds the only reference left,
// so that the capturer is destroyed on the calling thread when this returns
// rather than on whichever thread happens to let go of it last. Callers move
// their reference in, so that `capturer` is the caller's only one.
void ReleaseOnCurrentThread(scoped_refptr<RTCDesktopCapturer> capturer) {
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (std::chrono::steady_clock::now() < deadline) {
    // AddRef returns the new count, so 2 means `capturer` is the only owner.
    const int count = capturer->AddRef();
    capturer->Release();
    if (count <= 2) {
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
}

#ifdef HANASHI_PORTAL_SCREENCAST
// HANASHI: a Wayland session, where libwebrtc's listing of windows crashes.
bool IsWayland() {
  const char* session = std::getenv("XDG_SESSION_TYPE");
  return session != nullptr && std::string(session) == "wayland";
}

// HANASHI: whether screens and windows are shared through our own portal
// session (asked once).
bool UsePortal() {
  static const bool use = IsWayland() && hanashi::PortalScreenCast::Available();
  return use;
}

// HANASHI: the shares of a FlutterScreenCapture through the portal, by
// track ID, and the channel the app talks to them on ("hanashi/screencast"):
// "stop" {trackId} from the app, also for a share of flutter_webrtc's own
// (its sound stops), "ended" {trackId} to it; and for a share's sound,
// "canShareSound", "soundApps" (the apps playing, [{id, name}]) and
// "soundFrom" {app} (one app's id, or empty for every app's).
struct PortalShares {
  std::unique_ptr<MethodChannel> channel;
  std::map<std::string, std::shared_ptr<hanashi::PortalScreenCast>> pending;
  std::map<std::string, std::shared_ptr<hanashi::PortalScreenCast>> casts;
};

std::map<const void*, std::unique_ptr<PortalShares>>& AllPortalShares() {
  static auto* all = new std::map<const void*, std::unique_ptr<PortalShares>>();
  return *all;
}

// HANASHI: a share's sound stops, on the platform thread, where the app's
// channel asks after it.
void StopSound(std::unique_ptr<LoopbackCapturer>& capturer, scoped_refptr<RTCAudioSource>& source) {
  if (capturer) {
    capturer->Stop();
    capturer.reset();
  }
  source = nullptr;
}
#endif

}  // namespace

// libwebrtc keeps raw pointers to its media list and capturer observers. It
// checks them on one thread and calls them on the signaling thread, without
// synchronization, and it can still call them while the plugin is torn down
// (for example, a thumbnail finishing, or a capturer stopping when the
// factory is released). Clearing the pointer with DeRegister...Observer() is
// not safe for the same reason. So libwebrtc is given this proxy instead of
// the FlutterScreenCapture itself. Detach() turns every later call into a
// no-op, and the proxy is intentionally never freed.
class FlutterScreenCapture::ObserverProxy : public MediaListObserver,
                                            public DesktopCapturerObserver {
 public:
  explicit ObserverProxy(FlutterScreenCapture* target) : target_(target) {}

  // Waits for a call in progress to return.
  void Detach() {
    std::lock_guard<std::mutex> lock(mutex_);
    target_ = nullptr;
  }

  void OnMediaSourceAdded(scoped_refptr<MediaSource> source) override {
    std::lock_guard<std::mutex> lock(mutex_);
    if (target_) {
      target_->OnMediaSourceAdded(source);
    }
  }

  void OnMediaSourceRemoved(scoped_refptr<MediaSource> source) override {
    std::lock_guard<std::mutex> lock(mutex_);
    if (target_) {
      target_->OnMediaSourceRemoved(source);
    }
  }

  void OnMediaSourceNameChanged(scoped_refptr<MediaSource> source) override {
    std::lock_guard<std::mutex> lock(mutex_);
    if (target_) {
      target_->OnMediaSourceNameChanged(source);
    }
  }

  void OnMediaSourceThumbnailChanged(
      scoped_refptr<MediaSource> source) override {
    std::lock_guard<std::mutex> lock(mutex_);
    if (target_) {
      target_->OnMediaSourceThumbnailChanged(source);
    }
  }

  void OnStart(scoped_refptr<RTCDesktopCapturer> capturer) override {
    std::lock_guard<std::mutex> lock(mutex_);
    if (target_) {
      target_->OnStart(capturer);
    }
  }

  void OnPaused(scoped_refptr<RTCDesktopCapturer> capturer) override {
    std::lock_guard<std::mutex> lock(mutex_);
    if (target_) {
      target_->OnPaused(capturer);
    }
  }

  void OnStop(scoped_refptr<RTCDesktopCapturer> capturer) override {
    std::lock_guard<std::mutex> lock(mutex_);
    if (target_) {
      target_->OnStop(capturer);
    }
  }

  void OnError(scoped_refptr<RTCDesktopCapturer> capturer) override {
    std::lock_guard<std::mutex> lock(mutex_);
    if (target_) {
      target_->OnError(capturer);
    }
  }

 private:
  std::mutex mutex_;
  FlutterScreenCapture* target_;
};

FlutterScreenCapture::FlutterScreenCapture(FlutterWebRTCBase* base)
    : base_(base), observer_proxy_(new ObserverProxy(this)) {
  // Started here rather than in the initializer list, so that every member
  // the loop uses is constructed first.
  worker_thread_ = std::thread([this] { WorkerLoop(); });
#ifdef HANASHI_VOICE_GATE
  // HANASHI: the voice gate's channel, from the start; WebRTC's audio
  // processing is asked for only once the app configures the gate.
  hanashi::AttachVoiceGate(base_->messenger_, base_->task_runner_,
                            [base = base_] { return base->audio_processing(); });
#endif
#ifdef HANASHI_PORTAL_SCREENCAST
  // HANASHI: the channel, from the start (the app asks whether a share
  // can have sound before it shares), for shares through the portal and for
  // flutter_webrtc's own (X11) alike.
  auto& shares = AllPortalShares()[this];
  if (!shares) {
    shares = std::make_unique<PortalShares>();
    shares->channel = std::make_unique<MethodChannel>(
        base_->messenger_, "hanashi/screencast",
        &flutter::StandardMethodCodec::GetInstance());
    shares->channel->SetMethodCallHandler(
        [this](const MethodCall& call,
               std::unique_ptr<flutter::MethodResult<EncodableValue>> reply) {
          auto found = AllPortalShares().find(this);
          const auto* args = std::get_if<EncodableMap>(call.arguments());
          // Every loopback capturer here is one (see start_sound below).
          auto* sound = static_cast<hanashi::PipeWireAppSound*>(loopback_capturer_.get());
          if (call.method_name() == "stop" && found != AllPortalShares().end() &&
              args != nullptr) {
            found->second->casts.erase(findString(*args, "trackId"));
            StopSound(loopback_capturer_, loopback_audio_source_);
            reply->Success();
          } else if (call.method_name() == "canShareSound") {
            reply->Success(EncodableValue(hanashi::PipeWireAppSound::Available()));
          } else if (call.method_name() == "soundApps") {
            EncodableList apps;
            if (sound != nullptr) {
              for (const auto& app : sound->Apps()) {
                apps.push_back(EncodableValue(EncodableMap{
                    {EncodableValue("id"), EncodableValue(app.id)},
                    {EncodableValue("name"), EncodableValue(app.name)}}));
              }
            }
            reply->Success(EncodableValue(apps));
          } else if (call.method_name() == "soundFrom" && args != nullptr) {
            if (sound != nullptr) sound->SetApp(findString(*args, "app"));
            reply->Success();
          } else {
            reply->NotImplemented();
          }
        });
  }
#endif
}

FlutterScreenCapture::~FlutterScreenCapture() {
  closing_ = true;
#ifdef HANASHI_VOICE_GATE
  hanashi::DetachVoiceGate();
#endif
#ifdef HANASHI_PORTAL_SCREENCAST
  // HANASHI: our portal shares stop, and their portal sessions close.
  AllPortalShares().erase(this);
#endif

  // From here on libwebrtc callbacks no longer reach this object.
  observer_proxy_->Detach();

  // Stop the capturers that are still running, so that their capture loops
  // end now. They are destroyed later, when the factory is released, and
  // that joins each capture thread.
  std::vector<scoped_refptr<RTCDesktopCapturer>> capturers;
  {
    std::lock_guard<std::mutex> lock(capturers_mutex_);
    capturers.swap(active_capturers_);
  }
  for (auto& capturer : capturers) {
    capturer->Stop();
  }

  StopWorker();
}

void FlutterScreenCapture::StopWorker() {
  {
    std::lock_guard<std::mutex> lock(worker_mutex_);
    worker_stopping_ = true;
  }
  worker_cv_.notify_all();
#ifdef _WIN32
  // The task in progress may be enumerating or capturing windows of this
  // process, which sends messages to this thread and waits for the answer.
  // Keep answering sent messages until the worker is done. Posted messages
  // are left in the queue.
  while (!worker_exited_) {
    MsgWaitForMultipleObjects(0, nullptr, FALSE, 10, QS_SENDMESSAGE);
    MSG msg;
    PeekMessage(&msg, nullptr, 0, 0, PM_NOREMOVE | PM_QS_SENDMESSAGE);
  }
#endif
  if (worker_thread_.joinable()) {
    worker_thread_.join();
  }
}

void FlutterScreenCapture::PostToWorker(std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(worker_mutex_);
    if (worker_stopping_) {
      return;
    }
    worker_tasks_.push_back(std::move(task));
  }
  worker_cv_.notify_one();
}

void FlutterScreenCapture::WorkerLoop() {
  for (;;) {
    std::function<void()> task;
    {
      std::unique_lock<std::mutex> lock(worker_mutex_);
      worker_cv_.wait(
          lock, [this] { return worker_stopping_ || !worker_tasks_.empty(); });
      if (worker_stopping_) {
        break;
      }
      task = std::move(worker_tasks_.front());
      worker_tasks_.pop_front();
    }
    task();
  }
  // Drop the tasks still queued on this thread rather than the destructor's.
  // A queued task may hold the last reference to a stopped capturer, and
  // releasing that reference joins the capturer's thread.
  std::deque<std::function<void()>> dropped;
  {
    std::lock_guard<std::mutex> lock(worker_mutex_);
    dropped.swap(worker_tasks_);
  }
  dropped.clear();
  worker_exited_ = true;
}

void FlutterScreenCapture::PostResult(std::function<void()> reply) {
  if (closing_) {
    return;
  }
  if (base_->task_runner_) {
    base_->task_runner_->EnqueueTask(std::move(reply));
  } else {
    reply();
  }
}

std::vector<scoped_refptr<MediaSource>>
FlutterScreenCapture::SourcesSnapshot() {
  std::lock_guard<std::mutex> lock(sources_mutex_);
  return sources_;
}

scoped_refptr<MediaSource> FlutterScreenCapture::FindSource(
    const std::string& source_id) {
  std::lock_guard<std::mutex> lock(sources_mutex_);
  scoped_refptr<MediaSource> source;
  for (auto src : sources_) {
    if (src->id().std_string() == source_id) {
      source = src;
    }
  }
  return source;
}

bool FlutterScreenCapture::BuildDesktopSourcesList(const EncodableList& types,
                                                   bool force_reload) {
  std::lock_guard<std::mutex> build_lock(build_mutex_);
  size_t size = types.size();
  std::vector<scoped_refptr<MediaSource>> sources;
  // Publishes whatever was built so far, also when an unknown type stops the
  // build early, as the list was always left that way before.
  auto publish = [this, &sources]() {
    std::lock_guard<std::mutex> lock(sources_mutex_);
    sources_ = std::move(sources);
  };
  for (size_t i = 0; i < size; i++) {
    std::string type_str = GetValue<std::string>(types[i]);
    DesktopType desktop_type = DesktopType::kScreen;
    if (type_str == "screen") {
      desktop_type = DesktopType::kScreen;
    } else if (type_str == "window") {
      desktop_type = DesktopType::kWindow;
    } else {
      publish();
      return false;
    }
    scoped_refptr<RTCDesktopMediaList> source_list;
    auto it = medialist_.find(desktop_type);
    if (it != medialist_.end()) {
      source_list = (*it).second;
    } else {
      source_list = base_->desktop_device_->GetDesktopMediaList(desktop_type);
      source_list->RegisterMediaListObserver(observer_proxy_);
      medialist_[desktop_type] = source_list;
    }
#ifdef __linux__
    try {
      source_list->UpdateSourceList(force_reload, false);
    } catch (...) {
      continue;
    }
#else
    source_list->UpdateSourceList(force_reload, false);
#endif
    int count = source_list->GetSourceCount();
    for (int j = 0; j < count; j++) {
      sources.push_back(source_list->GetSource(j));
    }
  }
  publish();
  return true;
}

void FlutterScreenCapture::GetDesktopSources(
    const EncodableList& types,
    std::unique_ptr<MethodResultProxy> result) {
#ifdef HANASHI_PORTAL_SCREENCAST
  // HANASHI: none on Wayland, where the portal's dialog picks (and listing
  // windows crashes libwebrtc).
  if (IsWayland()) {
    EncodableMap none;
    none[EncodableValue("sources")] = EncodableValue(EncodableList());
    result->Success(EncodableValue(none));
    return;
  }
#endif
  std::shared_ptr<MethodResultProxy> shared_result(std::move(result));
  PostToWorker([this, types, shared_result]() {
    if (!BuildDesktopSourcesList(types, true)) {
      PostResult([shared_result]() {
        shared_result->Error("Bad Arguments", "Failed to get desktop sources");
      });
      return;
    }

    EncodableList sources;
    for (auto source : SourcesSnapshot()) {
      EncodableMap info;
      info[EncodableValue("id")] = EncodableValue(source->id().std_string());
      info[EncodableValue("name")] =
          EncodableValue(SanitizeUtf8ForFlutter(source->name().std_string()));
      info[EncodableValue("type")] =
          EncodableValue(source->type() == kWindow ? "window" : "screen");
      // TODO "thumbnailSize"
      info[EncodableValue("thumbnailSize")] = EncodableMap{
          {EncodableValue("width"), EncodableValue(0)},
          {EncodableValue("height"), EncodableValue(0)},
      };
      sources.push_back(EncodableValue(info));
    }

    auto map = EncodableMap();
    map[EncodableValue("sources")] = sources;
    PostResult([shared_result, map]() {
      shared_result->Success(EncodableValue(map));
    });
  });
}

void FlutterScreenCapture::UpdateDesktopSources(
    const EncodableList& types,
    std::unique_ptr<MethodResultProxy> result) {
  std::shared_ptr<MethodResultProxy> shared_result(std::move(result));
  PostToWorker([this, types, shared_result]() {
    if (!BuildDesktopSourcesList(types, false)) {
      PostResult([shared_result]() {
        shared_result->Error("Bad Arguments",
                             "Failed to update desktop sources");
      });
      return;
    }
    auto map = EncodableMap();
    map[EncodableValue("result")] = true;
    PostResult([shared_result, map]() {
      shared_result->Success(EncodableValue(map));
    });
  });
}

void FlutterScreenCapture::OnMediaSourceAdded(
    scoped_refptr<MediaSource> source) {
  EncodableMap info;
  info[EncodableValue("event")] = "desktopSourceAdded";
  info[EncodableValue("id")] = EncodableValue(source->id().std_string());
  info[EncodableValue("name")] =
      EncodableValue(SanitizeUtf8ForFlutter(source->name().std_string()));
  info[EncodableValue("type")] =
      EncodableValue(source->type() == kWindow ? "window" : "screen");
  // TODO "thumbnailSize"
  info[EncodableValue("thumbnailSize")] = EncodableMap{
      {EncodableValue("width"), EncodableValue(0)},
      {EncodableValue("height"), EncodableValue(0)},
  };
  base_->event_channel()->Success(EncodableValue(info));
}

void FlutterScreenCapture::OnMediaSourceRemoved(
    scoped_refptr<MediaSource> source) {
  EncodableMap info;
  info[EncodableValue("event")] = "desktopSourceRemoved";
  info[EncodableValue("id")] = EncodableValue(source->id().std_string());
  base_->event_channel()->Success(EncodableValue(info));
}

void FlutterScreenCapture::OnMediaSourceNameChanged(
    scoped_refptr<MediaSource> source) {
  EncodableMap info;
  info[EncodableValue("event")] = "desktopSourceNameChanged";
  info[EncodableValue("id")] = EncodableValue(source->id().std_string());
  info[EncodableValue("name")] =
      EncodableValue(SanitizeUtf8ForFlutter(source->name().std_string()));
  base_->event_channel()->Success(EncodableValue(info));
}

void FlutterScreenCapture::OnMediaSourceThumbnailChanged(
    scoped_refptr<MediaSource> source) {
  EncodableMap info;
  info[EncodableValue("event")] = "desktopSourceThumbnailChanged";
  info[EncodableValue("id")] = EncodableValue(source->id().std_string());
  info[EncodableValue("thumbnail")] =
      EncodableValue(source->thumbnail().std_vector());
  base_->event_channel()->Success(EncodableValue(info));
}

void FlutterScreenCapture::OnStart(scoped_refptr<RTCDesktopCapturer> capturer) {
}

void FlutterScreenCapture::OnPaused(
    scoped_refptr<RTCDesktopCapturer> capturer) {}

void FlutterScreenCapture::OnStop(scoped_refptr<RTCDesktopCapturer> capturer) {
#ifdef HANASHI_PORTAL_SCREENCAST
  // HANASHI: the sound is not stopped here, on whatever thread this comes
  // on, but by the app ("stop" on the channel), on the platform thread.
#else
  if (loopback_capturer_) {
    loopback_capturer_->Stop();
    loopback_capturer_.reset();
    loopback_audio_source_ = nullptr;
  }
#endif

  // The capturer is stopping, typically from its track source's destructor,
  // which is about to drop its own reference. Hand ours to the worker thread
  // so the final release, which joins the capturer's thread, happens there.
  scoped_refptr<RTCDesktopCapturer> retired;
  {
    std::lock_guard<std::mutex> lock(capturers_mutex_);
    for (auto it = active_capturers_.begin(); it != active_capturers_.end();
         ++it) {
      if (it->get() == capturer.get()) {
        retired = *it;
        active_capturers_.erase(it);
        break;
      }
    }
  }
  if (retired.get()) {
    PostToWorker([retired]() mutable {
      ReleaseOnCurrentThread(std::move(retired));
    });
  }
}

void FlutterScreenCapture::OnError(scoped_refptr<RTCDesktopCapturer> capturer) {
}

void FlutterScreenCapture::GetDesktopSourceThumbnail(
    std::string source_id,
    int width,
    int height,
    std::unique_ptr<MethodResultProxy> result) {
  (void)width;
  (void)height;
  std::shared_ptr<MethodResultProxy> shared_result(std::move(result));
  PostToWorker([this, source_id, shared_result]() {
    scoped_refptr<MediaSource> source = FindSource(source_id);
    if (source.get() == nullptr) {
      PostResult([shared_result]() {
        shared_result->Error("Bad Arguments",
                             "Failed to get desktop source thumbnail");
      });
      return;
    }
    source->UpdateThumbnail();
    EncodableValue thumbnail(source->thumbnail().std_vector());
    PostResult(
        [shared_result, thumbnail]() { shared_result->Success(thumbnail); });
  });
}

void FlutterScreenCapture::GetDisplayMedia(
    const EncodableMap& constraints,
    std::unique_ptr<MethodResultProxy> result) {
  std::string source_id = "0";
  // DesktopType source_type = kScreen;
  double fps = 30.0;
  // Whether the OS cursor is composited into the captured frames, driven by the
  // getDisplayMedia "cursor" video constraint. Defaults to true so behaviour is
  // unchanged when the constraint is absent — that is libwebrtc's own default.
  bool show_cursor = true;

  const EncodableMap video = findMap(constraints, "video");
  if (video != EncodableMap()) {
    const EncodableMap deviceId = findMap(video, "deviceId");
    if (deviceId != EncodableMap()) {
      source_id = findString(deviceId, "exact");
      if (source_id.empty()) {
        result->Error("Bad Arguments", "Incorrect video->deviceId->exact");
        return;
      }
      if (source_id != "0") {
        // source_type = DesktopType::kWindow;
      }
    }
    const EncodableMap mandatory = findMap(video, "mandatory");
    if (mandatory != EncodableMap()) {
      double frameRate = findDouble(mandatory, "frameRate");
      if (frameRate != 0.0) {
        fps = frameRate;
      }
    }
    // Accept both the spec's string form ("always"/"never") and a plain bool.
    // Only an explicitly supplied constraint moves off the default, so callers
    // that pass no "cursor" key keep exactly the behaviour they have today.
    const std::string cursor = findString(video, "cursor");
    if (!cursor.empty()) {
      show_cursor = (cursor == "always");
    } else if (video.find(EncodableValue("cursor")) != video.end()) {
      show_cursor = findBoolean(video, "cursor");
    }
  }

  std::string uuid = base_->GenerateUUID();

  scoped_refptr<RTCMediaStream> stream =
      base_->factory_->CreateStream(uuid.c_str());

  EncodableMap params;
  params[EncodableValue("streamId")] = EncodableValue(uuid);

  // AUDIO

  bool capture_audio = false;
  {
    auto audio_it = constraints.find(EncodableValue("audio"));
    if (audio_it != constraints.end()) {
      if (TypeIs<bool>(audio_it->second)) {
        capture_audio = GetValue<bool>(audio_it->second);
      } else if (TypeIs<EncodableMap>(audio_it->second)) {
        capture_audio = true;
      }
    }
  }

#ifdef HANASHI_PORTAL_SCREENCAST
  // HANASHI: a share's sound is what apps play, through PipeWire
  // (pipewire_app_sound.h), never the default output's monitor, which
  // carries the call too. It starts once the screen is shared (after the
  // portal's dialog on Wayland); the last share's stops now.
  StopSound(loopback_capturer_, loopback_audio_source_);
  params[EncodableValue("audioTracks")] = EncodableValue(EncodableList());
  auto start_sound = [this, capture_audio](scoped_refptr<RTCMediaStream> stream,
                                           EncodableMap& params) {
    if (!capture_audio || !hanashi::PipeWireAppSound::Available()) return;
    // A custom source's sound goes out as it is: no audio processing touches
    // it (echo cancelling, noise suppression and gain control work on the
    // microphone's). But WebRTC applies the options of each track it sends to
    // that one processor, so these are the microphone's (the app asks for all
    // three): "off" here would turn them off for the microphone while the
    // screen is shared.
    RTCAudioOptions options;
    options.echo_cancellation = true;
    options.auto_gain_control = true;
    options.noise_suppression = true;
    const std::string label = "screen_loopback_input_" + base_->GenerateUUID();
    scoped_refptr<RTCAudioSource> source = base_->factory_->CreateAudioSource(
        label.c_str(), RTCAudioSource::SourceType::kCustom, options);
    auto sound = std::make_unique<hanashi::PipeWireAppSound>();
    if (!sound->Start(source)) return;
    std::string id = base_->GenerateUUID();
    scoped_refptr<RTCAudioTrack> track =
        base_->factory_->CreateAudioTrack(source, id.c_str());
    EncodableMap info;
    info[EncodableValue("id")] = EncodableValue(track->id().std_string());
    info[EncodableValue("label")] = EncodableValue(track->id().std_string());
    info[EncodableValue("kind")] = EncodableValue(track->kind().std_string());
    info[EncodableValue("enabled")] = EncodableValue(track->enabled());
    params[EncodableValue("audioTracks")] =
        EncodableValue(EncodableList{EncodableValue(info)});
    stream->AddTrack(track);
    base_->local_tracks_[track->id().std_string()] = track;
    loopback_audio_source_ = source;
    loopback_capturer_ = std::move(sound);
  };
#else
  if (capture_audio) {
    // Stop any previous loopback session before starting a new one.
    if (loopback_capturer_) {
      loopback_capturer_->Stop();
      loopback_capturer_.reset();
    }

    // Disable all audio processing for loopback capture.  Echo cancellation,
    // AGC, and noise suppression are designed for microphone input; applied to
    // system audio they treat the captured content as echo/noise and destroy it.
    RTCAudioOptions loopback_opts;
    loopback_opts.echo_cancellation = false;
    loopback_opts.auto_gain_control = false;
    loopback_opts.noise_suppression = false;
    const std::string loopback_source_label =
      "screen_loopback_input_" + base_->GenerateUUID();
    loopback_audio_source_ = base_->factory_->CreateAudioSource(
      loopback_source_label.c_str(), RTCAudioSource::SourceType::kCustom,
        loopback_opts);

    std::string audio_uuid = base_->GenerateUUID();
    scoped_refptr<RTCAudioTrack> audio_track =
        base_->factory_->CreateAudioTrack(loopback_audio_source_,
                                          audio_uuid.c_str());

    loopback_capturer_ = CreateLoopbackCapturer(source_id);

    if (loopback_capturer_ && loopback_capturer_->Start(loopback_audio_source_)) {
      EncodableMap audio_info;
      audio_info[EncodableValue("id")] =
          EncodableValue(audio_track->id().std_string());
      audio_info[EncodableValue("label")] =
          EncodableValue(audio_track->id().std_string());
      audio_info[EncodableValue("kind")] =
          EncodableValue(audio_track->kind().std_string());
      audio_info[EncodableValue("enabled")] =
          EncodableValue(audio_track->enabled());

      EncodableList audioTracks;
      audioTracks.push_back(EncodableValue(audio_info));
      params[EncodableValue("audioTracks")] = EncodableValue(audioTracks);

      stream->AddTrack(audio_track);
      base_->local_tracks_[audio_track->id().std_string()] = audio_track;
    } else {
      // Loopback init failed or not supported — continue without audio.
      loopback_capturer_.reset();
      loopback_audio_source_ = nullptr;
      params[EncodableValue("audioTracks")] = EncodableValue(EncodableList());
    }
  } else {
    params[EncodableValue("audioTracks")] = EncodableValue(EncodableList());
  }
#endif

  // VIDEO

  EncodableMap video_constraints;
  auto it = constraints.find(EncodableValue("video"));
  if (it != constraints.end() && TypeIs<EncodableMap>(it->second)) {
    video_constraints = GetValue<EncodableMap>(it->second);
  }

#ifdef HANASHI_PORTAL_SCREENCAST
  // HANASHI: on Wayland, one portal session of our own: its dialog offers
  // screens and windows, once. The answer comes once the user chose.
  if (UsePortal() && (source_id == "0" || source_id == "portal")) {
    auto& shares = AllPortalShares()[this];
    // The stream's ID (`uuid`), the stream and `params` are made above.
    scoped_refptr<RTCVideoSource> video_source =
        base_->factory_->CreateCustomVideoSource(
            "screen_capture_input",
            base_->ParseMediaConstraints(video_constraints));
    auto cast = std::make_shared<hanashi::PortalScreenCast>(video_source,
                                                             show_cursor, fps);
    shares->pending[uuid] = cast;
    std::shared_ptr<MethodResultProxy> shared_result(std::move(result));
    cast->Start(
        [this, uuid, video_source, params, stream, shared_result, start_sound](
            bool ok, const std::string& error) mutable {
          auto found = AllPortalShares().find(this);
          if (found == AllPortalShares().end()) return;
          auto started = found->second->pending[uuid];
          found->second->pending.erase(uuid);
          if (!ok) {
            const bool cancelled = error == "cancelled";
            shared_result->Error(
                cancelled ? "NotAllowedError" : "Bad Arguments",
                cancelled ? "The user cancelled sharing the screen"
                          : "Sharing the screen failed: " + error);
            return;
          }
          scoped_refptr<RTCVideoTrack> track =
              base_->factory_->CreateVideoTrack(video_source, uuid.c_str());
          EncodableList videoTracks;
          EncodableMap info;
          info[EncodableValue("id")] = EncodableValue(track->id().std_string());
          info[EncodableValue("label")] =
              EncodableValue(track->id().std_string());
          info[EncodableValue("kind")] =
              EncodableValue(track->kind().std_string());
          info[EncodableValue("enabled")] = EncodableValue(track->enabled());
          videoTracks.push_back(EncodableValue(info));
          params[EncodableValue("videoTracks")] = EncodableValue(videoTracks);
          stream->AddTrack(track);
          base_->local_tracks_[track->id().std_string()] = track;
          base_->video_sources_[track->id().std_string()] = {video_source};
          base_->local_streams_[uuid] = stream;
          found->second->casts[track->id().std_string()] = started;
          start_sound(stream, params);
          shared_result->Success(EncodableValue(params));
        },
        [this, uuid]() {
          // Ended by the system: the app hears of it, on the platform
          // thread, where the share is let go of too.
          PostResult([this, uuid]() {
            auto found = AllPortalShares().find(this);
            if (found == AllPortalShares().end()) return;
            found->second->casts.erase(uuid);
            StopSound(loopback_capturer_, loopback_audio_source_);
            found->second->channel->InvokeMethod(
                "ended", std::make_unique<EncodableValue>(EncodableMap{
                             {EncodableValue("trackId"), EncodableValue(uuid)}}));
          });
        });
    return;
  }
#endif

  scoped_refptr<MediaSource> source = FindSource(source_id);

#ifdef __linux__
  // If the caller didn't specify a source (source_id == "0"), fall back to
  // the first available screen. When a specific source_id was requested but
  // isn't in the (possibly stale) cached list, rebuild the list and retry
  // the match instead of silently capturing the wrong source.
  // This fallback builds the list on the platform thread. That is safe on
  // Linux, where enumerating windows does not wait on their message loops.
  {
    auto sources = SourcesSnapshot();
    if (!source.get() && !sources.empty() && source_id == "0") {
      source = sources.front();
    }
  }
  if (!source.get()) {
    EncodableList types;
    types.push_back(EncodableValue(std::string("screen")));
    BuildDesktopSourcesList(types, true);
    source = FindSource(source_id);
    auto sources = SourcesSnapshot();
    if (!source.get() && !sources.empty() && source_id == "0") {
      source = sources.front();
    }
  }
#endif

  if (!source.get()) {
    result->Error("Bad Arguments", "source not found!");
    return;
  }

  scoped_refptr<RTCDesktopCapturer> desktop_capturer =
      base_->desktop_device_->CreateDesktopCapturer(source, show_cursor);

  if (!desktop_capturer.get()) {
    result->Error("Bad Arguments", "CreateDesktopCapturer failed!");
    return;
  }

  desktop_capturer->RegisterDesktopCapturerObserver(observer_proxy_);
  {
    std::lock_guard<std::mutex> lock(capturers_mutex_);
    active_capturers_.push_back(desktop_capturer);
  }

  const char* video_source_label = "screen_capture_input";

  scoped_refptr<RTCVideoSource> video_source =
      base_->factory_->CreateDesktopSource(
          desktop_capturer, video_source_label,
          base_->ParseMediaConstraints(video_constraints));

  // TODO: RTCVideoSource -> RTCVideoTrack

  scoped_refptr<RTCVideoTrack> track =
      base_->factory_->CreateVideoTrack(video_source, uuid.c_str());

  EncodableList videoTracks;
  EncodableMap info;
  info[EncodableValue("id")] = EncodableValue(track->id().std_string());
  info[EncodableValue("label")] = EncodableValue(track->id().std_string());
  info[EncodableValue("kind")] = EncodableValue(track->kind().std_string());
  info[EncodableValue("enabled")] = EncodableValue(track->enabled());
  videoTracks.push_back(EncodableValue(info));
  params[EncodableValue("videoTracks")] = EncodableValue(videoTracks);

  stream->AddTrack(track);

  base_->local_tracks_[track->id().std_string()] = track;
  base_->video_sources_[track->id().std_string()] = {video_source};

  base_->local_streams_[uuid] = stream;

  desktop_capturer->Start(uint32_t(fps));

#ifdef HANASHI_PORTAL_SCREENCAST
  // HANASHI: the sound, now that the screen is shared.
  start_sound(stream, params);
#endif
  result->Success(EncodableValue(params));
}

}  // namespace flutter_webrtc_plugin
