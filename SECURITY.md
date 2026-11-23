# Security policy

## Reporting a vulnerability

Please report security problems privately by email to brett@augiesrentals.ca. Don't open a public issue for a vulnerability. Include what you found, how to reproduce it and the app version, and I'll reply as soon as I can.

## Scope

Tilda is an on-device iPhone app. It has no servers, no accounts and makes no network calls, so there is no backend to attack. Reports that fit best:

- The app leaking scans, photos or measurements outside the device.
- Unsafe handling of files, such as export or share flows.
- Secrets or credentials committed to this repository.

The feedback feature only opens a prefilled GitHub issue page or a mail draft, and sends nothing itself. Problems in GitHub, Apple frameworks or iOS itself should go to those vendors.
