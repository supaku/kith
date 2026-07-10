# Releasing kith

Releases are tag-driven. Pushing a tag matching `v*.*.*` triggers `.github/workflows/release.yml`, which builds an arm64 release binary, signs + notarizes via the Apple Developer ID, attaches the tarball + sha256 to a GitHub Release, and bumps the cask in [supaku/homebrew-tools](https://github.com/supaku/homebrew-tools).

## Cutting a release

```sh
# 1. Bump the checked-in version in all release surfaces. The release
#    workflow verifies these agree with the tag before it builds.
$EDITOR version.env
$EDITOR Sources/KithAgent/main.swift
$EDITOR Sources/kith/Generated/BuildInfo.swift
$EDITOR Sources/kith/Resources/Info.plist
$EDITOR Sources/KithApp/Resources/Info.plist
$EDITOR Formula/kith.rb

# 2. REHEARSE the release locally. Don't skip this — it's the only thing
#    that catches packaging regressions (e.g. a missing SwiftPM resource
#    bundle) before they ship.
bash scripts/release-rehearsal.sh

# 3. Commit, tag, push.
git add -A
git commit -m "release: 0.2.4"
git tag -a v0.2.4 -m "kith 0.2.4"
git push origin main
git push origin v0.2.4
```

Watch the workflow at https://github.com/supaku/kith/actions/workflows/release.yml.

## What the rehearsal does

`scripts/release-rehearsal.sh` is a local equivalent of the CI package + smoke steps. It:

1. `swift build -c release --arch arm64`
2. Calls `scripts/package.sh` to assemble the libexec/wrapper tarball — same script CI runs.
3. Extracts the tarball into a temp dir.
4. Symlinks the wrapper from a different prefix (mimics how brew installs `/opt/homebrew/bin/kith` as a symlink into the cask's staged path).
5. Runs `kith version` and `kith chats --participant '+14155551212'` through the symlink. The phone-parse path forces PhoneNumberKit to load its resource bundle — if a SwiftPM dep added a new bundle that didn't make it into `scripts/package.sh`'s `REQUIRED_BUNDLES` list, this fails loudly here rather than at user runtime.

If the rehearsal exits 0, the package is shippable. Run it before every tag.

## Required secrets

All of these are configured as **organization secrets** on the `supaku` GitHub org with all-repo access. New repos in the org inherit them automatically.

| name | what | how to obtain |
|------|------|---------------|
| `APPLE_DEVELOPER_ID_CERT_BASE64`   | base64-encoded `.p12` of the Developer ID Application cert | export from Keychain Access → `base64 -i cert.p12 \| pbcopy` |
| `APPLE_DEVELOPER_ID_CERT_PASSWORD` | password protecting the `.p12`                              | set during Keychain export |
| `APPLE_DEVELOPER_ID`               | Apple ID email used for notarization                       | the team's notary login |
| `APPLE_PASSWORD`                   | app-specific password (NOT the account password)           | https://appleid.apple.com → Sign-In and Security → App-Specific Passwords |
| `APPLE_TEAM_ID`                    | 10-char team identifier                                    | https://developer.apple.com/account → Membership |
| `HOMEBREW_TAP_GITHUB_TOKEN`        | fine-grained PAT with `contents:write` on `supaku/homebrew-tools` | see below |

## Minting `HOMEBREW_TAP_GITHUB_TOKEN`

GitHub's `gh` CLI cannot mint user-scoped PATs; this one is created manually.

1. Go to https://github.com/settings/personal-access-tokens/new (fine-grained PAT settings).
2. **Token name:** `supaku/homebrew-tools cask bumper`
3. **Resource owner:** `supaku`
4. **Expiration:** 1 year (renew via reminder).
5. **Repository access:** *Only select repositories* → `supaku/homebrew-tools`.
6. **Repository permissions:**
   - **Contents:** Read and write
   - **Metadata:** Read-only (auto-required)
   - everything else: No access
7. Generate token, copy the value.
8. Add to org secrets: https://github.com/organizations/supaku/settings/secrets/actions/new
   - **Name:** `HOMEBREW_TAP_GITHUB_TOKEN`
   - **Repository access:** All repositories (or limit to `kith` if you prefer narrower scope)

Until this secret exists, the release workflow's "Bump supaku/homebrew-tools cask" step is skipped (the tarball still lands on the GitHub Release; users just have to wait for a manual cask bump).

## What the workflow does

1. Checks out the tag.
2. Selects Xcode 16+ (Swift 6) on `macos-15`.
3. Stamps `Sources/kith/Generated/BuildInfo.swift` with version + commit + ISO build timestamp.
4. `swift build -c release --arch arm64`.
5. Runs `scripts/sign-and-notarize.sh`:
   - imports the Developer ID cert into an ephemeral keychain in `$RUNNER_TEMP`
   - codesigns with hardened runtime + `--identifier com.supaku.kith`
   - `ditto`-zips the binary and submits to `xcrun notarytool submit --wait`
   - attempts `stapler staple` (always fails on bare CLI binaries — Gatekeeper does an online ticket lookup at first run instead)
6. Packages `kith-<version>-macos-arm64.tar.gz` + `.sha256` into `dist/`.
7. Creates/updates the GitHub Release, attaches both files.
8. Clones `supaku/homebrew-tools`, rewrites `version` and `sha256` in `Casks/kith.rb`, commits, pushes.

## Local rehearsal

You can dry-run the build + sign legs locally if you have a Developer ID cert in your login keychain:

```sh
# Build only, no signing.
bash scripts/build.sh

# Build + sign with an identity already in your keychain (no notarization).
KITH_SIGN_IDENTITY="Developer ID Application: Mark Kropf (BDJC7XF394)" bash scripts/build.sh
```

`scripts/sign-and-notarize.sh` is designed for CI (it imports a base64 cert into a fresh keychain) — running it locally requires exporting the same five `APPLE_*` env vars.

## Rollback

If a tag ships a broken release, the cleanest path is a fresh patch tag:

```sh
git tag -a v0.1.2 -m "kith 0.1.2 (rollback of 0.1.1)"
git push origin v0.1.2
```

The cask auto-bump will pick up the latest version. Avoid deleting tags or re-publishing the same tag — Homebrew clients cache the previous URL/sha256 and re-publishing causes opaque "checksum mismatch" failures.
