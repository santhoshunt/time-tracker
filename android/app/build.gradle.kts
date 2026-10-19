import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing lives outside the repo: android/key.properties points at
// the private keystore (both gitignored). Falls back to debug signing when
// absent so CI/another machine can still produce an installable build; the
// release workflow pins the real key's digest, so a debug-signed release
// fails there instead of shipping.
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasReleaseKeystore = keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "io.github.santhoshunt.drift"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    // AGP 9 creates JVM unit tests only for the tested build type. Release,
    // so the CI and release workflows run :app:testReleaseUnitTest against
    // the code that ships.
    testBuildType = "release"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Fixed forever: Android treats a different id as a different app,
        // and the in-app updater refuses an APK for another package.
        applicationId = "io.github.santhoshunt.drift"
        // 28 (Android 9) is the first level with screen and keyguard
        // usage events, which mark idle time.
        minSdk = 28
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 64-bit ARM only. --target-platform android-arm64 limits Flutter's own
    // libraries, but the jni and DataStore plugins still pack theirs for
    // every ABI (an ndk abiFilters line did not reach them), so their other
    // copies are dropped when the APK is packaged.
    packaging {
        jniLibs {
            excludes += setOf("lib/armeabi-v7a/**", "lib/x86_64/**", "lib/x86/**")
        }
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
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

dependencies {
    // Drawable.toBitmap for app icons, ContextCompat and IntentCompat for the
    // updater.
    implementation("androidx.core:core-ktx:1.18.0")
    // The hourly usage buffer (UsageBufferWorker), which outlives the app.
    implementation("androidx.work:work-runtime:2.10.5")
    testImplementation("junit:junit:4.13.2")
    // The real org.json: android.jar's copy is a stub in JVM tests.
    testImplementation("org.json:json:20240303")
}
