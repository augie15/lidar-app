# Age rating questionnaire

Expected result: **4+**.

Answer each App Store Connect question as follows.

| Question | Answer |
|---|---|
| Cartoon or Fantasy Violence | None |
| Realistic Violence | None |
| Prolonged Graphic or Sadistic Realistic Violence | None |
| Profanity or Crude Humor | None |
| Mature/Suggestive Themes | None |
| Horror/Fear Themes | None |
| Medical or Treatment Information | None |
| Alcohol, Tobacco, or Drug Use or References | None |
| Simulated Gambling | None |
| Sexual Content or Nudity | None |
| Graphic Sexual Content and Nudity | None |
| Contests | None |
| Gambling | No |
| Unrestricted Web Access | No (see below) |
| User-Generated Content | No |
| Messaging and Chat | No |
| Advertising | No |
| Parental Controls | No |
| Age Assurance | No |
| Health or Wellness topics | No |

Apple periodically changes the exact questions (the newer questionnaire adds items such as in-app controls, capabilities and medical topics). Answer anything not listed here with None or No.

## Unrestricted web access

Answer **No**. The only web content is the Send feedback screen, which opens one fixed GitHub new-issue URL (`https://github.com/augie15/lidar-app/issues/new`, prefilled) in an in-app SFSafariViewController. Apple's definition of unrestricted web access is an app that lets users browse freely, such as a browser or an app with a free-form address bar. Tilda does not have one. A user can navigate within GitHub from that page, so be ready to explain if review asks: it is a single feedback destination, not a browser.

If App Review disagrees, the safe fallback is to answer Yes. That raises the rating to 17+ on some versions of the questionnaire, so ask us first.

## Other notes

- GitHub issues are public user content, but the app neither hosts nor displays them. That is why User-Generated Content is No.
- Children: no accounts, ads, purchases or data collection. Do not enroll in the Kids Category.
