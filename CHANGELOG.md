# Changelog

All notable changes to Tilda are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Scan focus: on first open Tilda asks what you scan for (General, Renovation, Real estate, Interior design or Home inventory). Insights summaries and the order of facts follow it, and a card can be rewritten for a new focus. Change it in Settings.
- Scanning tips: during room and mesh scans, a small hint suggests tilting up or down, changing height, slowing down or looking back from the other side, until coverage is good. One tip at a time, with cooldowns. Turn it off in Settings, Guidance.
- Check with 3D photo: for scans with a 3D photo, fixture detection also looks at views rendered from the splat, square-on to each wall and up at the ceiling, with exact camera positions.
- 3D photos: train a Gaussian splat from a scan's photos on the iPhone (Pro models with 8 GB or more), with blurry photos skipped and people masked out by on-device Vision, then view or share it. Before training, a photo check rates the expected result (Good, Fair or Likely soft) from photo count for the room size, repeat views, height variety and ceiling coverage, with what to do differently. While scanning, frames blurred by fast turning are skipped, and Dense photo density now keeps up to 900 photos. Training takes a cooling break when the phone gets hot (iOS thermal state serious) and stops with a checkpoint at critical. Uses msplat-ios (Apache-2.0, built from source) and MetalSplatter (MIT); licences are in Settings.
- Fixture review: HVAC vents, bathroom fans and baseboard heaters are highlighted on the floor plan, the 3D model and the walkthrough, with counts on the scan page. Found fixtures can be confirmed, moved, retyped, resized (heater length), deleted with undo, or added by tapping the plan.

### Changed
- Tilda now runs on iOS 18 and later (was iOS 26), for iPhones that can't be updated, such as managed company devices. On iOS 18 to 25, Insights show measurements and tags without a written summary, Ask and the scan focus prompt are hidden, and everything else works.

### Fixed
- Fixture checks now include photos tilted up at the ceiling (the tour's photo picker ignored tilt, so a fan above a door could be skipped), and a bathroom fan with a built-in light is no longer rejected as a light.
- Closing the 3D photo viewer now releases the splat's memory.
- Vents and bathroom fans: each find now gets a close-up second look (grille required; lights, range hoods, detectors, door frames and bare surfaces rejected), and impossible box shapes are dropped. A room with no vents no longer shows made-up ones.

## [1.0.0] - 2026-11-23

First App Store version (build 2), submitted to App Review on 2026-11-23.

### Added
- Room scans with RoomPlan, for one room or a whole floor merged into a single model.
- Room summary with floor area, open floor area and estimated gross area (adjustable wall thickness), ceiling height, and door and window counts, with PDF export.
- Photo tour pinned to the floor plan, and a first-person 3D walkthrough.
- Object scans: Photoreal (Object Capture, built on the iPhone) and LiDAR quick, plus Photos for Mac export.
- Mesh scans: mesh, point cloud and surfaces, with LiDAR depth options (confidence, range, point spacing, remove people, 4K camera).
- Export to USDZ, OBJ, STL and PLY, and photos with camera poses (Nerfstudio-style `transforms.json`).
- Scan library with rename, delete, 3D preview and AR view. Scans are visible in the Files app.
- Apple Intelligence on supported iPhones: automatic names, summaries and tags, and Ask. Runs on device.
- Fixtures in room scans: HVAC vents, bathroom fans and baseboard heaters found in scan photos (on-device, iOS 27) and placed on the floor plan, with manual add and delete in the photo tour.
- Siri and Shortcuts actions and Spotlight indexing.
- Flashlight control and an option to turn it on at scan start.
- Settings for units, room model detail, photo density and wall thickness.
- In-app feedback that opens a prefilled GitHub issue or an email draft.
- Support for devices without LiDAR: scan modes show a clear message instead of opening.
- Privacy manifest, app icon, and a privacy policy, support page and landing page on GitHub Pages.
- Issue templates, `scripts/archive.sh` for App Store archives, and App Store submission notes in `docs/app-store/`.

### Fixed
- Photo tour no longer collapses turn-in-place scans to a single photo.
