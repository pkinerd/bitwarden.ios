# AP-63: Batch Processing Is Sequential

> **Issue:** #63 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Triaged
> **Source:** Review2/02_OfflineSyncResolver_Review.md

## Problem Statement

The `DefaultOfflineSyncResolver.processPendingChanges(userId:)` method processes all pending changes sequentially in a `for` loop. Each pending change is resolved one at a time — fetching server state, performing conflict resolution, and cleaning up — before moving to the next. If a user has accumulated many pending changes during an extended offline period, this sequential processing could be slow.

## Current Code

- `BitwardenShared/Core/Vault/Services/OfflineSyncResolver.swift:100-113`
```swift
func processPendingChanges(userId: String) async throws {
    let pendingChanges = try await pendingCipherChangeDataStore.fetchPendingChanges(userId: userId)
    guard !pendingChanges.isEmpty else { return }

    for pendingChange in pendingChanges {
        do {
            try await resolve(pendingChange: pendingChange, userId: userId)
        } catch {
            Logger.application.error(
                "Failed to resolve pending change for cipher \(pendingChange.cipherId ?? "nil"): \(error)"
            )
        }
    }
}
```

## Assessment

**Still valid; accepted as an intentional simplicity tradeoff.** The sequential processing is a deliberate design choice documented in the review. The rationale is strong:

1. **Avoids complex concurrent conflict resolution.** Parallel processing would require careful coordination to prevent race conditions when multiple pending changes interact with the same server state or Core Data store.
2. **Maintains actor isolation guarantees.** The `DefaultOfflineSyncResolver` is an `actor`, which serializes method calls. Attempting concurrent resolution within a single `processPendingChanges` call would fight the actor model.
3. **Error isolation is cleaner.** Sequential processing with catch-and-continue means a failure in one change doesn't affect others, and the order of operations is deterministic.
4. **Practical impact is minimal.** The Core Data `(userId, cipherId)` uniqueness constraint means there is at most one pending change per cipher per user. Even if a user edits 100 different ciphers offline, each resolution involves 1-2 API calls (GET + PUT), so the total time is roughly `100 * (2 * network_latency)`. At typical mobile latencies (200-500ms per call), this is 40-100 seconds — noticeable but acceptable for a recovery operation.

**Hidden risks:** None. The sequential approach is the safest option for conflict resolution. Concurrent resolution could introduce subtle ordering bugs (e.g., two updates to related ciphers where the second depends on the first succeeding).

## Options

### Option A: Accept As-Is (Recommended)
- **Rationale:** Sequential processing is the correct design choice for conflict resolution. The simplicity benefits outweigh the theoretical performance cost. Users with many pending changes will experience a longer resolution period, but this is an infrequent edge case (extended offline period with many distinct cipher edits). The user can also trigger resolution manually via pull-to-refresh.

### Option B: Add Concurrency with TaskGroup
- **Effort:** Medium (~2-4 hours)
- **Description:** Use `withThrowingTaskGroup` to process pending changes concurrently, with a concurrency limit (e.g., 3-5 concurrent resolutions).
- **Pros:** Faster resolution for users with many pending changes
- **Cons:** Significantly more complex, potential for race conditions with Core Data writes, conflicts between concurrent API calls for related ciphers, harder to reason about error handling, fights the actor model

### Option C: Add Progress Reporting
- **Effort:** Low-Medium (~1-2 hours)
- **Description:** Keep sequential processing but add progress reporting so the UI can show "Resolving offline changes (3/10)..." during sync.
- **Pros:** Better user experience during long resolution, no concurrency complexity
- **Cons:** Requires UI changes, depends on Issue U3 (pending changes indicator)

## Recommendation

**Option A: Accept As-Is.** Sequential processing is the right design for conflict resolution. It is simple, correct, and avoids the significant complexity of concurrent conflict resolution. The performance cost is acceptable for the expected usage patterns.

## Dependencies

- Related to Issue U3 (pending changes indicator): If sequential processing takes noticeably long, a UI indicator would improve the user experience.
- Related to Issue R3 (retry backoff): Sequential processing means that a permanently failing item blocks subsequent items only within a single batch; the next batch will re-process all remaining items.
