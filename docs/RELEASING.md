# How to release Portside

Portside ships as an ad-hoc signed app from GitHub Releases. Sparkle finds updates through `appcast.xml`, which every release uploads as an asset. The app reads it from `https://github.com/nicklasos/portside/releases/latest/download/appcast.xml`.

Pushing a `v*` tag runs `.github/workflows/release.yml`. The workflow builds and signs the app with `scripts/build-release.sh`. It then writes and signs the appcast with `scripts/generate-appcast.sh` and publishes the zip, the dmg, and `appcast.xml` as a GitHub release.

## Set up the update signing key once

Sparkle refuses an update unless its EdDSA signature matches the `SUPublicEDKey` in the installed app. Create the key pair once and keep it for the life of the project. If you lose the private key, installed copies of Portside can no longer update.

1. Run `scripts/build-release.sh` once. The build downloads Sparkle's tools to `build/dd/SourcePackages/artifacts/sparkle/Sparkle/bin/`.
2. Create the key pair in your login keychain:

	```sh
	build/dd/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
	```

	The tool prints the public key.
3. Replace `REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY` in `Portside/App/Info.plist` with the public key, then commit the change.
4. Export the private key and store it as the `SPARKLE_PRIVATE_KEY` repository secret:

	```sh
	build/dd/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt
	gh secret set SPARKLE_PRIVATE_KEY < sparkle-private-key.txt
	rm sparkle-private-key.txt
	```

## Publish a release

1. In `project.yml`, set `MARKETING_VERSION` to the new version, for example `"0.2.0"`.
2. In `project.yml`, increase `CURRENT_PROJECT_VERSION` by one. Sparkle compares this build number, not the marketing version, to decide whether an update is newer.
3. In `CHANGELOG.md`, rename the `## [Unreleased]` section to `## [0.2.0] - YYYY-MM-DD` and add a new empty `## [Unreleased]` section above it. The section body becomes the release notes in the appcast and on the GitHub release.
4. Commit the changes and push them to `main`.
5. Tag the commit and push the tag:

	```sh
	git tag v0.2.0
	git push origin v0.2.0
	```

6. Watch the **Release** workflow in the repository's **Actions** tab. When it finishes, the release page lists `Portside-0.2.0.zip`, `Portside-0.2.0.dmg`, and `appcast.xml`.

## Build a release locally

To check a release before you tag it, run the same scripts the workflow runs:

```sh
scripts/build-release.sh
SPARKLE_PRIVATE_KEY="$(cat sparkle-private-key.txt)" scripts/generate-appcast.sh
```

Both scripts take an optional version argument. Without one, they use `MARKETING_VERSION` from `project.yml`. The output goes to `dist/`:

- `Portside.app`, the signed app.
- `Portside-<version>.zip`, the archive that Sparkle downloads.
- `Portside-<version>.dmg`, the disk image for first installs.
- `Portside-<version>.md`, the release notes cut from `CHANGELOG.md`.
- `appcast.xml`, the signed feed.

To regenerate the app icon, the menu bar glyphs, the README icons, and the banner after you edit an SVG in `assets/`, run `assets/icon/generate-icns.sh`. The script needs `rsvg-convert` from `brew install librsvg`.

## Fix a failed release

The workflow stops before it publishes anything when one of these checks fails:

- **Tag does not match MARKETING_VERSION.** The tag `v0.2.0` needs `MARKETING_VERSION: "0.2.0"` in `project.yml`. Delete the tag, fix `project.yml`, and tag again.
- **CHANGELOG.md has no section for the version.** Add a `## [0.2.0]` section, then move the tag to the new commit.
- **appcast.xml is unsigned.** `generate_appcast` skips the signature without an error when `SUPublicEDKey` in `Portside/App/Info.plist` does not match `SPARKLE_PRIVATE_KEY`. Check that both come from the same key pair.

To move a tag after a fix, run `git tag -f v0.2.0` and `git push -f origin v0.2.0`.

## Why the app disables library validation

Release builds use the hardened runtime and an ad-hoc signature, because Portside has no Apple Developer account. An ad-hoc signature has no Team ID. The hardened runtime's library validation then refuses to load the embedded `Sparkle.framework`, and the app crashes at launch. `Portside/Portside.entitlements` sets `com.apple.security.cs.disable-library-validation` so that the app can load its own frameworks.
