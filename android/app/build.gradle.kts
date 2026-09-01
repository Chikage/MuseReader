plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val museReaderRoot = rootProject.projectDir.parentFile
val museScoreSource = project.findProperty("museScoreSourceDir")?.toString()
    ?: File(museReaderRoot.parentFile, "MuseScore-3.6.2").canonicalPath
val museReaderQt = project.findProperty("museReaderQtDir")?.toString()
    ?: File(museReaderRoot, "build/toolchains/qt/android/5.15.2/android").canonicalPath
// Qt's Android shared libraries use JNI_OnLoad to bind to the QtNative
// runtime class. Flutter does not use QtActivity, so androiddeployqt is not
// involved and the runtime jar must be packaged explicitly. Without it
// libQt5Core fails its JNI bootstrap with "initJNI failed" before the
// MuseScore bridge can initialize.
val museReaderQtAndroidJar = File(museReaderQt, "jar/QtAndroid.jar")
val museReaderQtBaseSource = project.findProperty("museReaderQtBaseSourceDir")?.toString()
    ?: File(museReaderRoot, "build/toolchains/src/qtbase-everywhere-src-5.15.2").canonicalPath
val museReaderSoundfont = File(museReaderRoot, "assets/sound/MS Basic.sf3").canonicalPath
val museReaderCmakeArgs = listOf(
    "-DMUSE_READER_BUILD_MUSESCORE_SOURCE=ON",
    "-DMUSE_READER_WITH_FLUIDSYNTH=ON",
    "-DMUSESCORE_SOURCE_DIR=$museScoreSource",
    "-DMUSE_READER_SOUNDFONT_PATH=$museReaderSoundfont",
    "-DMUSE_READER_QTBASE_SOURCE_DIR=$museReaderQtBaseSource",
    "-DQt5_DIR=$museReaderQt/lib/cmake/Qt5",
    "-DCMAKE_PREFIX_PATH=$museReaderQt",
    "-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=NEVER",
    "-DANDROID_STL=c++_shared",
)

android {
    namespace = "icu.ringona.musereader"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "icu.ringona.musereader"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            abiFilters.clear()
            abiFilters += "arm64-v8a"
        }

        externalNativeBuild {
            cmake {
                arguments += museReaderCmakeArgs
            }
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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
    implementation(files(museReaderQtAndroidJar))
}
