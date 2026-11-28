plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.phosphor.hud"
    compileSdk = 35

    buildFeatures {
        compose = true
        buildConfig = true
    }

    val phosphorVersion = file("../../VERSION").readText().trim()
    require(phosphorVersion.matches(Regex("""[0-9]+(\.[0-9]+){1,3}"""))) {
        "VERSION must look like 0.3.0, found: $phosphorVersion"
    }
    val versionParts = phosphorVersion.split(".").map { it.toInt() }
    val phosphorCode = versionParts.getOrElse(0) { 0 } * 10_000 +
        versionParts.getOrElse(1) { 0 } * 100 +
        versionParts.getOrElse(2) { 0 }

    defaultConfig {
        applicationId = "com.phosphor.hud"
        minSdk = 26
        targetSdk = 35
        versionCode = phosphorCode
        versionName = phosphorVersion
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.10.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.glance:glance-appwidget:1.1.1")
    implementation("androidx.work:work-runtime-ktx:2.9.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    testImplementation("junit:junit:4.13.2")
}
