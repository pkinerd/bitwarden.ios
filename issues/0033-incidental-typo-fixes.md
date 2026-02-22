---
id: 33
title: "[R2-DI-6] Incidental typo fixes — applied consistently"
status: closed
created: 2026-02-21
author: claude
labels: [enhancement]
priority: low
closed: 2026-02-21
---

## Description

Incidental typo fixes properly applied and consistent — accepted as-is.

**Disposition:** Accepted
**Action Plan:** AP-79 (Accepted)

**Related Documents:** Review2

## Action Plan

*Source: `ActionPlans/Accepted/AP-79_IncidentalTypoFixes.md`*

> **Issue:** #79 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Triaged
> **Source:** Review2/05_DIWiring_Review.md

## Problem Statement

The `ServiceContainer.swift` file includes two incidental typo fixes that are unrelated to the offline sync feature:

1. `DefultExportVaultService` renamed to `DefaultExportVaultService` (class instantiation)
2. `Exhange` corrected to `Exchange` (in comments)

These corrections were identified as part of the upstream spell-check hook (`[PM-27525] Add spell check git pre-commit hook (#2319)`) and were applied during the offline sync development period. They are mixed into the same commits as the offline sync `ServiceContainer` changes (addition of `offlineSyncResolver` and `pendingCipherChangeDataStore` wiring).

## Current State

**`DefultExportVaultService` to `DefaultExportVaultService`:**
- `BitwardenShared/Core/Platform/Services/ServiceContainer.swift:564` now reads:
  ```swift
  let exportVaultService = DefaultExportVaultService(
  ```
- No instances of `DefultExportVaultService` remain anywhere in the codebase (verified via codebase-wide search).
- The class definition in `BitwardenShared/Core/Vault/Services/ExportVaultService.swift:106` is `class DefaultExportVaultService: ExportVaultService` -- this is consistent.
- `BitwardenShared/Core/Vault/Services/ExportVaultServiceTests.swift:179` also uses `DefaultExportVaultService(` -- consistent.

**`Exhange` to `Exchange`:**
- `BitwardenShared/Core/Platform/Services/ServiceContainer.swift` no longer contains the string `Exhange` (verified via search). The corrected references at lines 87, 106, 237, 245 now correctly use `Exchange` in DocC comments related to Credential Exchange Format.

**Other typo fixes in the same file (from upstream):**
- `appllication` to `application` was also corrected (per Review2/09, line 22).

All corrections are applied consistently and the file compiles without errors.

## Assessment

**This issue is a valid but inconsequential process concern.** The typo fixes are:

1. **Correct** -- they fix genuine misspellings in a class name and comments.
2. **Compile-affecting** for the `DefultExportVaultService` rename (the class name had a typo, so both the definition and all call sites needed to be updated together).
3. **Not compile-affecting** for the `Exhange` to `Exchange` comment fix.
4. **Harmless** -- no behavioral change beyond the class name correction.
5. **Already applied consistently** across all affected files.

The concern is purely about commit hygiene. In practice, these fixes were naturally applied when the upstream spell-check hook was introduced, and they ended up in the offline sync branch because the branch was being actively developed when the hook was adopted.

## Options

### Option A: Accept As-Is (Recommended)
- **Effort:** None
- **Description:** Accept the current state. The typo fixes are correct, consistent, and fully applied. They are documented in both Review2/05_DIWiring_Review.md and Review2/09_UpstreamChanges_Review.md.
- **Pros:** No effort; no risk; corrections are beneficial.
- **Cons:** Commit history includes non-feature changes in feature commits.

### Option B: Note in PR Description
- **Effort:** 5 minutes
- **Description:** Include a note in the offline sync PR description listing the incidental typo fixes in `ServiceContainer.swift` as non-feature changes.
- **Pros:** Helps PR reviewers distinguish feature changes from incidental fixes.
- **Cons:** Minimal incremental value given the existing review documentation.

### Option C: Extract Into Separate Commit via Rebase
- **Effort:** 30-60 minutes (high risk)
- **Description:** Interactive rebase to isolate the typo fixes from the offline sync DI wiring changes in `ServiceContainer.swift`.
- **Pros:** Cleaner commit history; easier `git blame`.
- **Cons:** High risk of conflicts since `ServiceContainer.swift` has both typo fixes and offline sync changes interleaved. Disproportionate effort for cosmetic fix.

## Recommendation

**Option A: Accept As-Is.** Both typo fixes are correct, beneficial, and have no interaction with offline sync functionality. They are already well-documented in the review artifacts. Attempting to separate them retroactively would require rebasing a complex file with interleaved changes for minimal benefit.

## Dependencies

- Related to Issue #59 (R2-UP-5): The `DefultExportVaultService` rename is the same change observed from the `ExportVaultService.swift` side.
- Related to Issue #58 (R2-UP-4): The broader concern about upstream changes in the offline sync diff.

## Comments
