# AP-40: ViewItemProcessor Fallback Fetch -- No Re-Subscription Test

> **Issue:** #40 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Medium
> **Status:** Triaged
> **Source:** OfflineSyncCodeReview_Phase2.md (P2-T4)

## Problem Statement

When `ViewItemProcessor.streamCipherDetails()` at `ViewItemProcessor.swift:600-612` fails (the publisher stream throws an error), the processor falls back to `fetchCipherDetailsDirectly()` at `ViewItemProcessor.swift:619-632`. This fallback performs a one-shot fetch from the vault repository, displaying the cipher data. However, it does NOT re-establish the stream subscription.

This means that after the fallback executes:
- The cipher details are displayed correctly (one-time snapshot).
- Any subsequent changes to the cipher (e.g., sync resolves the offline cipher, user edits on another device, etc.) will NOT be reflected in the UI until the user navigates away and back.

There is no test verifying this "stale state" behavior -- that after fallback, the cipher details do NOT update when the underlying data changes.

## Current Test Coverage

- **`test_perform_appeared_errors_fallbackFetchSuccess`** at `ViewItemProcessorTests.swift:254-285`: Verifies that after the stream fails, the fallback fetch populates the state with cipher data. This is the happy-path fallback test.
- **`test_perform_appeared_errors_fallbackFetchFailure`** at `ViewItemProcessorTests.swift:290-305`: Verifies error state when fallback returns nil.
- **`test_perform_appeared_errors_fallbackFetchThrows`** at `ViewItemProcessorTests.swift:310-327`: Verifies error state and double error logging when fallback also throws.
- **`test_perform_appeared_errors`** at `ViewItemProcessorTests.swift:234-249`: Pre-existing test for stream failure (before fallback was added). Tests the behavior when `fetchCipherResult` is not configured (defaults to throwing), resulting in error state.

All four tests verify the immediate result of the fallback. None test what happens AFTER the fallback completes.

## Missing Coverage

1. After fallback fetch succeeds, subsequent cipher changes via `cipherDetailsPublisher` are NOT reflected in the state.
2. The `streamCipherDetailsTask` is not restarted after fallback.
3. No test verifies that navigating away and back re-establishes the stream.

## Assessment

**Still valid:** Yes. No test verifies the "stale state after fallback" behavior.

**Risk of not having the test:** Low.
- The fallback is a degraded-mode behavior. It is by design a one-shot fetch, not a stream.
- The review documents in `OfflineSyncCodeReview_Phase2.md` (Section 3.1) explicitly acknowledge: "fetchCipherDetailsDirectly is not a subscription... If the cipher changes later (e.g., sync resolves it), the UI won't update until the user navigates away and back. This is acceptable as a degraded-mode behavior."
- The root cause (offline-created cipher failing the publisher stream) has been fixed by `CipherView.withId()`. The fallback is defense-in-depth.
- Testing "no update happens" is inherently a negative test (asserting nothing changes after a timeout), which is harder to write reliably and can produce flaky tests.

**Priority:** Low. The behavior is documented, by design, and the root cause is fixed. A test for this would primarily serve as documentation of the accepted limitation.

## Options

### Option A: Add Stale-State-After-Fallback Test
- **Effort:** ~1-2 hours
- **Description:** Add a test that:
  1. Triggers a stream failure causing the fallback to execute.
  2. Verifies the state is populated from the fallback.
  3. Sends a new cipher value through the publisher subject.
  4. Asserts that the state does NOT change (the update is not received).
- **Test scenarios:**
  - `test_perform_appeared_errors_fallbackFetch_doesNotReSubscribe` -- after fallback succeeds, subsequent publisher events do not update state
- **Pros:** Documents the limitation. Would catch any future change that accidentally re-establishes the stream.
- **Cons:** Negative tests (asserting nothing changes) require timeouts and can be flaky. The behavior is by design and documented. Medium effort.

### Option B: Add Re-Navigation Test
- **Effort:** ~1-2 hours
- **Description:** Add a test that verifies navigating away and back (re-calling `perform(.appeared)`) re-establishes the stream after a fallback.
- **Test scenarios:**
  - `test_perform_appeared_afterFallback_reEstablishesStream` -- cancel the task, re-invoke `perform(.appeared)`, verify the stream is active
- **Pros:** Verifies the recovery path.
- **Cons:** Tests the general `.appeared` behavior rather than a specific offline sync concern.

### Option C: Accept As-Is
- **Rationale:** The stale-state behavior is by design and documented in `OfflineSyncCodeReview_Phase2.md`. The root cause (cipher decryption failure in publisher) has been fixed. The fallback is defense-in-depth. Negative tests for "no update" are flaky. The user experience impact is minimal (the cipher details shown are correct; only live updates are missed until re-navigation).

## Recommendation

**Option C (Accept As-Is).** The behavior is intentionally designed as a one-shot fallback and is explicitly documented as acceptable degraded-mode behavior. Adding a negative test would be fragile and would test a documented design decision rather than a bug. If the team decides to implement live-update recovery after fallback in the future (see Issue R2-UI-1 / #53), that would be the appropriate time to add tests.

## Dependencies

- **R2-UI-1 (#53):** Deferred UX improvement to add live updates after fallback. If implemented, this test gap would need to be revisited.
- **VI-1:** Root cause fix. The fallback is defense-in-depth.
