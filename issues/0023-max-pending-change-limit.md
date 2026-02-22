---
id: 23
title: "[R2-MAIN-7] Max pending change limit — unbounded accumulation risk very low"
status: closed
created: 2026-02-21
author: claude
labels: [enhancement]
priority: low
closed: 2026-02-21
---

## Description

No maximum pending change limit. Unbounded accumulation risk is very low (~1-5 KB per item) — accepted as-is.

**Disposition:** Accepted
**Action Plan:** AP-R2-MAIN-7 (Accepted)

**Related Documents:** Review2

## Action Plan

*Source: `ActionPlans/Accepted/AP-R2-MAIN-7_MaxPendingChangeLimit.md`*

> **Issue:** #43 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Triaged
> **Source:** Review2/00_Main_Review.md (Reliability & Error Handling table, line 281)

## Problem Statement

The offline sync system places no upper bound on the number of pending change records that can accumulate in Core Data, nor any maximum age for those records. During extended offline periods (days or weeks), a user could theoretically accumulate hundreds of pending changes. When connectivity returns, the `OfflineSyncResolver.processPendingChanges()` method processes all of them sequentially in a single `for` loop, which could be slow and potentially cause timeouts or resource pressure.

Additionally, very old pending changes may have a higher chance of conflict (since the server-side data has likely changed), increasing the number of backup ciphers created during resolution. There is no mechanism to warn the user about stale pending changes or to prioritize recent changes over old ones.

## Current Code

The pending changes are fetched and processed sequentially with no limits:

- `PendingCipherChangeDataStore.fetchPendingChanges(userId:)` at `PendingCipherChangeDataStore.swift:76-82` fetches ALL pending changes for a user, sorted by `createdDate` ascending, with no fetch limit.
- `OfflineSyncResolver.processPendingChanges(userId:)` at `OfflineSyncResolver.swift:100-113` iterates over all fetched changes in a `for` loop with no batching or count limit.
- `PendingCipherChangeData` has `createdDate` and `updatedDate` fields (`PendingCipherChangeData.swift:49-52`) but these are never checked for staleness.
- The `SyncService.fetchSync()` method at `SyncService.swift:343-350` counts pending changes and processes them, but does not impose any limit.

There is no code anywhere that checks the age or count of pending changes before processing, and no cleanup mechanism for stale records.

## Assessment

**Validity:** This issue is valid but represents a very low practical risk. The scenario requires:
1. A user who is offline for an extended period (days/weeks)
2. Who makes many offline cipher operations during that period
3. And has enough pending changes to cause performance issues during resolution

In practice, most users would have at most a handful of pending changes. The Core Data store can handle thousands of records without issues, and sequential processing of even dozens of changes would complete in seconds.

**Blast radius:** If accumulation did become problematic:
- Resolution could take noticeably long (seconds to minutes for hundreds of changes)
- Each resolved change may create a backup cipher, potentially cluttering the user's vault
- The sync service would be blocked until all changes are processed (line 347: `if remainingCount > 0 { return }`)
- No user data would be lost -- the design preserves all changes

**Likelihood:** Very low. Users typically make a few edits per session. Even a week offline would unlikely produce more than 20-30 pending changes.

## Options

### Option A: Add a Maximum Count Warning (Recommended)
- **Effort:** Small (1-2 hours)
- **Description:** Add a configurable maximum count constant. When the count exceeds the threshold, log a warning via `Logger.application.warning()` before processing. The processing still proceeds but the warning provides observability. Optionally, process in batches (e.g., 50 at a time) to limit per-sync-cycle work.
- **Pros:** Minimal code change; provides observability without behavioral change; batching prevents long-running sync cycles
- **Cons:** Does not actually prevent accumulation; warning alone doesn't solve the theoretical issue
- **Implementation:**
  ```swift
  // In OfflineSyncResolver.processPendingChanges()
  static let maxBatchSize = 50

  let pendingChanges = try await pendingCipherChangeDataStore.fetchPendingChanges(userId: userId)
  if pendingChanges.count > Self.maxBatchSize {
      Logger.application.warning(
          "Large number of pending changes (\(pendingChanges.count)) detected for user"
      )
  }
  // Process up to maxBatchSize per sync cycle
  let batch = Array(pendingChanges.prefix(Self.maxBatchSize))
  ```

### Option B: Add Age-Based Staleness Handling
- **Effort:** Medium (3-5 hours)
- **Description:** Add a maximum age constant (e.g., 30 days). When processing, flag changes older than this threshold with a warning log. Optionally, auto-expire very old changes (e.g., 90+ days) by deleting the pending change record (the local cipher data remains in Core Data, just the pending sync record is removed).
- **Pros:** Prevents unbounded growth over very long periods; addresses the staleness concern
- **Cons:** Auto-expiring changes risks losing the user's intent to sync; choosing the right age threshold is arbitrary; more complex logic
- **Risk:** If changes are auto-expired, the user's offline edits remain locally but are never pushed to the server. This could lead to data divergence.

### Option C: Accept As-Is
- **Rationale:** The practical risk is very low. Users making enough offline edits to cause performance issues is an extreme edge case. The system already handles the scenario correctly (all changes are processed, data is preserved). The sequential processing is actually simpler and more predictable than batched approaches. Core Data can handle thousands of records efficiently. The `createdDate` ascending sort order in `fetchPendingChanges` already ensures oldest changes are resolved first, which is the correct priority. Adding limits introduces new edge cases (what happens to changes beyond the limit?) that may be worse than the theoretical performance concern.

## Recommendation

**Option C: Accept As-Is**, with the caveat that **Option A's logging enhancement** (just the warning log, not the batching) is a sensible low-effort addition for observability. The practical risk does not justify adding count limits or age-based expiration. The system correctly preserves all user data regardless of accumulation volume. If performance becomes a real issue in production (observable through the feature flags and server telemetry), batching can be added incrementally.

If any action is taken, it should be limited to adding a log warning when pending change count exceeds a threshold (e.g., 50), providing telemetry without changing behavior.

## Dependencies

- **AP-R3_RetryBackoff.md** (Issue R3): Retry backoff would reduce the frequency of failed resolution attempts, indirectly reducing the "processing storm" risk on reconnect.
- **AP-R4_SilentSyncAbort.md** (Issue R4): User visibility into pending changes would help users understand why sync appears stuck during extended offline periods.
- **AP-S8_FeatureFlag.md** (Issue S8): The server-controlled feature flags provide a kill switch if unbounded accumulation causes issues in production.

## Comments
