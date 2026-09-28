import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "cl.easysoft.easyspectrum"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "cl.easysoft.easyspectrum"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = 1
        versionName = "1.0.0"

        externalNativeBuild {
            cmake {
                abiFilters("arm64-v8a", "x86_64")
                arguments("-DANDROID_STL=c++_shared")
            }
        }
    }

    // Dos ediciones del mismo código. El namespace (paquete de Kotlin) no cambia;
    // solo el applicationId, que es la identidad en el teléfono y en Play Store.
    // En Dart se distingue con `appFlavor` (ver lib/core/edition.dart).
    flavorDimensions += "edicion"
    productFlavors {
        create("free") {
            dimension = "edicion"
            resValue("string", "app_name", "Easy Spectrum")
        }
        create("pro") {
            dimension = "edicion"
            applicationIdSuffix = ".pro"   // cl.easysoft.easyspectrum.pro
            resValue("string", "app_name", "Easy Spectrum Pro")
        }
    }

    externalNativeBuild {
        cmake {
            path = file("../../native/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release") else signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
