// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ezeesti",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "EzeestiCore", targets: ["EzeestiCore"]),
        .library(name: "EzeestiASR", targets: ["EzeestiASR"]),
        .library(name: "EzeestiLLM", targets: ["EzeestiLLM"]),
        .library(name: "EzeestiTTS", targets: ["EzeestiTTS"]),
        .library(name: "EzeestiTutor", targets: ["EzeestiTutor"]),
        .library(name: "EzeestiLearning", targets: ["EzeestiLearning"]),
        .library(name: "EzeestiUI", targets: ["EzeestiUI"]),
    ],
    targets: [
        .target(
            name: "EzeestiCore",
            resources: [
                .copy("Resources/Lessons"),
                .copy("Resources/Texts"),
                .copy("Resources/Lexicon"),
            ]
        ),
        .target(
            name: "EzeestiASR",
            dependencies: ["EzeestiCore"]
        ),
        .target(
            name: "EzeestiLLM",
            dependencies: ["EzeestiCore"]
        ),
        .target(
            name: "EzeestiTTS",
            dependencies: ["EzeestiCore"]
        ),
        .target(
            name: "EzeestiTutor",
            dependencies: ["EzeestiCore", "EzeestiASR", "EzeestiLLM", "EzeestiTTS"]
        ),
        .target(
            name: "EzeestiLearning",
            dependencies: ["EzeestiCore", "EzeestiASR", "EzeestiLLM", "EzeestiTTS"]
        ),
        .target(
            name: "EzeestiUI",
            dependencies: [
                "EzeestiCore",
                "EzeestiASR",
                "EzeestiLLM",
                "EzeestiTTS",
                "EzeestiTutor",
                "EzeestiLearning",
            ]
        ),
        .testTarget(
            name: "EzeestiCoreTests",
            dependencies: ["EzeestiCore"]
        ),
        .testTarget(
            name: "EzeestiTutorTests",
            dependencies: ["EzeestiTutor", "EzeestiCore", "EzeestiLLM", "EzeestiASR"]
        ),
        .testTarget(
            name: "EzeestiLearningTests",
            dependencies: ["EzeestiLearning", "EzeestiCore"]
        ),
        .testTarget(
            name: "EzeestiLLMTests",
            dependencies: ["EzeestiLLM", "EzeestiCore"]
        ),
        .testTarget(
            name: "EzeestiUITests",
            dependencies: ["EzeestiUI"]
        ),
    ]
)
