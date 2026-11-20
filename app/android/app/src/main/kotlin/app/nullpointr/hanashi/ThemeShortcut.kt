package app.nullpointr.hanashi

import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.os.Build
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The app on the home screen as the theme shown names and draws it
 * (`lib/launcher/theme_launcher.dart`), on the channel "hanashi/shortcut": a
 * shortcut the user pins once, which then follows the theme. The launcher's
 * own entry for the app stays the build's: Android changes that for nothing
 * the app was not built with.
 *
 * - `supported`: whether the launcher takes pinned shortcuts (Android 8+).
 * - `pin` {label, icon}: asks the launcher to pin it; the user confirms there.
 * - `update` {label, icon}: changes it, if it is pinned; says whether it is.
 *
 * `icon` is a PNG of an adaptive icon's full layer (108 dp, the middle 72 dp
 * showing), as the app composes it.
 */
class ThemeShortcut(private val context: Context) {
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            result.success(false)
            return
        }
        handleNow(call, result)
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun handleNow(call: MethodCall, result: MethodChannel.Result) {
        val manager = context.getSystemService(ShortcutManager::class.java)
        if (manager == null) {
            result.success(false)
            return
        }
        when (call.method) {
            "supported" -> result.success(manager.isRequestPinShortcutSupported)
            "pin", "update" -> {
                val info = info(call)
                if (info == null) {
                    result.error("bad_arguments", "A label and a picture are needed", null)
                    return
                }
                val pinned = manager.pinnedShortcuts.any { it.id == ID }
                when {
                    pinned -> {
                        manager.updateShortcuts(listOf(info))
                        result.success(true)
                    }
                    call.method == "pin" -> result.success(manager.requestPinShortcut(info, null))
                    else -> result.success(false)
                }
            }
            else -> result.notImplemented()
        }
    }

    @RequiresApi(Build.VERSION_CODES.O)
    private fun info(call: MethodCall): ShortcutInfo? {
        val label = call.argument<String>("label") ?: return null
        val png = call.argument<ByteArray>("icon") ?: return null
        val bitmap = BitmapFactory.decodeByteArray(png, 0, png.size) ?: return null
        val intent = Intent(context, MainActivity::class.java).setAction(Intent.ACTION_MAIN)
        return ShortcutInfo.Builder(context, ID)
            .setShortLabel(label)
            .setLongLabel(label)
            .setIcon(Icon.createWithAdaptiveBitmap(bitmap))
            .setIntent(intent)
            .build()
    }

    companion object {
        /** One shortcut, which follows the theme. */
        const val ID = "theme"
    }
}
