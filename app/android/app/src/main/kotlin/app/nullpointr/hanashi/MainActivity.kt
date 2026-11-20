package app.nullpointr.hanashi

import android.app.KeyguardManager
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.display.DisplayManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.view.Display
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** The app's window, with what a call needs of it (`lib/calls/call_window.dart`). */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    /** The home-screen shortcut that follows the theme (ThemeShortcut.kt). */
    private var shortcutChannel: MethodChannel? = null

    /** The screen goes dark while something is near it, as an ear is. */
    private var proximity: PowerManager.WakeLock? = null

    /** The call wants [proximity]; it is held only while the window is in front. */
    private var proximityWanted = false
    private var inFront = false

    private var ringtone: Ringtone? = null
    private var vibrating = false

    /** Opened from a call's notification: shown over the lock screen until the call is over. */
    private var forCall = false

    /** Shown over the lock screen now, as the app was last told. */
    private var overLockScreen = false

    private val unlocked = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = updateOverLockScreen()
    }

    /** Sharing the screen (`lib/calls/livekit_connection.dart`). */
    private var screencast: MethodChannel? = null

    /** Others' shared screens' sound, played as media (see [StreamSound]). */
    private var streamSound: StreamSound? = null
    private var streamSoundChannel: MethodChannel? = null

    /** The microphone's voice gate (see [VoiceGate]). */
    private var voiceGate: VoiceGate? = null
    private var voiceChannel: MethodChannel? = null

    /** flutter_webrtc's display for sharing the screen, while there is one. */
    private var sharedDisplay: Int? = null

    private val main = Handler(Looper.getMainLooper())

    /**
     * Android stopping a share of the screen (its "Stop sharing" chip):
     * flutter_webrtc does not tell, but the display it shares through goes
     * dark while the screen itself is on. (While the screen is off both are
     * dark, and both come back with it.)
     */
    private val displays = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) {
            if (displayManager().getDisplay(displayId)?.name == SHARED_DISPLAY) sharedDisplay = displayId
        }

        override fun onDisplayChanged(displayId: Int) {
            if (sharedDisplay == null) return
            // Once the screen and the shared display have both changed.
            main.removeCallbacks(checkShared)
            main.postDelayed(checkShared, SHARED_SETTLE_MS)
        }

        override fun onDisplayRemoved(displayId: Int) {
            if (displayId == sharedDisplay) sharingEnded()
        }
    }

    private val checkShared = Runnable {
        val id = sharedDisplay ?: return@Runnable
        val shared = displayManager().getDisplay(id)?.state
        val screen = displayManager().getDisplay(Display.DEFAULT_DISPLAY)?.state
        if (shared == Display.STATE_OFF && screen == Display.STATE_ON) sharingEnded()
    }

    /** Told also when the app stopped it: the app knows then, and does nothing. */
    private fun sharingEnded() {
        sharedDisplay = null
        main.removeCallbacks(checkShared)
        screencast?.invokeMethod("ended", null)
    }

    private fun displayManager() = getSystemService(DISPLAY_SERVICE) as DisplayManager

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        takeCallIntent(intent)
        val unlocking = IntentFilter(Intent.ACTION_USER_PRESENT)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(unlocked, unlocking, RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(unlocked, unlocking)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        takeCallIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hanashi/call_window").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "proximity" -> {
                        proximityWanted = call.arguments as Boolean
                        applyProximity()
                        result.success(null)
                    }
                    "ringing" -> {
                        if (call.arguments as Boolean) startRinging() else stopRinging()
                        result.success(null)
                    }
                    "overLockScreen" -> {
                        updateOverLockScreen()
                        result.success(overLockScreen)
                    }
                    "callOver" -> {
                        callOver()
                        result.success(null)
                    }
                    "unlock" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            (getSystemService(KEYGUARD_SERVICE) as KeyguardManager).requestDismissKeyguard(this@MainActivity, null)
                        }
                        result.success(null)
                    }
                    "allowRingingFullScreen" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                            startActivity(
                                Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:$packageName")),
                            )
                        }
                        result.success(null)
                    }
                    "canRingFullScreen" -> result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE ||
                            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).canUseFullScreenIntent(),
                    )
                    else -> result.notImplemented()
                }
            }
        }
        screencast = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hanashi/screencast")
        displayManager().registerDisplayListener(displays, main)
        val sound = StreamSound(flutterEngine)
        streamSound = sound
        streamSoundChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hanashi/stream_sound").apply {
            setMethodCallHandler { call, result ->
                val trackId = call.argument<String>("trackId")
                when {
                    call.method == "start" && trackId != null -> result.success(sound.start(trackId))
                    call.method == "stop" && trackId != null -> {
                        sound.stop(trackId)
                        result.success(null)
                    }
                    call.method == "volume" && trackId != null -> {
                        sound.volume(trackId, call.argument<Double>("volume") ?: 1.0)
                        result.success(null)
                    }
                    call.method == "stopAll" -> {
                        sound.stopAll()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        shortcutChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hanashi/shortcut").apply {
            setMethodCallHandler(ThemeShortcut(this@MainActivity)::handle)
        }
        val voice = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hanashi/voice")
        val gate = VoiceGate(flutterEngine, voice)
        voice.setMethodCallHandler(gate::handle)
        voiceGate = gate
        voiceChannel = voice
    }

    override fun onResume() {
        super.onResume()
        inFront = true
        applyProximity()
        updateOverLockScreen()
    }

    override fun onPause() {
        // Another app's screen is not to go dark.
        inFront = false
        applyProximity()
        super.onPause()
    }

    override fun onDestroy() {
        unregisterReceiver(unlocked)
        proximityWanted = false
        applyProximity()
        stopRinging()
        channel?.setMethodCallHandler(null)
        channel = null
        displayManager().unregisterDisplayListener(displays)
        main.removeCallbacks(checkShared)
        screencast = null
        streamSoundChannel?.setMethodCallHandler(null)
        streamSoundChannel = null
        streamSound?.stopAll()
        streamSound = null
        voiceChannel?.setMethodCallHandler(null)
        voiceChannel = null
        voiceGate?.detach()
        voiceGate = null
        super.onDestroy()
    }

    /**
     * Back on the app's first screen: to the background, as Android does by
     * itself since version 12, rather than closing it with a call going on.
     */
    override fun popSystemNavigator(): Boolean {
        moveTaskToBack(true)
        return true
    }

    // The lock screen

    /** A call's notification (tapped, full screen, or Accept) opened the app. */
    private fun takeCallIntent(intent: Intent?) {
        val action = intent?.action ?: return
        if (action != "SELECT_NOTIFICATION" && action != "SELECT_FOREGROUND_NOTIFICATION") return
        if (intent.getStringExtra("payload")?.startsWith("call:") != true) return
        forCall = true
        showOverLockScreen(true)
        updateOverLockScreen()
    }

    @Suppress("DEPRECATION")
    private fun showOverLockScreen(on: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(on)
            setTurnScreenOn(on)
        } else {
            val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (on) window.addFlags(flags) else window.clearFlags(flags)
        }
    }

    private fun updateOverLockScreen() {
        val locked = (getSystemService(KEYGUARD_SERVICE) as KeyguardManager).isKeyguardLocked
        val now = forCall && locked
        if (now == overLockScreen) return
        overLockScreen = now
        channel?.invokeMethod("overLockScreen", now)
    }

    /** Over the lock screen no longer: behind it again, if it was there. */
    private fun callOver() {
        val wasOver = overLockScreen
        forCall = false
        showOverLockScreen(false)
        updateOverLockScreen()
        if (wasOver) moveTaskToBack(true)
    }

    // Ringing while the app is in front, as the phone is set to

    private fun startRinging() {
        if (ringtone != null || vibrating) return
        val ringer = (getSystemService(AUDIO_SERVICE) as AudioManager).ringerMode
        val usage = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        if (ringer == AudioManager.RINGER_MODE_NORMAL) {
            val uri = RingtoneManager.getActualDefaultRingtoneUri(this, RingtoneManager.TYPE_RINGTONE)
                ?: Settings.System.DEFAULT_RINGTONE_URI
            ringtone = RingtoneManager.getRingtone(this, uri)?.apply {
                audioAttributes = usage
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) isLooping = true
                play()
            }
        }
        val vibrator = vibrator()
        if (ringer != AudioManager.RINGER_MODE_SILENT && vibrator.hasVibrator() &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
        ) {
            @Suppress("DEPRECATION")
            vibrator.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 1000, 1000), 0), usage)
            vibrating = true
        }
    }

    private fun stopRinging() {
        ringtone?.stop()
        ringtone = null
        if (vibrating) vibrator().cancel()
        vibrating = false
    }

    @Suppress("DEPRECATION")
    private fun vibrator(): Vibrator =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (getSystemService(VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
        } else {
            getSystemService(VIBRATOR_SERVICE) as Vibrator
        }

    // The proximity sensor

    private fun applyProximity() {
        if (!proximityWanted || !inFront) {
            proximity?.let { if (it.isHeld) it.release(PowerManager.RELEASE_FLAG_WAIT_FOR_NO_PROXIMITY) }
            proximity = null
            return
        }
        if (proximity?.isHeld == true) return
        val power = getSystemService(Context.POWER_SERVICE) as PowerManager
        if (!power.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) return
        proximity = power.newWakeLock(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK, "hanashi:call").apply {
            setReferenceCounted(false)
            // Taken again whenever the window comes back to the front.
            acquire(PROXIMITY_AT_MOST)
        }
    }

    private companion object {
        const val PROXIMITY_AT_MOST = 4 * 60 * 60 * 1000L

        /** flutter_webrtc's (`OrientationAwareScreenCapturer`). */
        const val SHARED_DISPLAY = "WebRTC_ScreenCapture"
        const val SHARED_SETTLE_MS = 1500L
    }
}
