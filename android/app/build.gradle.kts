import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Upload key for Google Play, kept outside git in android/key.properties:
//   storeFile=/absolute/path/to/evenda-upload.jks
//   storePassword=...
//   keyAlias=evenda-upload
//   keyPassword=...
val keyProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "com.dantechsolutionsgroup.evenda"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.dantechsolutionsgroup.evenda"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keyProps.getProperty("storeFile") != null) {
            create("upload") {
                storeFile = file(keyProps.getProperty("storeFile"))
                storePassword = keyProps.getProperty("storePassword")
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Google Play rejects debug-signed bundles, so a release build
            // without android/key.properties fails instead of silently using
            // the debug key.
            signingConfig = signingConfigs.findByName("upload")
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
    // EvendaMessagingService builds the call-style Evenda Now alert. Same
    // Firebase BoM as firebase_core 5.0.0, so there is one firebase-messaging.
    implementation(platform("com.google.firebase:firebase-bom:35.0.0"))
    implementation("com.google.firebase:firebase-messaging")
}

// Push notifications: Firebase reads android/app/google-services.json at build
// time. Until that file is added the app builds without push (in-app
// notifications still work), so a missing file never breaks the build.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

// Fail release builds (only) when the upload key is missing, so a
// debug-signed bundle can never be produced by accident.
gradle.taskGraph.whenReady {
    if (allTasks.any { it.name.contains("Release") } && keyProps.getProperty("storeFile") == null) {
        throw GradleException("Release signing: create android/key.properties (see the comment at the top of android/app/build.gradle.kts).")
    }
}
