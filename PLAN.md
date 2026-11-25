# Tilda: work plan

**Tilda = The Instant LiDAR Digitizing App.** A free iPhone app (built and tested on an iPhone 17 Pro Max) that scans rooms, objects and spaces with LiDAR and exports them in a few taps.

## Principles
- **Completely free.** Apple frameworks (RoomPlan, RealityKit Object Capture, ARKit, ModelIO, SceneKit, QuickLook, Vision, Foundation Models and App Intents) plus two on-device open-source libraries for Gaussian splats: msplat-ios (Apache-2.0, vendored and built from source in `Vendor/Msplat`) and MetalSplatter (MIT). No accounts, no servers, no ads, no networking, no in-app purchases.
- **On-device and private.** Scans never leave the phone unless you export or share them. The app makes no network calls.
- **Simple.** One home screen with three scan buttons and a list of saved scans.

## Features (v1)
| Mode | Apple API | Output | Best for |
|---|---|---|---|
| **Room** | RoomPlan | USDZ with walls, doors, windows and furniture boxes. One room, or a whole floor merged from several rooms | Floor plans and layouts |
| **Object** | Object Capture with on-device photogrammetry (Photoreal), or LiDAR mesh cropped to a box (LiDAR quick) | Textured or plain USDZ | Furniture, rental items, products |
| **Mesh** | ARKit scene reconstruction and LiDAR depth | Mesh, colored point cloud, or surfaces colored by type | Whole spaces, odd shapes, Blender |

- **Room summary:** floor, open-floor and estimated gross area (adjustable wall thickness), ceiling height, door and window counts, PDF export.
- **Photo tour and walkthrough:** photos pinned to the floor plan, and a first-person 3D walk through the scan.
- **Library:** each scan is saved to `Documents/Scans/<id>/` with a `scan.json`. Scans can be renamed and deleted, and they show up in the Files app.
- **Preview:** 3D and AR with QuickLook.
- **Export:** USDZ, OBJ (with MTL), STL and PLY, photos with poses (Nerfstudio-style `transforms.json`), Photos for Mac, and the room summary PDF.
- **Apple Intelligence (optional):** names, summaries and tags, Ask, Siri and Shortcuts, Spotlight.
- **Settings and extras:** units, room detail, photo density, LiDAR depth options, flash, and in-app feedback to GitHub issues or email.

## Milestones
1. **Done:** project skeleton. XcodeGen `project.yml`, SwiftUI app, iOS 26 deployment target, camera permission. Signing comes from an untracked `Config/Signing.local.xcconfig` because the repo is public.
2. **Done:** scan library. Model and store, home list, preview, rename and delete.
3. **Done:** room scan, including whole-floor merge.
4. **Done:** mesh scan, with point cloud and surfaces modes and LiDAR depth options.
5. **Done:** object scan. Photoreal and LiDAR quick, plus Photos for Mac.
6. **Done:** export. USDZ, OBJ, STL, PLY and photos with poses.
7. **Done:** polish. App icon, empty states, a clear message on devices without LiDAR.
8. **Done:** room summary with floor, open-floor and estimated gross area, photo tour and walkthrough.
9. **Done:** Apple Intelligence (insights, Ask), Siri Shortcuts and Spotlight.
10. **Done:** feedback flow, privacy manifest, privacy policy, support page, landing page, issue templates and App Store text.
11. **Done:** release tooling. `scripts/archive.sh` and the submission checklist.
12. **Next:** device testing. Scan one room, one floor, one object and one mesh on the iPhone 17 Pro Max and open each export in Files and Blender. Also check on a non-LiDAR device that scan modes show their message.
13. **Next:** TestFlight. Archive and upload so the app installs over the air.
14. **Next:** App Store submission, following `docs/app-store/checklist.md`.

## Later ideas
- iPad layout.
- Floor-plan PDF with dimensions on the walls.
- AR measure tool.
- CI, once GitHub runners ship Xcode 27.

## Risks and notes
- LiDAR capture can't run in the Simulator. The Simulator only checks that the app builds and that the UI looks right, so real testing needs the phone.
- Object reconstruction uses a lot of memory and heat. The capture session is released before processing starts. The iPhone builds at reduced detail, so full detail needs Photos for Mac.
- Point clouds can get large. Point spacing and range settings keep them manageable.
- OBJ, STL and PLY exports may drop textures. USDZ keeps them.
- `UIRequiredDeviceCapabilities` can't require LiDAR, so non-LiDAR devices can install the app. Every scan path is gated and shows a message instead.
- Apple Intelligence features depend on device support and are optional.
- Distribution: a paid Apple Developer account means installs from Xcode don't expire after 7 days, and TestFlight and the App Store are both available. The app stays free to users.
- The repo is public and licensed all rights reserved. Keep signing details and secrets out of tracked files.
