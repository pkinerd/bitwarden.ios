---
id: 121
title: "Pre-upstream PR checklist for offline sync feature"
status: open
created: 2026-02-22
author: pkinerd
labels: [documentation]
priority: high
---

## Description

Master checklist of tasks to complete before submitting the offline sync feature as a pull request to the upstream Bitwarden iOS repository.

Source document: `docs/OfflineSyncDocs/PreUpstreamPRTasks.md` on `claude/issues` branch.

---

## 1. Create Clean Squashed Branch

- [ ] **1a.** Remove `.claude/` changes (revert fork-specific CLAUDE.md modifications, remove artifacts)
- [ ] **1b.** Remove custom scripts (build scripts, automation, helper scripts not part of the feature)
- [ ] **1c.** Remove build changes / custom build configuration (revert .xcodeproj/.xcworkspace changes, match upstream Package.resolved, remove CI/build-log infrastructure)
- [ ] **1d.** Remove offline sync docs folder (`_OfflineSyncDocs/` directory)
- [ ] **1e.** Verify clean diff — every remaining change directly relates to offline sync feature

## 2. Review Outstanding Issues

### 2a. Open Issues Requiring Code Changes

- [ ] **R3** — No retry backoff for permanently failing resolution items (issue #0003)
- [ ] **R1** — No data format versioning for cipherData JSON (issue #0004)
- [ ] **U2-B** — No offline-specific error messages for unsupported operations (issue #0005)

### 2b. Partially Addressed Issues

- [ ] **EXT-3/CS-2** — SDK CipherView manual copy fragility — guard tests exist but underlying fragility remains (issue #0006)

### 2c. Review2 Open Items

- [ ] **R2-PCDS-1** — No Core Data schema versioning step (issue #0022)
- [ ] **R2-UI-1** — Fallback fetch not a stream (issue #0025)
- [ ] **R2-UI-2** — Generic error message when both publisher and fallback fail (issue #0026)
- [ ] **VR-4** — No user feedback on successful offline save (issue #0027)
- [ ] **R2-MAIN-2** — No offline support for attachment operations (issue #0028)

### 2d. Deferred Items (confirm acceptable to defer, document in PR)

- [ ] **U3** — No pending changes indicator (issue #0007)
- [ ] **U2-A** — Full offline archive/unarchive/restore support (issue #0008)
- [ ] **DI-1-B** — Separate CoreServices typealias (issue #0009)
- [ ] **R4-C** — SyncResult enum from fetchSync (issue #0010)
- [ ] **PLAN-3** — Phase 5 integration tests (issue #0011)

## 3. Contributing Guidelines Compliance

- [ ] **3a.** Sign the Contributor Agreement (CLA)
- [ ] **3b.** Create community discussion post in GitHub Discussions — Password Manager
- [ ] **3c.** Verify feature flags (offline save + offline resolution) — defaults to off, coordinate LaunchDarkly flag creation
- [ ] **3d.** Code style & linting — SwiftLint clean, files under 1000 lines, sorted imports, trailing commas, DocC on all new public APIs, 120-char line limit
- [ ] **3e.** Testing — all existing tests pass, all ~119 new tests pass, conventions followed (co-location, Mock naming, BitwardenTestCase)
- [ ] **3f.** Security review — zero-knowledge preserved, encrypt-before-queue verified, Keychain patterns followed, no custom crypto, document offlinePasswordChangeCount rationale
- [ ] **3g.** PR preparation — target correct branch, follow PR template, consider splitting into 5 PRs, clear commit messages
- [ ] **3h.** Architecture compliance — Core/UI split, Services/Repositories/Coordinators/Processors pattern, ServiceContainer DI, unidirectional data flow
- [ ] **3i.** Internationalization — all user-facing strings use i18n, offline error messages localized

## 4. Pre-Submission Final Gate

- [ ] Clean squashed branch created (Section 1)
- [ ] Outstanding issues reviewed with decisions documented (Section 2)
- [ ] CLA signed
- [ ] Community discussion post created
- [ ] All formatters and linters pass
- [ ] All tests pass (existing + new)
- [ ] Feature flags properly implemented
- [ ] Security considerations documented
- [ ] PR description complete (tracking, objective, screenshots)
- [ ] CI builds pass on PR branch

## Comments
