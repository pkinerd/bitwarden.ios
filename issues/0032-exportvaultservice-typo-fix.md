---
id: 32
title: "[R2-UP-5] ExportVaultService typo fix — applied consistently"
status: closed
created: 2026-02-21
author: claude
labels: [enhancement]
priority: low
closed: 2026-02-21
---

## Description

ExportVaultService typo fix already applied consistently — accepted as-is.

**Disposition:** Accepted
**Action Plan:** AP-59 (Accepted)

**Related Documents:** Review2

## Action Plan

*Source: `ActionPlans/Accepted/AP-59_ExportVaultServiceTypoFix.md`*

> **Issue:** #59 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Triaged
> **Source:** Review2/09_UpstreamChanges_Review.md

## Problem Statement

The `ExportVaultService.swift` file contains a typo fix (`encypted` to `encrypted`) that was included as part of the offline sync commits rather than being in a separate, dedicated commit. This is a process concern: mixing incidental fixes with feature work makes the commit history harder to understand and can complicate `git bisect` or `git blame` operations if issues arise later.

The review document (Review2/09_UpstreamChanges_Review.md, line 63) notes that `ExportVaultService.swift` included both a typo fix ("encypted" to "encrypted") and a class rename fix, and that these changes were included in the offline sync commits. The `ServiceContainer.swift` reference was also part of this: the class was renamed from `DefultExportVaultService` to `DefaultExportVaultService`.

## Current State

**ExportVaultService.swift:**
- `BitwardenShared/Core/Vault/Services/ExportVaultService.swift:106` declares `class DefaultExportVaultService: ExportVaultService` -- the typo has been corrected. No instances of `DefultExportVaultService` remain.
- `BitwardenShared/Core/Vault/Services/ExportVaultService.swift:135` references `DefaultExportVaultService` in DocC -- corrected.
- No instances of the `encypted` typo remain in this file (lines 13-14 use `encryptedJson`).

**ExportVaultServiceTests.swift:**
- `BitwardenShared/Core/Vault/Services/ExportVaultServiceTests.swift:179` uses `DefaultExportVaultService(` -- corrected.

**ServiceContainer.swift:**
- `BitwardenShared/Core/Platform/Services/ServiceContainer.swift:564` uses `DefaultExportVaultService(` -- corrected.
- No instances of `DefultExportVaultService` remain anywhere in the codebase.

All corrections have been applied consistently across the codebase. The changes compile and tests pass.

## Assessment

**This issue is a valid but low-impact process concern.** The typo fixes are correct and beneficial. The concern is purely about commit hygiene -- ideally, typo corrections would be in a separate commit from feature work. However:

1. The corrections are straightforward and harmless (spelling fix + class name fix).
2. The review has already identified and cataloged these changes.
3. The code is in its correct final state.
4. Retroactively extracting these into a separate commit would require a rebase, which carries risk disproportionate to the benefit.

This is a common occurrence in feature branch development, especially when the upstream repository introduces a pre-commit spell-checking hook (as documented in Review2/09: `[PM-27525] Add spell check git pre-commit hook (#2319)`).

## Options

### Option A: Accept As-Is (Recommended)
- **Effort:** None
- **Description:** Accept the current state. The typo fixes are correct, documented, and harmless. The commit history accurately reflects that these fixes were noticed and applied during offline sync development.
- **Pros:** No effort; no risk; the corrections are beneficial regardless of which commit they landed in.
- **Cons:** Commit history is slightly less clean.

### Option B: Note in PR Description
- **Effort:** 5 minutes
- **Description:** When creating the PR, note in the description that the `ExportVaultService` rename (`DefultExportVaultService` to `DefaultExportVaultService`) and related typo fix are incidental corrections, not part of the offline sync feature.
- **Pros:** Helps PR reviewers understand the scope.
- **Cons:** Minimal benefit given the review documentation already exists.

### Option C: Extract Into Separate Commit via Rebase
- **Effort:** 30-60 minutes (high risk)
- **Description:** Interactive rebase to move the `ExportVaultService` typo fix into its own commit.
- **Pros:** Cleaner commit history.
- **Cons:** Rebase risk; disproportionate effort for a cosmetic fix; the review is already complete.

## Recommendation

**Option A: Accept As-Is.** The typo correction is applied correctly across all affected files (`ExportVaultService.swift`, `ExportVaultServiceTests.swift`, `ServiceContainer.swift`). The change is beneficial, harmless, and already documented in the review. Extracting it into a separate commit would provide negligible benefit at non-trivial risk.

## Dependencies

- Related to Issue #79 (R2-DI-6), which covers the same `DefultExportVaultService` to `DefaultExportVaultService` rename as observed in `ServiceContainer.swift`, and the `Exhange` to `Exchange` typo fix in the same file.
- Related to Issue #58 (R2-UP-4), the broader concern about upstream changes complicating the diff.

## Comments
