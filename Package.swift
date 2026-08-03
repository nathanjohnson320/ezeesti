// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Ezeesti",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "EzeestiCore", targets: ["EzeestiCore"]),
        .library(name: "EzeestiASR", targets: ["EzeestiASR"]),
        .library(name: "EzeestiLLM", targets: ["EzeestiLLM"]),
        .library(name: "EzeestiTTS", targets: ["EzeestiTTS"]),
        .library(name: "EzeestiTutor", targets: ["EzeestiTutor"]),
        .library(name: "EzeestiUI", targets: ["EzeestiUI"]),
    ],
    targets: [
        .target(
            name: "EzeestiCore",
            resources: [
                .copy("Resources/Lessons"),
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
            name: "EzeestiUI",
            dependencies: ["EzeestiCore", "EzeestiTutor"]
        ),
        .testTarget(
            name: "EzeestiCoreTests",
            dependencies: ["EzeestiCore"]
        ),
        .testTarget(
            name: "EzeestiTutorTests",
            dependencies: ["EzeestiTutor", "EzeestiCore", "EzeestiLLM"]
        ),
    ]
)
