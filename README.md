# Tilda: the instant LiDAR digitizing app

Scan a room, a whole floor or an object with your iPhone's LiDAR scanner and export it in a few taps.

<!-- App Store badge: coming soon. Replace the link below once the app is live.
[![Download on the App Store](docs/images/app-store-badge.svg)](https://apps.apple.com/app/idXXXXXXXXXX)
-->
**App Store: coming soon.** Website: <https://augie15.github.io/lidar-app/>

Tilda is free, private and runs entirely on your iPhone. There are no accounts, no ads, no tracking and no servers. It uses Apple frameworks plus two open-source libraries for 3D photos (msplat-ios and MetalSplatter), which also run entirely on the phone. Your scans leave the phone only when you choose to export or share them.

## Features

### Room
- Scan one room, or scan a whole floor and merge the rooms into a single model (RoomPlan).
- Room summary with floor area, open floor area and estimated gross area (you set the assumed wall thickness), plus ceiling height and door and window counts. Share it as a PDF.
- Photo tour: swipe through photos pinned to spots on the floor plan.
- Walkthrough: move through the scanned space in 3D in first person.

### Object
- **Photoreal:** a textured model built on the iPhone with Apple's Object Capture. The iPhone builds at reduced detail.
- **LiDAR quick:** an instant shape cropped from the LiDAR mesh, good for shiny or plain objects.
- **Photos for Mac:** keep the capture photos and export them to rebuild the object at full detail with Object Capture on a Mac.

### Mesh
- **Mesh:** solid surfaces, colored from the camera.
- **Point cloud:** a dense colored cloud built from the LiDAR depth map.
- **Surfaces:** the mesh colored by type (wall, floor, ceiling, table, seat, door, window).
- LiDAR depth options: confidence level, maximum range (1.5, 3 or 5 m), point spacing (5, 10 or 20 mm), remove people, and 4K camera color.

### 3D photos (Gaussian splats)
- Turn a scan with photos into a photo-real 3D splat, trained on the iPhone. Needs an iPhone 15 Pro or later Pro model.
- Apple's on-device Vision models drop blurry photos and mask out people walking through, so they are not baked in.
- View it with orbit, pan and zoom, or share the `.ply` for other splat viewers.

### Export
- USDZ, OBJ, STL and PLY through the share sheet (AirDrop, Files, Mail). Point clouds export as PLY.
- Photos + poses: your photos with camera poses in a Nerfstudio-style `transforms.json`, for photogrammetry and Gaussian splat tools.
- Room summary PDF.
- Scans are also visible in the Files app under On My iPhone, Tilda.

### Apple Intelligence
On supported iPhones with Apple Intelligence turned on. All optional, all on device.
- **Insights:** automatic names, summaries and tags for new scans.
- **Ask:** ask a scan a question, such as how much paint the walls need or whether a sofa will fit.
- **Siri and Shortcuts:** start a room, object or mesh scan, or open your latest scan, by voice.
- **Spotlight:** find your scans from iPhone search.

### Settings and extras
- Units (feet and square feet, or metres and square metres), room model detail, photo density and wall thickness.
- Flash: turn on the flashlight from the scan screen, or have it start on automatically.
- Feedback: send a bug report or feature request from Settings. It opens a prefilled GitHub issue (or an email draft) that you review before sending.

## Screenshots

Screenshots are not in the repo yet. To add them, save PNG files in `docs/images/` and replace the placeholders below.

| Home | Room scan | Room summary |
|---|---|---|
| `docs/images/home.png` | `docs/images/room.png` | `docs/images/summary.png` |

| Object | Point cloud | Export |
|---|---|---|
| `docs/images/object.png` | `docs/images/point-cloud.png` | `docs/images/export.png` |

For example: `![Home](docs/images/home.png)`. App Store sizes are listed in [docs/app-store/screenshots.md](docs/app-store/screenshots.md).

## Requirements

- An iPhone or iPad Pro with a LiDAR scanner. The app is built for iPhone and tested on an iPhone 17 Pro Max.
- iOS 18 or later. Names, summaries and Ask need iOS 26 with Apple Intelligence; finding fixtures from photos needs iOS 27.
- Xcode 27 or later to build from source.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen).
- The splat trainer is vendored prebuilt from source in `Vendor/Msplat`. To rebuild it, run `scripts/build-msplat.sh` (needs CMake and Xcode's Metal Toolchain).

## Build from source

```bash
brew install xcodegen
printf 'DEVELOPMENT_TEAM = YOURTEAMID\n' > Config/Signing.local.xcconfig   # untracked
xcodegen generate
open Tilda.xcodeproj
```

Choose your device as the run destination and press Run. Scanning needs a real LiDAR device and does not work in the Simulator. The Simulator is only useful for checking that the app builds and the UI looks right.

`Config/Signing.local.xcconfig` is ignored by git. Never commit it.

The app icon is rendered from the `TildaMark` SwiftUI view. After changing the mark, run `sh scripts/render-icon.sh`.

## Project structure

```
Tilda/
  App/        App entry point
  AI/         Apple Intelligence: insights, Ask, measurements, Spotlight indexing
  Export/     USDZ, OBJ, STL, PLY, photos and poses export
  Intents/    Siri and Shortcuts (App Intents) and in-app navigation
  Models/     Scan model and store, settings, floor plan, room facts
  Scanning/   Capture flows
    Room/     RoomPlan capture, whole-floor merge, floor plan and area geometry
    Object/   Photoreal (Object Capture) and LiDAR quick scans
    Mesh/     Mesh, point cloud and surfaces capture and export
  Theme/      Colors, type and the Tilda mark
  Views/      Home, scan detail, settings, room summary, photo tour,
              walkthrough, feedback
docs/         GitHub Pages site (landing, privacy, support) and App Store text
scripts/      archive.sh and app icon rendering
```

## Privacy

Tilda has no servers and makes no network calls. Scans, photos and measurements stay on your iPhone, and Apple Intelligence features use Apple's on-device model only. Data leaves the phone only when you export, share or send feedback. Read the full [privacy policy](https://augie15.github.io/lidar-app/privacy.html).

## Support and feedback

- In the app: Settings, Send feedback.
- Bugs and ideas: [GitHub Issues](https://github.com/augie15/lidar-app/issues/new/choose).
- Email: brett@augiesrentals.ca
- Help page: <https://augie15.github.io/lidar-app/support.html>

To report a security problem, see [SECURITY.md](SECURITY.md).

## Release

Archive and export with `scripts/archive.sh` (run it with `--help` for options). The full submission steps are in [docs/app-store/checklist.md](docs/app-store/checklist.md). See [PLAN.md](PLAN.md) for status and roadmap, and [CHANGELOG.md](CHANGELOG.md) for what changed.

## License

All rights reserved. The source is visible but may not be copied, modified or redistributed without written permission. See [LICENSE](LICENSE). Contributions are welcome through issues, see [CONTRIBUTING.md](CONTRIBUTING.md).
