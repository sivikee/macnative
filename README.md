# MacNative

Play the Windows games you own on Steam and GOG on your Mac, from one launcher. No Wine config files, no bottles to manage, no setup hell.

MacNative is a native SwiftUI app. It borrows its design language and its per-game settings model from [GameNative](https://github.com/utkarshdalal/GameNative), the Android launcher, and runs games through Wine, DXVK and DXMT under the hood.

> Status: **v0.1, early.** Expect rough edges and games that don't run yet.

## What works in v0.1

- **Library.** A GameNative-style grid with Steam, GOG and Custom sources. It has tabs (All / Installed / Favorites / Steam / GOG / Custom), search and favorites, and the selected game's artwork blurs into the backdrop.
- **GOG.** Sign in, see the Windows games you own, and install them with one click. MacNative downloads the offline installer and runs it silently, with no Galaxy client. Launching reads `goggame-*.info`.
- **Steam.** One click installs the official Windows Steam client into its own prefix. Installed and owned games show up in the library, and Install / Play are passed to the client. That means Steam DRM, cloud saves and achievements keep working.
- **Custom games.** Add any Windows `.exe`. Artwork is matched automatically.
- **Per-game settings**, modelled on GameNative's container config:
  - graphics backend (WineD3D / DXVK / DXMT)
  - Wine engine and Windows version
  - Retina mode, virtual desktop and ⌘-as-Ctrl
  - MSync / ESync and AVX
  - DXVK HUD, async and FPS cap; Metal HUD
  - launch arguments, DLL overrides and environment variables
- **Controllers.** Xbox, PlayStation (DualShock 4 / DualSense), Switch Pro and MFi pads drive the launcher menus through Apple's GameController framework. In games, Wine's bundled SDL2 exposes them as XInput controllers. The keyboard works too.
- **Engine manager.** Downloads and switches Wine builds. DXVK and DXMT are fetched automatically the first time a game needs them.

## How it runs Windows games

| Layer | What it does | Source |
|---|---|---|
| Rosetta 2 | Translates x86_64 Wine to Apple Silicon | Apple (the only system-wide prerequisite) |
| Wine (Staging/Devel) | The Windows API | [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds) |
| MoltenVK | Vulkan on top of Metal | Bundled in the Wine build |
| DXVK-macOS | Direct3D 10/11 → Vulkan | [Gcenx/DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) |
| DXMT | Direct3D 10/11 → Metal | [3Shain/dxmt](https://github.com/3Shain/dxmt) |
| WineD3D | Direct3D 9 and older → OpenGL | Built into Wine |

Proton is Linux-only, so MacNative uses the same building blocks that Proton and CrossOver use on macOS. DXMT needs files inside Wine's own lib folder. Rather than changing the engine, MacNative makes an APFS clone of it (instant, no extra disk space) and adds DXMT to the clone.

## Self-contained by design

Everything MacNative creates lives in **one folder**: engines, prefixes, downloads, logs, artwork cache, account tokens, settings and the library. Delete the folder and it's all gone.

- **Release builds:** `~/Library/Application Support/MacNative`
- **Dev builds** (`scripts/build.sh`): `./data` inside this repo (gitignored)
- **Override:** the `MACNATIVE_HOME=/some/path` environment variable

MacNative never installs Homebrew packages, system Wine or anything else outside that folder. The one exception is Rosetta 2. If it's missing, MacNative offers to install it through Apple's own `softwareupdate`, behind the standard admin prompt.

## Build

Requirements: macOS 14+, Apple Silicon, Xcode command line tools.

```sh
scripts/build.sh            # dev build → build/MacNative.app, data in ./data
open build/MacNative.app

scripts/build.sh --release  # release build, data in Application Support
```

The project is a plain Swift package with no dependencies, so `swift build` works too.

## Project layout

```
Sources/MacNative/
  App/         App entry, AppState (library, installs, launching), navigation, controller input
  Core/        Models (Game, GameConfig, …) and Paths (the single data root)
  Services/    EngineManager, WineRunner, SteamService, GOGService, Downloader, VDF parser, …
  UI/          Theme (GameNative palette + Bricolage Grotesque), Library, Game page, Settings, Setup
  Resources/   Fonts (SIL OFL)
scripts/build.sh
```

## Roadmap

**v0.2 – make more games run**
- Per-game known-good configs, auto-applied (like GameNative's community configs)
- Bring-your-own D3DMetal from Apple's Game Porting Toolkit, for DirectX 12
- Controller navigation inside the settings screens
- Running state and playtime for Steam games; quit Steam cleanly when a game exits

**v0.3 – native stores**
- Native Steam login and depot downloads (no Windows client), the way GameNative uses JavaSteam
- GOG cloud saves; resumable and parallel GOG downloads
- Epic Games (Legendary-compatible)

**Later**
- Compatibility reports, an in-game overlay/quick menu, Game Mode tuning, signed and notarized releases with auto-update

## Credits & licenses

MacNative is licensed under **GPL-3.0** (see `LICENSE`), the same licence as GameNative, whose design it follows.

Third-party pieces:
- **Downloaded at runtime:** Wine (LGPL), DXVK (zlib), DXMT (zlib), MoltenVK (Apache-2.0). None of them are bundled in this repo.
- **Bundled:** the Bricolage Grotesque font (SIL OFL 1.1, see `Sources/MacNative/Resources/Fonts/OFL.txt`).
- **GOG sign-in:** uses the public GOG Galaxy client credentials, the same ones Heroic, Lutris and GameNative use.

Not affiliated with Valve, GOG, Apple or the GameNative project.
