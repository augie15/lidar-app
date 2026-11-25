# Notes for App Review

Paste into **App Review Information, Notes**. Attach nothing else. No sign-in is required.

## Contact

Brett Auger, brett@augiesrentals.ca. Phone entered directly in App Store Connect (not kept in the repo).

## Sign-in

None. Tilda has no accounts or login. Leave "Sign-in required" unchecked.

## Notes to paste

```
Tilda is a free, private 3D scanning app: no accounts, ads, analytics or in-app purchases. Everything runs on device; the app makes no network calls of its own.

NEW IN 1.1: 3D photos (on-device Gaussian splats), scanning tips, a scan focus for summaries, better fixture finding, and iOS 18 support.

HARDWARE
Scanning needs a LiDAR iPhone (iPhone 12 Pro or later Pro models). iPhone only. Without LiDAR the app opens and tapping a scan mode explains that LiDAR is needed; Home, Settings, feedback and saved scans still work. A demo video is available on request at brett@augiesrentals.ca.

CAMERA
Used for scanning only; the prompt appears at the first scan. All camera, depth and photo data stays on the device.

HOW TO TEST (no login)
1. Room: tap Room, "One room", "Start scanning". Walk slowly, pointing at walls, floor and corners for 30 to 60 s, tap Done. Open the scan for the 3D preview, room summary, photo tour and walk-through.
2. Whole floor: Room, "Whole floor". Scan a room, tap "Next room", walk through the doorway, "Continue", then "Finish floor". Rooms merge into one model.
3. Object, Photoreal (Settings, Object mode): circle a small object as guided; it processes on device in 1 to 5 min.
4. Object, LiDAR quick: scan an object for a few seconds; the model is ready at once.
5. Mesh: tap Mesh (Mesh, Point cloud or Surfaces in Settings), walk around, tap Done.
6. Export: open a scan, tap USDZ, OBJ, STL or PLY under "Export as", choose Save to Files.
7. Flash: tap the flash button during a scan.
8. 3D photo (iPhone 15 Pro or later): on a room scan's "3D photo" card choose Quick, tap "Make 3D photo" and keep the app open (a few minutes; the phone gets warm and training pauses itself if too hot). Then "View 3D photo": drag to orbit, pinch to zoom, two fingers to pan.
9. Scanning tips: during a room or mesh scan a small hint suggests tilting up or down, changing height or slowing down. Settings, Guidance turns it off.
10. Feedback: Settings, Send feedback opens a prefilled public GitHub issue page in an in-app browser. Nothing is sent unless you submit it on GitHub.

APPLE INTELLIGENCE (OPTIONAL, iOS 26+)
Scans get a name, summary and tags; Ask answers questions about a scan; "What do you scan for?" (asked once at first open, also in Settings) shapes summaries. On iOS 27, room scan photos are checked for HVAC vents, bathroom fans and baseboard heaters, and "Check with 3D photo" also checks views drawn from a 3D photo. On-device Foundation Models and Vision only; Private Cloud Compute is not used. On iOS 18 to 25 or other devices these features are absent.

SIRI, SHORTCUTS, SPOTLIGHT
"Start a room scan in Tilda", "Open my latest scan in Tilda". Scans are indexed in on-device Spotlight.

FILES
Scans are in the app's Documents folder, visible in Files (On My iPhone, Tilda). Not synced anywhere.

OPEN-SOURCE CODE
Two on-device libraries for 3D photos: msplat-ios (Apache-2.0, splat training, built from source) and MetalSplatter (MIT, splat viewing). Neither connects to the network. Licences: Settings, Open-source licences.

EXPORT COMPLIANCE
Only OS-provided encryption, no network connections. ITSAppUsesNonExemptEncryption is NO.

PRIVACY
Data Not Collected. Policy: https://augie15.github.io/lidar-app/privacy.html
```

## Export compliance answers (if App Store Connect asks)

- Does your app use encryption? The Info.plist key `ITSAppUsesNonExemptEncryption` is `false`, so the question is skipped on upload.
- If asked anyway: "Uses only encryption provided by Apple (exempt)", no proprietary or third-party cryptography, no HTTPS calls by the app.
- France: no additional documentation is needed.

## Things a reviewer may ask

- "Why does it need a LiDAR device?" RoomPlan, Object Capture and ARKit scene reconstruction require LiDAR. Apple's own `isSupported` checks are used.
- "Why does 3D photo need an iPhone 15 Pro or later?" Training needs a LiDAR iPhone with at least 8 GB of memory. On other iPhones the 3D photo card does not appear, and a 3D photo made elsewhere can still be viewed.
- "Does it work on iPad?" The build targets iPhone only (`TARGETED_DEVICE_FAMILY = 1`). iPad Pro with LiDAR can run it in iPhone compatibility mode.
