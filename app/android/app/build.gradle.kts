import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "app.nullpointr.hanashi"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications needs newer Java APIs on old Androids.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.nullpointr.hanashi"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // The minutes since 2026-01-01 (UTC) when the build was made, here or
        // in CI, rather than the build number: every build has a higher
        // version code than the ones before it, so builds from this machine
        // and from CI install over each other in the order they were made
        // (Android refuses a lower one). Split APKs keep it as it is (see
        // gradle.properties).
        versionCode = (System.currentTimeMillis() / 60_000 - 29_453_760).toInt()
        versionName = flutter.versionName
    }

    signingConfigs {
        // Builds are signed with the app's release key: in CI from the
        // ANDROID_KEYSTORE_* variables (see .github/workflows/ci.yml), locally
        // from android/key.properties (kept out of git). Every build must use
        // the same key, or Android refuses to install an update over an
        // earlier version.
        val local = Properties().apply {
            val file = rootProject.file("key.properties")
            if (file.exists()) file.inputStream().use { load(it) }
        }
        fun setting(variable: String, property: String): String? =
            System.getenv(variable) ?: local.getProperty(property)
        val keystore = setting("ANDROID_KEYSTORE_PATH", "storeFile")
        if (keystore != null) {
            create("release") {
                storeFile = file(keystore)
                storePassword = setting("ANDROID_KEYSTORE_PASSWORD", "storePassword")
                keyAlias = setting("ANDROID_KEY_ALIAS", "keyAlias")
                keyPassword = setting("ANDROID_KEY_PASSWORD", "keyPassword")
            }
        }
    }

    buildTypes {
        // Debug builds too, so that `flutter run` installs over a CI build
        // without losing the app's data. Without a release key, the debug key
        // (such builds cannot update a released app).
        val key = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        configureEach { signingConfig = key }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

configurations.all {
    // UnifiedPush brings Tink built for the JVM; flutter_secure_storage the
    // same Tink built for Android. One copy of the classes is enough.
    exclude(group = "com.google.crypto.tink", module = "tink")
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    // UnifiedPush distributor for phones without a distributor app: FCM
    // through Google Play services (no Firebase project or Google library
    // needed; the server signs its pushes with VAPID).
    implementation("org.unifiedpush.android:embedded-fcm-distributor:3.1.0")
    // Others' shared screens' sound played as media (StreamSound.kt) needs
    // WebRTC's own classes, which flutter_webrtc brings in: the same version.
    compileOnly("io.github.webrtc-sdk:android:150.7871.04")
}
