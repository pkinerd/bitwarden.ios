---
id: 3
title: "[R3] No retry backoff for permanently failing resolution items"
status: open
created: 2026-02-21
author: claude
labels: [bug]
priority: high
---

## Description

A single permanently failing pending change blocks ALL syncing indefinitely via the early-abort pattern in `SyncService.swift:348-352`. No retry count, backoff, or expiry mechanism exists.

**Severity:** High
**Complexity:** Medium
**Est. Effort:** ~30-50 lines, 2-3 files, Core Data schema change

**Recommendation:** Option D (`.failed` state) + Option A (retry count after 10 failures). Requires re-adding `timeProvider` dependency (removed in A3).

**Related Documents:** AP-R3, AP-00, OfflineSyncCodeReview.md, OfflineSyncChangelog.md, ReviewSection_SyncService.md, Review2/00_Main, Review2/02_OfflineSyncResolver

**Priority:** Most impactful remaining reliability issue.

## Action Plan

*Source: `ActionPlans/AP-R3_RetryBackoff.md`*

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | R3 / SS-5 |
| **Component** | `OfflineSyncResolver` / `SyncService` |
| **Severity** | Low |
| **Type** | Reliability |
| **Files** | `OfflineSyncResolver.swift`, `PendingCipherChangeData.swift` |

## Description

Failed resolution items are retried on every subsequent sync attempt with no backoff or maximum retry limit. If a specific cipher consistently fails to resolve (e.g., server returns 404 because it was deleted via another device, or a persistent server error), the resolver will attempt it on every sync indefinitely. This results in wasted API calls and, due to the early-abort pattern, can permanently block syncing.

## Context

The early-abort pattern in `SyncService.swift` (lines 334-343) means that if any pending changes remain after resolution, the sync is aborted entirely (`return` at line 340). A permanently failing item therefore permanently blocks sync for that user. While the per-item catch-and-continue in `OfflineSyncResolver.swift:113-117` allows other items to resolve, the remaining count check (`pendingChangeCount(userId:)`) will always find at least one remaining item.

This is the most impactful consequence: **a single permanently failing pending change blocks ALL syncing.** Given that sync is critical for the user's vault being current across devices, this is a significant reliability concern.

**Codebase pattern for time-based logic:** The project uses `TimeProvider` for injectable time (see `MockTimeProvider` in tests). If time-based expiry is implemented, using `timeProvider.presentTime` rather than `Date()` ensures testability. Note: `timeProvider` has been removed from the resolver (A3 implemented — YAGNI), so it would need to be re-added with a clear purpose if time-based expiry is implemented.

---

## Options

### Option A: Add Retry Count with Maximum

Add a `retryCount: Int16` attribute to `PendingCipherChangeData` that increments on each failed resolution attempt. After reaching a maximum (e.g., 10 retries), the pending change is either deleted or moved to a "failed" state.

**Approach:**
1. Add `retryCount` attribute to Core Data entity (default: 0)
2. In `OfflineSyncResolver`, in the catch block, increment `retryCount` via the data store
3. Before resolving each item, check if `retryCount >= maxRetries`
4. If exceeded: delete the pending record and log a warning

**Pros:**
- Prevents permanently stuck items from blocking sync
- Simple counter-based approach
- Configurable maximum

**Cons:**
- User's offline changes are silently deleted after max retries
- Requires Core Data schema change
- Need to choose an appropriate max (too low = premature deletion; too high = prolonged blocking)
- Does not distinguish between transient failures (retry is useful) and permanent failures (retry is futile)

### Option B: Add Expiry/TTL Based on Age (Recommended)

Delete pending changes older than a configurable threshold (e.g., 7 or 30 days) under the assumption that very old pending changes are stale.

**Approach:**
1. In `OfflineSyncResolver.processPendingChanges`, check each item's `createdDate`
2. If `Date().timeIntervalSince(createdDate) > maxAge`, delete and log
3. No schema change needed — uses existing `createdDate`

**Pros:**
- No schema change required
- Simple age-based cleanup
- Handles both permanently failing items and forgotten offline changes
- Does not require tracking retry attempts

**Cons:**
- User's offline changes are deleted based on age, not failure count
- A user who is offline for longer than the threshold loses their changes
- The threshold choice is difficult (7 days is aggressive; 30 days is lenient)
- Does not prevent repeated API calls during the TTL period

### Option C: Exponential Backoff with Next-Retry Timestamp

Add a `nextRetryDate: Date?` attribute to `PendingCipherChangeData`. On failure, set `nextRetryDate` to an exponentially increasing future time. Skip items whose `nextRetryDate` is in the future.

**Approach:**
1. Add `nextRetryDate` and `retryCount` to Core Data entity
2. On failure: `retryCount += 1; nextRetryDate = Date() + min(2^retryCount * 60, maxBackoff)`
3. In processing loop: `if nextRetryDate > Date() { continue }` (skip this item)
4. After max retries or max age, delete the item

**Pros:**
- Reduces API call frequency for failing items
- Still allows eventual resolution (items are retried, just less frequently)
- Combines well with a maximum retry count
- Most sophisticated and correct approach

**Cons:**
- Core Data schema change (2 new attributes)
- More complex implementation
- Items in backoff still contribute to the pending count, potentially blocking sync
- Need to handle the backoff items differently in the count check (don't count backed-off items as "remaining" for the early-abort decision)

### Option D: Move Failed Items to a Separate "Failed" State

Add a `PendingCipherChangeType.failed` state that marks items as no longer eligible for resolution. These items are excluded from the pending count check in SyncService.

**Approach:**
1. Add `.failed` case to `PendingCipherChangeType`
2. After N failures, set the change type to `.failed`
3. In `SyncService`, only count non-failed items for the early-abort check
4. Add a mechanism to surface failed items to the user (notification or UI)

**Pros:**
- Failed items don't block sync
- User's data is preserved (not deleted)
- Failed items can be surfaced in the UI for manual resolution
- Clean separation of state

**Cons:**
- New state to manage
- UI work needed to surface failed items (ties into U3 — pending changes indicator)
- Adds complexity to the data model
- Need to define what "manual resolution" means for the user

### Option E: Accept Current Behavior (No Change)

Accept the risk of permanently failing items and address specific cases as they arise in production.

**Pros:**
- No code change
- Simpler implementation
- The feature flags (S8 — now resolved: `.offlineSyncEnableResolution`, `.offlineSyncEnableOfflineChanges`) can be used as a kill switch if issues arise

**Cons:**
- A single permanently failing item blocks all syncing
- No automated recovery
- Production debugging is difficult without retry metadata

---

## Recommendation

**Option B** (TTL-based expiry) as the minimum viable approach, combined with **Option A** (retry count) for a more robust solution. The priority is preventing permanently blocked sync. A reasonable default would be: delete pending changes after 10 failed retries OR after 30 days, whichever comes first.

If implementing a full retry backoff (Option C) is feasible, it is the technically superior approach but adds more complexity.

## Estimated Impact

- **Files changed:** 2-3 (Core Data model, `PendingCipherChangeData.swift`, `OfflineSyncResolver.swift`)
- **Lines added:** ~30-50
- **Risk:** Low-Medium — Core Data schema change + logic change in resolver

## Related Issues

- **R1 (PCDS-3)**: Data format versioning — both involve pending changes becoming unresolvable. If format versioning is implemented (version mismatch → delete), it provides a partial solution.
- **A3 (RES-5)**: Unused timeProvider — if retry backoff uses time-based expiry, `timeProvider` could be repurposed instead of removed.
- **R4 (SS-3)**: Silent sync abort — if items are expired/deleted, logging becomes even more important.
- **S8**: Feature flag — **[Resolved]** the two feature flags (`.offlineSyncEnableResolution`, `.offlineSyncEnableOfflineChanges`) provide a complementary production safety mechanism. Both default to `false` (server-controlled rollout).
- **SS-4**: Pre-sync resolution on every sync — retry backoff directly addresses the efficiency concern of retrying failed items on every sync.

## Updated Review Findings

The review confirms this is the most impactful reliability issue. After reviewing the implementation:

1. **Code verification**: `SyncService.swift:335-341` shows the critical flow:
   ```
   let pendingCount = try await pendingCipherChangeDataStore.pendingChangeCount(userId: userId)
   if pendingCount > 0 {
       try await offlineSyncResolver.processPendingChanges(userId: userId)
       let remainingCount = try await pendingCipherChangeDataStore.pendingChangeCount(userId: userId)
       if remainingCount > 0 {
           return  // <-- SYNC ABORTED
       }
   }
   ```
   A single permanently failing item causes `remainingCount > 0` on every sync, permanently blocking `replaceCiphers` and all server-to-local updates.

2. **Error handling verification**: `OfflineSyncResolver.swift:113-117` shows the per-item catch. When resolution fails, the error is logged but the pending record survives. On every subsequent sync trigger (periodic ~30min, foreground, pull-to-refresh), the same failing item is retried with the same result.

3. **Failure scenarios that cause permanent blocking**:
   - Server returns 404 for a deleted cipher (permanent failure)
   - `cipherData` decode fails due to format mismatch (permanent failure per R1)
   - Server-side permission change prevents update (permanent failure)
   - Cipher exceeds server-side size limits (permanent failure)

4. **timeProvider status**: The `timeProvider` has been removed from the resolver (A3 implemented). If R3 TTL is implemented, `timeProvider` would need to be re-added with a clear purpose (time-based expiry checking). This is the correct sequence per YAGNI.

5. **Recommendation refinement**: After code review, the combined approach (Option A + B) is confirmed as the best balance. Specifically:
   - Add `retryCount: Int16` (default 0) to Core Data entity
   - In resolver catch block: increment retryCount, save
   - Before resolving: check `retryCount >= 10` OR `createdDate` older than 30 days → delete and log warning
   - The "skip but don't count as remaining" approach is better than deletion: mark items as `.failed` state per Option D, so they don't block sync but data is preserved

6. **Updated recommendation**: **Option D (failed state)** combined with **Option A (retry count)** is the best approach. Add a `.failed` case to `PendingCipherChangeType` (value 3). After 10 failures, mark as `.failed`. In SyncService, only count non-failed items for the early-abort check. Failed items are preserved for manual resolution or future automated recovery. This avoids silently deleting user data.

**Updated conclusion**: This is the most impactful reliability improvement. A permanently failing item blocks ALL syncing for the user. Recommend Option D (failed state) + Option A (retry count). Priority should be elevated to Medium. The feature flags (S8 — now resolved: `.offlineSyncEnableResolution`, `.offlineSyncEnableOfflineChanges`) provide complementary production safety but require manual server-side intervention; retry backoff is automated client-side recovery.

## Consolidated Assessment

*From: ConsolidatedOutstandingIssues.md — Section 1: Open Issues Requiring Code Changes*

A single permanently failing pending change blocks ALL syncing indefinitely via the early-abort pattern in `SyncService.swift:348-352`. No retry count, backoff, or expiry mechanism exists. **Recommended:** Option D (`.failed` state) + Option A (retry count after 10 failures). Requires re-adding `timeProvider` dependency (removed in A3). Bundle Core Data schema change with R1.

## Code Review References

Relevant review documents:
- `ReviewSection_SyncService.md`
- `ReviewSection_OfflineSyncResolver.md`

## Comments

### claude — 2026-02-22

**Codebase validated — issue confirmed OPEN.**

1. SyncService.swift:344-352 still has the early-abort pattern: `pendingChangeCount > 0` after resolution → `return` (sync aborted)
2. PendingCipherChangeData has NO `retryCount`, `nextRetryDate`, or failed state attributes
3. OfflineSyncResolver `processPendingChanges` catches errors silently (log only, no backoff/TTL)
4. PendingCipherChangeType enum has only: `update`, `create`, `softDelete`, `hardDelete` — no `.failed` case

A single permanently failing pending change still blocks ALL syncing indefinitely.
