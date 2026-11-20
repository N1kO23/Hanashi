package app.nullpointr.hanashi

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.util.Log
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import io.flutter.embedding.engine.FlutterEngine
import org.webrtc.AudioTrackSink
import java.nio.ByteBuffer
import kotlin.math.max

/**
 * A shared screen's sound in a call, played as media, as a video app's sound
 * is (`lib/calls/livekit_connection.dart`). Everything WebRTC plays goes the
 * call's voice way, which phones process for speech: noise suppression and
 * the like, which spoil music. WebRTC still receives and decrypts the sound;
 * its own playing of it is silenced, and what it decodes plays here.
 */
class StreamSound(private val engine: FlutterEngine) {
    private val players = HashMap<String, Player>()

    /** Plays the track [trackId] as media; false if WebRTC has no such track. */
    fun start(trackId: String): Boolean {
        if (players.containsKey(trackId)) return true
        val plugin = engine.plugins.get(FlutterWebRTCPlugin::class.java) as? FlutterWebRTCPlugin ?: return false
        val track = plugin.getRemoteTrack(trackId) as? org.webrtc.AudioTrack ?: return false
        players[trackId] = Player(track).also { it.start() }
        Log.i(TAG, "a shared screen's sound plays as media")
        return true
    }

    /** Back to WebRTC's own playing, if the track is still there, as it came. */
    fun stop(trackId: String) {
        players.remove(trackId)?.stop()
    }

    /** How loud [trackId] plays: 1 as it comes, up to 4 (`PeerVolume.most`). */
    fun volume(trackId: String, volume: Double) {
        players[trackId]?.gain = volume
    }

    fun stopAll() {
        players.values.forEach { it.stop() }
        players.clear()
    }

    /** The decoded sound of one track, into a media player of its own. */
    private class Player(private val track: org.webrtc.AudioTrack) : AudioTrackSink {
        private var out: AudioTrack? = null
        private var rate = 0
        private var channels = 0
        private var bytes = ByteArray(0)
        private var stopped = false

        /**
         * Applied here: the sound comes to sinks before WebRTC's own volume,
         * and a media player plays no louder than it comes.
         */
        @Volatile var gain = 1.0

        fun start() {
            track.setVolume(0.0)
            track.addSink(this)
        }

        fun stop() {
            synchronized(this) {
                stopped = true
                out?.let {
                    it.pause()
                    it.flush()
                    it.release()
                }
                out = null
            }
            try {
                track.removeSink(this)
                track.setVolume(1.0)
            } catch (e: IllegalStateException) {
                // Gone already, with the call or the share.
            }
        }

        // On WebRTC's thread, 10 ms at a time.
        override fun onData(
            audioData: ByteBuffer,
            bitsPerSample: Int,
            sampleRate: Int,
            numberOfChannels: Int,
            numberOfFrames: Int,
            absoluteCaptureTimestampMs: Long,
        ) {
            if (bitsPerSample != 16 || numberOfChannels !in 1..2) return
            synchronized(this) {
                if (stopped) return
                val player = playerFor(sampleRate, numberOfChannels) ?: return
                val size = minOf(numberOfFrames * numberOfChannels * 2, audioData.remaining())
                if (bytes.size < size) bytes = ByteArray(size)
                audioData.duplicate().get(bytes, 0, size)
                val gain = this.gain
                if (gain != 1.0) amplify(bytes, size, gain)
                // Never holding WebRTC up: a frame too many is dropped.
                player.write(bytes, 0, size, AudioTrack.WRITE_NON_BLOCKING)
            }
        }

        /** 16-bit samples in the device's (little-endian) order, scaled; too loud, they clip. */
        private fun amplify(bytes: ByteArray, size: Int, gain: Double) {
            for (i in 0 until size - 1 step 2) {
                val sample = (bytes[i].toInt() and 0xFF) or (bytes[i + 1].toInt() shl 8)
                val scaled = (sample * gain).toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                bytes[i] = scaled.toByte()
                bytes[i + 1] = (scaled shr 8).toByte()
            }
        }

        private fun playerFor(sampleRate: Int, count: Int): AudioTrack? {
            if (out != null && sampleRate == rate && count == channels) return out
            out?.release()
            out = null
            rate = sampleRate
            channels = count
            val mask = if (count == 2) AudioFormat.CHANNEL_OUT_STEREO else AudioFormat.CHANNEL_OUT_MONO
            val least = AudioTrack.getMinBufferSize(sampleRate, mask, AudioFormat.ENCODING_PCM_16BIT)
            if (least <= 0) return null
            return try {
                AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                            .build(),
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(sampleRate)
                            .setChannelMask(mask)
                            .build(),
                    )
                    // A fifth of a second: steady, without much delay.
                    .setBufferSizeInBytes(max(least * 2, sampleRate * count * 2 / 5))
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build()
                    .also {
                        it.play()
                        out = it
                        Log.i(TAG, "playing as media: $sampleRate Hz, $count channel(s)")
                    }
            } catch (e: Exception) {
                Log.w(TAG, "no media player for a shared screen's sound: $e")
                null
            }
        }
    }

    private companion object {
        const val TAG = "HanashiStreamSound"
    }
}
