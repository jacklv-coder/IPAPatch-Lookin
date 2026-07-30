# IPAPatch-Lookin

Prepare an Xcode project that patches an authorized decrypted iOS IPA and
injects [LookinServer](https://github.com/QMUI/LookinServer). You choose the
signing team and destination in Xcode, then run the rebuilt app for live UI
inspection.

Prepare the project with one command:

```sh
./ipapatch-lookin run ~/Downloads/YourApp.ipa
```

The command validates the IPA and its architecture, saves its path in the
Git-ignored local configuration, resolves LookinServer, and prints the Xcode
project to open. In Xcode, select the `IPAPatch-DummyApp` scheme and a matching
physical device or Simulator, choose your development team under Signing &
Capabilities when building for a physical device, then press `Cmd-R`.

You can drag an IPA from Finder into Terminal after `./ipapatch-lookin run `
instead of typing its path. The IPA is read directly from that location; it is
not copied into or committed with this repository.

This project is based on [Naituw/IPAPatch](https://github.com/Naituw/IPAPatch).
The upstream README is preserved in
[README_UPSTREAM.md](README_UPSTREAM.md).

> Use this project only with applications you own or are authorized to inspect.
> No IPA files, signing certificates, or provisioning profiles are included.

## What is automated

`ipapatch-lookin run`:

1. extracts and validates the IPA;
2. rejects an encrypted main executable (`cryptid != 0`);
3. reads both `CFBundleSupportedPlatforms` and the Mach-O platform;
4. verifies that a device IPA has an arm64/arm64e slice, or that a Simulator
   IPA matches the Mac architecture;
5. saves the selected IPA path for the Xcode build phase;
6. resolves the pinned LookinServer Swift Package; and
7. reports the ready-to-open Xcode project.

When you press `Cmd-R`, Xcode builds the project, injects
`IPAPatchFramework`, normalizes its Mach-O load command, signs the rebuilt
bundle, removes embedded app extensions that cannot be re-signed under the
new host identifier, installs it, and launches it on the destination you
selected.

For fully automated command-line deployment, use
`./ipapatch-lookin deploy` instead.

LookinServer `1.2.8` is pinned with Xcode Swift Package Manager. Ruby,
Bundler, CocoaPods, and an `.xcworkspace` are not required.

## Requirements

- macOS 13 or newer with Xcode
- the [Lookin macOS app](https://lookin.work/)
- a decrypted IPA you are authorized to inspect
- for an `iPhoneOS` IPA: a connected iPhone or iPad with Developer Mode
  enabled and iOS 15.0 or newer, plus an Apple Development signing identity
- for an `iPhoneSimulator` IPA: an installed iOS Simulator runtime and a
  Simulator slice matching the Mac architecture

Most downloaded or decrypted App Store IPAs are `iPhoneOS` arm64 builds. They
can run on a real device, not in the Simulator. An arm64 architecture alone
does not make an IPA Simulator-compatible; its Mach-O platform must be
`iPhoneSimulator`.

## Quick start

```sh
git clone git@github.com:jacklv-coder/IPAPatch-Lookin.git
cd IPAPatch-Lookin
./ipapatch-lookin run ~/Downloads/YourApp.ipa
```

The first invocation builds the small Swift command-line tool and resolves
LookinServer through Swift Package Manager. It then prints the absolute path
to `IPAPatch.xcodeproj`. Open that project, select the
`IPAPatch-DummyApp` scheme, choose a matching physical device or Simulator,
configure a signing team when needed, and press `Cmd-R`.

After the patched app launches, open Lookin on the Mac and select the running
app. Its display name is prefixed with `🔬 `.

As an alternative to passing a path, place exactly one IPA anywhere inside the
ignored `Input/` directory:

```sh
cp ~/Downloads/YourApp.ipa Input/
./ipapatch-lookin run
```

The repository intentionally keeps only `Input/.gitkeep`; IPA files in that
directory are ignored by Git.

## Optional local setup

`setup` resolves the Xcode package and saves reusable local preferences:

```sh
./ipapatch-lookin setup \
  --team ABCDE12345 \
  --bundle-id-prefix com.example.ipapatch
```

You can also save a default destination for the optional `deploy` command:

```sh
./ipapatch-lookin setup --device "My iPhone"
./ipapatch-lookin setup --simulator "iPhone 17 Pro"
```

Configuration is stored in the Git-ignored `.ipapatch-lookin.json`. Setup is
optional; all deployment settings can be passed to `deploy`.

The CLI and Xcode build phase coordinate access to this file with
`.ipapatch-lookin.json.lock`, so a concurrent `run`, `setup`, or build cannot
read a partially updated IPA selection. Concurrent `run` preparations are
serialized with `.ipapatch-lookin.prepare.lock` without holding the
configuration lock during package resolution.

## Commands

```sh
./ipapatch-lookin inspect /path/to/App.ipa
./ipapatch-lookin run /path/to/App.ipa
./ipapatch-lookin deploy /path/to/App.ipa --device DEVICE_NAME_OR_UDID
./ipapatch-lookin devices
./ipapatch-lookin simulators
```

Useful `deploy` options:

- `--team TEAM_ID`: Apple development team used to sign a device build
- `--bundle-id BUNDLE_ID`: exact identifier for the patched app
- `--bundle-id-prefix PREFIX`: prefix for the generated identifier
- `--build-only`: build and verify without installing
- `--no-launch`: install without launching
- `--derived-data PATH`: override the reusable build cache location

To validate a device IPA without signing or connecting a device:

```sh
./ipapatch-lookin deploy /path/to/App.ipa --build-only
```

## Device and Simulator behavior

The `run` command does not select or require a destination. For `deploy`, the
behavior is:

| IPA platform | Destination | Signing |
| --- | --- | --- |
| `iPhoneOS` | connected physical iPhone/iPad | Apple Development |
| `iPhoneSimulator` | local iOS Simulator | automatic ad-hoc; no team required |

The tool does not attempt to convert a device binary into a Simulator binary.
That conversion is not possible through re-signing or Mach-O load-command
patching.

## How the patch works

The original application remains an `MH_EXECUTE` Mach-O. Xcode compiles
`IPAPatchFramework`, the build script copies it to
`Dylibs/IPAPatchFramework`, and `optool` inserts
`@executable_path/Dylibs/IPAPatchFramework` into the original executable.
The Swift normalizer changes the legacy upward-load command into a standard
`LC_LOAD_DYLIB`, validates every universal-binary slice, and then the bundle is
re-signed for installation.

LookinServer is compiled into the injected framework for Debug builds. Its
Swift Package condition disables the inspection server in Release builds.
The injected framework targets iOS 15.0, whose system image already includes
the Swift runtime used by LookinServer; it does not depend on the input IPA
having embedded Swift runtime dylibs.

## Analysis compatibility configuration

On every build, the patch script reads
`com.apple.security.application-groups` from the input app's code-signing
entitlements and generates sandbox-local redirects in the built app. The
repository therefore does not contain identifiers belonging to a particular
vendor.

You can still edit `Assets/Resources/IPAPatchLookinConfig.plist` to override a
generated App Group destination or configure app-specific defaults:

```xml
<key>AppGroupRedirects</key>
<dict>
    <key>group.vendor.original</key>
    <string>IPAPatchLookinAppGroup</string>
</dict>
<key>RedirectUserDefaultsSuites</key>
<true/>
<key>ForcedBooleanDefaults</key>
<dict>
    <key>CloudFeatureRestricted</key>
    <true/>
</dict>
```

These redirects help authorized UI analysis but do not grant the patched app
the original developer's entitlements. Manually configured mappings take
precedence over generated mappings.

## Troubleshooting

### `Physical device "iPhone" is unavailable`

`run` only prepares the project and does not require a connected device.
Update the CLI from this repository, run the command again, and open the
printed `IPAPatch.xcodeproj` path. Select the device in Xcode yourself.

Use `deploy` only when you intentionally want command-line device discovery,
building, installation, and launch.

### `Missing decrypted IPA at .../Assets/app.ipa`

Prepare the current checkout before building:

```sh
./ipapatch-lookin run /absolute/path/to/App.ipa
```

The selected path is local to this checkout and is not committed. If the IPA
was moved or deleted, rerun the command with its new path.

### `App Extensions must be prefixed with the main bundle identifier`

The patched app uses a new bundle identifier and cannot sign extensions that
still use the original developer's identifier. The build script removes
standard and nonstandard embedded `.appex` directories, including content
under `PlugIns/`, `Extensions/`, `AppClips/`, and `Watch/`. It also removes the
root App Store `SC_Info` metadata. A decrypted main executable does not need
those SINF records, while retaining them can make a second Xcode Run recreate
an incomplete extension directory or request an unavailable App Store patch
ticket.

If this message remains after updating, choose **Product → Clean Build
Folder** in Xcode and build again.

For a patched app installed before this fix, delete that patched copy from the
device once and press `Cmd-R` again. The official App Store app uses a different
bundle identifier and is not affected.

### App Group entitlement warnings

Messages such as `client is not entitled` are expected when the original app
accesses capabilities owned by its vendor. They do not by themselves prove
that the app crashed. App Group identifiers are redirected automatically when
they are present in the input IPA's code-signing entitlements. If the decrypted
export no longer contains readable entitlements, add only the required group
identifiers to `Assets/Resources/IPAPatchLookinConfig.plist` as described
above.

`LookinServer - Will launch` confirms that the injected framework started.

### Lookin closes the app while loading the hierarchy on iOS 26

LookinServer `1.2.8` normally captures some views with
`drawViewHierarchyInRect:afterScreenUpdates:`. On iOS 26 that API can raise a
UIKit hierarchy assertion for an otherwise valid app. The injected framework
automatically installs an iOS 26 compatibility renderer that uses
`CALayer.render(in:)` for Lookin screenshots instead.

The Xcode console prints
`[IPAPatch-Lookin] Installed iOS 26 safe screenshot compatibility` when the
workaround is active. Some GPU-backed or visual-effect content may have lower
screenshot fidelity, but hierarchy inspection remains available.

`Terminated due to signal 9` is only the debugger's final termination message.
Use the preceding exception or the device crash report to identify the cause;
App Group warnings printed earlier are not sufficient evidence.

## Limitations

Re-signing does not transfer the original team's App Groups, CloudKit
containers, push environment, associated domains, Sign in with Apple, keychain
groups, or server-side authorization. App extensions, App Clips, and Watch
content are removed to simplify signing. Features that depend on those
capabilities may remain unavailable.

## License and attribution

IPAPatch-Lookin retains the original IPAPatch copyright and MIT license. See
[LICENSE](LICENSE) and [README_UPSTREAM.md](README_UPSTREAM.md) for upstream
attribution and third-party license notices.
