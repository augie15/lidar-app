# Tilda — The Instant LiDAR Digitizing App

A free, private iPhone app that scans rooms and objects with LiDAR and exports them in a few taps. Built only on Apple frameworks: no accounts, servers, ads or third-party code.

| Mode | How | Output |
|---|---|---|
| Room | RoomPlan | Clean USDZ model: walls, doors, windows, furniture boxes |
| Object | Object Capture + on-device photogrammetry | Textured, photoreal USDZ |
| Mesh | ARKit scene reconstruction | Raw LiDAR mesh as USDZ |

Each scan opens in an interactive 3D preview and can be viewed in AR. You can export it as **USDZ, OBJ, STL or PLY** through the share sheet (AirDrop, Files, Mail). Scans also appear in the Files app under *On My iPhone › Tilda*.

Requires an iPhone with LiDAR (Pro models). Developed on an iPhone 17 Pro Max, iOS 26+.

## Build

```bash
brew install xcodegen
printf 'DEVELOPMENT_TEAM = YOURTEAMID\n' > Config/Signing.local.xcconfig   # untracked
xcodegen generate
open Tilda.xcodeproj
```

Choose your iPhone as the run destination and press Run. Scanning doesn't work in the Simulator.

The app icon is rendered from the `TildaMark` SwiftUI view. After changing the mark, regenerate it with `sh scripts/render-icon.sh`.

See [PLAN.md](PLAN.md) for the roadmap.
