# Menfez — macOS signing, notarisation and distribution

Status: researched 2026-11-15. Each claim carries a URL and the source date, and
is marked Apple / Homebrew / third-party.

Assumed context: native Swift/SwiftUI `.app` (~2 MB), not sandboxed, no system or
network extensions. It ships `Contents/MacOS/menfez-route`, run as root via a
passwordless rule in `/etc/sudoers.d/menfez`. Distribution is outside the App
Store. Source is Apache-2.0 on GitHub.

---

## 1. Recommended plan

### Before the membership arrives (today)

1. **Keep shipping, but stop implying it is signed.** Build ad-hoc only
   (`codesign -s - ...`), and use "unsigned" wording everywhere in user-facing
   text. Do not put a certificate name you do not own into the build script.
2. **Ship a `.dmg` containing the `.app`, not a bare `.zip`.** Apple: "You can't
   sign a zip archive"; dmg and pkg can be signed and stapled. This way, going
   notarised later changes signing only, not packaging.
3. **Write the install page for the unsigned case first** — exact Open Anyway
   steps plus the `xattr` fallback for the "damaged" dialog (section 3.1).
4. **Keep the sudoers drop-in for now, plan its replacement.** It is the only
   privilege mechanism that works with no Apple account, but it is the most
   alarming to a reviewer and the most dangerous residue if the helper path is
   later replaced. `uninstall.sh` already removes and re-validates it.
5. **Do not submit to `homebrew/cask` yet.** Official casks must pass Gatekeeper
   on a default macOS configuration. A third-party tap is allowed meanwhile.
6. **Publish the GitHub release anyway.** Notarisation status is a friction and
   trust problem, not a legal gate, and the source is public.

### After the membership is active

1. **Create both certificates** under Certificates, Identifiers & Profiles →
   Developer ID: *Developer ID Application* (app, helper, dmg) and *Developer ID
   Installer* (only if shipping a `.pkg`). Account Holder role only; up to 5 of
   each.
2. **Sign inside-out, never `--deep`:** nested dylibs/frameworks →
   `menfez-route` → `Menfez.app` → the dmg (and the `.pkg`, if used).
3. **Notarise the outermost container only**, then staple:
   `notarytool submit ... --wait`, `stapler staple`.
4. **Verify before publishing:** `codesign -vvv --strict`,
   `spctl -a -vvv -t exec`, and on a *different* Mac download the dmg through a
   browser so it gets quarantined.
5. **Then** switch the download page to the notarised wording, submit the cask,
   and migrate the helper to an `SMAppService` LaunchDaemon
   (app-registered or signed-pkg-installed).

---

## 1a. Build and package

Three scripts in the repository root. `build-dmg.sh` runs `build-app.sh`, so one command
produces the artifact that gets published.

| Script | What it does |
|---|---|
| `build-app.sh` | Builds `Menfez` and `menfez-route` for `x86_64` **and** `arm64` in separate scratch directories, fuses each pair with `lipo -create`, asserts both architectures and `minos 13.0` in every slice, runs `swift test`, then assembles and ad-hoc signs `Menfez.app`. A thin binary or a raised deployment target is a hard failure. |
| `build-dmg.sh` | Calls `build-app.sh` (so the test gate covers the dmg too), stages `Menfez.app`, an `/Applications` symlink and `INSTALL.txt` (the section 3.1 wording), creates the signed disk image, and prints its SHA-256. |
| `verify-build.sh` | Re-checks a finished build and dmg and prints PASS/FAIL per item; exits non-zero if anything fails. Run it before uploading, and quote its output in the release notes. |

```
./build-app.sh        # universal .app only
./build-dmg.sh        # .app + .dmg + sha256
./verify-build.sh     # gate: lipo, minos, codesign, dmg contents, byte identity
```

**Artifact name:** `Menfez-<version>.dmg`, version read from the bundle's
`CFBundleShortVersionString`. The current build is **`Menfez-1.0.0.dmg`**;
the volume name inside is `Menfez`, and the sha256 printed by `build-dmg.sh`
(or by `verify-build.sh`) is the number the download page must publish.

Both executables are universal, so the same download runs natively on Intel
and on Apple silicon. The minimum OS is 13.0 in *both* slices.

Two notes for the future signing work:

- Both scripts sign through `tools/sign.sh`: ad-hoc when
  `MENFEZ_SIGN_IDENTITY` is unset, Developer ID otherwise (see the release
  checklist below). The dmg layout, the artifact name and the scripts'
  arguments do not change.
- The `build/` directory holds the per-architecture scratch trees and the fused
  binaries. It is disposable; deleting it costs one rebuild.

---

## 1b. Release checklist

Signing is driven by two environment variables, read by `tools/sign.sh`.
Nothing in the repository names an identity, an Apple ID or a password.

| Variable | Value | Unset |
|---|---|---|
| `MENFEZ_SIGN_IDENTITY` | `Developer ID Application: <Name> (<TEAMID>)`, exactly as `security find-identity` prints it | ad-hoc, as before |
| `MENFEZ_NOTARY_PROFILE` | the keychain profile name, e.g. `menfez-notary` | no notarisation |

With an identity, signing is inside-out and never `--deep`: `menfez-route`,
then `Menfez.app` (both `--options runtime --timestamp`), then each dmg
(`--timestamp`). No entitlements file: the app is not sandboxed, loads no
third-party library and only spawns system tools (`/usr/bin/curl`,
`/usr/sbin/netstat`, `/usr/bin/osascript`, ...), which the hardened runtime
allows (section B). Bundle id, Info.plist and provisioning are unchanged.

**Once per machine**

```
# 1. The certificate is in the login keychain; copy its exact name:
security find-identity -v -p codesigning

# 2. Store notarisation credentials (asks for an app-specific password,
#    made at account.apple.com; it goes into the keychain, not the repo):
xcrun notarytool store-credentials menfez-notary \
    --apple-id "<your Apple ID>" --team-id "<TEAMID>"
```

**Every release**

```
cd macos
# Bump VERSION in build-app.sh and add the Changelog entry (ChangelogTests).
export MENFEZ_SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)"
export MENFEZ_NOTARY_PROFILE="menfez-notary"
./build-app.sh          # tests, universal app, signed inside-out
./build-dmg.sh          # arm64 + intel dmgs: thin, re-sign, sign dmg,
                        # notarytool submit --wait, stapler staple,
                        # spctl -a -vvv -t open --context context:primary-signature <dmg>,
                        # spctl -a -vvv -t exec <app>
./verify-build.sh       # asserts the identity and hardened runtime too
```

`build-dmg.sh` stops if Apple's answer is not `status: Accepted`; the
submission log is `xcrun notarytool log <id> --keychain-profile menfez-notary`.
The sha256 lines it prints are taken after stapling, so they are the ones to
publish.

**By hand, to check a finished dmg**

```
codesign -dvv --verbose=4 Menfez.app      # Authority=Developer ID Application: ..., flags=...runtime
xcrun stapler validate Menfez-<v>-arm64.dmg
spctl -a -vvv -t open --context context:primary-signature Menfez-<v>-arm64.dmg
spctl -a -vvv -t exec /Volumes/Menfez/Menfez.app      # after mounting it
```

Then download the dmg through a browser on another Mac (so it is
quarantined) and open it once before publishing. With neither variable set
everything above is skipped and the build is ad-hoc, exactly as before.

---

## 2. Answers

### A. Membership and certificates

**A1. What the membership actually provides.**
Two distinct certificate types, both under "Developer ID": *Developer ID
Application* ("A certificate used to sign a Mac app") and *Developer ID
Installer* ("A certificate used to sign a Mac Installer Package, containing your
signed app"). Up to five of each; requires the Account Holder role.

- `.app` outside the App Store → **Developer ID Application**.
- `.pkg` → additionally **Developer ID Installer**, identity named
  `Developer ID Installer: <TeamID>`; listed by `security find-identity -v`
  (note: *not* `-p codesigning`).
- The dmg is signed with the *Application* identity, not the Installer one.

Sources: [create-developer-id-certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
(Apple, current 2026); [resolving-common-notarization-issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
(Apple, 2026); [packaging-mac-software-for-distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
(Apple, 2026).

**A2. Enrolment wait time; can you notarise without it?**
Apple's official line: you receive a confirmation email after purchase, and "If
you haven't received a membership confirmation within 24 hours of your purchase,
contact us" with your Enrollment ID. Individual enrolment can be reviewed and
paid in one session; organisation enrolment waits on D-U-N-S and
binding-authority verification.

Developer reports are longer and erratic: one thread asks about the "current
average" and reports 5 days pending while the profile promises 48 hours
([forums/thread/844653](https://developer.apple.com/forums/thread/844653), 2026);
others describe weeks and rejections after 10–14 days. Treat 1–7 days as typical,
weeks as possible — these are user reports, not Apple statements.

**You cannot notarise without an active membership.** Only Developer ID
signatures are accepted, Developer ID certificates exist only inside the
programme, and the service rejects unconfigured teams ("Team is not yet
configured for notarization").

Sources: [program-enrollment](https://developer.apple.com/help/account/membership/program-enrollment/)
(Apple, 2026); [forums/thread/844653](https://developer.apple.com/forums/thread/844653)
(forum, 2026); resolving-common-notarization-issues (above).

**A3. Free path to notarisation?**
No. Notarisation requires a Developer ID signature; ad-hoc, self-signed, Apple
Development and Mac Distribution certificates are explicitly rejected. A free
Apple Account gives Xcode, local signing and on-device testing only.

Sources: [resolving-common-notarization-issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues);
[notarizing-macos-software-before-distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
(both Apple, 2026).

### B. Signing and notarisation mechanics

**B4. Exact command; is hardened runtime mandatory?**

```
codesign -s "Developer ID Application: <Team Name> (<TEAMID>)" -f --timestamp \
         -o runtime --entitlements <file>.plist <path>
```

- `-f` only when re-signing.
- `--timestamp` is required; `codesign -dvv` must show `Timestamp=` rather than
  `Signed Time=`.
- `-o runtime` is the hardened runtime and is **mandatory** — without it
  notarisation fails with "The executable does not have the hardened runtime
  enabled."
- `-i <suffix>` for non-bundled code such as `menfez-route`
  (`com.example.menfez.menfez-route`).
- Never run `codesign` under `sudo`.

Sources: [creating-distribution-signed-code-for-the-mac](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac);
[resolving-common-notarization-issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
(Apple, 2026).

**B5. notarytool: syntax, turnaround, status; is altool gone?**

```
xcrun notarytool store-credentials "menfez" --apple-id <id> --team-id <TEAMID> --password <app-specific-password>
xcrun notarytool submit Menfez.dmg --keychain-profile "menfez" --wait
xcrun notarytool info  <id> --keychain-profile "menfez"
xcrun notarytool log   <id> --keychain-profile "menfez" notary-log.json
xcrun notarytool history --keychain-profile "menfez"
```

Turnaround: Apple says "usually takes less than an hour" and separately that most
finish within 5 minutes, 98% within 15 minutes. `--wait` blocks until done, so no
polling. Always read the log, even on success. Limit is 75 submissions/day.

`altool` for notarisation is **dead**: deprecated, and the service stopped
accepting altool and Xcode 13-or-earlier uploads on **1 November 2023**. altool
still works for App Store submission.

Sources: [customizing-the-notarization-workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
(Apple, 2026); [TN3147](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)
(Apple, rev. 2024-02-05).

**B6. stapler: when, and on what.**
Staple so Gatekeeper can find the ticket offline: "If you don't staple the ticket
to your distribution file, Gatekeeper might block a user from installing or using
your product while their Mac is offline."

- `.app`, `.dmg`, flat `.pkg` staple directly.
- **A `.zip` cannot be stapled** — notarise then staple each item inside, then
  rebuild the zip.
- For app→pkg→dmg chains, notarise the outer container; a common safe recipe is
  staple the `.app`, build/sign the dmg, staple the dmg.
- Bare standalone binaries get a ticket but "it's not currently possible to
  staple tickets to them."

Sources: [packaging-mac-software-for-distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution);
[customizing-the-notarization-workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
(Apple, 2026).

**B7. What must be signed; does `--deep` work?**
Everything executable: the `.app`, `menfez-route`, every framework/dylib/plugin
in `Contents/Frameworks` or `Contents/PlugIns`. Entitlements go only on main
executables, never on library code.

Sign **inside-out**: sign `B` before `A` if `A` depends on `B`. For Menfez:
dylibs → `menfez-route` (with `-i`) → `Menfez.app` → dmg.

**`--deep` is not reliable for signing and Apple says not to use it.** It applies
identical options (including the same entitlements) to every item, and only signs
nested code in expected locations — anything elsewhere is left unsigned,
surfacing later as "The signature of the binary is invalid". `--deep` is still
fine for *verification* (`codesign -vvv --deep --strict`) and for `spctl`.

Sources: [creating-distribution-signed-code-for-the-mac](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)
("Avoid deep code signing", Apple, 2026); [forums/thread/129980](https://developer.apple.com/forums/thread/129980)
(Apple staff, "--deep Considered Harmful"; bot-checked at time of research).

**B8. Entitlements for sudo + `route`/`wg-quick`/`networksetup`; does hardened
runtime break `Process()`?**

- **None are needed.** Hardened runtime protects the *process itself* (injection,
  DYLD env vars, unsigned executable memory, library validation). None of that
  restricts `Process`/`NSTask`/`posix_spawn` launching another program, nor the
  child's syscalls. **It does not break `Process()`.**
- The only relevant default is **library validation**: a hardened process loads
  only same-Team-ID or Apple libraries. Menfez loads no third-party dylibs, so
  `com.apple.security.cs.disable-library-validation` is **not** needed. Don't add
  it speculatively.
- Root is not an entitlement question: the user authenticates sudo, or the helper
  runs as a root LaunchDaemon. There is no entitlement granting root to a GUI app.
- Sandbox is off, so no `com.apple.security.app-sandbox` and no temporary
  exceptions.
- Keep `com.apple.security.get-task-allow` **out** of distribution builds — its
  mere presence fails notarisation.

Sources: [hardened-runtime](https://developer.apple.com/documentation/security/hardened-runtime);
[resolving-common-notarization-issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues);
[disable-library-validation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)
(Apple, 2026).

### C. Gatekeeper behaviour for users

**C9. What the user sees.**

- **(a) Ad-hoc, downloaded.** No Developer ID and no ticket. Apple's support page
  lists "Apple cannot check … for malicious software" / "developer cannot be
  verified", or — when macOS decides the software was modified or damaged —
  "…is damaged and can't be opened. You should move it to the Trash." Which
  appears is not fully deterministic; ad-hoc downloads very often land on
  "damaged" because no trusted identity anchors the seal. First launch also
  involves App Translocation (runs from a randomised read-only path) until moved.
- **(b) Developer ID signed, not notarised.** Identity is trusted but there is no
  ticket, so it is blocked: "Apple could not verify 'Menfez' is free of
  malware." Since Catalina, notarisation is required by default for Developer ID
  software.
- **(c) Signed and notarised.** Ordinary "downloaded from the Internet"
  confirmation naming the developer; no override needed, and it works offline
  when stapled.

Sources: [support.apple.com/en-us/102445](https://support.apple.com/en-us/102445)
(Apple Support, 2026-05-27); [notarizing-macos-software-before-distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
(Apple: all Developer ID software built after 2019-06-01 must be notarised);
packaging doc for translocation.

**C10. Is right-click → Open still available?**
**No.** Apple, 2024-08-06: "In macOS Sequoia, users will no longer be able to
Control-click to override Gatekeeper when opening software that isn't signed
correctly or notarized. They'll need to visit System Settings > Privacy &
Security…" Still true in macOS 26.

Replacement path: try to open once → System Settings → Privacy & Security →
Security → **Open Anyway** → confirm.

Sources: [developer.apple.com/news/?id=saqachfa](https://developer.apple.com/news/?id=saqachfa)
(Apple, 2024-08-06); [support.apple.com/en-us/102445](https://support.apple.com/en-us/102445)
(Apple, 2026-05-27).

**C11. Does `xattr -d com.apple.quarantine` still work; is recommending it
acceptable?**
It works on current releases for the ordinary case, and
`xattr -dr com.apple.quarantine /Applications/Menfez.app` is the standard fix for
"damaged". Acceptable **as a fallback**, with caveats: scope it to the app path,
never suggest `spctl --master-disable`, and put it *after* Open Anyway with an
explanation. Once removed, macOS does not re-check that bundle.

There is one report that macOS 26 adds a SIP-protected `com.apple.provenance`
attribute that defeats the trick for some apps — unverified, see section 4.

Sources: [support.apple.com/en-us/102445](https://support.apple.com/en-us/102445)
(Apple, 2026-05-27); [github.com/sowoky/osxEQL/issues/4](https://github.com/sowoky/osxEQL/issues/4)
(third-party, 2026-08-30, unverified).

### D. Privileged helper

**D12. Legitimate alternatives for root access.**

- **SMJobBless** — deprecated; Apple's own docs carry "Please use SMAppService
  instead" (deprecated macOS 13). Don't start here.
- **SMAppService** (macOS 13+) — supported path today. Plists and binary live in
  the bundle (`Contents/Library/LaunchDaemons/`, `Contents/Resources/`), the plist
  uses `BundleProgram` not `Program`, and the app calls
  `SMAppService.daemon(plistName:).register()`. The user approves once in System
  Settings → General → Login Items, and approving the daemon covers the bundle's
  other helpers.
- **LaunchDaemon via signed `.pkg` postinstall** — supported, but needs Developer
  ID Installer signing plus notarisation, and is a legacy `/Library/LaunchDaemons`
  plist unless you adopt the bundle-relative form.
- **sudoers drop-in** — works with no account, but invisible in the UI, easy to
  leave behind, and grants root to a *path*: if that path is later occupied by
  another binary, the rule grants root to that binary.

(i) Supported today: SMAppService, or signed pkg + LaunchDaemon.
(ii) Signing: SMAppService needs app and helper signed and sharing a Team ID
(unsigned helpers appear unsigned in Login Items and registration fails); the pkg
route additionally needs Developer ID Installer.
(iii) Least frightening: **SMAppService**, because consent is a standard system
dialog naming your app, not a Terminal command.

Recommendation for Menfez: SMAppService daemon + XPC, keeping sudoers as fallback
for macOS 12 or failed registration. This is an after-membership change, since
SMAppService is meaningless without a Team ID.

Sources: [SMJobBless](https://developer.apple.com/documentation/servicemanagement/smjobbless(_:_:_:_:))
(Apple, deprecation summary); [updating-helper-executables](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos);
[SMAppService sample](https://developer.apple.com/documentation/servicemanagement/updating-your-app-package-installer-to-use-the-new-service-management-api)
(Apple, macOS 13+).

**D13. If the helper ships in a `.pkg`, does the pkg need its own signature and
notarisation?**
The pkg is its own signed code item: sign with `Developer ID Installer`
(`productbuild --sign`, `pkgbuild --sign` or `productsign`), which includes a
secure timestamp by default. Then notarise the **outermost container**: app → pkg
→ dmg, sign each, notarise the dmg only, and staple the dmg. Tickets are issued
for nested items even though you submit once. `pkgutil --check-signature` should
report "Signed with a trusted timestamp" and "1. Developer ID Installer:".

Sources: [packaging-mac-software-for-distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
("only notarize the outermost container"); [resolving-common-notarization-issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
(Apple, 2026).

**D14. What Homebrew does for comparable apps.**
Official casks install **prebuilt upstream artefacts** (dmg/zip/pkg) checksummed
by sha256 — Homebrew does not build them. Policy now requires that macOS
apps/installers Gatekeeper can assess "must pass Homebrew's Gatekeeper checks and
must not require System Integrity Protection or Gatekeeper to be disabled or
bypassed", and Homebrew *applies* quarantine so Gatekeeper runs. So Homebrew is
**not** a way around notarisation for official casks.

Comparable privileged networking casks: `tailscale-app` ships a `.pkg` from
`pkgs.tailscale.com`; `mullvad-vpn` ships a `.pkg` and uninstalls with
`launchctl: "net.mullvad.daemon"` — both use a signed pkg-installed root daemon,
not sudoers.

Sources: [Homebrew-Security-and-Supply-Chain](https://docs.brew.sh/Homebrew-Security-and-Supply-Chain);
[Acceptable-Casks](https://docs.brew.sh/Acceptable-Casks) (Homebrew, 2026);
[tailscale-app.rb](https://github.com/Homebrew/homebrew-cask/blob/master/Casks/t/tailscale-app.rb),
[mullvad-vpn.rb](https://github.com/Homebrew/homebrew-cask/blob/master/Casks/m/mullvad-vpn.rb)
(accessed 2026-11-15).

### E. Distribution channels

**E15. Homebrew Cask requirements and user experience.**
A cask needs `version`, `sha256`, `url`, `name`, `desc`, `homepage` and at least
one artifact stanza (`app`, `pkg`, `binary`, …). For `homebrew/cask` you also need
`zap`, and Acceptable Casks applies: works on the latest macOS, verifiable
upstream distribution from the developer, passes Gatekeeper on a default
configuration. Notarisation is therefore effectively **required** for an official
cask of a GUI app. A third-party tap has no such check.

Experience: `brew install --cask menfez` downloads, verifies sha256, applies
quarantine, moves the app to `/Applications`; a `pkg` artifact runs the system
Installer with an admin prompt. With an unnotarised app the install "succeeds"
but the first launch is still blocked.

Sources: [Cask-Cookbook](https://docs.brew.sh/Cask-Cookbook);
[Acceptable-Casks](https://docs.brew.sh/Acceptable-Casks);
[Adding-Software-to-Homebrew](https://docs.brew.sh/Adding-Software-to-Homebrew)
(Homebrew, 2026).

**E16. dmg vs zip vs pkg.**
`.pkg` is technically correct when you must place a root LaunchDaemon or
privileged helper — Apple: an installer package "is the best choice if your
product contains multiple components, must be copied to specific locations, or if
you need to run custom code during installation". Cost: second certificate, admin
password, harder uninstall.

`.dmg` is least friction for a drag-to-Applications app, is signable and
staplable, and is the best default **while the helper is still sudoers-based**.

`.zip` is cheapest and worst to trust: cannot be signed or stapled, and gains
nothing.

Recommended: today a `.dmg` with the `.app` inside and sudoers configured by the
app's installer; after membership, a `.dmg` with the `.app` (helper as SMAppService
daemon), or a `.dmg` wrapping a signed `.pkg` if you prefer explicit root
installation.

Sources: [packaging-mac-software-for-distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
(Apple, 2026).

**E17. Consequences of shipping unnotarised beyond friction.**
No legal or licensing consequence found — Apple does not require notarisation;
Gatekeeper merely enforces it on the user's machine, and Apple frames notarisation
as user protection, not a distribution licence condition. Real consequences:
**`homebrew/cask` ineligibility**; MDM/enterprise fleets pinned to "identified
developers only" block it outright; no revocation lever if your build is
tampered with; users cannot distinguish your build from malware; every launch is
a support ticket.

Sources: [notarizing-macos-software-before-distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution);
[Acceptable-Casks](https://docs.brew.sh/Acceptable-Casks).

### F. The "no developer account yet" window

**F18. Best temporary plan.**

1. Ad-hoc sign and state plainly: "This build is not signed by Apple."
2. Ship a `.dmg` (signable later without changing layout) with a short
   `INSTALL.txt` and a screenshot of the Privacy & Security pane.
3. Document both escapes in order: **Open Anyway** first (no Terminal), then
   `xattr -dr com.apple.quarantine /Applications/Menfez.app` for the "damaged"
   dialog.
4. Offer build-from-source: a locally built app is not quarantined and opens with
   no override.
5. A cask in your **own tap** is legitimate and helps, but does not launder
   Gatekeeper — the app is still quarantined and still needs Open Anyway. Do not
   submit to `homebrew/cask` until notarised.
6. There is **no notarisation-free path that avoids the dialog**. The only
   escapes are (a) one-time Open Anyway, (b) clearing quarantine, (c) building
   locally, (d) an MDM-managed machine that permits it.

**F19. Is "damaged" caused by quarantine + ad-hoc, and does removing quarantine
fix it?**
Largely yes. Apple describes the alert as macOS detecting that software "has been
modified or damaged"; with an ad-hoc signature there is no trusted identity
anchoring the seal, so a quarantined download is treated as broken rather than
merely unidentified. `xattr -dr com.apple.quarantine <path>` removes the
Gatekeeper check for that bundle and usually works — but it is not guaranteed on
macOS 26, it must target the app bundle (not just the dmg), and once removed
macOS will not re-check that bundle, including after you replace it.

For Menfez the sudoers rule makes "just clear quarantine" weaker advice than
usual: tell users to verify the published sha256 or run `codesign -dv`.

Sources: [support.apple.com/en-us/102445](https://support.apple.com/en-us/102445)
(Apple, 2026-05-27); [osxEQL#4](https://github.com/sowoky/osxEQL/issues/4)
(third-party, 2026-08-30).

---

## 3. What to put on the download page

Use exactly one block, matching the build actually published. Keep it
non-technical; avoid "ad-hoc", "quarantine" and "notarisation" in the first
sentence.

### 3.1 While the build is unsigned (today)

> **Menfez is not signed by Apple yet.**
> Menfez is a free, open-source tool. We are waiting for our Apple Developer
> account, so macOS will warn you the first time you open it. This is expected,
> and it does not mean anything is wrong with the app.
>
> To open it the first time:
> 1. Drag **Menfez** into your **Applications** folder.
> 2. Double-click Menfez. macOS will refuse to open it. Click **Done**.
> 3. Open **System Settings → Privacy & Security** and scroll down to **Security**.
> 4. Click **Open Anyway**, then click **Open** in the dialog that appears.
>
> If macOS says **"Menfez is damaged and can't be opened"**, that message is
> misleading — the file is fine, macOS simply does not trust it. Open
> **Terminal**, paste this line, press Return, and open Menfez normally:
> ```
> xattr -dr com.apple.quarantine /Applications/Menfez.app
> ```
>
> You do not have to trust us. The full source code is at <GitHub URL>, the
> SHA-256 of this download is listed below, and you can build it yourself with
> Xcode — an app you build yourself opens without any of these steps.

Below it: the sha256, the version, and one line saying the notice disappears once
the app is signed and notarised.

### 3.2 Signed but not yet notarised

> **Menfez is signed by its developer but not yet checked by Apple.**
> macOS will show "Apple could not verify that Menfez is free of malware" the
> first time you open it. To continue, open **System Settings → Privacy &
> Security**, scroll to **Security**, click **Open Anyway**, and confirm. You only
> need to do this once.

(This state should last hours, not weeks. It reads worse to a cautious user than
the unsigned case.)

### 3.3 Signed and notarised

> **Menfez is signed and notarised by Apple.**
> Download the disk image, open it, and drag **Menfez** into your **Applications**
> folder. The first time you open it, macOS will ask you to confirm that you want
> to open an app downloaded from the internet — click **Open**. No security
> settings need to be changed.
>
> Menfez needs administrator rights to change network routes and DNS settings. The
> app will ask for your password when it needs them.

---

## 4. Not confirmed (unverified)

- **macOS 26 "provenance" blocking the xattr workaround.** A single 2026-08-30
  GitHub issue claims macOS 26 adds a SIP-protected `com.apple.provenance`
  attribute that defeats `xattr -dr com.apple.quarantine` for ad-hoc-signed apps,
  and that `spctl --add` no longer works. No Apple documentation either way. Test
  on a Tahoe machine before relying on the xattr instructions.
- **"Open Anyway" expiring after about an hour.** Widely repeated in blogs; not
  stated by Apple.
- **Which dialog an ad-hoc download produces** ("could not verify" vs "damaged").
  Apple documents both outcomes but not the selection rule.
- **Current average enrolment delay**, and Turkey-specific processing time. Apple
  states only "contact us after 24 hours"; forum reports span 1 day to several
  weeks.
- **`spctl --add` status.** Deprecation reports are third-party only.
- **The `--deep Considered Harmful` thread** returned a bot-check page during
  research; the "don't use `--deep`" rule is nonetheless Apple's official
  position, restated in current Xcode distribution docs.
- **Notarising a dmg that contains only an ad-hoc app** was not tested; Apple's
  rule that nested code must be signed implies it will not notarise meaningfully.

## 5. Sources

| # | Source | Type | Date |
|---|---|---|---|
| 1 | https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution | Apple docs | current, © 2026 |
| 2 | https://developer.apple.com/documentation/security/customizing-the-notarization-workflow | Apple docs | current, © 2026 |
| 3 | https://developer.apple.com/documentation/security/resolving-common-notarization-issues | Apple docs | current, © 2026 |
| 4 | https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool | Apple technote | rev. 2024-02-05 |
| 5 | https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac | Apple docs | current, © 2026 |
| 6 | https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution | Apple docs | current, © 2026 |
| 7 | https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases | Apple docs | current, © 2026 |
| 8 | https://developer.apple.com/documentation/security/hardened-runtime | Apple docs | current, © 2026 |
| 9 | https://developer.apple.com/help/account/certificates/create-developer-id-certificates/ | Apple account help | current, 2026 |
| 10 | https://developer.apple.com/help/account/membership/program-enrollment/ | Apple account help | current, 2026 |
| 11 | https://developer.apple.com/news/?id=saqachfa | Apple news | 2024-08-06 |
| 12 | https://support.apple.com/en-us/102445 | Apple Support | 2026-05-27 |
| 13 | https://developer.apple.com/documentation/servicemanagement/smjobbless(_:_:_:_:) | Apple API docs | current, © 2026 |
| 14 | https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos | Apple docs | current, © 2026 |
| 15 | https://developer.apple.com/documentation/servicemanagement/updating-your-app-package-installer-to-use-the-new-service-management-api | Apple sample code | macOS 13+, © 2026 |
| 16 | https://developer.apple.com/forums/thread/844653 | Developer forum | 2026 |
| 17 | https://developer.apple.com/forums/thread/129980 | Apple staff forum post | bot-checked at fetch |
| 18 | https://docs.brew.sh/Cask-Cookbook | Homebrew docs | current, 2026 |
| 19 | https://docs.brew.sh/Acceptable-Casks | Homebrew docs | current, 2026 |
| 20 | https://docs.brew.sh/Homebrew-Security-and-Supply-Chain | Homebrew docs | current, 2026 |
| 21 | https://docs.brew.sh/Adding-Software-to-Homebrew | Homebrew docs | current, 2026 |
| 22 | https://github.com/Homebrew/homebrew-cask/blob/master/Casks/t/tailscale-app.rb | Cask source | accessed 2026-11-15 |
| 23 | https://github.com/Homebrew/homebrew-cask/blob/master/Casks/m/mullvad-vpn.rb | Cask source | accessed 2026-11-15 |
| 24 | https://github.com/sowoky/osxEQL/issues/4 | Third-party report | 2026-08-30 |
