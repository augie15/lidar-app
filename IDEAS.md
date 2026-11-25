# Ideas

Parked ideas, not scheduled. Each has the reasoning so it can be picked up later without redoing the research.

## Gaussian splats on the phone

**Status:** built (2026-11-24) as "3D photos", using msplat-ios for training and MetalSplatter for viewing. Kept here for the reasoning; see CHANGELOG.

**Idea:** turn a scan into a Gaussian splat on the iPhone itself, with no server and no account, and view it in the app. Pro phones only (17 Pro and later; 12 GB of memory on the 17 Pro).

### Why Tilda is well placed

- It already records photos with ARKit camera poses (the Nerfstudio-style `transforms.json` export), so it skips the slow step where desktop tools work out each camera position.
- LiDAR depth gives a starting point cloud. That trains faster than random points and keeps the room's true size and shape.
- Scaniverse already trains splats on iPhone in a minute or two for a room-sized scene, so this is known to work.

### Two stages

1. **Viewer (cheap):** open and view splat files (`.ply` / `.splat`) in the app. MetalSplatter is an open-source Swift and Metal renderer (MIT licence) that could be added as a package. A recent iPhone can show a few million splats smoothly.
2. **On-device training (the big job):** no Swift library exists for this. It needs the splat drawing and the training step written as Metal compute shaders. Expect a few weeks to get it working well.

### Constraints

- **Memory and heat:** cap the number of splats (around 1 to 2 million) and the photo resolution. Training takes minutes and warms the phone.
- **Running time:** use `BGContinuedProcessingTask` (iOS 26) so training can continue with a progress bar after the user leaves the app.
- **Privacy:** everything stays on the device, matching "Data Not Collected".
- Keep the photos-and-poses export for people who use desktop tools (Nerfstudio, Postshot, gsplat).

### Work when picked up

1. Check the current versions and licences of MetalSplatter and any Swift splat trainers that have appeared since.
2. Build the viewer stage and test performance on a 17 Pro.
3. Prototype training on one saved room: LiDAR points to start, then pose-based training. Measure time, memory and heat.
4. Decide on the user-facing flow: a "Make splat" action on a saved scan, Pro-only, with a time estimate.

## Optional tip jar ("Support Tilda")

**Status:** parked (2026-11-23). Revisit once there is real uptake data from version 1.0.

**Idea:** a gentle "Enjoying Tilda? Consider sending a dollar to support it" prompt. The app stays fully free; a tip unlocks nothing.

### Deciding signal

Tilda has no analytics by design, so judge uptake from App Store Connect only: App Analytics (impressions, downloads, sessions and retention from users who share data with developers), ratings and reviews, and in-app feedback (GitHub issues and email). Consider the tip jar once there is steady use, for example repeat sessions and a few hundred active devices a month.

### Recommended approach: in-app purchase tip jar

- Consumable in-app purchases, for example $0.99, $2.99 and $4.99, with a thank-you message. StoreKit 2, no server, no account, no tracking.
- Placement: a "Support Tilda" row in Settings, plus a one-time card after a user has saved a few scans. Never during a scan, never repeated.
- Why in-app purchase rather than an outside payment:
  - **Fees:** Apple's App Store Small Business Program takes 15%, so about $0.15 of a $1 tip. Stripe takes about 2.9% + $0.30, so about $0.33 of $1. Stripe only becomes cheaper at around $5 and up.
  - **Review rules:** guideline 3.1.1 expects tips and donations in an app to use in-app purchase. It works in every country with no storefront checks.
  - **Privacy:** Apple handles payment, so App Privacy can stay "Data Not Collected".

### Alternative considered: Stripe through the Augie's Rentals store

- A single "Support Tilda" product on the store, opened in Safari from the app.
- Since the 2025 Epic v. Apple ruling, apps on the **US** storefront may link to outside payment. Elsewhere, external links are not allowed or need special entitlements, and the EU has its own rules. The link would have to show only on the US storefront, which StoreKit's `Storefront.current` can check.
- Use $3 or more so fees do not take most of the tip. Payments count as the business's income, so check sales tax and bookkeeping with the accountant.
- This rule area changes often. Re-check the current App Review Guidelines (3.1.1 and the US storefront rules) before building either version.

### Work when picked up

1. Owner, in App Store Connect: sign the Paid Apps agreement, add banking and tax under Business, enrol in the App Store Small Business Program, and create the tip products under In-App Purchases.
2. App: StoreKit 2 tip view with product loading, purchase, a thank-you state and failure handling; the Settings row and one-time card.
3. Store listing and docs: change "no in-app purchases" in `docs/app-store/metadata.md` to "Free, with optional tips". Add the tips to `review-notes.md`, and confirm `app-privacy.md` stays "Data Not Collected".
4. Submit the first in-app purchase together with a new app version, since App Store Connect requires that for a first in-app purchase.
