package app.nullpointr.hanashi

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.audio.AudioProcessingAdapter
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min

/**
 * The voice gate's decisions: the microphone's audio, 10 ms at a time,
 * after WebRTC's echo cancelling and noise suppression, goes out only while
 * the user speaks; in between it is silence, which Opus sends as next to
 * nothing. The twin of `linux/webrtc/voice_gate_core.h`: keep the two the
 * same, and see there for how it decides.
 */
class VoiceGateCore {
    companion object {
        const val PRE_ROLL = 3 // frames held back
        const val CONFIRM = 3 // frames at the threshold to open
        const val HOLD = 40 // frames it stays open after
        const val SHORT_HOLD = 10 // ... after a burst shorter than
        const val VOICE = 10 // frames at the threshold
        const val RELEASE = 20 // frames open after the key is let go
        const val HYSTERESIS = 4f // dB under the threshold
        const val MARGIN = 15f // dB over the noise (automatic)
        const val AUTO_LOWEST = -55f
        const val AUTO_HIGHEST = -30f
        const val BLOCK = 25 // frames in a block of the noise's minimum
        const val BLOCKS = 8 // blocks remembered
        const val SILENCE = -100f

        // WebRTC's samples are floats, full scale at 32768.
        const val FULL_SCALE = 32768.0
        private const val SLOTS = PRE_ROLL + 1

        private fun db(energy: Double): Float {
            if (!(energy > 0)) return SILENCE
            return max(SILENCE, (10 * log10(energy / (FULL_SCALE * FULL_SCALE))).toFloat())
        }
    }

    private var automatic = true
    private var manual = -50f
    private var pushToTalk = false
    private var pushed = false

    private var frame = 0
    private var ring = FloatArray(0)
    private val opens = BooleanArray(SLOTS)
    private var at = 0
    private var wasOn = false

    var open = false
        private set
    private var run = 0
    private var hold = 0
    private var loud = 0 // frames at the threshold since it opened

    private val recent = DoubleArray(3)
    private var recentAt = 0
    private var blockMin = Float.POSITIVE_INFINITY
    private var blockCount = 0
    private val blocks = FloatArray(BLOCKS)
    private var blockAt = 0
    private var blocksFilled = 0

    /** The last frame's level, and the threshold it was held to (dBFS). */
    var level = SILENCE
        private set
    var threshold = AUTO_LOWEST
        private set
    var noise = SILENCE
        private set

    /** A threshold of its own (dBFS), or the automatic one; or push to talk. */
    fun configure(automatic: Boolean, threshold: Float, pushToTalk: Boolean = false) {
        this.automatic = automatic
        manual = threshold
        this.pushToTalk = pushToTalk
    }

    /** The push-to-talk button is held, or not. */
    fun setPushed(pushed: Boolean) {
        this.pushed = pushed
    }

    /**
     * Gates one frame of [count] samples in place: out comes the one from
     * [PRE_ROLL] frames before, faded in, as is, faded out or silent. True
     * when the gate opened or closed with it.
     */
    fun process(samples: FloatArray, count: Int): Boolean {
        if (count <= 0) return false
        if (count != frame) reset(count)

        var energy = 0.0
        for (i in 0 until count) energy += samples[i].toDouble() * samples[i]
        energy /= count
        level = db(energy)

        // The noise: the quietest of the last blocks, each frame averaged
        // with the two before it (one quiet frame within a word is not the
        // noise).
        recent[recentAt] = energy
        recentAt = (recentAt + 1) % recent.size
        blockMin = min(blockMin, db(recent.sum() / recent.size))
        if (++blockCount == BLOCK) {
            blocks[blockAt] = blockMin
            blockAt = (blockAt + 1) % BLOCKS
            blocksFilled = min(blocksFilled + 1, BLOCKS)
            blockMin = Float.POSITIVE_INFINITY
            blockCount = 0
        }
        var lowest = blockMin
        for (i in 0 until blocksFilled) lowest = min(lowest, blocks[i])
        noise = if (lowest.isFinite()) lowest else SILENCE
        threshold = if (automatic) (noise + MARGIN).coerceIn(AUTO_LOWEST, AUTO_HIGHEST) else manual

        val wasOpen = open
        if (pushToTalk) {
            if (pushed) {
                open = true
                hold = RELEASE
            } else if (open && --hold <= 0) {
                open = false
            }
            run = 0
        } else if (!open) {
            run = if (level >= threshold) run + 1 else 0
            if (run >= CONFIRM) {
                open = true
                loud = run
                hold = SHORT_HOLD
            }
        } else if (level >= threshold - HYSTERESIS) {
            if (level >= threshold) loud++
            hold = if (loud >= VOICE) HOLD else SHORT_HOLD
        } else if (--hold <= 0) {
            open = false
            run = 0
        }

        // In goes this frame; out goes the oldest, which counts as open if
        // the gate is open at it or at any frame after it that is held back.
        System.arraycopy(samples, 0, ring, at * count, count)
        opens[at] = open
        val oldest = (at + 1) % SLOTS
        at = oldest
        val on = opens.any { it }
        val out = oldest * count
        when {
            on && wasOn -> System.arraycopy(ring, out, samples, 0, count)
            on -> for (i in 0 until count) samples[i] = ring[out + i] * (i + 1) / count
            wasOn -> for (i in 0 until count) samples[i] = ring[out + i] * (count - 1 - i) / count
            else -> samples.fill(0f, 0, count)
        }
        wasOn = on
        return open != wasOpen
    }

    /** Everything forgotten: a frame of [count] samples from now on. */
    fun reset(count: Int) {
        frame = count
        ring = FloatArray(SLOTS * count)
        opens.fill(false)
        at = 0
        wasOn = false
        open = false
        run = 0
        hold = 0
        loud = 0
        recent.fill(0.0)
        recentAt = 0
        blockMin = Float.POSITIVE_INFINITY
        blockCount = 0
        blockAt = 0
        blocksFilled = 0
        level = SILENCE
        noise = SILENCE
    }
}

/**
 * The voice gate in WebRTC's audio processing (flutter_webrtc's capture
 * post-processing, after its own), on the channel "hanashi/voice" as on
 * Linux (`linux/webrtc/voice_gate.h`): from the app "configure"
 * {automatic, threshold, pushToTalk} (on from the first), "push" {held},
 * "meter" {on} and "info"; to it "open" (bool) as it opens and closes, and
 * "level" {level, threshold, open} 20 times a second while metering.
 */
class VoiceGate(private val engine: FlutterEngine, private val channel: MethodChannel) :
    AudioProcessingAdapter.ExternalAudioFrameProcessing {
    private val main = Handler(Looper.getMainLooper())

    // Only ever on WebRTC's audio thread.
    private val core = VoiceGateCore()
    private var samples = FloatArray(0)

    @Volatile private var on = false
    @Volatile private var automatic = true
    @Volatile private var setThreshold = -50f
    @Volatile private var pushToTalk = false
    @Volatile private var pushed = false
    private var adapter: AudioProcessingAdapter? = null

    // For the meter and the log: the loudest frame since the meter last
    // looked, the threshold, and what WebRTC hands over.
    private val lock = Any()
    private var peak = VoiceGateCore.SILENCE
    @Volatile private var threshold = VoiceGateCore.AUTO_LOWEST
    @Volatile private var open = false
    @Volatile private var rate = 0
    @Volatile private var channels = 0
    @Volatile private var bands = 0
    @Volatile private var frames = 0
    @Volatile private var size = 0
    @Volatile private var processed = 0L

    private var metering = false
    private val meter = object : Runnable {
        override fun run() {
            if (!metering) return
            val loudest = synchronized(lock) { peak.also { peak = VoiceGateCore.SILENCE } }
            channel.invokeMethod(
                "level",
                mapOf("level" to loudest.toDouble(), "threshold" to threshold.toDouble(), "open" to open),
            )
            main.postDelayed(this, 50)
        }
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "configure" -> {
                if (!install()) {
                    result.success(false)
                    return
                }
                automatic = call.argument<Boolean>("automatic") ?: true
                setThreshold = (call.argument<Number>("threshold") ?: -50).toFloat()
                pushToTalk = call.argument<Boolean>("pushToTalk") ?: false
                on = true
                result.success(true)
            }
            "push" -> {
                pushed = call.argument<Boolean>("held") ?: false
                result.success(null)
            }
            "meter" -> {
                val wanted = call.argument<Boolean>("on") ?: false
                if (wanted && !metering) {
                    metering = true
                    main.post(meter)
                } else if (!wanted) {
                    metering = false
                    main.removeCallbacks(meter)
                }
                result.success(null)
            }
            "info" -> result.success(
                if (adapter == null) null
                else mapOf(
                    "rate" to rate,
                    "channels" to channels,
                    "bands" to bands,
                    "frames" to frames,
                    "size" to size,
                    "processed" to processed,
                ),
            )
            else -> result.notImplemented()
        }
    }

    /** Into WebRTC's audio processing, the first time; false if WebRTC is not set up. */
    private fun install(): Boolean {
        if (adapter != null) return true
        val plugin = engine.plugins.get(FlutterWebRTCPlugin::class.java) as? FlutterWebRTCPlugin ?: return false
        val controller = plugin.audioProcessingController ?: return false
        // Not left out: WebRTC may otherwise skip what comes after its own.
        controller.externalAudioProcessingFactory.setBypassFlagForCapturePost(false)
        controller.capturePostProcessing.addProcessor(this)
        adapter = controller.capturePostProcessing
        Log.i(TAG, "the voice gate is in WebRTC's audio processing")
        return true
    }

    /** The engine goes: everything through, and nobody told. */
    fun detach() {
        on = false
        metering = false
        main.removeCallbacks(meter)
        adapter?.removeProcessor(this)
        adapter = null
    }

    override fun initialize(sampleRateHz: Int, numChannels: Int) {
        rate = sampleRateHz
        channels = numChannels
    }

    override fun reset(newRate: Int) {
        rate = newRate
    }

    // On WebRTC's audio thread, 10 ms at a time: floats, in the platform's
    // byte order.
    override fun process(numBands: Int, numFrames: Int, buffer: ByteBuffer) {
        if (!on) return
        buffer.order(ByteOrder.nativeOrder())
        val count = buffer.capacity() / 4
        bands = numBands
        frames = numFrames
        size = count
        // Frames are 10 ms. (It is added after WebRTC set up its processing,
        // so it may never have been told the rate.)
        rate = numFrames * 100
        processed++
        if (samples.size != count) samples = FloatArray(count)
        for (i in 0 until count) samples[i] = buffer.getFloat(i * 4)
        core.configure(automatic, setThreshold, pushToTalk)
        core.setPushed(pushed)
        val changed = core.process(samples, count)
        for (i in 0 until count) buffer.putFloat(i * 4, samples[i])
        synchronized(lock) { peak = max(peak, core.level) }
        threshold = core.threshold
        open = core.open
        if (changed) {
            val now = core.open
            main.post { channel.invokeMethod("open", now) }
        }
    }

    companion object {
        private const val TAG = "HanashiVoiceGate"
    }
}
