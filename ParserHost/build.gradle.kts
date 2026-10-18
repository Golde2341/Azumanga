plugins {
    kotlin("jvm") version "2.2.10"
    application
}

kotlin {
    jvmToolchain(17)
}

dependencies {
    // Built locally from the pinned Kotatsu parsers fork and published to
    // mavenLocal (see README.md). Pinned deliberately: the parser corpus moves.
    implementation("org.koitharu:kotatsu-parsers:1.0")

    // The parsers declare these as implementation/api deps; the host needs them
    // directly because MangaLoaderContext exposes OkHttp types in its contract.
    implementation("com.squareup.okhttp3:okhttp:5.1.0")
    implementation("org.json:json:20240303")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
}

application {
    mainClass.set("azumanga.host.MainKt")
}

/**
 * Single self-contained jar. Avoids pulling in a shading plugin: the bundled
 * trimmed runtime has no third-party jars on its classpath, so everything the
 * host needs has to be inside this one artifact.
 */
tasks.register<Jar>("fatJar") {
    group = "build"
    description = "Builds a single jar containing the host and all its dependencies."
    archiveClassifier.set("all")
    duplicatesStrategy = DuplicatesStrategy.EXCLUDE

    manifest {
        attributes["Main-Class"] = "azumanga.host.MainKt"
    }

    from(sourceSets.main.get().output)
    dependsOn(configurations.runtimeClasspath)
    from({
        configurations.runtimeClasspath.get()
            .filter { it.name.endsWith(".jar") }
            .map { zipTree(it) }
    })

    // Merging signed jars leaves stale signatures that break loading.
    exclude("META-INF/*.SF", "META-INF/*.DSA", "META-INF/*.RSA", "META-INF/*.EC")
    exclude("module-info.class", "META-INF/versions/**/module-info.class")
}
