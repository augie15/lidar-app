# Tilda: work plan

**Tilda = The Instant LiDAR Digitizing App.** A free iPhone app (built and tested on an iPhone 17 Pro Max) that scans rooms and objects with LiDAR and exports them in a few taps.

## Principles
- **Completely free.** Only Apple's built-in frameworks: RoomPlan, RealityKit Object Capture, ARKit, ModelIO and QuickLook. No accounts, no servers, no ads, no third-party libraries, no in-app purchases.
- **On-device and private.** Scans never leave the phone unless you export them.
- **Simple.** One home screen with three scan buttons and a list of saved scans.

## Features (v1)
| Mode | Apple API | Output | Best for |
|---|---|---|---|
| **Room** | RoomPlan `RoomCaptureView` | Clean USDZ model with walls, doors, windows and furniture boxes | Floor plans and layouts |
| **Object** | `ObjectCaptureSession`, then on-device `PhotogrammetrySession` | Textured, photoreal USDZ | Furniture, rental items, products |
| **Mesh** | ARKit scene reconstruction (`ARMeshAnchor`) | Raw LiDAR mesh | Whole spaces, odd shapes, Blender |

**Library:** each scan is saved to `Documents/Scans/<id>/` with a `scan.json` holding its name, mode and date. Scans can be renamed and deleted, and they also show up in the Files app.

**Preview:** QuickLook in 3D and AR.

**Export:** a share sheet offering **USDZ** (native), plus **OBJ**, **STL** and **PLY** converted with ModelIO. You can AirDrop a scan, save it to Files or send it by email.

## Screens
1. **Home:** three large tiles (Room, Object, Mesh) above a list of recent scans with thumbnails.
2. **Scan screen** (one per mode): a full-screen camera view with one main button (Start, then Done) and short coaching text.
3. **Processing:** a progress bar while the model is built. Object models take about 1 to 5 minutes.
4. **Scan detail:** the 3D preview, with Export, Rename and Delete buttons.

## Milestones
1. **Project skeleton:** XcodeGen `project.yml`, a SwiftUI app, a deployment target of iOS 26, and camera permission. Signing comes from an untracked `Config/Signing.local.xcconfig` because the repo is public.
2. **Scan library:** a scan model and store, the home list, QuickLook preview, rename and delete.
3. **Room scan:** RoomPlan capture saved as USDZ.
4. **Mesh scan:** ARKit mesh capture, converted with ModelIO and saved as USDZ.
5. **Object scan:** the Object Capture guided flow (detect, capture, finish), then on-device reconstruction with a progress bar.
6. **Export:** USDZ, OBJ (with MTL), STL and PLY through the share sheet.
7. **Polish:** app icon, empty states, a warning on devices without LiDAR, and an "unsupported" message.
8. **Test on device:** build to the iPhone 17 Pro Max and scan one room, one object and one mesh, then open each export in Files and Blender.
9. **TestFlight:** an archive and upload so the app installs on your phone over the air.
10. **Optional later:** a 2D floor-plan PDF from RoomPlan, real-world measurements, multi-room merge, and an App Store listing.

## Risks and notes
- LiDAR capture can't run in the Simulator. The Simulator only checks that the app builds and that the UI looks right, so real testing needs the phone.
- Object reconstruction uses a lot of memory and heat. The capture session is released before processing starts.
- OBJ, STL and PLY exports may drop textures. USDZ keeps them.
- Distribution: the paid Apple Developer account means installs from Xcode don't expire after 7 days, and TestFlight and the App Store are both available. The app stays free to users.
