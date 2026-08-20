## Summary

- Describe the user-visible change.
- Explain why it is needed.

## Validation

- [ ] `xcrun swift test`
- [ ] `sh -n ipapatch-lookin Tools/patch.sh Tools/verify_patch.sh`
- [ ] `plutil -lint IPAPatch.xcodeproj/project.pbxproj`
- [ ] `git diff --check`

## Safety and compatibility

- [ ] No IPA, certificate, provisioning profile, device identifier, or other sensitive material is included.
- [ ] Existing `run`, direct-IPA, and `deploy` behavior remains compatible, or the change is documented.
- [ ] Documentation and tests are updated when user-facing behavior changes.
