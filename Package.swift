// swift-tools-version: 5.9
//
// SousChefDesk — a macOS harness that compiles the iPhone app's ACTUAL extraction code
// (Sources/SousChef/Extraction + Scaling + Conversion + the recipe models) into a
// three-pane desktop app: URL input → extracted-recipe review → cook-mode display. It exists
// so any problem post can be debugged with the real pipeline — real fetch ladders, real
// Vision OCR, real parsers — without an Xcode build-and-deploy to a phone.
//
// This package is independent of the iOS build: the app still builds from
// SousChef.xcodeproj (XcodeGen), and nothing here is registered in project.pbxproj.
//
// Run it:   swift run SousChefDesk
// Cookies:  put cookies.txt at the repo root (or SOUSCHEF_COOKIES=/path) for Instagram.
// LLM:      export ANTHROPIC_API_KEY=sk-ant-… to enable the structurer rungs.
import PackageDescription

let package = Package(
    name: "SousChefDesk",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Same dependency + floor as the app target (project.yml).
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "SousChefDesk",
            dependencies: ["SwiftSoup"],
            path: "Sources",
            sources: [
                "SousChef/Extraction",
                "SousChef/Scaling",
                "SousChef/Conversion",
                // IngredientConverter renders the SwiftData Ingredient model directly; the
                // models file is self-contained (Foundation + SwiftData, both on macOS 14).
                "SousChef/Models/Recipe.swift",
                "SousChefDesk",
            ],
            resources: [
                .copy("SousChef/Resources/Data")
            ]
        ),
    ]
)
