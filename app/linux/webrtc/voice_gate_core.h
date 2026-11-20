// Hanashi: the voice gate's decisions. The microphone's audio, 10 ms at a
// time, after WebRTC's echo cancelling and noise suppression, goes out only
// while the user speaks; in between it is silence, which Opus sends as next
// to nothing. Android has a twin of this in Kotlin (VoiceGate.kt): keep the
// two the same.
//
// - It opens once three frames in a row (30 ms) reach the threshold, so that
//   a click alone does not open it, even as WebRTC's processing draws it
//   out. The audio is held back 30 ms, so what came just before goes out
//   too, and a word's first sound is not cut.
// - It stays open while the level stays within 4 dB of the threshold, and
//   for 400 ms after: words, and the pauses between them. (Not more: WebRTC
//   turns its gain up for a quiet voice, and with it the noise after.) After
//   a burst of less than 100 ms at the threshold, such as a click, only for
//   100 ms.
// - It fades in and out over 10 ms, so it never clicks.
// - Automatic: the threshold is 15 dB over the quietest the last 2 seconds
//   were (the noise around), between -55 and -30 dBFS.
// - Push to talk: open while the key is held, from the moment it is, and
//   200 ms after it is let go (the end of the last word); the level is still
//   measured, for the meter.
//
// Levels are dBFS, of a frame's mean square: 0 is the loudest a frame can be.

#ifndef HANASHI_VOICE_GATE_CORE_H_
#define HANASHI_VOICE_GATE_CORE_H_

#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <vector>

namespace hanashi {

class VoiceGateCore {
 public:
  static constexpr int kPreRoll = 3;      // frames held back
  static constexpr int kConfirm = 3;      // frames at the threshold to open
  static constexpr int kHold = 40;        // frames it stays open after
  static constexpr int kShortHold = 10;   // ... after a burst shorter than
  static constexpr int kVoice = 10;       // frames at the threshold
  static constexpr int kRelease = 20;     // frames open after the key is let go
  static constexpr float kHysteresis = 4;  // dB under the threshold
  static constexpr float kMargin = 15;     // dB over the noise (automatic)
  static constexpr float kAutoLowest = -55;
  static constexpr float kAutoHighest = -30;
  static constexpr int kBlock = 25;   // frames in a block of the noise's minimum
  static constexpr int kBlocks = 8;   // blocks remembered
  static constexpr float kSilence = -100;
  // WebRTC's samples are floats, full scale at 32768.
  static constexpr double kFullScale = 32768;

  // A threshold of its own (dBFS), or the automatic one; or push to talk.
  void Configure(bool automatic, float threshold, bool push_to_talk = false) {
    automatic_ = automatic;
    manual_ = threshold;
    push_to_talk_ = push_to_talk;
  }

  // The push-to-talk key is held, or not.
  void SetPushed(bool pushed) { pushed_ = pushed; }

  // Gates one frame of `count` samples in place: out comes the one from
  // kPreRoll frames before, faded in, as is, faded out or silent. True when
  // the gate opened or closed with it.
  bool Process(float* samples, int count) {
    if (count <= 0) return false;
    if (count != frame_) Reset(count);

    double energy = 0;
    for (int i = 0; i < count; ++i) energy += double(samples[i]) * samples[i];
    energy /= count;
    level_ = Db(energy);

    // The noise: the quietest of the last blocks, each frame averaged with
    // the two before it (one quiet frame within a word is not the noise).
    recent_[recent_at_] = energy;
    recent_at_ = (recent_at_ + 1) % int(recent_.size());
    double average = 0;
    for (double e : recent_) average += e;
    block_min_ = std::min(block_min_, Db(average / recent_.size()));
    if (++block_count_ == kBlock) {
      blocks_[block_at_] = block_min_;
      block_at_ = (block_at_ + 1) % kBlocks;
      blocks_filled_ = std::min(blocks_filled_ + 1, kBlocks);
      block_min_ = std::numeric_limits<float>::infinity();
      block_count_ = 0;
    }
    float noise = block_min_;
    for (int i = 0; i < blocks_filled_; ++i) noise = std::min(noise, blocks_[i]);
    noise_ = std::isfinite(noise) ? noise : kSilence;
    threshold_ = automatic_ ? std::clamp(noise_ + kMargin, kAutoLowest, kAutoHighest) : manual_;

    const bool was_open = open_;
    if (push_to_talk_) {
      if (pushed_) {
        open_ = true;
        hold_ = kRelease;
      } else if (open_ && --hold_ <= 0) {
        open_ = false;
      }
      run_ = 0;
    } else if (!open_) {
      run_ = level_ >= threshold_ ? run_ + 1 : 0;
      if (run_ >= kConfirm) {
        open_ = true;
        loud_ = run_;
        hold_ = kShortHold;
      }
    } else if (level_ >= threshold_ - kHysteresis) {
      if (level_ >= threshold_) ++loud_;
      hold_ = loud_ >= kVoice ? kHold : kShortHold;
    } else if (--hold_ <= 0) {
      open_ = false;
      run_ = 0;
    }

    // In goes this frame; out goes the oldest, which counts as open if the
    // gate is open at it or at any frame after it that is held back.
    std::copy(samples, samples + count, ring_.begin() + at_ * count);
    opens_[at_] = open_;
    const int oldest = (at_ + 1) % kSlots;
    at_ = oldest;
    bool on = false;
    for (bool o : opens_) on = on || o;
    const float* out = ring_.data() + oldest * count;
    if (on && was_on_) {
      std::copy(out, out + count, samples);
    } else if (on) {
      for (int i = 0; i < count; ++i) samples[i] = out[i] * float(i + 1) / count;
    } else if (was_on_) {
      for (int i = 0; i < count; ++i) samples[i] = out[i] * float(count - 1 - i) / count;
    } else {
      std::fill(samples, samples + count, 0.0f);
    }
    was_on_ = on;
    return open_ != was_open;
  }

  // Everything forgotten: a frame of `count` samples from now on.
  void Reset(int count) {
    frame_ = count;
    ring_.assign(size_t(kSlots) * count, 0.0f);
    opens_.fill(false);
    at_ = 0;
    was_on_ = open_ = false;
    run_ = hold_ = loud_ = 0;
    recent_.fill(0);
    recent_at_ = 0;
    block_min_ = std::numeric_limits<float>::infinity();
    block_count_ = block_at_ = blocks_filled_ = 0;
    level_ = noise_ = kSilence;
  }

  bool open() const { return open_; }
  // The last frame's level, and the threshold it was held to.
  float level() const { return level_; }
  float threshold() const { return threshold_; }
  float noise() const { return noise_; }

 private:
  static constexpr int kSlots = kPreRoll + 1;

  static float Db(double energy) {
    if (!(energy > 0)) return kSilence;
    return std::max(kSilence, float(10 * std::log10(energy / (kFullScale * kFullScale))));
  }

  bool automatic_ = true;
  float manual_ = -50;
  bool push_to_talk_ = false;
  bool pushed_ = false;

  int frame_ = 0;
  std::vector<float> ring_;
  std::array<bool, kSlots> opens_{};
  int at_ = 0;
  bool was_on_ = false;

  bool open_ = false;
  int run_ = 0;
  int hold_ = 0;
  int loud_ = 0;  // frames at the threshold since it opened

  std::array<double, 3> recent_{};
  int recent_at_ = 0;
  float block_min_ = std::numeric_limits<float>::infinity();
  int block_count_ = 0;
  std::array<float, kBlocks> blocks_{};
  int block_at_ = 0;
  int blocks_filled_ = 0;

  float level_ = kSilence;
  float noise_ = kSilence;
  float threshold_ = kAutoLowest;
};

}  // namespace hanashi

#endif  // HANASHI_VOICE_GATE_CORE_H_
