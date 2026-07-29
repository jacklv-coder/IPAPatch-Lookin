# IPAPatch-Lookin

Inject [LookinServer](https://github.com/QMUI/LookinServer) into a decrypted
iOS app, re-sign it with Xcode, and inspect its live view hierarchy on a real
device.

This project is based on [Naituw/IPAPatch](https://github.com/Naituw/IPAPatch).
The original README is preserved in [README_UPSTREAM.md](README_UPSTREAM.md).

> Use this project only with applications you own or are authorized to inspect.
> No IPA files, signing certificates, or provisioning profiles are included.

## What this fork adds

- LookinServer `1.2.8` linked into Debug builds of the injected
  `IPAPatchFramework` (Release and Archive builds exclude the inspection server)
- Xcode 26-compatible CocoaPods and deployment settings
- standard `LC_LOAD_DYLIB` normalization for the bundled legacy `optool`
- optional App Group and `UserDefaults` redirection into the patched app sandbox
- configurable forced boolean defaults for disabling unavailable cloud features
- unsigned generic-device builds for static verification
- a verification script for the injection and LookinServer linkage

The original app remains an `MH_EXECUTE` Mach-O. IPAPatch compiles a small
dynamic library, copies it to `Dylibs/IPAPatchFramework`, inserts a load command
into the original executable, and re-signs the resulting app bundle.

## Requirements

- macOS with Xcode
- Ruby 3.2 or newer and Bundler `4.0.16` (Homebrew Ruby is recommended)
- CocoaPods through Bundler
- a real iPhone or iPad with Developer Mode enabled
- an Apple development team for signing
- a decrypted IPA (`cryptid = 0`)
- the Lookin macOS app

App Store IPAs normally contain iPhoneOS arm64 code and cannot run in the iOS
Simulator.

The project currently targets iOS 15.0. Lower it in both the project and
`Podfile` if the authorized app or test device requires an older deployment
target.

## Setup

Install a current Ruby, activate the pinned Bundler version, and generate the
workspace. On a Homebrew-based setup:

```sh
brew install ruby
export PATH="$(brew --prefix ruby)/bin:$PATH"
gem install bundler -v 4.0.16
bundle _4.0.16_ config set path Vendor/bundle
bundle _4.0.16_ install
bundle _4.0.16_ exec pod install
```

Apple's system Ruby 2.6 is not supported by the locked dependency set.

Then:

1. Copy your authorized decrypted IPA to `Assets/app.ipa`.
2. Open `IPAPatch.xcworkspace`.
3. Select the `IPAPatch-DummyApp` target.
4. Choose your development team and set a unique bundle identifier.
5. Select a connected real device and press `Cmd + R`.
6. Launch Lookin on the Mac and select the running patched app.

The patched app display name is prefixed with `🔬 ` so it is easy to distinguish
from the original installation.

## Analysis configuration

Edit `Assets/Resources/IPAPatchLookinConfig.plist` before building:

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

`AppGroupRedirects` maps an App Group identifier owned by the original
developer to a directory under the patched app's own `Library` directory. When
`RedirectUserDefaultsSuites` is enabled, matching `NSUserDefaults` suites use
the patched app's standard defaults instead.

This is intended for UI analysis when extensions and cross-process sharing are
not required. It does not grant the patched app the original developer's
entitlements.

## Verification

Build without signing when you only need to verify the patch structure:

```sh
xcodebuild \
  -workspace IPAPatch.xcworkspace \
  -scheme IPAPatch-DummyApp \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/ipapatch-lookin-dd \
  CODE_SIGNING_ALLOWED=NO \
  build

Tools/verify_patch.sh \
  /tmp/ipapatch-lookin-dd/Build/Products/Debug-iphoneos/IPAPatch-DummyApp.app
```

Expected runtime logs include:

```text
LookinServer - Will launch. Framework version: 1.2.8
[IPAPatch-Lookin] LookinServer loaded
```

Configured compatibility redirects also emit an
`[IPAPatch-Lookin] Redirected ...` message.

## Entitlement limitations

Re-signing does not transfer the original team's App Groups, CloudKit
containers, push environment, associated domains, Sign in with Apple, or
keychain groups. Configure only the compatibility redirects needed for
authorized analysis, and expect unrelated online SDK features to remain
unavailable.

## License and attribution

IPAPatch-Lookin retains the original IPAPatch copyright and MIT license. See
[LICENSE](LICENSE) and [README_UPSTREAM.md](README_UPSTREAM.md) for upstream
attribution and third-party license notices.
