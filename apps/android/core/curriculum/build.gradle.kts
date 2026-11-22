plugins {
    `java-library`
    alias(libs.plugins.kotlin.jvm)
}

kotlin {
    jvmToolchain(21)
}

dependencies {
    api(project(":core:domain"))
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.platform.launcher)
}

tasks.test {
    useJUnitPlatform()
}

tasks.register<JavaExec>("fixtureRun") {
    group = "verification"
    description = "Run the engine over a fixture directory and print its normalized task stream."
    mainClass.set("masoon.curriculum.fixture.FixtureRunnerKt")
    classpath = sourceSets["main"].runtimeClasspath
    workingDir = rootDir
}
