# Submission checklist

Legend: **[x] done in the repo**, **[ ] owner only** (needs you in App Store Connect, GitHub or on a device), **[~] decide**.

## 1. Repo and build

- [x] Privacy manifest `Tilda/PrivacyInfo.xcprivacy` (no tracking, no collected data, UserDefaults CA92.1). It is bundled in the .app.
- [x] `ITSAppUsesNonExemptEncryption = false` and `NSCameraUsageDescription` in `Tilda/Info.plist`.
- [x] App icon (1024 px) in the asset catalog.
- [x] Privacy policy, support and landing pages in `docs/`.
- [x] Store text drafted in `docs/app-store/` (metadata, privacy, age rating, review notes, screenshots).
- [x] `scripts/archive.sh` archives and exports for App Store Connect.
- [ ] Commit and push to `main` (the coordinator does this).
- [x] Remove or sanitize the team ID in `PLAN.md` (done: it no longer appears in tracked files). The repo is public. The team ID is not secret in itself (it is public inside any signed app), but the project rule is to keep it out of tracked files.

## 2. GitHub

- [ ] Enable GitHub Pages: repo Settings, Pages, Deploy from a branch, `main`, folder `/docs`.
- [ ] Open https://augie15.github.io/lidar-app/privacy.html, `support.html` and the home page and check they load. App Review opens the privacy and support URLs.
- [x] Support email added: brett@augiesrentals.ca (on the support and privacy pages, and in the review notes).
- [ ] Confirm the GitHub issue templates `bug_report.yml` and `feature_request.yml` exist on `main` (the in-app feedback links use them).

## 3. App Store Connect

- [ ] Apple Developer Program membership is active and the Agreements, Tax and Banking page shows the Free Apps agreement as Active. No bank details are needed for a free app.
- [ ] Create the app record (My Apps, New App): platform iOS, bundle ID `com.augie15.tilda`, SKU (for example `tilda-ios`), primary language English. Use a name option from `metadata.md` (the name is global, so try options in order).
- [ ] Set Pricing to **Free** (price tier 0) and choose availability.
- [ ] Paste the subtitle, promotional text, description and keywords from `metadata.md`. Enter the support, marketing and privacy URLs and the copyright line.
- [ ] Choose the primary and secondary categories.
- [ ] Complete App Privacy as in `app-privacy.md` (Data Not Collected) and publish it.
- [ ] Answer the age rating questionnaire as in `age-rating.md` (4+).
- [ ] Add the review contact and notes from `review-notes.md`. Sign-in required: off.
- [ ] Content rights: answer No (the app does not show third-party content).
- [ ] Take the device screenshots as in `screenshots.md` and upload the 6.9" set.

## 4. Build and upload

- [ ] Run `scripts/archive.sh --bump --upload` (uploads to App Store Connect) or `scripts/archive.sh --bump` and upload the exported .ipa with Transporter. Distribution signing must be available (Xcode, Settings, Accounts).
- [ ] Wait for processing (about 10 to 30 minutes). Fix any email from App Store Connect about the build.
- [ ] Optional but recommended: install through TestFlight and scan one room, one object and one mesh on the phone before submitting.
- [ ] Select the build on the version page, answer the export compliance prompt if shown (uses only Apple encryption, exempt), and add "What's New".

## 5. Submit

- [ ] Add for Review, then Submit to App Review. Release option: manual or automatic as you prefer.

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

Result: every scan path is gated, so there is no crash path found by grep. Remaining caveat: the Room scan error text says "iPhone or iPad", which is slightly different from the Home alert. Also test on a non-LiDAR device or confirm the app opens without scans before submitting, since the Simulator reports unsupported for all modes and can be used for this check. (fixed: all messages now say iPhone)
