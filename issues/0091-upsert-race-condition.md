---
id: 91
title: "[R2-PCDS-4] Upsert race condition — fetch-then-insert/update not atomic"
status: closed
created: 2026-02-21
author: claude
labels: [bug]
priority: low
closed: 2026-02-21
---

## Description

**Resolution:** Prevented by serial backgroundContext, uniqueness constraint, and merge policy. AP-R2-PCDS-4 (Resolved)

**Disposition:** Resolved / Superseded

## Action Plan

*Source: `ActionPlans/Resolved/AP-R2-PCDS-4_UpsertRaceCondition.md`*

> **Issue:** #49 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Resolved (Hypothetical — prevented by serial context and uniqueness constraint)
> **Source:** Review2/01_PendingCipherChangeData_Review.md (Reliability Concerns section)

## Problem Statement

The `upsertPendingChange` method in `PendingCipherChangeDataStore` performs a fetch-then-insert/update pattern that is not atomic at the database level. The method first fetches an existing record matching `(userId, cipherId)`, then either updates it or creates a new one. If two concurrent calls attempt to upsert for the same `(userId, cipherId)` pair, both could complete the fetch step before either creates the record, leading to two insert attempts for the same key.

The `(userId, cipherId)` uniqueness constraint on `PendingCipherChangeData` provides a safety net -- Core Data will prevent duplicate inserts at the constraint level. The `NSMergeByPropertyObjectTrumpMergePolicy` configured on the background context (at `DataStore.swift:40`) handles constraint violations by updating the existing record with the new values, effectively turning a duplicate insert into an update.

## Current Code

**`upsertPendingChange` at PendingCipherChangeDataStore.swift:91-123:**
```swift
func upsertPendingChange(
    cipherId: String,
    userId: String,
    changeType: PendingCipherChangeType,
    cipherData: Data?,
    originalRevisionDate: Date?,
    offlinePasswordChangeCount: Int16
) async throws {
    try await backgroundContext.performAndSave {
        let request = PendingCipherChangeData.fetchByCipherIdRequest(userId: userId, cipherId: cipherId)
        let existing = try self.backgroundContext.fetch(request).first  // Step 1: Fetch

        if let existing {
            // Update existing record
            existing.cipherData = cipherData
            existing.changeTypeRaw = changeType.rawValue
            existing.updatedDate = Date()
            existing.offlinePasswordChangeCount = offlinePasswordChangeCount
            // Do NOT overwrite originalRevisionDate
        } else {
            // Create new pending change record
            _ = PendingCipherChangeData(                              // Step 2: Insert
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

**`performAndSave` at NSManagedObjectContext+Extensions.swift:62-67:**
```swift
func performAndSave(closure: @escaping () throws -> Void) async throws {
    try await perform {
        try closure()
        try self.saveIfChanged()
    }
}
```

**Background context merge policy at DataStore.swift:39-41:**
```swift
private(set) lazy var backgroundContext: NSManagedObjectContext = {
    let context = persistentContainer.newBackgroundContext()
    context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    return context
}()
```

**Uniqueness constraint in schema (Bitwarden.xcdatamodel/contents, lines 55-59):**
```xml
<uniquenessConstraints>
    <uniquenessConstraint>
        <constraint value="userId"/>
        <constraint value="cipherId"/>
    </uniquenessConstraint>
</uniquenessConstraints>
```

## Assessment

**Validity:** This issue is technically valid -- the fetch-then-insert is not a single atomic database operation. However, multiple layers of mitigation make this a non-issue in practice:

1. **Single background context serialization.** The `DataStore` creates a single `backgroundContext` (lazy property at line 38). All `performAndSave` calls use this same context. The `NSManagedObjectContext.perform` method serializes work on the context's private queue -- operations submitted to the same context run sequentially, not concurrently. This means two `upsertPendingChange` calls on the same `DataStore` instance will execute one after the other, preventing the race entirely.

2. **Singleton DataStore in DI.** The `DataStore` is created once in `ServiceContainer` and injected everywhere via dependency injection. There is only one `DataStore` instance in the app, which means only one `backgroundContext`, which means all upserts are serialized.

3. **Uniqueness constraint as safety net.** Even if two contexts existed (which they don't in practice), the `(userId, cipherId)` uniqueness constraint would prevent duplicate inserts. Combined with `NSMergeByPropertyObjectTrumpMergePolicy`, a constraint violation would be resolved by keeping the latest values -- effectively an upsert at the Core Data level.

4. **Calling code serialization.** The callers (`handleOfflineAdd`, `handleOfflineUpdate`, etc. in `VaultRepository`) are triggered by explicit user actions (tap "save," tap "delete"). These are inherently serialized -- the user cannot perform two cipher operations simultaneously from the UI.

**Blast radius:** If the race condition did occur (effectively impossible given the serialization above):
- Core Data would see a uniqueness constraint violation on the second insert
- `NSMergeByPropertyObjectTrumpMergePolicy` would resolve it by keeping the latest property values
- The end result would be a single pending change record with the most recent data
- No data loss, no crash, no corruption

**Likelihood:** Effectively zero. The single background context serializes all operations.

## Options

### Option A: Use NSBatchInsertRequest with Upsert Behavior
- **Effort:** Medium (3-4 hours)
- **Description:** Replace the fetch-then-insert/update with an `NSBatchInsertRequest` that handles upserts natively. Core Data's batch insert respects uniqueness constraints and can perform upserts in a single database operation.
- **Pros:** Truly atomic at the database level; eliminates the theoretical race condition; potentially more efficient for bulk operations
- **Cons:** `NSBatchInsertRequest` bypasses the managed object context, which means change notifications and in-memory state need manual handling; more complex code; overkill for single-record operations; the current pattern is used throughout the codebase for other entities

### Option B: Add Explicit Locking
- **Effort:** Small (1-2 hours)
- **Description:** Add an `NSLock` or `actor` wrapper around the upsert method to explicitly prevent concurrent access.
- **Pros:** Makes the serialization explicit in code
- **Cons:** Redundant -- `performAndSave` already serializes on the context's queue; adds unnecessary complexity; could introduce deadlocks if not carefully implemented

### Option C: Accept As-Is
- **Rationale:** The race condition is already prevented by three independent mechanisms: (1) the single background context serializes all `performAndSave` calls, (2) the uniqueness constraint prevents duplicate inserts at the database level, (3) `NSMergeByPropertyObjectTrumpMergePolicy` gracefully resolves constraint violations. The same fetch-then-update pattern is used by every other data store in the project (`CipherDataStore`, `FolderDataStore`, `CollectionDataStore`, `SendDataStore`) and has operated without issues. Adding explicit locking or switching to batch inserts would diverge from the established pattern without addressing a real problem.

## Recommendation

**Option C: Accept As-Is.** The race condition is mitigated by three independent layers of protection (context serialization, uniqueness constraint, merge policy). The pattern is consistent with all other data stores in the project. The theoretical race requires conditions that cannot occur in the app's architecture (multiple DataStore instances or concurrent user operations on the same cipher).

## Resolution

**Resolved as hypothetical (2026-02-20).** The action plan's own assessment confirms: "The race condition is already prevented by three independent mechanisms." (1) The single `backgroundContext` serializes all `performAndSave` calls. (2) The `(userId, cipherId)` uniqueness constraint prevents duplicate inserts at the database level. (3) `NSMergeByPropertyObjectTrumpMergePolicy` gracefully resolves any constraint violations. The same fetch-then-update pattern is used by every other data store in the project without issues. The theoretical race requires conditions (multiple DataStore instances or concurrent user operations) that cannot occur in the app's architecture. This is the same class of impossibility as P2-T2.

## Dependencies

- No dependencies on other issues. This is a self-contained data store concern.
- The `NSMergeByPropertyObjectTrumpMergePolicy` at `DataStore.swift:40` is a critical part of the mitigation and should not be changed without considering its impact on the upsert behavior.

## Resolution Details

Hypothetical — prevented by serial backgroundContext, uniqueness constraint, and merge policy; same pattern used by all data stores.

## Comments
