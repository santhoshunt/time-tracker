# Drift

Drift is an Android app that compares the day you planned with how you actually used your phone. You lay out your day as calendar blocks, such as Gym, Deep work or Lunch, and mark which apps belong in each one. Drift reads Android's app-usage history and draws it over your plan. App use outside a block's allowed apps shows as drift.

Everything stays on the phone. Drift has no account and no server, and makes no network calls except to check this repository for new releases.

## Install

1. Download `app-release.apk` from the [latest release](https://github.com/santhoshunt/time-tracker/releases/latest) on your phone.
2. Open it, and allow your browser or file manager to install apps when Android asks.
3. In Drift, follow the setup pages to turn on Usage access and to allow running without battery limits.

Later versions install from inside the app, from the banner on the Today tab or from Settings > Check for updates. Android installs an update only if it's signed with the same key as the installed app.

## How it decides what counts as drift

- Each block lists allowed apps and off-track apps.
- When you open an app the block doesn't list, Drift guesses from the app's Play Store category. Games, video, social and news count as off track, and everything else counts as on track. The guess shows in amber until you answer.
- Time with the screen off or locked counts as on track. So does time on the home screen.
- Time outside every block isn't scored.

## Building

The app is built with Flutter 3.44.1:

```
flutter pub get
flutter analyze
flutter test --exclude-tags golden,generate
flutter build apk --release
```

Golden-image tests (tag `golden`) are generated and compared on the developer's Windows machine only, because Linux draws text differently.

Pushing a `vX.Y.Z` tag that matches the `version:` line in `pubspec.yaml` runs the release workflow. It tests, builds, checks the signing certificate and package, and publishes `app-release.apk`. The signing key never enters the repository. It's restored from GitHub Actions secrets for the length of the build only.
