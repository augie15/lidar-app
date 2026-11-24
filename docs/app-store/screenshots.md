# Screenshots

## Required sizes

Tilda is iPhone-only (`TARGETED_DEVICE_FAMILY = 1`), so only iPhone screenshots are needed. No iPad screenshots.

| Display | Pixels (portrait) | Status |
|---|---|---|
| **6.9" (required)** | **1320 x 2868**. Also accepted: 1290 x 2796, 1260 x 2736 | Required. Take these on the iPhone 17 Pro Max (it is a 6.9" device). |
| 6.5" | 1284 x 2778 or 1242 x 2688 | Optional. If you skip it, App Store Connect scales the 6.9" set down. |

Upload 1 to 10 screenshots per size, in PNG or JPEG, with no alpha channel, and no device frame needed. A full-screen capture from the phone is exactly 1320 x 2868. Press the side button and volume up together, then AirDrop them to your Mac.

App Preview video is optional (up to 30 seconds, same pixel sizes). A 15-second screen recording of a room scan is a good one.

## Shots to take (in this order)

Set up first: turn on Apple Intelligence if available, scan a furnished room and a plain object beforehand, and use a tidy space. Hide personal items, addresses and faces. Every screenshot can be taken on the device, since scanning does not work in the Simulator.

| # | Screen | Caption (add as overlay text if you use one) |
|---|---|---|
| 1 | Home screen with the three scan tiles and a few saved scans | Scan rooms and objects with LiDAR |
| 2 | Live room scan with the RoomPlan overlay on walls | Walk a room. Tilda builds the model. |
| 3 | Room summary: square footage, ceiling height, doors and windows | Square footage in seconds |
| 4 | Floor plan with photo tour pins and photos below | A photo tour of every room |
| 5 | Whole-floor scan: "Rooms: 3" chip, or the merged floor model | Merge a whole floor |
| 6 | Photoreal object scan result in the 3D preview | Photoreal objects, built on your iPhone |
| 7 | Mesh, point cloud or Surfaces preview in color | Mesh, point cloud and surfaces |
| 8 | Export section (USDZ, OBJ, STL, PLY) with the share sheet | Export to USDZ, OBJ, STL and PLY |

Optional extras if you have room (max 10): Ask screen answering "How much paint for the walls?" (caption "Ask your scan, on device"), and Shortcuts showing the Tilda actions ("Start a scan by voice").

## Simulator set (taken 2026-11-23)

In `docs/app-store/screenshots/`, 1320 x 2868 JPEG, no alpha, 9:41 status bar. Taken on the iPhone 17 Pro Max
Simulator with the Debug-only sample library (launch with `-TildaDemoData`; see `Tilda/App/DemoData.swift`, compiled out
of Release). The sample data is two room scans in the scanner's own format: real app screens, synthetic measurements.

| File | Covers shot | Caption |
|---|---|---|
| `01-home.jpg` | 1 | Scan rooms and objects with LiDAR |
| `02-room-summary.jpg` | 3 | Square footage in seconds |
| `03-whole-floor.jpg` | 5 | Merge a whole floor |
| `04-insights-export.jpg` | 8 | Export to USDZ, OBJ, STL and PLY |

Still needed from the phone (the Simulator cannot scan, and its Apple Intelligence runtime fails on Ask):
2 (live room scan), 4 (photo tour, needs real photos), 6 (photoreal object), 7 (mesh or point cloud), and the
optional Ask screen. Upload order suggestion: 1, 2, 3, 4, 5, 6, 7, 8.

To retake: build Debug for the Simulator, then
`xcrun simctl status_bar booted override --time 9:41 --batteryLevel 100 --batteryState charged`,
`xcrun simctl launch --terminate-running-process booted com.augie15.tilda -TildaDemoData` (seeds and replaces the
library), relaunch without the flag, and `xcrun simctl io booted screenshot <file>.png`. Flatten alpha before upload.

## Tips

- The app is dark-only. Use a 100% battery and a clean status bar (time 9:41 is a convention, not a rule).
- Apple Intelligence screens (Insights card, Ask) only show on supported iPhones. Do not claim features in captions that are not visible.
- Captions are marketing text. Keep them factual: do not use "best", prices or other-platform names.
- Do not show GitHub, the feedback screen or any third-party UI in screenshots.

## Creative assets (header and search result)

In `docs/app-store/creative/`, rendered by `scripts/render-creative.swift` (uses the real `TildaMark` and the screenshots above):

| File | Placement | Size | Art safe area |
|---|---|---|---|
| `header.png` | Product page header | 3840 x 1646 PNG (21:9) | 1646 x 661 at (1097, 493) |
| `search.png` | Search result | 3840 x 2560 PNG (3:2) | 2168 x 1030 at (836, 765) |

Both have no alpha and no prices, URLs or other platforms' logos. Upload them on the version page under "Header and Search Results". This is not possible while a version is Waiting for Review (App Store Connect hides the upload), so add them to the next version, or after release if App Store Connect allows editing them then.
