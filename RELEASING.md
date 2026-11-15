# Releasing with SwiftPM

Nothing has been tagged or published. SwiftPM resolves semantic version git tags;
there is no package registry upload or separate version field. The tag is the
version source. `vX.Y.Z` tags must reference a commit reachable from `main` and
have a matching nonempty `CHANGELOG.md` entry. Prereleases are not supported yet.

The tag workflow checks these rules, runs the same complete build/test/API matrix
as pull requests, then requests approval through the `release` environment.
Only the final step receives the GitHub token and creates a **draft** GitHub
Release using that changelog entry. All releases remain drafts until an owner
publishes them manually. Workflow checks prevent mistakes; environment protection
and tag rules are required controls.

## One-time owner setup

1. The repository owner decides when to make the repository public. Confirm the license, source,
   example and documentation are ready. Public SwiftPM consumption requires
   public repository access; private consumers need their own Git authentication.
2. Create the GitHub environment `release` with a required reviewer, prevent
   self-approval and restrict deployments to tags matching `v*`. Confirm the
   repository plan supports enforcing these protections at its chosen visibility.
3. Create an active tag ruleset for `v*` restricting tag creation, updates and
   deletion to authorized release maintainers. Protect `main` and review workflow
   changes. Tags themselves make versions resolvable before a draft is published,
   so approval to create the first public tag is the first-release manual gate.
4. Confirm Actions can create releases using the job's `contents: write`
   permission. No custom publishing token or signing secret is required.
5. Merge the release preparation only after CI is green. No tags, releases,
   visibility changes or environment configuration are performed by that PR.

## Public package contract

- Swift tools version: 6.0; iOS 15 and macOS 13 minimums. iOS UI compilation uses
  Xcode 26.2 in CI for the iOS 26 SDK while retaining the iOS 15 deployment target.
- `MobilerunStream` is the iOS session/UI product. `MobilerunProtocol` exposes
  standalone wire helpers. These are the only library products.
- `MobilerunStreamCore` stays an implementation target, not a separate product.
  Its public value types re-exported by `MobilerunStream` are part of the API contract;
  its package-only orchestration and transport types are excluded.
- LiveKitWebRTC is pinned exactly to `150.7871.05` (SwiftPM canonical spelling
  `150.7871.5`), never a range. Review the resolved checksum/version on upgrades.
- `api/MobilerunStream.api.txt` records sorted symbol-graph declarations,
  availability, generic constraints and conformances for macOS and iOS, including
  SwiftUI extension APIs. Internal, package and SPI symbols are excluded, as are
  synthesized members, Objective-C protocol conformances, inherited conformances
  marked by the extractor and compiler-only
  `SendableMetatype` markers. Generate and compare with the pinned Xcode 26.2
  toolchain: newer compilers emit different annotations and SDK conformances.
  Symbol graphs can omit closure attributes such as `@Sendable`; inspect those
  source changes explicitly. They can also omit setter visibility for
  `@Published public private(set)` properties; inspect changes to those setters
  in source. This is a source API baseline, not an ABI guarantee.

## Each release

1. Update the changelog with the intended stable `X.Y.Z` version. Refresh the
   README installation example and remove its pre-release notes for the first
   release. There is no version to bump in `Package.swift`.
2. Select the same Xcode as CI. Run `swift build`, `swift test`, and the simulator
   library/example builds and simulator tests in `.github/workflows/ci.yml`.
   For intentional public API changes, run `tool/api-dump.sh`, inspect the diff
   and commit it. `tool/api-dump.sh --check` must pass. Both supported destinations
   are necessary: macOS alone omits UIKit and SwiftUI streaming APIs. The dump
   uses SwiftPM's native build backend and extracts only the shipping modules.
3. After the first tag exists, also run the compatibility diagnostic against the
   last released version, for example `swift package diagnose-api-breaking-changes
   v0.1.0`. Run it for the iOS destination as well, using the same `--sdk` and
   `--triple` options as `tool/api-dump.sh`. Resolve or document intentional
   breaking changes and choose the next version accordingly.
4. Merge the release PR only after CI, including the release dry run, is green.
   With explicit release authorization, tag the exact merged commit on `main`:

   ```sh
   git tag v0.1.0 <merged-commit>
   git push origin v0.1.0
   ```

5. Inspect the successful verification run, tag and commit before approving the
   `release` environment. Review the draft's changelog notes and manually publish
   it when ready. Verify SwiftPM resolves the tag before announcing the release.
   Do not move a published version tag; diagnose failures before retrying a run.
