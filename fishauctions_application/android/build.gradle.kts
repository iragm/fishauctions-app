allprojects {
    repositories {
        google()
        mavenCentral()
        // Square Mobile Payments SDK (Tap to Pay). Public repo, no credentials.
        // Declared here because modern Gradle ignores repositories declared by
        // plugin subprojects, so the square_mobile_payments_sdk module can't
        // resolve com.squareup.sdk:mobile-payments-sdk on its own.
        maven { url = uri("https://sdk.squareup.com/public/android") }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
