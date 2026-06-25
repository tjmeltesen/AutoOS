plugins {
    id("com.gtnewhorizons.gtnhconvention")
}

// Configure Javadoc to prevent build failures
tasks.withType<Javadoc>().configureEach {
    val javadocOptions = options as StandardJavadocDocletOptions
    javadocOptions.addStringOption("Xdoclint:none", "-quiet")
    javadocOptions.encoding = "UTF-8"
    javadocOptions.charSet = "UTF-8"
}