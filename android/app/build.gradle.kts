plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val museReaderCmakeArgs = mutableListOf<String>()
if (project.findProperty("museReaderWithMuseScore") == "true") {
    museReaderCmakeArgs += "-DMUSE_READER_WITH_MUSESCORE=ON"
    mapOf(
        "museScoreSourceDir" to "MUSESCORE_SOURCE_DIR",
        "museScoreBuildDir" to "MUSESCORE_BUILD_DIR",
        "museScoreLibraries" to "MUSESCORE_LIBRARIES",
        "museReaderQtPrefixPath" to "CMAKE_PREFIX_PATH",
    ).forEach { (propertyName, cmakeName) ->
        project.findProperty(propertyName)?.toString()?.let { value ->
            museReaderCmakeArgs += "-D$cmakeName=$value"
        }
    }
}

android {
    namespace = "com.musereader.muse_reader"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

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
        applicationId = "com.musereader.muse_reader"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

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
