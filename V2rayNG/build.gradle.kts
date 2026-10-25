// Top-level build file where you can add configuration options common to all sub-projects/modules.
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.compose) apply false
    // Chaquopy：app 内嵌 Python 运行时（socks5_client_mqtt 数据面）。
    // 版本与 xime 实测组合一致（AGP 9.1 + Gradle 9.5 验证通过）。
    id("com.chaquo.python") version "17.0.0" apply false
}

buildscript {
    dependencies {
        classpath(libs.gradle.license.plugin)
    }
}
