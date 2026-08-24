<div align="center">
  <img src="docs/icon.png" width="120" alt="Chunky app icon" />

  # Chunky

  **A fast, native comic book reader for iOS, iPadOS, macOS, and tvOS — CBZ, CBR, and PDF, with iCloud sync, remote libraries, and a reading experience tuned for long series.**

  [![Platform](https://img.shields.io/badge/platform-iOS%2017%2B%20%7C%20macOS%2014%2B%20%7C%20tvOS%2017%2B-lightgrey)](#requirements)
  [![Swift](https://img.shields.io/badge/Swift-5-orange)](#requirements)
  [![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

</div>

Chunky is a SwiftUI comic/manga reader built for people with large digital libraries — CBZ and CBR archives, PDFs, and loose folders of scanned images. It runs natively on iPhone/iPad, Mac, and Apple TV, keeps your library in sync via iCloud, and can pull comics straight from WebDAV, SMB, FTP/SFTP, OPDS servers, or your Mac's shared folders.

<div align="center">
  <img src="docs/screenshots/iphone-library.png" width="18%" alt="iPhone library grid, grouped by series" />
  <img src="docs/screenshots/iphone-reader.png" width="18%" alt="iPhone reader" />
  <img src="docs/screenshots/ipad-library.png" width="27%" alt="iPad library" />
  <img src="docs/screenshots/mac-library.png" width="27%" alt="Mac library" />
</div>
<div align="center">
  <img src="docs/screenshots/tvos-library.png" width="49%" alt="Apple TV library, ten-foot UI" />
  <img src="docs/screenshots/tvos-detail.png" width="49%" alt="Apple TV comic detail screen" />
</div>

## ✨ Features

### 📚 Library
- Automatic grouping by series, with favorites and read/unread progress
- iCloud Drive sync — one library across all your devices
- Import from WebDAV, SMB, FTP/SFTP, AFP, OPDS, or a local upload server reachable from any browser on the same Wi-Fi
- Turn a folder of loose scanned images into a proper comic archive
- "Rebuild library" recovery tool for restores gone half-right

### 📖 Reader
- CBZ, CBR, and PDF, with left-to-right or manga (right-to-left) reading direction
- Single or double-page spreads, automatic or manual
- Configurable page-turn feel for both tap and swipe — instant, sliding, or cross-fade
- Per-page zoom modes, including a scrollable "fit width" mode for tall pages
- One-handed mode and "hot corner" shortcuts for quick navigation without a HUD
- Auto-crop scan borders, auto tint/contrast correction, and upscaling for low-res pages
- Motion-blur while panning a zoomed page, and light/dark/sepia page themes
- Panel/region selection to share just one panel instead of a whole page

### 🔒 Privacy & control
- Face ID / Touch ID–protected parental lock, with auto-lock on background
- Kiosk mode with an idle-reset timer, built for shop-display or shared-device use
- Local-only crash diagnostics via MetricKit — nothing leaves the device

Chunky is a from-scratch SwiftUI rebuild of an earlier iOS-only app of the same name, extended with macOS support, iCloud sync, remote library access, and a dedicated tvOS app along the way.

## 🧰 Requirements

- Xcode 16+
- iOS 17+ / macOS 14+ / tvOS 17+ deployment targets
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the `.xcodeproj` (not checked into the repo — see below)

## 🚀 Getting started

```bash
git clone https://github.com/Scunio/Chunky.git
cd Chunky

brew install xcodegen
xcodegen generate

open Chunky.xcodeproj
```

The project is defined in [`project.yml`](project.yml) and the `.xcodeproj` is generated from it (and gitignored), so the repo stays diff-friendly. The per-platform `Info.plist` and `.entitlements` files under `Support/` are generated the same way and are likewise gitignored. **Re-run `xcodegen generate` any time `project.yml` changes** — and before opening the project after a fresh clone or a `git pull`, since targets (including the test targets) exist only in `project.yml`.

`Chunky_iOS`, `Chunky_macOS`, and `Chunky_tvOS` are three separate targets rather than one multiplatform target, so each ships only the Info.plist keys and entitlements that apply to it. `Scripts/verify-plists.sh <derived-data-path> [macos|ios|both]` checks that for iOS/macOS, and runs in CI.

Once open in Xcode, pick the `Chunky_iOS`, `Chunky_macOS`, or `Chunky_tvOS` scheme and run. No signing team is configured by default — set your own in Xcode's Signing & Capabilities tab before running on a device or enabling iCloud sync. tvOS has no Files app/iCloud Drive, so it always uses remote servers (WebDAV, SMB, FTP/SFTP, OPDS) or a local upload server instead — no iCloud sync there.

Dependencies ([ZIPFoundation](https://github.com/weichsel/ZIPFoundation) and [Unrar.swift](https://github.com/mtgto/Unrar.swift)) are resolved automatically by Swift Package Manager on first build.

## 🗂️ Project structure

```
Sources/Chunky/
├── Views/       SwiftUI screens (library, reader, settings, accounts…)
├── ViewModels/  Import/library orchestration
├── Services/    Archive readers, iCloud, remote clients, image processing…
├── Models/      Core Data model extensions
└── Resources/   Assets, Core Data model, acknowledgements
```

`Support/` (generated) holds the per-platform `Info.plist` and `.entitlements`; `Scripts/` holds build-verification scripts.

The reader supports CBZ/CBR/PDF via a shared `ComicPageProvider` protocol (see `Sources/Chunky/Services/ComicPageProvider.swift`), so adding a new archive format is a matter of implementing one more provider.

## 🧪 Tests

```bash
xcodegen generate
xcodebuild test -scheme Chunky_macOS -destination 'platform=macOS'
xcodebuild test -scheme Chunky_iOS -destination 'platform=iOS Simulator,name=iPhone 16'
xcodebuild test -scheme Chunky_tvOS -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)'
```

Unit tests use **Swift Testing** (`@Test` / `#expect`); UI tests use **XCTest**, since XCUITest has no Swift Testing equivalent — don't try to unify them.

The unit test bundles are *not* hosted in the app: they compile the sources under test directly (everything except `ChunkyApp.swift`). Hosting them would mean signing the app, and the iCloud entitlements need a provisioning profile that CI doesn't have. The trade-off is that tests live in the same module as the code, so there is no `@testable import Chunky`.

UI tests need the real app, so they live in the separate `ChunkyUI_iOS` / `ChunkyUI_macOS` / `ChunkyUI_tvOS` schemes and run nightly rather than on every PR.

Fixtures under `Tests/ChunkyTests/Fixtures` are committed, not generated at test time: `Unrar.swift` only decompresses, so a `.cbr` has to be checked in regardless, and one source of truth beats two. Regenerate the images and the PDF with `swift Scripts/make-fixtures.swift <output-dir>`, then re-zip.

## 🤝 Contributing

Issues and pull requests are welcome — from bug fixes to entirely new features. If you're planning something larger than a small fix, opening an issue first to discuss the approach is appreciated but not required.

## 🙏 Acknowledgements

Chunky is built on [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) and [Unrar.swift](https://github.com/mtgto/Unrar.swift) (both MIT). Full license texts are also bundled in-app under Settings → Licenze open source.

## 📄 License

MIT — see [LICENSE](LICENSE).
