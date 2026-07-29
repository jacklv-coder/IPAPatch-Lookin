# IPAPatch-Lookin

Patch an authorized decrypted iOS IPA, inject
[LookinServer](https://github.com/QMUI/LookinServer), install the rebuilt app,
and launch it for live UI inspection.

The normal workflow is one command:

```sh
./ipapatch-lookin run ~/Downloads/YourApp.ipa
```

You can drag an IPA from Finder into Terminal after
`./ipapatch-lookin run ` instead of typing its path. The IPA is read directly
from that location; it is not copied into or committed with this repository.

This project is based on [Naituw/IPAPatch](https://github.com/Naituw/IPAPatch).
The upstream README is preserved in
[README_UPSTREAM.md](README_UPSTREAM.md).

> Use this project only with applications you own or are authorized to inspect.
> No IPA files, signing certificates, or provisioning profiles are included.

## What is automated

`ipapatch-lookin`:

1. extracts and validates the IPA;
2. rejects an encrypted main executable (`cryptid != 0`);
3. reads both `CFBundleSupportedPlatforms` and the Mach-O platform;
4. selects a physical device for an `iPhoneOS` IPA or a Simulator for an
   `iPhoneSimulator` IPA;
5. generates a stable, locally owned bundle identifier;
6. builds the Xcode project, injects `IPAPatchFramework`, and normalizes its
   Mach-O load command;
7. verifies the patched bundle; and
8. installs and launches it.

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
LookinServer through Swift Package Manager. For a device build, the command
uses the only available Apple Development team and connected device when each
choice is unambiguous.

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

You can also save a default destination:

```sh
./ipapatch-lookin setup --device "My iPhone"
./ipapatch-lookin setup --simulator "iPhone 17 Pro"
```

Configuration is stored in the Git-ignored `.ipapatch-lookin.json`. Setup is
optional; all settings can be passed to `run`.

## Commands

```sh
./ipapatch-lookin inspect /path/to/App.ipa
./ipapatch-lookin devices
./ipapatch-lookin simulators
./ipapatch-lookin run /path/to/App.ipa --device DEVICE_NAME_OR_UDID
./ipapatch-lookin run /path/to/App.ipa --simulator NAME_OR_UDID
```

Useful `run` options:

- `--team TEAM_ID`: Apple development team used to sign a device build
- `--bundle-id BUNDLE_ID`: exact identifier for the patched app
- `--bundle-id-prefix PREFIX`: prefix for the generated identifier
- `--build-only`: build and verify without installing
- `--no-launch`: install without launching
- `--derived-data PATH`: override the reusable build cache location

To validate a device IPA without signing or connecting a device:

```sh
./ipapatch-lookin run /path/to/App.ipa --build-only
```

## Device and Simulator behavior

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

Edit `Assets/Resources/IPAPatchLookinConfig.plist` when the original app expects
App Groups or cloud-related defaults that are unavailable after re-signing:

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
the original developer's entitlements.

## Limitations

Re-signing does not transfer the original team's App Groups, CloudKit
containers, push environment, associated domains, Sign in with Apple, keychain
groups, or server-side authorization. App extensions and Watch content are
removed to simplify signing. Features that depend on those capabilities may
remain unavailable.

## License and attribution

IPAPatch-Lookin retains the original IPAPatch copyright and MIT license. See
[LICENSE](LICENSE) and [README_UPSTREAM.md](README_UPSTREAM.md) for upstream
attribution and third-party license notices.
