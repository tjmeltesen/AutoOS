plugins {
    id 'com.gtnewhorizons.retrofuturagradle' version '1.3.35'
}

group = 'autos'
version = '1.0.0'

java {
    toolchain {
        languageVersion = JavaLanguageVersion.of(8)
    }
}

minecraft {
    mcVersion = '1.7.10'
    username = 'AutoOS-QA'
}

repositories {
    maven {
        name = 'GTNH Maven'
        url = 'https://nexus.gtnewhorizons.com/repository/public/'
    }
    mavenCentral()
}

dependencies {
    // Horizon-QA GameTest framework
    testImplementation 'com.gtnewhorizons:Horizon-QA:1.0.+:dev'
}

// Horizon-QA CI mode: -Dhorizonqa.mode=ci passed via --mcJvmArgs in workflow
