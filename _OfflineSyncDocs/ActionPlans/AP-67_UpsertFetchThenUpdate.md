# AP-67: `upsertPendingChange` Uses Fetch-Then-Update Pattern Rather Than Atomic Upsert

> **Issue:** #67 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Medium
> **Status:** Triaged
> **Source:** ReviewSection_PendingCipherChangeDataStore.md (Observation PCDS-4)

## Problem Statement

The `upsertPendingChange` method in `DataStore+PendingCipherChangeDataStore` implements upsert semantics using a fetch-then-insert-or-update pattern within a single `performAndSave` block. This is a two-step operation (fetch existing record, then create or update) rather than a true atomic upsert.

While Core Data does not natively support SQL `INSERT ... ON CONFLICT UPDATE` semantics, alternative approaches exist (e.g., using `NSMergeByPropertyObjectTrumpMergePolicy` with a direct insert that leverages the uniqueness constraint). The current approach is safe given the serial queue execution model of `backgroundContext.performAndSave`, but it is theoretically susceptible to a race condition if two concurrent calls bypass the serial queue.

## Current Code

- `BitwardenShared/Core/Vault/Services/Stores/PendingCipherChangeDataStore.swift:91-123`
```swift
func upsertPendingChange(
    cipherId: String, userId: String, changeType: PendingCipherChangeType,
    cipherData: Data?, originalRevisionDate: Date?, offlinePasswordChangeCount: Int16
) async throws {
    try await backgroundContext.performAndSave {
        let request = PendingCipherChangeData.fetchByCipherIdRequest(userId: userId, cipherId: cipherId)
        let existing = try self.backgroundContext.fetch(request).first

        if let existing {
            // Update existing record, preserving originalRevisionDate from first offline edit
            existing.cipherData = cipherData
            existing.changeTypeRaw = changeType.rawValue
            existing.updatedDate = Date()
            existing.offlinePasswordChangeCount = offlinePasswordChangeCount
            // Do NOT overwrite originalRevisionDate - it's the baseline for conflict detection
        } else {
            // Create new pending change record
            _ = PendingCipherChangeData(
                context: self.backgroundContext,
                cipherId: cipherId,
                userId: userId,
                changeType: changeType,
                cipherData: cipherData,
                originalRevisionDate: originalRevisionDate,
                offlinePasswordChangeCount: offlinePasswordChangeCount
            )
        }
    }
}
```

## Assessment

**Still valid; correctly assessed as informational in the original review.** The fetch-then-update pattern is safe in the current codebase for several reasons:

1. **Serial queue execution.** All operations run on `backgroundContext.perform {}` / `performAndSave {}`, which confines them to the background context's serial dispatch queue. This prevents concurrent execution of two `upsertPendingChange` calls on the same context.

2. **Uniqueness constraint as safety net.** The `(userId, cipherId)` uniqueness constraint in the Core Data schema (defined in the `.xcdatamodel`) provides a database-level safety net. If a race condition somehow caused a duplicate insert, Core Data's merge policy (`NSMergeByPropertyObjectTrumpMergePolicy` on the `backgroundContext`, as set in `DataStore.swift:40`) would resolve it by keeping the newer values.

3. **Consistent with existing patterns.** Other `DataStore` extensions in the codebase use the same fetch-then-update pattern (see `DataStore+CipherData`, `DataStore+FolderData`, etc.). This is the established Core Data access pattern in this project.

4. **Business logic requires fetch.** The `originalRevisionDate` must be preserved from the first offline edit. A pure insert-with-merge-policy approach would overwrite all fields, including `originalRevisionDate`, which would break conflict detection. The explicit conditional update in the current code is necessary for correct business logic.

**Hidden risks:** None. The serial queue model and uniqueness constraint together provide adequate protection. The fetch-then-update pattern is the right choice given the need to conditionally preserve `originalRevisionDate`.

## Options

### Option A: Accept As-Is (Recommended)
- **Rationale:** The fetch-then-update pattern is correct, safe, and consistent with the rest of the codebase. The serial queue execution prevents race conditions, and the business logic (preserving `originalRevisionDate`) requires the conditional update. A true atomic upsert using `NSMergePolicy` alone would not support the conditional preservation of `originalRevisionDate`.

### Option B: Use `NSMergePolicy` with Conditional Logic
- **Effort:** Medium (~2-4 hours)
- **Description:** Always insert a new object and rely on `NSMergeByPropertyObjectTrumpMergePolicy` to resolve conflicts. Add a custom merge policy or post-save hook to preserve `originalRevisionDate`.
- **Pros:** Eliminates the fetch step
- **Cons:** Custom merge policies are complex and error-prone, the conditional preservation of `originalRevisionDate` is much harder to express, inconsistent with codebase patterns, and the serial queue already prevents the race condition

### Option C: Add Explicit Lock for Extra Safety
- **Effort:** Low (~30 minutes)
- **Description:** Wrap the `performAndSave` block in an additional `NSLock` or use `actor` isolation to provide a second layer of serialization.
- **Pros:** Defense-in-depth against potential future misuse
- **Cons:** Redundant given the serial queue, adds complexity, not consistent with existing patterns

## Recommendation

**Option A: Accept As-Is.** The fetch-then-update pattern is the correct approach for this use case. It is required by the business logic (conditional `originalRevisionDate` preservation), protected by the serial queue execution model, backed by a uniqueness constraint safety net, and consistent with all other `DataStore` extensions in the codebase.

## Dependencies

- Related to Issue #49 (R2-PCDS-4): The race condition concern. **[R2-PCDS-4 Resolved]** — Hypothetical; prevented by serial backgroundContext, uniqueness constraint, and merge policy.
