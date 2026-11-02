plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.filmstream_personal"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.filmstream_personal"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("filmstreamRelease") {
            val keystorePath = System.getenv("FILMSTREAM_KEYSTORE_PATH")
            val storePass = System.getenv("FILMSTREAM_STORE_PASSWORD")
            val keyPass = System.getenv("FILMSTREAM_KEY_PASSWORD")
            require(!keystorePath.isNullOrBlank() &&
                !storePass.isNullOrBlank() && !keyPass.isNullOrBlank()) {
                "Release signing secrets are missing. Configure the stable Film Streaming keystore."
            }
            storeFile = file(keystorePath)
            storePassword = storePass
            keyAlias = "filmstream"
            keyPassword = keyPass
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("filmstreamRelease")
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
