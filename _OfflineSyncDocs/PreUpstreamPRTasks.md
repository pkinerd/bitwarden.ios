# Pre-Upstream PR Tasks

> **Created:** 2026-02-21
> **Purpose:** Checklist of tasks to complete before submitting the offline sync feature as a pull request to the upstream Bitwarden iOS repository (`bitwarden/ios`).
> **Contributing guidelines reference:** [contributing.bitwarden.com](https://contributing.bitwarden.com/contributing/) / cloned locally from `https://github.com/pkinerd/bitwarden.contributing-docs`

---

## 1. Create Clean Squashed Branch

Create a clean branch from the current `main` (or upstream `main`) containing only the offline sync feature changes. The squashed branch must exclude all development-only artifacts:

### 1a. Remove `.claude/` Changes

- [ ] Remove or revert any modifications to `.claude/CLAUDE.md` that are specific to this fork's development workflow
- [ ] Remove any other `.claude/` directory artifacts not present in upstream

### 1b. Remove Custom Scripts

- [ ] Remove any custom build scripts, automation scripts, or helper scripts added during development that are not part of the feature itself
- [ ] Verify no references to removed scripts remain in other files

### 1c. Remove Build Changes / Custom Build Configuration

- [ ] Revert any `.xcodeproj` / `.xcworkspace` changes that are not required by the offline sync feature (e.g., custom build schemes, debug configurations)
- [ ] Ensure the `Package.resolved` / SPM dependency state matches upstream (except for any SDK version updates that are part of the feature)
- [ ] Remove any CI/build-log infrastructure specific to this fork (e.g., `build-logs/` branch automation)

### 1d. Remove Offline Sync Docs Folder

- [ ] Remove the entire `_OfflineSyncDocs/` directory (plans, reviews, action plans, changelogs — all development-only artifacts)
- [ ] Verify no source code references `_OfflineSyncDocs/` paths

### 1e. Verify Clean Diff

- [ ] Run `git diff upstream/main...<clean-branch>` and verify every remaining change is directly related to the offline sync feature
- [ ] Confirm upstream typo fixes, SDK changes, and other incidental changes (cataloged in `Review2/09_UpstreamChanges_Review.md`) are either excluded or properly rebased onto upstream `main`

---

## 2. Review of Outstanding Issues

Review the consolidated issue tracker (`ConsolidatedOutstandingIssues.md`) and make a deliberate decision on each open item before submitting upstream.

### 2a. Open Issues Requiring Code Changes

| Issue ID | Description | Decision Needed |
|----------|-------------|-----------------|
| **R3** | No retry backoff for permanently failing resolution items — blocks all syncing | Fix before PR, defer to follow-up PR, or document as known limitation |
| **R1** | No data format versioning for `cipherData` JSON | Fix before PR (bundle schema change with R3) or defer |
| **U2-B** | No offline-specific error messages for unsupported operations | Fix before PR (low effort) or defer |

### 2b. Partially Addressed Issues

| Issue ID | Description | Decision Needed |
|----------|-------------|-----------------|
| **EXT-3 / CS-2** | SDK `CipherView` manual copy fragility — guard tests exist but underlying fragility remains | Accept with documentation or propose further mitigation |

### 2c. Review2 Open Items

| Issue ID | Description | Decision Needed |
|----------|-------------|-----------------|
| **R2-PCDS-1** | No Core Data schema versioning step | Address or document |
| **R2-UI-1 (AP-53)** | Fallback fetch not a stream — no live updates for offline-created cipher | Defer or fix |
| **R2-UI-2 (AP-54)** | Generic error message when both publisher and fallback fail | Defer or fix |
| **VR-4 (AP-55)** | No user feedback on successful offline save | Defer or fix |
| **R2-MAIN-2 (AP-78)** | No offline support for attachment operations | Document as known limitation |

### 2d. Deferred Items

Confirm these are acceptable to defer and document clearly in the PR description:

- **U3** — No pending changes indicator (future enhancement)
- **U2-A** — Full offline support for archive/unarchive/restore
- **DI-1-B** — Separate `CoreServices` typealias
- **R4-C** — `SyncResult` enum from `fetchSync`
- **PLAN-3 / AP-77** — Phase 5 integration tests

---

## 3. Contributing Guidelines Compliance

Tasks derived from [Bitwarden Contributing Guidelines](https://contributing.bitwarden.com/contributing/) and the project's PR process documentation.

### 3a. Contributor Agreement

- [ ] Sign the [Contributor Agreement (CLA)](https://cla-assistant.io/bitwarden/clients) — required before any PR can be accepted

### 3b. Community Discussion Post

- [ ] Create a discussion post in [GitHub Discussions — Password Manager](https://github.com/orgs/bitwarden/discussions/categories/password-manager) describing the offline sync feature, including:
  - Description of the contribution
  - Screenshots (if applicable)
  - Links to any relevant feature requests or issues
  - **Required for features with significant UX changes** (per contributing guidelines)

### 3c. Feature Flags

- [ ] Verify the two server-controlled feature flags (offline save + offline resolution) are properly implemented per [feature flag guidelines](https://contributing.bitwarden.com/contributing/feature-flags/)
- [ ] Confirm feature defaults to "off" when flags are unavailable (defensive coding per guidelines)
- [ ] Coordinate with Bitwarden team on LaunchDarkly flag creation (needed before merge to `main`)

### 3d. Code Style & Linting

- [ ] Run SwiftLint and resolve all warnings/errors (`swiftlint lint`)
- [ ] Verify all files remain under 1000 lines (`file_length` rule)
- [ ] Confirm sorted imports, trailing commas, `type_contents_order` compliance
- [ ] Verify DocC documentation on all new public APIs (except protocol implementations and mocks)
- [ ] Ensure 120-character line limit compliance

### 3e. Testing

- [ ] All existing tests pass with the offline sync changes
- [ ] All ~119 new offline sync tests pass (across 7 test files)
- [ ] Confirm test file co-location follows project conventions
- [ ] Verify mock naming conventions (`Mock<Name>`)
- [ ] Verify test class inherits from `BitwardenTestCase`

### 3f. Security Review

- [ ] Zero-knowledge architecture preserved — no new plaintext transmitted or stored at rest
- [ ] Encrypt-before-queue pattern verified — pending queue stores encrypted data only
- [ ] iOS Keychain usage follows existing patterns
- [ ] No custom cryptography introduced (all crypto via SDK)
- [ ] Review `offlinePasswordChangeCount` plaintext storage decision (accepted in SEC-2/AP-83, but document rationale for reviewers)

### 3g. PR Preparation

- [ ] Target the correct branch (`main` for feature-flag-gated work, or coordinate long-lived feature branch with team)
- [ ] Follow PR template (`.github/PULL_REQUEST_TEMPLATE.md`):
  - **Tracking**: Link to Jira issue or GitHub Discussion post
  - **Objective**: Clear description of offline sync feature purpose
  - **Screenshots**: UI changes (offline save behavior, error messages, conflict backup)
- [ ] Keep PR to a manageable size — if the diff is significantly above a few hundred lines, consider splitting into multiple PRs:
  - PR 1: Core Data model + `PendingCipherChangeDataStore` + tests
  - PR 2: `OfflineSyncResolver` conflict resolution engine + tests
  - PR 3: `VaultRepository` offline fallback handlers + tests
  - PR 4: `SyncService` pre-sync resolution integration + tests
  - PR 5: DI wiring + `CipherView` extensions + remaining tests
- [ ] Write clear commit messages (under 50 characters, grouped by related changes)
- [ ] Avoid force-push after review begins

### 3h. Architecture Compliance

- [ ] Core/UI split maintained — offline sync logic in Core layer
- [ ] Services/Repositories/Coordinators/Processors pattern followed
- [ ] `ServiceContainer` DI used for `HasOfflineSyncResolver`
- [ ] Unidirectional data flow preserved
- [ ] Verify against project `Docs/Architecture.md`

### 3i. Internationalization

- [ ] All user-facing strings use i18n (localization) — no hardcoded English strings in UI layer
- [ ] Verify offline error messages and any new UI text are localized

---

## 4. Pre-Submission Verification Checklist

Final checks before marking the PR as "Ready for Review":

- [ ] Clean squashed branch created (Section 1 complete)
- [ ] Outstanding issues reviewed and decisions documented (Section 2 complete)
- [ ] CLA signed
- [ ] Community discussion post created
- [ ] All formatters and linters pass
- [ ] All tests pass (existing + new)
- [ ] Feature flags properly implemented
- [ ] Security considerations documented
- [ ] PR description complete with tracking, objective, and screenshots
- [ ] CI builds pass on the PR branch

---

## References

- [Contributing Guidelines](https://contributing.bitwarden.com/contributing/)
- [Pull Request Process](https://contributing.bitwarden.com/contributing/pull-requests/)
- [Code Review Expectations](https://contributing.bitwarden.com/contributing/pull-requests/code-review/)
- [Community PR Review Process](https://contributing.bitwarden.com/contributing/pull-requests/community-pr-process/)
- [Feature Flags](https://contributing.bitwarden.com/contributing/feature-flags/)
- [Branching Strategy](https://contributing.bitwarden.com/contributing/pull-requests/branching/)
- [Swift Code Style](https://contributing.bitwarden.com/contributing/code-style/swift)
- [iOS Architecture](https://contributing.bitwarden.com/architecture/mobile-clients/ios/)
- [Security Principles](https://contributing.bitwarden.com/architecture/security/)
- [Consolidated Outstanding Issues](./../_OfflineSyncDocs/ConsolidatedOutstandingIssues.md)
- [PR Template](/.github/PULL_REQUEST_TEMPLATE.md)
