# Contributing to IPAPatch-Lookin

Thanks for helping improve IPAPatch-Lookin. Contributions should support
applications that contributors own or are authorized to inspect.

Never commit or attach IPA files, proprietary application code, signing
certificates, provisioning profiles, device identifiers, Apple team IDs, or
other secrets. Use synthetic fixtures and redact local paths and identifiers
from logs.

## Development

Requirements:

- macOS 13 or newer;
- Xcode with its command-line tools selected; and
- Swift 5.9 or newer.

Run the local validation suite before opening a pull request:

```sh
xcrun swift test
sh -n ipapatch-lookin Tools/patch.sh Tools/verify_patch.sh
plutil -lint IPAPatch.xcodeproj/project.pbxproj
git diff --check
```

Tests that need an IPA must use an application you own or are authorized to
inspect. Do not add that IPA to the repository, an issue, or a pull request.

## Pull requests

Keep each pull request focused. Describe the user-visible behavior, list the
validation performed, and update both `README.md` and `README.zh-CN.md` when a
workflow or requirement changes.

Bug fixes should include a regression test when practical. Changes to project
generation should verify both a newly created project and reuse of an existing
project.
