// Hanashi: sharing a screen or a window on Wayland, through the desktop
// portal (org.freedesktop.portal.ScreenCast) and PipeWire, into a WebRTC
// video source of our own.
//
// libwebrtc's PipeWire capturer, as flutter_webrtc 1.6.3 bundles it, asks
// the portal for screens only, and flutter_webrtc starts two portal sessions
// for one share (a source list, then the capturer): two dialogs, and no
// windows. This asks once, for a screen or a window, as browsers do. See
// flutter_screen_capture.cc beside this file for where it is used.

#ifndef HANASHI_PORTAL_SCREEN_CAST_H_
#define HANASHI_PORTAL_SCREEN_CAST_H_

#include <gio/gio.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "rtc_video_source.h"

struct spa_pod;

namespace hanashi {

class PortalScreenCast : public std::enable_shared_from_this<PortalScreenCast> {
 public:
  // Whether sharing goes this way: a Wayland session, its portal on the
  // session bus, and PipeWire's library to load.
  static bool Available();

  // Once the user chose (ok), or did not, or it failed: `error` is
  // "cancelled" when the user said no.
  using Done = std::function<void(bool ok, const std::string& error)>;

  // The share ended without being asked to: the system's own "Stop
  // sharing", or the stream failing. Called on any thread, once.
  using Ended = std::function<void()>;

  PortalScreenCast(libwebrtc::scoped_refptr<libwebrtc::RTCVideoSource> source, bool cursor, double max_fps);
  ~PortalScreenCast();

  // Asks the portal, which shows its dialog. Call on the main thread (the
  // GLib main loop's), through a shared_ptr; `done` comes there too.
  void Start(Done done, Ended ended);

 private:
  struct PipeWire;

  void Call(const char* method, GVariant* parameters, const std::string& token,
            std::function<void(uint32_t response, GVariant* results)> next);
  void SelectSources();
  void StartCast();
  void OpenRemote();
  void Fail(const std::string& error);
  void TellEnded();
  void CloseSession();

  void StartStream(int fd);
  void StopStream();
  void OnFormat(const ::spa_pod* param);
  void OnProcess();
  void Repeat();
  void Push(const uint8_t* pixels, int stride, int x, int y, int width, int height);

  libwebrtc::scoped_refptr<libwebrtc::RTCVideoSource> source_;
  const bool cursor_;
  const double max_fps_;

  GDBusConnection* bus_ = nullptr;
  GCancellable* cancellable_ = nullptr;
  std::string sender_;
  std::string session_;
  guint closed_subscription_ = 0;
  uint32_t node_ = 0;
  uint32_t types_ = 1;
  uint32_t cursor_mode_ = 1;
  int tokens_ = 0;
  Done done_;
  Ended ended_;
  std::atomic<bool> ended_told_{false};

  // On PipeWire's thread from here on.
  std::unique_ptr<PipeWire> pw_;
  uint32_t format_ = 0;
  int width_ = 0;
  int height_ = 0;
  int64_t last_push_us_ = 0;

  // The last frame, sent again now and then for those who join late (a
  // still screen sends no new frames).
  std::mutex last_mutex_;
  std::vector<uint8_t> y_, u_, v_;
  int last_width_ = 0;
  int last_height_ = 0;
  int64_t last_frame_us_ = 0;
  std::thread repeater_;
  std::condition_variable repeat_cv_;
  bool stopping_ = false;
};

}  // namespace hanashi

#endif  // HANASHI_PORTAL_SCREEN_CAST_H_
