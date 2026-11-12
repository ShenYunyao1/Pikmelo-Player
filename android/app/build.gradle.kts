import java.util.Properties
import java.security.KeyStore
import java.security.MessageDigest

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingFile = System.getenv("PIKMELO_SIGNING_PROPERTIES")?.let(::file)
    ?: file("D:/Develop/Signing/PikmeloPlayer/signing.properties")
val releaseSigning = Properties()
if (signingFile.exists()) signingFile.inputStream().use(releaseSigning::load)
val pinnedCertificate = rootProject.file("release-cert.sha256").readText().trim()
val instrumentationRuntime by configurations.creating {
    isCanBeConsumed = false
    isTransitive = false
}

android {
    namespace = "top.shenyunyao.pikmelo_player"
    compileSdk = 36
    buildFeatures { buildConfig = true }
    testBuildType = "release"
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "top.shenyunyao.pikmelo_player"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = 35
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField("String", "RELEASE_CERT_SHA256", "\"$pinnedCertificate\"")
    }

    signingConfigs {
        create("official") {
            if (releaseSigning.isNotEmpty()) {
                storeFile = file(releaseSigning.getProperty("storeFile"))
                storePassword = releaseSigning.getProperty("storePassword")
                keyAlias = releaseSigning.getProperty("keyAlias")
                keyPassword = releaseSigning.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("official")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

tasks.configureEach {
    if (name.startsWith("validateSigning") && name.endsWith("Release")) {
        doFirst {
            check(releaseSigning.isNotEmpty()) { "Set PIKMELO_SIGNING_PROPERTIES to the official signing configuration." }
            val keystore = KeyStore.getInstance("PKCS12")
            file(releaseSigning.getProperty("storeFile")).inputStream().use {
                keystore.load(it, releaseSigning.getProperty("storePassword").toCharArray())
            }
            val certificate = keystore.getCertificate(releaseSigning.getProperty("keyAlias"))
            val digest = MessageDigest.getInstance("SHA-256").digest(certificate.encoded)
                .joinToString("") { "%02x".format(it.toInt() and 0xff) }
            check(digest == pinnedCertificate) { "Release signing identity does not match the pinned certificate." }
        }
    }
}

dependencies {
    implementation("com.android.tools.build:apksig:8.11.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    instrumentationRuntime("org.jetbrains.kotlin:kotlin-stdlib:2.2.20")
    // Release shrinking removes Kotlin APIs needed only by AndroidJUnitRunner.
    androidTestImplementation(files(instrumentationRuntime))
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
