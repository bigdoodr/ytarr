# Releasing

1. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in the Xcode target and update `RELEASE_NOTES.md`.
2. `cd YTArr && swift test`.
3. Xcode: Product > Archive > Distribute App > Direct Distribution (Developer ID, notarize). Export the notarized `YTArr.app`.
4. `ditto -c -k --keepParent YTArr.app YTArr.zip`
5. `xcrun stapler validate YTArr.app` and `spctl -a -vv YTArr.app` (should say "accepted, source=Notarized Developer ID").
6. `git tag v1.0.0 && git push --tags`, then create the GitHub release with `RELEASE_NOTES.md` and attach `YTArr.zip`:
   `gh release create v1.0.0 YTArr.zip --title "YTArr 1.0" --notes-file RELEASE_NOTES.md`

## Automated release (GitHub Actions)
`.github/workflows/release.yml` does steps 3-6 above when you push a tag like `v1.0.0`: it runs the tests, builds, signs with
Developer ID, notarizes, staples, zips, and creates the GitHub release with `RELEASE_NOTES.md` and `YTArr.zip`.
Update `RELEASE_NOTES.md` before tagging. The tag sets the app version (`v1.2.0` becomes 1.2.0).

One-time setup: repo Settings > Secrets and variables > Actions > New repository secret.

| Secret | What it is |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Your "Developer ID Application" certificate with its private key, exported from Keychain Access as .p12, then `base64 -i cert.p12 \| pbcopy` |
| `DEVELOPER_ID_P12_PASSWORD` | The password you set when exporting the .p12 |
| `NOTARY_KEY_P8_BASE64` | An App Store Connect API key (Users and Access > Integrations > Team Keys, Developer access): `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
| `NOTARY_KEY_ID` | That key's Key ID |
| `NOTARY_ISSUER_ID` | The Issuer ID shown on the same page |

The team ID (`C7ZFPH2CB5`) is set in the workflow. Delete the .p12 and .p8 from your Mac's Downloads afterwards.
Then: `git tag v1.0.0 && git push origin v1.0.0`.
