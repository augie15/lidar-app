# Contributing

Thanks for your interest in Tilda.

## Issues and feature requests

These are welcome. Use the [issue templates](https://github.com/augie15/lidar-app/issues/new/choose), or send feedback from the app (Settings, Send feedback). Issues are public, so don't include private information or scan contents.

## Pull requests

The source is under an all-rights-reserved [license](LICENSE), so pull requests are accepted only by arrangement. Open an issue first and describe what you want to change. If we agree, I'll say how to proceed. By contributing, you agree that your contribution may be used in the app.

## Dev setup

See [Build from source](README.md#build-from-source) in the README. You need a LiDAR device to test scanning.

## Code style

- SwiftUI, in Swift 5 language mode (`SWIFT_VERSION: 5.0`), for iOS 26 and later.
- Apple frameworks only. No third-party dependencies.
- No network calls from the app. Feedback opens a prefilled page or mail draft that the user sends.
- No secrets in the repo, including the Apple team ID. Signing comes from the untracked `Config/Signing.local.xcconfig`.
- The Xcode project is generated from `project.yml`. Edit that file, not the project by hand.
- Match the surrounding code: small files grouped by feature, doc comments on non-obvious logic.
