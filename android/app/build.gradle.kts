plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.djstudio.djstudio_player"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.djstudio.djstudio_player"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    // Llave fija de release (CI): misma firma en cada versión => el celular
    // actualiza encima sin desinstalar. Sin variables (build local) cae a debug.
    // Sin variables: llave fija incluida en el repo (android/app/djstudio.jks),
    // sin secretos: todas las compilaciones (CI o local) llevan la misma firma.
    val ksPath = System.getenv("ANDROID_KEYSTORE_PATH")
    val hasEnvKey = ksPath != null && file(ksPath).exists()
    signingConfigs {
        create("djstudioRelease") {
            if (hasEnvKey) {
                storeFile = file(ksPath!!)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            } else {
                storeFile = file("djstudio.jks")
                storePassword = "djstudio"
                keyAlias = "djstudio"
                keyPassword = "djstudio"
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("djstudioRelease")
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
