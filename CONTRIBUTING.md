# Contributing to OpenSpatial

## Build

You need a Mac with Apple silicon, Xcode 26 or later and [uv](https://docs.astral.sh/uv/).

```sh
app/build.sh
```

It builds `app/build/OpenSpatial.app`, ad-hoc signed. The first run also:

- downloads the room measurements into `room/sofa` and exports the response tables into `app/brir` with `room/export.py`;
- downloads BlackHole 0.7.1 into `driver/blackhole`, applies `driver/openspatial.patch` and builds the audio driver with `driver/build.sh`.

The app carries the driver and installs it on launch whenever the installed one has a different build. Raise `build` in `driver/build.sh` with every driver change.

`uv run separation/export.py path/to/music.wav` builds the AI surround model. It is published once, as its own release, and the app downloads it from there; `app/VocalSeparator.swift` holds its address and SHA-256.

## Changes

- Commits and pull request titles follow [Conventional Commits](https://www.conventionalcommits.org): `feat`, `fix`, `perf`, `security`, `revert`, `deps`, `docs`, `refactor`, `test`, `build`, `ci` or `chore`.
- Interface text lives in `app/en.lproj/Localizable.strings`, never in the code.
- A pull request describes the change, its risks and how it was verified, with screenshots for interface changes.

## Releases

Releases are automated with [release-please](https://github.com/googleapis/release-please). Every push to `main` updates a release pull request that bumps `version.txt` and writes `CHANGELOG.md` from the commits since the last release. Merging it tags a draft release, builds, signs and notarizes the app, attaches the disk image with `SHA256SUMS` and build provenance, and publishes the release. A failed build leaves the release as a draft.

No version number is edited by hand.

### Release configuration

Repository secrets:

| Secret | Contents |
| --- | --- |
| `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD` | Developer ID Application certificate with its private key, base64-encoded `.p12`, and its password |
| `APPLE_API_KEY_P8`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID` | App Store Connect API key for notarization, the `.p8` base64-encoded |
| `RELEASE_PLEASE_TOKEN` | Optional fine-grained token with contents and pull-request write access, so CI runs on the release pull request |

Files go in base64-encoded, for example `base64 -i certificate.p12 | gh secret set MACOS_CERTIFICATE_P12`.

### Signed builds on your Mac

`app/release.sh` signs the app `app/build.sh` built and writes a notarized disk image to `app/build/release`. It needs the Developer ID Application identity in the login keychain, passed as `IDENTITY` by its hash when the keychain holds it twice, and notarization credentials stored once with `xcrun notarytool store-credentials openspatial` or passed as `NOTARY_ARGS`.
