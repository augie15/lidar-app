# Notes for App Review

Paste into **App Review Information, Notes**. Attach nothing else. No sign-in is required.

## Contact

Brett Auger, brett@augiesrentals.ca (phone: add yours in App Store Connect).

## Sign-in

None. Tilda has no accounts or login. Leave "Sign-in required" unchecked.

## Notes to paste

```
Tilda is a free, private 3D scanning app. It has no accounts, no ads, no analytics and no in-app purchases. Everything runs on device. The app makes no network calls of its own.

HARDWARE REQUIREMENT
Scanning needs an iPhone with a LiDAR scanner (iPhone 12 Pro or later Pro models). The app is iPhone-only. The reviewer's device must have LiDAR to test scanning.
On devices without LiDAR the app still opens. Tapping a scan mode shows an alert explaining that "Room/Object/Mesh scans need an iPhone with a LiDAR scanner". Home, Settings, the feedback screen and any saved scans remain usable.
If you cannot test on a LiDAR device, a short demo video is available on request at brett@augiesrentals.ca.

CAMERA PERMISSION
The camera is used for scanning only. The permission prompt appears the first time you start a scan. All camera, depth and photo data stays on the device.

HOW TO TEST EACH MODE (no login)
1. Room: Home, tap Room. Choose "One room", tap "Start scanning", walk slowly while pointing at walls, floor and corners for about 30 to 60 seconds, then tap Done. A 3D model is saved. Open it for the 3D preview, room summary (square footage), photo tour and walk-through.
2. Whole floor: Home, tap Room, choose "Whole floor". Tap "Start scanning", scan one room, tap "Next room", walk through the doorway and tap "Continue", then tap "Finish floor". The rooms are merged into one model with a floor plan.
3. Object, Photoreal: Home, tap Object, set Settings, Object, mode to Photoreal. Place a small object on a table, follow the on-screen guidance to circle it, then let it process on device (1 to 5 minutes).
4. Object, LiDAR quick: set Object mode to "LiDAR quick" in Settings. Scan the object for a few seconds and finish. The model is ready immediately.
5. Mesh: Home, tap Mesh. Choose Mesh, Point cloud or Surfaces in Settings, then walk around a space and tap Done.
6. Export: open any scan, then under "Export as" tap USDZ, OBJ, STL or PLY. The iOS share sheet appears. Choose "Save to Files".
7. Flash: tap the flash button during a scan, or turn on Settings, "Flash on when a scan starts".
8. Feedback: Settings, Send feedback. Enter a title and tap the GitHub button to open a prefilled public GitHub issue page in an in-app browser. Nothing is submitted unless you submit it on GitHub.

APPLE INTELLIGENCE (OPTIONAL)
On supported iPhones with Apple Intelligence turned on, scans get an automatic name, summary and tags, and an Ask button lets you question a scan. This uses Apple's on-device Foundation Models and Vision only. Private Cloud Compute is not used. On other devices these features are simply absent and nothing else changes. Settings has a toggle for automatic summaries.

SIRI, SHORTCUTS AND SPOTLIGHT
App Shortcuts (App Intents) let you say "Start a room scan in Tilda" or "Open my latest scan in Tilda". Scans are indexed in on-device Spotlight. No Siri usage description is needed.

FILES
Scans are saved in the app's Documents folder, which is visible in the Files app under On My iPhone, Tilda (UIFileSharingEnabled and LSSupportsOpeningDocumentsInPlace). They are not synced to any server.

EXPORT COMPLIANCE
The app uses only encryption provided by Apple's operating system and makes no network connections itself. ITSAppUsesNonExemptEncryption is set to NO in Info.plist.

PRIVACY
App Privacy: Data Not Collected. Privacy policy: https://augie15.github.io/lidar-app/privacy.html
```

## Export compliance answers (if App Store Connect asks)

- Does your app use encryption? The Info.plist key `ITSAppUsesNonExemptEncryption` is `false`, so the question is skipped on upload.
- If asked anyway: "Uses only encryption provided by Apple (exempt)", no proprietary or third-party cryptography, no HTTPS calls by the app.
- France: no additional documentation is needed.

## Things a reviewer may ask

- "Why does it need a LiDAR device?" RoomPlan, Object Capture and ARKit scene reconstruction require LiDAR. Apple's own `isSupported` checks are used.
- "Does it work on iPad?" The build targets iPhone only (`TARGETED_DEVICE_FAMILY = 1`). iPad Pro with LiDAR can run it in iPhone compatibility mode.
