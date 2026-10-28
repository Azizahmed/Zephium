# Windows signing setup

Status: implementation awaiting a successful SignPath test. Do not merge the
production workflow until the test passes and the production certificate is
issued. Existing public releases are not changed by this work.

On 2026-10-27, SignPath accepted `windows.xml` as the valid `initial`
configuration. The public test certificate thumbprint was verified in its
dashboard and saved as the GitHub Actions variable:
`7999635F7895816566299F09FF451C457C082F13`.

## SignPath dashboard

- Organization: `6d23e298-6eb5-4692-b09e-9ab18f484855` (Zephium [OSS]).
- Project slug: `Zephium` (case-sensitive spelling as shown by SignPath).
- Repository: `https://github.com/zephium-browser/Zephium.git`.
- Replace artifact configuration `initial` with `windows.xml` in this directory.
  The root is ZIP; one exact `Zephium.exe` entry must have product name Zephium
  and the requested product version. The workflow stages each signing target
  under that name separately; it never submits third-party plugins.
- `test-signing`: use the existing test certificate and CI submitter.
- `release-signing`: retain the CI submitter, one manual approval from Hayk,
  GitHub trusted-build requirement, and repository origin verification.
- Before production, restrict allowed build definitions to the release workflow
  and source refs to the approved release flow. Check the exact origin recorded
  by both a tag push and a manual rebuild before narrowing the ref rule. Do not
  disable origin verification to accommodate mismatched checkout/workflow refs.
- The production certificate was CSR pending at inspection. Issuance/import
  belongs to SignPath Foundation after their review. Do not replace it with the
  test certificate or weaken validation to make a release pass.

## GitHub configuration

`SIGNPATH_API_TOKEN` is an Actions secret for the existing CI user. It is passed
only to SignPath's official action, not to compilation or the packaging hook.
The existing `TAURI_SIGNING_PRIVATE_KEY` and password remain updater-only keys.

Set these Actions variables from the public certificate details in SignPath:

| Variable | Value |
| --- | --- |
| `SIGNPATH_TEST_CERT_THUMBPRINT` | Exact 40-hex SHA-1 thumbprint of Test certificate 2026 |
| `SIGNPATH_RELEASE_CERT_THUMBPRINT` | Exact thumbprint of the issued production certificate |

The thumbprint is a certificate identifier, not the digest used for signing.
Review and update it explicitly when the certificate is renewed. Missing or
incorrect pins fail closed. The GitHub trusted-build link is already active;
verify GitHub App repository access if the connector reports an authorization
error. Grant only Zephium access. Never share tokens in an issue, log, or chat.

## Packaging and approval order

Tauri 2.11.4 patches the main executable for NSIS before signing it, then restores
the original build-directory executable after bundling. Pre-signing the original
executable is insufficient. `scripts/release/signpath.ps1` starts `tauri bundle`
with Tauri's documented `bundle.windows.signCommand` callback. It pauses at:

1. The patched browser executable.
2. The NSIS-generated uninstaller (`!uninstfinalize`).
3. The completed installer containing the two signed executables.

For each stage, the composite action uploads the unsigned file with the official
GitHub action, submits its artifact ID with SignPath's pinned official action,
checks the returned certificate and Authenticode validity, then resumes Tauri.
Each request can require a separate production approval. No private API or
direct token-based artifact upload bypasses GitHub provenance.

Only the five exact bundled NSIS plugin paths from the pinned Tauri source are
excluded from Zephium signing. Their upstream signatures/unsigned status are
preserved. This does not promise that every third-party PE in the package is
signed, nor does it claim Microsoft Store eligibility.

The pipeline verifies the installed browser and uninstaller against the signed
copies, then uninstalls from a disposable GitHub-hosted Windows runner. It does
not rely on Tauri's restored build-directory executable as signing evidence.

## Test workflow

Run `SignPath test signing`. On the isolated `signpath-windows` branch, pushes to
its signing files bootstrap the test before the workflow is on the default
branch. Remove that push trigger when merging. The workflow cannot publish a
release and has no repository write permission.

For cryptographic verification of the self-signed certificate, the workflow
temporarily trusts ONLY the independently pinned public test certificate in the
disposable runner's LocalMachine root store (the CurrentUser store can show an
interactive confirmation dialog). Cleanup removes that added entry. No developer
or end-user machine is modified, and output verification has a five-minute timeout.
Production uses ordinary Windows trust validation and requires a timestamp.
Never install the test root on an end user's machine. Test artifacts expire in
seven days and must never be uploaded as public release assets.

Success requires all three signing requests, verified installed bytes,
installation/uninstallation, rejection of tampered/wrong-publisher/wrong-version
files, and Linux minisign verification over the final signed installer.
This is not an end-to-end automatic-update qualification. Before production,
test an actual upgrade from the prior public release on a disposable Windows
machine, checking retained profile data and startup. Use a release candidate
and approved test update endpoint; do not change the live update feed for a test.

## Integration with the security work

The other workstream adds authenticated release identity in commit
`cf930035fe50339d076ec4bc3c94849945bf5581` (`fix/security-boundaries`, local
remediation repository). It is deliberately not copied/pushed by this branch.

When merging both changes, keep its unconditional step named
`Sign the final Windows bytes for the updater` after SignPath and after the
generic Tauri re-sign step, immediately before staging:

```sh
cargo run --locked -p xtask -- sign-windows-updater \
  "target/release/bundle/nsis/Zephium_${VERSION}_x64-setup.exe" "${VERSION}"
```

Its trusted comment must be exactly
`zephium-updater-v1 version=${VERSION} target=windows-x86_64-nsis`.
Do not overwrite that signature afterward or add a fallback when the helper
is missing. Run its `scripts/release/test_windows_updater.py` regression tests
and updater unit tests on the combined tree. Checksums, manifest and provenance
must reference the final signed files.

## Foundation handoff

Before requesting production review, publish a Code signing policy linked from
the project home page and download/release pages. It must credit SignPath.io
and SignPath Foundation, identify the actual committers/reviewers and signing
approvers, and link the applicable privacy policies. Confirm the maintainer
roster and policy URLs before publishing; do not substitute a blanket promise
of no network transfers for the browser's actual update and online features.
All team members need MFA for SignPath and GitHub. These are Foundation
requirements, not settings that a successful CI run can prove by itself.

After a successful test, send SignPath the Actions run URL, three signing request
URLs (recorded in the run summary), artifact XML, and code signing policy link.
Ask them to review the full coverage and production source restrictions. Once
they issue the certificate, record its public thumbprint, run an approved
production signing validation, and finish Windows update qualification before
publishing. Keep published assets immutable; ship a higher version for fixes.

## Official references

- https://docs.signpath.io/trusted-build-systems/github
- https://docs.signpath.io/artifact-configuration/examples
- https://docs.signpath.io/artifact-configuration/reference
- https://signpath.org/terms
- https://v2.tauri.app/distribute/sign/windows/#custom-sign-command
- https://github.com/tauri-apps/tauri/blob/tauri-cli-v2.11.4/crates/tauri-bundler/src/bundle.rs
- https://github.com/tauri-apps/tauri/blob/tauri-cli-v2.11.4/crates/tauri-bundler/src/bundle/windows/nsis/installer.nsi
- https://github.com/SignPath/github-action-submit-signing-request/tree/f6d04783b4569d051e0c80105fe66e82819d0092
