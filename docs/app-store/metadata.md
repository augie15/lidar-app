# App Store Connect metadata

Paste these into App Store Connect. Character counts are exact (counted by script).

## App name (30 characters max)

"Tilda" alone is probably taken. Names are checked for uniqueness only when you save them in App Store Connect, so try them in order.

| Option | Name | Characters |
|---|---|---|
| 1 | `Tilda: LiDAR 3D Scanner` | 23 |
| 2 (**in use**: the App Store Connect record was created with this name) | `Tilda: Room & Object Scanner` | 28 |
| 3 | `Tilda LiDAR Room Scanner` | 24 |

## Subtitle (30 characters max)

`LiDAR floor plans & 3D models` (29 characters)

Written for the name in use, "Tilda: Room & Object Scanner". It avoids repeating words from the name or keywords, because Apple indexes all three together, and adds "LiDAR" and "3D", which the name no longer has. "Free" moved to the keywords.

## Promotional text (170 characters max)

```
Scan any room or object with your iPhone's LiDAR. Get floor plans, square footage and 3D models, then export to USDZ, OBJ, STL or PLY. Free and private.
```
(152 characters). This field can be changed at any time without a new review.

## Description (4000 characters max)

(2341 characters)

```
Tilda turns the LiDAR scanner in your iPhone Pro into a fast, private 3D scanner. Scan a room, a whole floor or an object, then export in a few taps. Free, with no accounts, no ads and no tracking.

ROOM SCANS
- Scan one room, or switch to whole-floor mode and merge several rooms into one model.
- Get a clean 3D model with walls, doors, windows and furniture, plus a floor plan.
- Room summary with square footage, ceiling height, and door and window counts. Share it as a PDF.
- Photo tour: swipe through photos pinned to spots on the floor plan.
- Walk-through: move through your scanned space in 3D.

OBJECT SCANS
- Photoreal: a textured 3D model built on your iPhone with Apple's Object Capture.
- LiDAR quick: an instant shape that works well for shiny or plain objects.

MESH SCANS
- Mesh: solid surfaces colored from the camera.
- Point cloud: millions of colored LiDAR points.
- Surfaces: walls, floor, furniture and more in separate colors.

EXPORT ANYWHERE
- USDZ, OBJ, STL and PLY for Blender, CAD, 3D printing and AR.
- Photos with camera poses for photogrammetry and Gaussian splat tools.
- Photos for Mac, to rebuild an object at full detail with Object Capture.
- Share by AirDrop, Files, Mail or any app. Scans also show up in the Files app.

APPLE INTELLIGENCE (OPTIONAL)
- On supported iPhones, Tilda names and summarizes your scans, and suggests tags.
- Ask a scan questions such as "How much paint for the walls?" or "Will a 2 m sofa fit?"
- It all runs on your iPhone with Apple's on-device model. Nothing is sent to a cloud.

SIRI, SHORTCUTS AND SPOTLIGHT
- Say "Start a room scan in Tilda" or "Open my latest scan in Tilda".
- Find your scans in Spotlight search.

FREE AND PRIVATE
- No account, no ads, no in-app purchases, no analytics.
- Scans stay on your iPhone. Tilda makes no network connections of its own.
- Data leaves your phone only when you choose to export or share a file.

REQUIREMENTS
- An iPhone with a LiDAR scanner (Pro models, iPhone 12 Pro and later) running iOS 26 or later. Without LiDAR, Tilda explains that scanning is not available.
- Apple Intelligence features need a supported iPhone with Apple Intelligence turned on.

Tips: walk slowly, keep walls, floor and corners in view, and use the flash in dark rooms.

Questions or ideas? Visit the support page or send feedback from Settings.
```

## Keywords (100 characters max)

```
measure,square footage,sqft,usdz,obj,stl,ply,point cloud,mesh,photogrammetry,roomplan,home,free
```
(95 characters.)

Rules followed: comma-separated, no spaces after commas, none of the words from the name in use (tilda, room, object, scanner) or the subtitle (lidar, floor, plans, 3d, models).

## Categories

- Primary: **Utilities**. Alternative: **Graphics & Design**.
- Secondary: **Productivity**. Alternative: **Business**.

Reasoning: Tilda is a capture and measurement tool, and Utilities has less crowding than Graphics & Design. Graphics & Design suits the 3D export angle but pits it against creative suites. Pick one primary and one secondary in App Store Connect.

## URLs

| Field | URL |
|---|---|
| Support URL | https://augie15.github.io/lidar-app/support.html |
| Marketing URL | https://augie15.github.io/lidar-app/ |
| Privacy Policy URL | https://augie15.github.io/lidar-app/privacy.html |

These work after GitHub Pages is enabled (Settings, Pages, Deploy from branch, main, /docs).

## Contact information (App Review and support)

brett@augiesrentals.ca. This email is also published on the support and privacy pages.

## Copyright

`2026 Brett Auger` (App Store Connect adds the symbol itself, so do not type one. Replace with your legal name or company if different.)

## Other fields

- Version: 1.0 (build number is bumped by `scripts/archive.sh --bump`).
- Price: Free. No in-app purchases.
- What's New (v1.0): `First release.`
- Age rating: see `age-rating.md`. Privacy: see `app-privacy.md`.
