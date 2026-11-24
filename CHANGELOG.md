# Changelog

All notable changes to Tilda are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Fixture review: HVAC vents, bathroom fans and baseboard heaters are highlighted on the floor plan, the 3D model and the walkthrough, with counts on the scan page. Found fixtures can be confirmed, moved, retyped, resized (heater length), deleted with undo, or added by tapping the plan.

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
