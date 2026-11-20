// Hanashi: see voice_gate.h.

#include "voice_gate.h"

#include <glib.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <utility>

#include "voice_gate_core.h"

namespace hanashi {

namespace {

// Runs on WebRTC's audio thread, 10 ms at a time. Settings come in, and
// what the meter shows goes out, through atomics: nothing waits there.
class GateProcessor : public libwebrtc::RTCAudioProcessing::CustomProcessing {
 public:
  explicit GateProcessor(std::function<void(bool)> changed) : changed_(std::move(changed)) {}

  void Configure(bool automatic, float threshold, bool push_to_talk) {
    automatic_ = automatic;
    threshold_ = threshold;
    push_to_talk_ = push_to_talk;
    on_ = true;
  }

  void Push(bool held) { pushed_ = held; }

  // Everything through, as before it was configured.
  void Off() { on_ = false; }

  // The loudest frame since the last call, the threshold, and whether it
  // is open.
  float TakePeak() { return peak_.exchange(VoiceGateCore::kSilence); }
  float Threshold() const { return current_threshold_; }
  bool Open() const { return open_; }

  // What WebRTC hands it, once it has.
  int rate() const { return rate_; }
  int channels() const { return channels_; }
  int bands() const { return bands_; }
  int frames() const { return frames_; }
  int size() const { return size_; }
  int64_t processed() const { return processed_; }

  void Initialize(int sample_rate_hz, int num_channels) override {
    rate_ = sample_rate_hz;
    channels_ = num_channels;
  }

  void Process(int num_bands, int num_frames, int buffer_size, float* buffer) override {
    if (!on_ || buffer == nullptr) return;
    bands_ = num_bands;
    frames_ = num_frames;
    size_ = buffer_size;
    processed_.fetch_add(1, std::memory_order_relaxed);
    core_.Configure(automatic_, threshold_, push_to_talk_);
    core_.SetPushed(pushed_);
    const bool changed = core_.Process(buffer, buffer_size);
    const float level = core_.level();
    float peak = peak_.load();
    while (level > peak && !peak_.compare_exchange_weak(peak, level)) {
    }
    current_threshold_ = core_.threshold();
    open_ = core_.open();
    if (changed) changed_(core_.open());
  }

  void Reset(int new_rate) override { rate_ = new_rate; }

  // Never freed: WebRTC may hold on to it for as long as the process runs.
  void Release() override {}

 private:
  const std::function<void(bool)> changed_;
  VoiceGateCore core_;

  std::atomic<bool> on_{false};
  std::atomic<bool> automatic_{true};
  std::atomic<float> threshold_{-50};
  std::atomic<bool> push_to_talk_{false};
  std::atomic<bool> pushed_{false};

  std::atomic<float> peak_{VoiceGateCore::kSilence};
  std::atomic<float> current_threshold_{VoiceGateCore::kAutoLowest};
  std::atomic<bool> open_{false};

  std::atomic<int> rate_{0};
  std::atomic<int> channels_{0};
  std::atomic<int> bands_{0};
  std::atomic<int> frames_{0};
  std::atomic<int> size_{0};
  std::atomic<int64_t> processed_{0};
};

struct VoiceGate {
  std::unique_ptr<MethodChannel> channel;
  // Held while the audio thread hands over a change, and while the engine
  // goes.
  std::mutex mutex;
  TaskRunner* task_runner = nullptr;
  std::function<libwebrtc::scoped_refptr<libwebrtc::RTCAudioProcessing>()> processing;
  GateProcessor* processor = nullptr;  // once installed
  guint meter = 0;                     // the meter's timer, while on
};

// The one gate, for as long as the process runs (WebRTC's audio thread
// may still call it when the engine goes).
VoiceGate& Gate() {
  static auto* gate = new VoiceGate();
  return *gate;
}

double NumberOf(const EncodableMap& map, const char* key, double otherwise) {
  auto found = map.find(EncodableValue(key));
  if (found == map.end()) return otherwise;
  if (const auto* d = std::get_if<double>(&found->second)) return *d;
  if (const auto* i = std::get_if<int32_t>(&found->second)) return *i;
  if (const auto* l = std::get_if<int64_t>(&found->second)) return double(*l);
  return otherwise;
}

bool BoolOf(const EncodableMap& map, const char* key, bool otherwise) {
  auto found = map.find(EncodableValue(key));
  if (found == map.end()) return otherwise;
  if (const auto* b = std::get_if<bool>(&found->second)) return *b;
  return otherwise;
}

// On the platform thread.
void Send(const char* method, EncodableValue value) {
  auto& gate = Gate();
  if (gate.channel) gate.channel->InvokeMethod(method, std::make_unique<EncodableValue>(std::move(value)));
}

gboolean SendLevel(gpointer) {
  auto& gate = Gate();
  if (gate.processor == nullptr) return G_SOURCE_CONTINUE;
  Send("level", EncodableValue(EncodableMap{
                    {EncodableValue("level"), EncodableValue(double(gate.processor->TakePeak()))},
                    {EncodableValue("threshold"), EncodableValue(double(gate.processor->Threshold()))},
                    {EncodableValue("open"), EncodableValue(gate.processor->Open())},
                }));
  return G_SOURCE_CONTINUE;
}

// Installs the processor into WebRTC, the first time; false if WebRTC has
// no audio processing to take it.
bool Install() {
  auto& gate = Gate();
  if (gate.processor != nullptr) return true;
  auto processing = gate.processing();
  if (!processing) return false;
  gate.processor = new GateProcessor([](bool open) {
    // From the audio thread to the platform thread.
    auto& gate = Gate();
    std::lock_guard<std::mutex> lock(gate.mutex);
    if (gate.task_runner) gate.task_runner->EnqueueTask([open] { Send("open", EncodableValue(open)); });
  });
  processing->SetCapturePostProcessing(gate.processor);
  return true;
}

}  // namespace

void AttachVoiceGate(
    BinaryMessenger* messenger, TaskRunner* task_runner,
    std::function<libwebrtc::scoped_refptr<libwebrtc::RTCAudioProcessing>()> processing) {
  auto& gate = Gate();
  if (gate.channel) return;
  {
    std::lock_guard<std::mutex> lock(gate.mutex);
    gate.task_runner = task_runner;
  }
  gate.processing = std::move(processing);
  gate.channel = std::make_unique<MethodChannel>(messenger, "hanashi/voice",
                                                 &flutter::StandardMethodCodec::GetInstance());
  gate.channel->SetMethodCallHandler(
      [](const MethodCall& call, std::unique_ptr<flutter::MethodResult<EncodableValue>> reply) {
        auto& gate = Gate();
        static const EncodableMap none;
        const auto* found = std::get_if<EncodableMap>(call.arguments());
        const EncodableMap& args = found != nullptr ? *found : none;
        if (call.method_name() == "configure") {
          if (!Install()) {
            reply->Success(EncodableValue(false));
            return;
          }
          gate.processor->Configure(BoolOf(args, "automatic", true),
                                    float(NumberOf(args, "threshold", -50)),
                                    BoolOf(args, "pushToTalk", false));
          reply->Success(EncodableValue(true));
        } else if (call.method_name() == "push") {
          if (gate.processor != nullptr) gate.processor->Push(BoolOf(args, "held", false));
          reply->Success();
        } else if (call.method_name() == "meter") {
          const bool on = BoolOf(args, "on", false);
          if (on && gate.meter == 0) {
            gate.meter = g_timeout_add(50, SendLevel, nullptr);
          } else if (!on && gate.meter != 0) {
            g_source_remove(gate.meter);
            gate.meter = 0;
          }
          reply->Success();
        } else if (call.method_name() == "info") {
          const auto* p = gate.processor;
          reply->Success(p == nullptr ? EncodableValue()
                                      : EncodableValue(EncodableMap{
                                            {EncodableValue("rate"), EncodableValue(p->rate())},
                                            {EncodableValue("channels"), EncodableValue(p->channels())},
                                            {EncodableValue("bands"), EncodableValue(p->bands())},
                                            {EncodableValue("frames"), EncodableValue(p->frames())},
                                            {EncodableValue("size"), EncodableValue(p->size())},
                                            {EncodableValue("processed"), EncodableValue(p->processed())},
                                        }));
        } else {
          reply->NotImplemented();
        }
      });
}

void DetachVoiceGate() {
  auto& gate = Gate();
  if (gate.meter != 0) {
    g_source_remove(gate.meter);
    gate.meter = 0;
  }
  if (gate.processor) gate.processor->Off();
  {
    std::lock_guard<std::mutex> lock(gate.mutex);
    gate.task_runner = nullptr;
  }
  gate.channel.reset();
}

}  // namespace hanashi
