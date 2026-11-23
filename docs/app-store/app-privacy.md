# App Privacy questionnaire (App Store Connect, App Privacy)

## Answers

1. **Do you or your third-party partners collect data from this app?** Choose **No, we do not collect data from this app.**
2. The result is the **Data Not Collected** label. There are no data type questions to answer, and no "Data Used to Track You".
3. **Privacy Policy URL:** https://augie15.github.io/lidar-app/privacy.html
4. Tracking (App Tracking Transparency): not used. Do not add `NSUserTrackingUsageDescription`. The privacy manifest sets `NSPrivacyTracking` to false.

## Reasoning

Apple defines "collect" as transmitting data off the device in a way that lets you or a partner keep it for longer than needed to service the request. Tilda never does that.

| Data | Where it goes | Collected? |
|---|---|---|
| Camera and LiDAR (depth, images) | Processed on device, saved in the app's Documents folder | No. Never transmitted. |
| Scans, photos, measurements, summaries | Documents folder (visible in Files), indexed in on-device Spotlight | No |
| Apple Intelligence (Foundation Models) and Vision | On-device only. Private Cloud Compute is not used. | No |
| Settings and preferences | UserDefaults on device | No |
| Siri and Shortcuts (App Intents) | Handled by iOS on device | No |
| Exports | Only when the user picks a destination in the share sheet. The user, not the app, sends the file. | No |
| Feedback, GitHub | The app opens a prefilled public GitHub issue page in SFSafariViewController. The user submits it to GitHub under GitHub's terms. The app sends nothing itself. | No |
| Feedback, email | Opens an iOS Mail draft that the user sends. The app does not transmit it. | No (see note) |

Other facts that support the label:

- No accounts, analytics, advertising, crash-reporting or third-party SDKs. The code contains no `URLSession` or other networking calls (checked by grep).
- No advertising identifier, no tracking, no data sharing with data brokers.
- The privacy manifest (`Tilda/PrivacyInfo.xcprivacy`) declares no collected data types and no tracking domains.

## Notes

- If you later receive feedback emails, you hold the sender's address and message. That is user-initiated correspondence, not data the app collects, and Apple does not require disclosing it. If you want to be conservative, you may still answer No, and the policy page explains it.
- If you ever add analytics, a crash reporter, iCloud sync to your own container, or any network call, revisit this answer and the privacy manifest first.
