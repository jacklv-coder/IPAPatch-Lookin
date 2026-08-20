# Changelog

## IPAPatch-Lookin 0.4.2 — 2026-08-20

First packaged release of the current IPAPatch-Lookin workflow.

### Highlights

- generate or reuse an isolated Xcode project for each byte-distinct IPA;
- accept `./ipapatch-lookin App.ipa` as the primary project-generation command;
- validate IPA encryption state, Mach-O platform, and architecture before use;
- inject the pinned LookinServer 1.2.8 package;
- support physical-device and compatible Simulator workflows;
- redirect declared App Groups into the patched app's sandbox;
- provide bilingual documentation and actionable project-ready output; and
- cover the CLI, project generator, command runner, and Mach-O handling with
  automated tests.

The repository's `1.0` and `1.0.1` tags are historical tags inherited from the
upstream IPAPatch project. Current IPAPatch-Lookin releases use the
`ipapatch-lookin-v<version>` tag prefix to avoid ambiguity.
