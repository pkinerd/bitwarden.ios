---
id: 58
title: "[TC-6] Mock defaults silently bypass abort logic"
status: closed
created: 2026-02-21
author: claude
labels: [enhancement]
priority: medium
closed: 2026-02-21
---

## Description

24 of 25 `fetchSync` tests use default `pendingChangeCountResult = 0` with no assertions about offline resolution.

**Severity:** Medium
**Rationale:** `test_fetchSync_preSyncResolution_skipsWhenResolutionFlagDisabled` already covers the negative path; feature flag default `false` provides strong gate.

**Related Documents:** AP-41 (Accepted As-Is)

**Disposition:** Accepted — no code change planned.

## Action Plan

*Source: `ActionPlans/Accepted/AP-41_MockDefaultsBypassAbortLogic.md`*

> **Issue:** #41 from ConsolidatedOutstandingIssues.md
> **Severity:** Medium | **Complexity:** Low
> **Status:** Accepted As-Is
> **Source:** ReviewSection_TestChanges.md (TC-6 / Deep Dive 6)

## Problem Statement

The `MockPendingCipherChangeDataStore` has a default `pendingChangeCountResult = 0` at `MockPendingCipherChangeDataStore.swift:26`. The `MockConfigService` returns `false` (the `defaultValue`) for any unset feature flag.

In `SyncService.fetchSync()` at `SyncService.swift:341-351`, the offline resolution block is gated by `configService.getFeatureFlag(.offlineSyncEnableResolution)`. Since the default value is `false`, the block is skipped entirely in all pre-existing `fetchSync` tests that do not explicitly set this flag.

The original review concern (TC-6) noted that 24 of 25 pre-existing `fetchSync` tests "silently bypass abort logic" with default `pendingChangeCountResult = 0` and "no assertions about offline resolution." The concern was that if `pendingChangeCountResult` were changed to a positive number, tests would break.

**However, this concern has been substantially mitigated by the feature flag.** Since the feature flag defaults to `false`, the offline resolution block is never reached in pre-existing tests regardless of `pendingChangeCountResult`. The mock default for `pendingChangeCountResult` is irrelevant when the feature flag is off.

## Current Test Coverage

- **7 dedicated offline sync tests in SyncServiceTests.swift (lines 1100-1225):**
  - `test_fetchSync_preSyncResolution_triggersPendingChanges` (line 1100) -- flag on, count [1,0], verifies resolver called
  - `test_fetchSync_preSyncResolution_skipsWhenVaultLocked` (line 1116) -- flag on, vault locked, verifies resolver NOT called
  - `test_fetchSync_preSyncResolution_noPendingChanges` (line 1129) -- flag on, count=0, verifies resolver NOT called
  - `test_fetchSync_preSyncResolution_abortsWhenPendingChangesRemain` (line 1146) -- flag on, count [2,2], verifies sync aborted
  - `test_fetchSync_preSyncResolution_resolverThrows_syncFails` (line 1166) -- flag on, resolver throws, verifies error propagation
  - `test_fetchSync_preSyncResolution_stillResolvesWhenOfflineSyncFlagDisabled` (line 1191) -- resolution flag on, offline changes flag off
  - `test_fetchSync_preSyncResolution_skipsWhenResolutionFlagDisabled` (line 1212) -- flag off, verifies entire block skipped
- **24+ pre-existing `fetchSync` tests (lines 379-995):** None set `offlineSyncEnableResolution = true`. They rely on the default `false` to skip the resolution block entirely.

## Missing Coverage

1. Pre-existing `fetchSync` tests do not assert that offline resolution was NOT triggered (no `XCTAssertTrue(pendingCipherChangeDataStore.pendingChangeCountCalledWith.isEmpty)` or similar).
2. If someone changed the feature flag default to `true`, all pre-existing tests would need to handle the resolution block (but this is an unlikely change since defaults are `false` by design).
3. There is no "safety assertion" in the test setup that documents the assumption about feature flag defaults.

## Assessment

**Partially valid with reduced severity.** The original TC-6 concern assumed that mock defaults for `pendingChangeCountResult` could silently cause tests to take the wrong path. However, the subsequent addition of the `offlineSyncEnableResolution` feature flag (which defaults to `false`) has substantially mitigated this concern:

- Pre-existing tests never enter the resolution block because the feature flag is off.
- The `pendingChangeCountResult` default is irrelevant when the feature flag is off.
- The 7 dedicated resolution tests explicitly set the flag to `true` and configure `pendingChangeCountResults` appropriately.
- The `test_fetchSync_preSyncResolution_skipsWhenResolutionFlagDisabled` test explicitly verifies that `pendingChangeCountCalledWith.isEmpty` when the flag is off.

**Risk of not adding assertions:** Low. The feature flag provides a strong gate. The risk scenario requires someone to either (1) change the feature flag default to `true`, or (2) remove the feature flag check. Both would be intentional changes that should update tests accordingly.

**Priority:** Low. The concern is valid as a test hygiene observation but the practical risk has been reduced from Medium to Low by the feature flag.

## Options

### Option A: Add Negative Assertions to Pre-Existing Tests
- **Effort:** ~1-2 hours, ~24 lines (one assertion per test)
- **Description:** Add `XCTAssertTrue(pendingCipherChangeDataStore.pendingChangeCountCalledWith.isEmpty)` to each of the 24 pre-existing `fetchSync` tests as a safety assertion.
- **Test scenarios:**
  - Each pre-existing `test_fetchSync_*` gets a new assertion verifying no offline resolution interaction occurred.
- **Pros:** Makes the assumption explicit. Documents that these tests expect the resolution block to be skipped.
- **Cons:** 24 assertion additions is tedious. Low value per assertion. Adds noise to existing tests.

### Option B: Add a Single Guard Test (Recommended)
- **Effort:** ~15 minutes, ~20 lines
- **Description:** Add a single test that explicitly verifies the default behavior: when no feature flag is set, `fetchSync` does NOT interact with `pendingCipherChangeDataStore` or `offlineSyncResolver`. This is essentially what `test_fetchSync_preSyncResolution_skipsWhenResolutionFlagDisabled` already does.
- **Test scenarios:**
  - Verify existing `test_fetchSync_preSyncResolution_skipsWhenResolutionFlagDisabled` covers this case (it does -- line 1212).
- **Pros:** The test already exists. No new code needed.
- **Cons:** Does not add assertions to individual pre-existing tests.

### Option C: Accept As-Is
- **Rationale:** The feature flag gate makes the mock default irrelevant for pre-existing tests. The `test_fetchSync_preSyncResolution_skipsWhenResolutionFlagDisabled` test explicitly verifies the "flag off" path. The 7 dedicated resolution tests cover all resolution scenarios. Adding 24 negative assertions to pre-existing tests provides marginal value at significant tedium cost.

## Recommendation

**Option C (Accept As-Is).** The concern has been substantially addressed by the feature flag addition. The existing `test_fetchSync_preSyncResolution_skipsWhenResolutionFlagDisabled` test at `SyncServiceTests.swift:1212-1225` explicitly verifies that when the flag is disabled, no pending-count check or resolver call occurs. This is the definitive "guard" test for the pre-existing test behavior. Adding 24 individual negative assertions provides insufficient incremental value.

## Dependencies

- None. The feature flag gate is the mitigating factor.

## Consolidated Assessment

*From: ConsolidatedOutstandingIssues.md — Section 5: Open Issues — Accepted As-Is*

Mock defaults silently bypass abort logic: 24 of 25 `fetchSync` tests use default `pendingChangeCountResult = 0` with no assertions about offline resolution. `test_fetchSync_preSyncResolution_skipsWhenResolutionFlagDisabled` already covers the negative path; feature flag default `false` provides strong gate.

## Code Review References

Relevant review documents:
- `Review2/08_TestCoverage_Review.md`

## Comments
