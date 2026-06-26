
plugins {
    id("com.gtnewhorizons.gtnhconvention")
}

// Default to build — bare `gradlew` should compile, not launch a server
defaultTasks("build")

// Configure Javadoc task to prevent GitHub Actions from failing
tasks.withType<Javadoc>().configureEach {
    val javadocOptions = options as StandardJavadocDocletOptions

    // Prevent the build from failing due to missing/incomplete Javadocs
    javadocOptions.addStringOption("Xdoclint:none", "-quiet")

    // Ensure special characters display correctly in MkDocs
    javadocOptions.encoding = "UTF-8"
    javadocOptions.charSet = "UTF-8"

    javadocOptions.windowTitle = "Horizon-QA v${project.version} API Documentation"
    javadocOptions.docTitle = "<h1>Horizon-QA Testing Framework - v${project.version}</h1>"

    // Clean up CI logs
    javadocOptions.quiet()
}

// gregtech.overminddl1.com mirror is dead; its ancient Scala 2.11 module versions
// (1.0.1, 1.0.2) don't exist on Maven Central. Upgrade to the earliest available
// versions on Central and remap to the org.scala-lang.modules group.
configurations.all {
    resolutionStrategy.eachDependency {
        if (requested.group == "org.scala-lang") {
            when (requested.name) {
                "scala-parser-combinators_2.11" -> {
                    useTarget("org.scala-lang.modules:scala-parser-combinators_2.11:1.0.4")
                    because("1.0.1 only on dead overmind mirror")
                }
                "scala-swing_2.11" -> {
                    useTarget("org.scala-lang.modules:scala-swing_2.11:1.0.2")
                    because("1.0.1 only on dead overmind mirror")
                }
                "scala-xml_2.11" -> {
                    useTarget("org.scala-lang.modules:scala-xml_2.11:1.0.6")
                    because("1.0.2 only on dead overmind mirror")
                }
            }
        }
    }
}

// The java17Dependencies configuration in subprojects requires rfgDeobfuscatorTransformed=true when
// resolving variants. External JARs acquire this attribute through the RFG deobfuscator transform,
// but local project dependencies (devOnlyNonPublishable(project(":"))) bypass that transform.
// Declare the attribute on runtimeElements variants so Gradle can disambiguate them.
afterEvaluate {
    val rfgDeobfAttr = org.gradle.api.attributes.Attribute.of("rfgDeobfuscatorTransformed", Boolean::class.javaObjectType)
    configurations["runtimeElements"].attributes {
        attribute(rfgDeobfAttr, true)
    }
}
