# Submission checklist

Last updated: 2026-11-23. Status: **version 1.0 (build 2) submitted to App Review on 2026-11-23**, Waiting for Review.
Available in 174 countries (China mainland excluded, see section 6), Free, releases automatically after approval.

Legend: **[x] done in the repo**, **[ ] owner only** (needs you in App Store Connect, GitHub or on a device), **[~] decide**.

## 1. Repo and build

- [x] Privacy manifest `Tilda/PrivacyInfo.xcprivacy` (no tracking, no collected data, UserDefaults CA92.1). It is bundled in the .app.
- [x] `ITSAppUsesNonExemptEncryption = false` and `NSCameraUsageDescription` in `Tilda/Info.plist`.
- [x] App icon (1024 px) in the asset catalog.
- [x] Privacy policy, support and landing pages in `docs/`.
- [x] Store text drafted in `docs/app-store/` (metadata, privacy, age rating, review notes, screenshots).
- [x] `scripts/archive.sh` archives and exports for App Store Connect.
- [x] Committed and pushed to `main`.
- [x] Repo meta: `LICENSE` (all rights reserved), README, CHANGELOG, CONTRIBUTING, SECURITY, PR template.
- [x] Unsupported-device messages all say "iPhone with a LiDAR scanner" (target is iPhone-only).
- [x] Remove or sanitize the team ID in `PLAN.md` (done: it no longer appears in tracked files). The repo is public. The team ID is not secret in itself (it is public inside any signed app), but the project rule is to keep it out of tracked files.

## 2. GitHub

- [x] GitHub Pages enabled: deploys from `main`, folder `/docs`.
- [x] Live and returning 200: https://augie15.github.io/lidar-app/ , [privacy.html](https://augie15.github.io/lidar-app/privacy.html) and [support.html](https://augie15.github.io/lidar-app/support.html). App Review opens the privacy and support URLs.
- [x] Repo description, homepage (the Pages URL) and topics set.
- [x] Support email added: brett@augiesrentals.ca (on the support and privacy pages, and in the review notes).
- [x] Issue templates `bug_report.yml`, `feature_request.yml` and `config.yml` are on `main` (the in-app feedback links use them), and the `bug` and `enhancement` labels exist.

## 3. Device testing (iPhone 17 Pro Max)

- [x] Room, Object and Mesh scans work (owner confirmed).
- [x] Flash button in each scan mode.
- [x] Photo tour shows multiple views (fixed: turn-in-place scans no longer collapse to one photo).
- [x] Fixtures (HVAC vents, bathroom fans, baseboard heaters) found on a real room scan through TestFlight build 2 (owner confirmed).
- [ ] Whole floor: Next room, then Continue across 2 or 3 rooms, then Finish floor. Check the merged model and the summary totals.
- [ ] Room summary on a fresh scan: floor area, open floor and est. gross against a room of known size. Check PDF share.
- [ ] Walk through on a room scan (look, stick, wall collision).
- [ ] Object: Photoreal with the coverage preview, and LiDAR quick (box placement, crop, color).
- [ ] Mesh: Point cloud alignment and frame rate, Surfaces colors and legend, colored Mesh.
- [ ] Apple Intelligence: auto-name, Insights, Ask (paint, sofa fit), Home search, Spotlight, and "Start a room scan in Tilda" with Siri.
- [ ] Exports: USDZ, OBJ, STL, PLY, Photos + poses zip, Photos for Mac zip (open one in Files or on a Mac).
- [ ] Send feedback: GitHub opens prefilled, and the email option works.
- [ ] Settings: each toggle takes effect; storage size is shown.

## 4. App Store Connect

- [x] Apple Developer Program membership is active and the Agreements, Tax and Banking page shows the Free Apps agreement as Active. No bank details are needed for a free app.
- [x] App record created: "Tilda: Room & Object Scanner", bundle ID `com.augie15.tilda`, SKU `tilda-ios`, primary language English (Canada), Apple ID 6838497058. App ID registered by Xcode automatic signing.
- [x] Pricing **Free**; availability 174 countries (all except China mainland). Mac and Apple Vision Pro availability turned off (clears ITMS-90984).
- [x] Paste the subtitle, promotional text, description and keywords from `metadata.md`. Enter the support, marketing and privacy URLs and the copyright line.
- [x] Choose the primary and secondary categories.
- [x] Complete App Privacy as in `app-privacy.md` (Data Not Collected) and publish it.
- [x] Answer the age rating questionnaire as in `age-rating.md` (4+).
- [x] Add the review contact and notes from `review-notes.md`. Sign-in required: off.
- [x] Content rights: answer No (the app does not show third-party content).
- [x] Simulator screenshots 1, 3, 5 and 8 taken (`docs/app-store/screenshots/`, 1320 x 2868, no alpha).
- [x] Simulator screenshots uploaded to both iPhone slots: 6.3" (required, resized to 1206 x 2622) and 6.9" (1320 x 2868).
- [ ] Next version: take device screenshots 2, 4, 6 and 7 (and optionally Ask) on the phone and add them.

## 5. Build and upload

- [x] Run `scripts/archive.sh --bump --upload` (uploads to App Store Connect) or `scripts/archive.sh --bump` and upload the exported .ipa with Transporter. Distribution signing must be available (Xcode, Settings, Accounts).
- [x] Wait for processing (about 10 to 30 minutes). Fix any email from App Store Connect about the build.
- [x] Optional but recommended: install through TestFlight and scan one room, one object and one mesh on the phone before submitting.
- [x] Select the build on the version page, answer the export compliance prompt if shown (uses only Apple encryption, exempt), and add "What's New".

## 6. Submit

- [x] Submitted to App Review on 2026-11-23 (release: automatic after approval). Before it could be added, China mainland had to be removed from availability: apps with AI features need a Security Assessment and an AI-generated content filing there.
- [x] Tagged `v1.0.0` and dated the CHANGELOG entry.
- [ ] Wait for the review email (up to 48 hours). If rejected, fix and resubmit with `scripts/archive.sh --bump --upload`.

## Things to know before you submit

1. **No LiDAR device requirement.** `UIRequiredDeviceCapabilities` has only `arkit`. Apple has no public LiDAR key, so the app will be listed on and installable by iPhones without LiDAR (and App Review may test on one). It must degrade gracefully, and it does. See the audit below.
2. **iPad.** The target is iPhone-only, so iPads install it in compatibility mode only if the App Store allows it. LiDAR iPad Pros could run it. The review notes say so.
3. **Apple Intelligence.** The features are optional. The listing says "supported iPhones".
4. **Version numbers.** Marketing version is 1.0. Each upload needs a unique build number (`--bump`).
5. **Do not enable Kids Category.**

## Graceful degradation audit (grep for `isSupported`)

| Place | Check | What a non-LiDAR user sees |
|---|---|---|
| `Tilda/Views/DeviceSupport.swift` | `RoomCaptureSession.isSupported`, `ObjectCaptureSession.isSupported`, `ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)` | Central gate per mode |
| `Tilda/Views/HomeView.swift` `start(_:)` | `DeviceSupport.isSupported(kind)` | Instead of opening the scanner, an alert shows "Room/Object/Mesh scans need an iPhone with a LiDAR scanner." |
| `Tilda/Scanning/RoomScanView.swift` | `RoomCaptureSession.isSupported` (3 places) | The camera view is not created, and an error alert is shown. `start()` returns early. |
| `Tilda/Scanning/MeshScanView.swift` | `supportsSceneReconstruction(.mesh)` | The AR session is not started |
| `Tilda/Scanning/Object/LidarObjectScanView.swift` | `supportsSceneReconstruction(.mesh)` | Unsupported state |
| `Tilda/Scanning/Object/PhotorealObjectScanView.swift` and `ObjectScanModel.swift` | `ObjectCaptureSession.isSupported`, `PhotogrammetrySession.isSupported` | Guarded, shows a failure message |

Result: every scan path is gated, so there is no crash path found by grep. Also test on a non-LiDAR device or confirm the app opens without scans before submitting, since the Simulator reports unsupported for all modes and can be used for this check.

The earlier wording mismatch ("iPhone or iPad" in Room and Mesh) is fixed: every message now says iPhone.
