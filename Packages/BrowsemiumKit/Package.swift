// swift-tools-version: 6.1

import Foundation
import PackageDescription

let isHeadless = ProcessInfo.processInfo.environment["BROWSEMIUM_HEADLESS"] == "1"

var products: [Product] = [
    .library(name: "BrowsemiumCore", targets: ["BrowsemiumCore"]),
    .library(name: "BrowsemiumData", targets: ["BrowsemiumData"]),
    .library(name: "BrowsemiumEngineKit", targets: ["BrowsemiumEngineKit"]),
    .library(name: "BrowsemiumEngine", targets: ["BrowsemiumEngine"]),
    .library(name: "BrowsemiumAI", targets: ["BrowsemiumAI"])
]

var targets: [Target] = [
    .target(
        name: "BrowsemiumCore",
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .target(
        name: "BrowsemiumData",
        dependencies: [
            "BrowsemiumCore",
            .product(name: "GRDB", package: "GRDB.swift")
        ],
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    // The engine seam: the protocol a window uses and the vocabulary both
    // engines speak. Kept free of WebKit and Chromium so either edition can
    // link it without dragging the other engine in.
    .target(
        name: "BrowsemiumEngineKit",
        dependencies: ["BrowsemiumCore"],
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .target(
        name: "BrowsemiumEngine",
        dependencies: ["BrowsemiumCore", "BrowsemiumEngineKit"],
        resources: [
            .copy("Resources/Readability.js"),
            .copy("Resources/Readability-LICENSE.md"),
            .copy("Resources/StarterContentRules.json")
        ],
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .target(
        name: "BrowsemiumAI",
        dependencies: [
            "BrowsemiumCore",
            .product(name: "Markdown", package: "swift-markdown")
        ],
        resources: [
            .copy("Resources/ModelCapabilities.json")
        ],
        swiftSettings: [.swiftLanguageMode(.v6)]
    )
]

if isHeadless {
    products.append(.executable(name: "BrowsemiumHeadlessTests", targets: ["BrowsemiumHeadlessTests"]))
    targets.append(
        .executableTarget(
            name: "BrowsemiumHeadlessTests",
            dependencies: [
                "BrowsemiumCore",
                "BrowsemiumData",
                "BrowsemiumEngine",
                "BrowsemiumEngineKit",
                "BrowsemiumAI",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Tests",
            exclude: [
                "BrowsemiumAITests",
                "BrowsemiumCoreTests",
                "BrowsemiumDataTests",
                "BrowsemiumEngineTests",
                "BrowsemiumUISnapshotTests",
                "BrowsemiumUITests"
            ],
            sources: ["HeadlessRunner.swift"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    )
} else {
    products += [
        .library(name: "BrowsemiumUI", targets: ["BrowsemiumUI"]),
        .executable(name: "BrowsemiumPreview", targets: ["BrowsemiumPreview"])
    ]
    targets += [
        .target(
            name: "BrowsemiumUI",
            dependencies: [
                "BrowsemiumCore",
                "BrowsemiumData",
                "BrowsemiumEngine",
                "BrowsemiumEngineKit",
                "BrowsemiumAI"
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "BrowsemiumPreview",
            dependencies: ["BrowsemiumUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BrowsemiumCoreTests",
            dependencies: ["BrowsemiumCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BrowsemiumDataTests",
            dependencies: [
                "BrowsemiumCore",
                "BrowsemiumData",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BrowsemiumEngineTests",
            dependencies: ["BrowsemiumCore", "BrowsemiumEngine", "BrowsemiumEngineKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BrowsemiumAITests",
            dependencies: ["BrowsemiumCore", "BrowsemiumAI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BrowsemiumUITests",
            dependencies: ["BrowsemiumCore", "BrowsemiumEngine", "BrowsemiumEngineKit", "BrowsemiumUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BrowsemiumUISnapshotTests",
            dependencies: ["BrowsemiumUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
}

let package = Package(
    name: "BrowsemiumKit",
    platforms: [
        .macOS(.v14)
    ],
    products: products,
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0")
    ],
    targets: targets,
    swiftLanguageModes: [.v6]
)
