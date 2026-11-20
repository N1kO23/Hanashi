// Hanashi: the voice gate on the desktop (voice_gate_core.h decides).
// WebRTC hands the microphone's audio to it after its own processing (echo
// cancelling, noise suppression, gain), before encoding: what it leaves
// silent goes out as silence, and the app hears when it opens and closes.
//
// The channel "hanashi/voice":
// - from the app: "configure" {automatic, threshold, pushToTalk} (the gate
//   is on from the first one), "push" {held} (the push-to-talk key), "meter"
//   {on} (levels for Settings, 20 a second, while on), "info" (what WebRTC
//   hands it, for the log and to tell that it does);
// - to the app: "open" (bool) whenever it opens or closes, "level"
//   {level, threshold, open} while metering.
//
// See flutter_screen_capture.cc beside this file for where it is attached.

#ifndef HANASHI_VOICE_GATE_H_
#define HANASHI_VOICE_GATE_H_

#include <functional>

#include "flutter_common.h"
#include "rtc_audio_processing.h"
#include "task_runner.h"

namespace hanashi {

// Sets up the channel, once. `processing` gives WebRTC's audio processing,
// asked for only once the app configures the gate (by then WebRTC is set
// up the app's way).
void AttachVoiceGate(
    BinaryMessenger* messenger, TaskRunner* task_runner,
    std::function<libwebrtc::scoped_refptr<libwebrtc::RTCAudioProcessing>()> processing);

// The engine goes: the gate lets everything through, and tells nobody.
void DetachVoiceGate();

}  // namespace hanashi

#endif  // HANASHI_VOICE_GATE_H_
