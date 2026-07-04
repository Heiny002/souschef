# SousChef AI

Voice-guided cooking companion for iOS. Extracts structured recipes from web
pages and social-video URLs using a deterministic-first extraction pipeline
(Schema.org JSON-LD → Microdata → heuristic HTML → LLM fallback), cross-checks
them against household dietary profiles, and guides you through cooking hands-free.

- **Platform:** iOS 17+ (Swift 6, SwiftUI, SwiftData)
- **Design:** Dark mode, warm palette
- **Dependencies:** [SwiftSoup](https://github.com/scinfu/SwiftSoup) via Swift Package Manager

## Requirements

- **macOS** with **Xcode 16 or newer** (iOS 17 SDK + Swift 6 toolchain)
- An iOS 17+ simulator (bundled with Xcode)
- Internet access on first build (to resolve the SwiftSoup package)
- *Optional:* an Anthropic API key to enable the LLM-fallback extraction layers

> iOS builds require Apple's toolchain, which only runs on macOS. You cannot
> build or run this project on Linux or Windows.

## Quick start (run in a simulator)

```bash
git clone https://github.com/Heiny002/souschef.git
cd souschef

# Create Secrets.xcconfig from the template (see "API key" below)
./Scripts/bootstrap.sh

# Open in Xcode and press Run, or build from the command line:
xcodebuild -project SousChef.xcodeproj -scheme SousChef \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

To open in the IDE instead: `open SousChef.xcodeproj`, pick an iOS simulator in
the scheme's run destination, and press **⌘R**.

Running in a simulator does **not** require an Apple Developer account or code
signing — the empty `DEVELOPMENT_TEAM` is fine. (A real device build would need
a signing team.)

## API key (optional)

The project's base configuration references `Secrets.xcconfig`, which is
gitignored so keys never land in the repo. `Scripts/bootstrap.sh` copies the
committed `Secrets.example.xcconfig` template into place. To turn on the
LLM-fallback layers, edit `Secrets.xcconfig`:

```
ANTHROPIC_API_KEY = sk-ant-...
```

The app builds and runs without a key; the deterministic extraction layers work
regardless, and the LLM-fallback features simply stay inert.

## Running the tests

```bash
xcodebuild test -project SousChef.xcodeproj -scheme SousChef \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Regenerating the Xcode project

The committed `SousChef.xcodeproj` is generated from `project.yml` via
[XcodeGen](https://github.com/yonaskolb/XcodeGen). You only need this if you
change targets, resources, or build settings:

```bash
brew install xcodegen   # once
xcodegen generate
```

## Continuous integration

`.github/workflows/ios-build.yml` builds and tests the project on a macOS
runner on every push and pull request, giving verification that can't be done
on non-macOS machines.

## Project layout

```
Sources/SousChef/
  Extraction/     6-layer recipe extraction pipeline + bio-link resolution
  Models/         SwiftData models (Recipe, DinerProfile, DietDefinition, …)
  Diet/           Profile matching + substitution suggestions
  CookMode/       Voice-first, step-by-step cooking UI helpers
  Views/          SwiftUI screens (Library, Import, Review, Cook Mode, …)
  DesignSystem/   Colors, typography, spacing tokens
  Resources/      Bundled fonts (Lora) and data (diets, foods, substitutions)
Tests/SousChefTests/   Unit tests
```
