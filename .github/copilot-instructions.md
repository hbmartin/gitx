# GitHub Copilot Instructions for GitX

## Project Overview

GitX is a native macOS graphical client for the `git` version control system. It is built with Objective-C and Swift using Xcode, targeting macOS.

## Tech Stack

- **Language**: Objective-C (primary), Swift (secondary)
- **UI Framework**: AppKit (Cocoa)
- **Build System**: Xcode (`.xcodeproj` / `.xcworkspace`)
- **Git Integration**: Uses `libgit2` via the `ObjectiveGit` framework (in `External/`)
- **VCS**: Git

## Project Structure

- `Classes/` — Main application source code
  - `Controllers/` — View and window controllers (AppKit MVC pattern)
  - `git/` — Git model layer (`PBGitRepository`, `PBGitCommit`, `PBGitRef`, `PBGitIndex`, etc.)
  - `Views/` — Custom AppKit views
  - `Util/` — Utility helpers
- `External/` — Third-party dependencies (e.g., ObjectiveGit/libgit2)
- `Resources/` — App resources (nibs, icons, etc.)
- `GitXUITests/` — UI test targets
- `.github/workflows/` — CI workflows (GitHub Actions)

## Coding Conventions

- Follow existing Objective-C patterns with `PB`-prefixed class names for project classes
- Use `NS_ASSUME_NONNULL_BEGIN` / `END` and nullability annotations in headers
- Prefer AppKit APIs; avoid UIKit
- Swift files coexist with Objective-C via the bridging header `GitX-Bridging-Header.h`
- Use `.clang-format` settings for C/Objective-C formatting

## Key Concepts

- `PBGitRepository` is the central model representing an open git repository
- `PBGitCommit` represents a single git commit
- `PBGitIndex` manages the staging area
- `PBGitRef` represents git refs (branches, tags, remotes)
- The history graph is built by `PBGitGrapher` / `PBGitHistoryGrapher`
- The sidebar uses source-view items (e.g., `PBSourceViewGitBranchItem`)

## Build Requirements

- macOS with Xcode 26.6 or newer installed
- Signing is set per target in `GitX.xcodeproj` and cannot be overridden from `Dev.xcconfig`; target settings outrank xcconfigs. Build with `CODE_SIGNING_ALLOWED=NO` or change the team in Xcode's Signing & Capabilities tab.
- Build through `scripts/xcodebuild.sh`, which pins the toolchain and the derived data path

## License

GPL version 2 — ensure any contributions are compatible.
