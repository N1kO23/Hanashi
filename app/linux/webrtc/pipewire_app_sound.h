// Hanashi: the sound of a shared screen on Linux, from PipeWire into a
// WebRTC audio source of our own: what apps play (all of them, or one),
// never Hanashi's own.
//
// flutter_webrtc 1.6.3 records the default output's monitor instead
// (pulse_loopback_capturer.cc), which carries the call too: everyone would
// hear themselves. For the same reason this leaves out what an effects app
// such as EasyEffects plays on: apps play into its sink, and what it plays
// to the sound card has every app in it, the call too. See
// flutter_screen_capture.cc beside this file for where it is used.

#ifndef HANASHI_PIPEWIRE_APP_SOUND_H_
#define HANASHI_PIPEWIRE_APP_SOUND_H_

#include <memory>
#include <string>
#include <vector>

#include "loopback_capturer.h"

namespace hanashi {

class PipeWireAppSound : public flutter_webrtc_plugin::LoopbackCapturer {
 public:
  // Whether sound can be taken this way: PipeWire's library loads.
  static bool Available();

  // An app playing sound.
  struct App {
    std::string id;    // its binary (else its name): what SetApp takes
    std::string name;  // what it calls itself
  };

  PipeWireAppSound();
  ~PipeWireAppSound() override;

  // Starts taking sound into `source`; false if PipeWire is not there.
  bool Start(libwebrtc::scoped_refptr<libwebrtc::RTCAudioSource> source) override;
  void Stop() override;

  // The apps playing sound now, Hanashi aside.
  std::vector<App> Apps();

  // From now on only `app`'s sound (an App's id), or every app's (empty).
  void SetApp(const std::string& app);

  // Its insides, in pipewire_app_sound.cc.
  struct State;

 private:
  std::unique_ptr<State> state_;
};

}  // namespace hanashi

#endif  // HANASHI_PIPEWIRE_APP_SOUND_H_
