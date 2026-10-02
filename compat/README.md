# Compatibility database

`games.json` lists known results and known-good settings per game. MacNative downloads the latest
version from this repository and applies a game's `config` automatically, unless the player already
changed that game's settings.

## Adding or updating a game

Open a pull request editing `games.json`, or use the **Report compatibility** button in MacNative
(game page → ⋯), which opens a pre-filled issue.

| Field | Meaning |
|---|---|
| `store` | `steam`, `gog` or `custom` |
| `id` | Steam app id or GOG product id |
| `status` | `works` (plays fine), `playable` (minor issues), `broken` (doesn't run), `unknown` |
| `revision` | Bump it when you change `config`, so players get the new settings |
| `notes` | What works, what doesn't, workarounds |
| `testedWith` | MacNative version, engine, Mac model, macOS version |
| `config` | Settings to apply (all optional, see below) |

`config` keys mirror the per-game settings:

- `graphics`: `wined3d`, `dxvk`, `dxmt` or `d3dmetal`
- `windowsVersion`: `win11`, `win10`, `win81`, `win7` or `winxp64`
- `sync`: `msync`, `esync` or `none`
- `engine`: an engine id from Settings → Engines, e.g. `wine-staging-11.18` or `ws-winecx24.0.7`
- `retinaMode`, `advertiseAVX`, `dxvkAsync`, `commandAsControl`, `useSteamClient`, `stripSteamStub`: `true` / `false`
- `virtualDesktop`: e.g. `"1920x1080"`
- `fpsLimit`: a number, `0` for unlimited
- `launchArguments`, `dllOverrides`: strings
- `environment`: an object of environment variables, e.g. `{ "DXVK_HUD": "fps" }`
