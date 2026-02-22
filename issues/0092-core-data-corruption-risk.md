---
id: 92
title: "[R2-PCDS-5] Core Data corruption risk — pending changes lost"
status: closed
created: 2026-02-21
author: claude
labels: [bug]
priority: low
closed: 2026-02-21
---

## Description

**Resolution:** Inherent platform limitation; not specific to offline sync. AP-R2-PCDS-5 (Resolved)

**Disposition:** Resolved / Superseded

## Action Plan

*Source: `ActionPlans/Resolved/AP-R2-PCDS-5_CoreDataCorruptionRisk.md`*

> **Issue:** #50 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** High
> **Status:** Resolved (Inherent platform limitation — not an offline sync defect)
> **Source:** Review2/01_PendingCipherChangeData_Review.md (Data Safety section)

## Problem Statement

If the Core Data persistent store (`Bitwarden.sqlite`) becomes corrupted, all pending cipher change records would be lost along with the rest of the locally cached vault data. This is inherent to Core Data -- there is no built-in redundancy for the SQLite file that backs the persistent store.

For the offline sync feature specifically, this means:
1. Any pending changes that have not yet been resolved against the server would be permanently lost
2. The user's local cipher edits (stored in `CipherData`) would also be lost
3. On next launch, the app would either fail to load the store or load an empty store
4. The next sync would pull fresh data from the server, but any offline-only edits would be gone

This risk is shared with ALL data in the Core Data store -- it is not specific to the offline sync feature. The existing vault data (`CipherData`, `FolderData`, `CollectionData`, etc.) faces the same corruption risk.

## Current Code

**Persistent store location at DataStore.swift:70-73:**
```swift
case .persisted:
    let storeURL = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: Bundle.main.groupIdentifier)!
        .appendingPathComponent("Bitwarden.sqlite")
    storeDescription = NSPersistentStoreDescription(url: storeURL)
```

**Store loading with error handling at DataStore.swift:76-79:**
```swift
persistentContainer.loadPersistentStores { _, error in
    if let error {
        errorReporter.log(error: error)
    }
}
```

The store loading error handler logs the error but does not attempt recovery. If the store fails to load, the app is in a degraded state.

**Data cleanup on user logout at DataStore.swift:91-109:**
```swift
func deleteDataForUser(userId: String) async throws {
    try await backgroundContext.perform {
        try self.backgroundContext.executeAndMergeChanges(
            batchDeleteRequests: [
                CipherData.deleteByUserIdRequest(userId: userId),
                // ... other entities ...
                PendingCipherChangeData.deleteByUserIdRequest(userId: userId),
            ],
        )
    }
}
```

The `PendingCipherChangeData` is included in the batch delete on user data cleanup, which is correct -- pending changes should be cleaned up with other user data.

## Assessment

**Validity:** This issue is valid but represents an inherent limitation of using Core Data (or any single-file local database), not a flaw in the offline sync implementation. The risk applies equally to all data in the store.

**Key observations:**

1. **This is not specific to offline sync.** The existing `CipherData` entity (which stores the offline vault copy) faces the exact same corruption risk. If the store corrupts, the entire local vault is lost, not just pending changes. The app would need to re-sync everything from the server on next launch.

2. **Core Data corruption is extremely rare.** SQLite (which backs Core Data) is one of the most battle-tested database engines. Corruption typically occurs only in extreme circumstances:
   - Hardware failure (flash storage dying)
   - OS-level filesystem corruption
   - App killed during a write operation (mitigated by SQLite's WAL journaling)
   - Running out of disk space during a write

3. **iOS provides additional protection.** The iOS filesystem uses APFS with crash protection. SQLite uses WAL (Write-Ahead Logging) mode by default, which provides crash consistency. A clean app termination or even a force-quit during a background write should not corrupt the store.

4. **The server is the source of truth.** For all cipher data that has been synced, the server holds the authoritative copy. Pending changes are the only data that exists solely on the client. A corruption event would lose pending changes but not the overall vault.

5. **The blast radius is proportional to the number of pending changes.** If a user has 0 pending changes (the common case), corruption affects offline sync not at all. If they have 1-3 pending changes, those specific edits are lost but the rest of the vault is recoverable from the server.

**Blast radius:** If Core Data corruption occurs and a user has pending changes:
- Pending change records are lost
- The user's offline edits that were saved to `CipherData` are also lost (same store)
- On app restart, if the store is recoverable, data is fine; if not, a full re-sync from server restores everything except offline-only edits
- For password changes made offline, the user would need to re-set the password
- This is the worst-case scenario for any local data, not specific to offline sync

**Likelihood:** Extremely low. Core Data/SQLite corruption on iOS is a rare event that affects all apps equally.

## Options

### Option A: Add a Separate Backup File for Pending Changes
- **Effort:** High (1-2 days)
- **Description:** In addition to Core Data, write a JSON backup of pending change metadata to a separate file (e.g., `pending_changes_backup.json`) in the app's container. On startup, if the Core Data store fails to load, attempt to recover pending changes from this backup file. The backup would contain enough information to recreate the pending change records (cipher IDs, change types, timestamps) but not the full cipher data (which is large and encrypted).
- **Pros:** Provides a recovery path for pending change metadata; the backup file is independent of the Core Data store
- **Cons:** High complexity; the backup must be kept in sync with Core Data (dual-write consistency); the cipher data itself is still in Core Data, so even with recovered metadata, the actual edit content may be lost; adds a maintenance burden; the backup file could also be corrupted (same filesystem)
- **Risk:** Dual-write systems are notoriously difficult to keep consistent. A bug in the backup sync could cause phantom pending changes or missing records.

### Option B: Add Store Corruption Detection and Recovery
- **Effort:** High (1-2 days)
- **Description:** Modify the `loadPersistentStores` error handler at `DataStore.swift:76-79` to detect store corruption and attempt recovery. Recovery options include: (1) delete the corrupted store and create a fresh one (losing all local data), (2) attempt SQLite PRAGMA integrity_check, (3) restore from an iOS backup.
- **Pros:** Handles the corruption scenario gracefully instead of leaving the app in a degraded state; provides a clean recovery path
- **Cons:** Loss of all local data on recovery (same outcome as no recovery -- the next sync restores server data); does not specifically help offline sync; this is a project-wide concern that goes beyond offline sync
- **Note:** This is a general app resilience improvement, not an offline-sync-specific fix. It should be evaluated independently of the offline sync feature.

### Option C: Use a Separate Core Data Store for Pending Changes
- **Effort:** Medium-High (1 day)
- **Description:** Create a separate `NSPersistentContainer` with its own SQLite file for `PendingCipherChangeData`. This isolates pending changes from the main vault data, so corruption in one store does not affect the other.
- **Pros:** Isolates pending change data from vault data corruption; failure in the pending change store does not affect the main vault and vice versa
- **Cons:** Significant architectural change; two Core Data stacks to manage; cross-store queries are not possible (e.g., cannot join pending changes with cipher data); increases memory and file descriptor usage; the isolated store can still corrupt independently; diverges significantly from the project's established single-store pattern

### Option D: Accept As-Is
- **Rationale:** Core Data corruption is an inherent risk of using Core Data, shared equally by all data in the store. The existing vault data (`CipherData` with hundreds or thousands of cipher records) faces the same risk. The offline sync feature does not increase this risk -- it adds a small number of records (typically 0-5) to the same store. The server is the source of truth for all synced data. The only data exclusively at risk is pending changes that have not yet been resolved, which is a small and transient dataset. iOS's filesystem protections (APFS, WAL journaling) make corruption extremely rare. Adding redundancy (backup files, separate stores) introduces significant complexity with its own failure modes, for an extremely unlikely scenario. The effort is better spent on features that provide value in common cases rather than protecting against rare infrastructure failures.

## Recommendation

**Option D: Accept As-Is.** Core Data corruption is an app-wide infrastructure concern, not an offline-sync-specific issue. The offline sync feature adds a negligible amount of data to the existing Core Data store and does not increase the corruption risk. The mitigation options (backup files, separate stores) add significant complexity with their own failure modes and maintenance burdens.

If the team wants to improve Core Data resilience generally, **Option B** (store corruption detection and recovery) would benefit the entire app, not just offline sync. This should be evaluated as a separate project-wide initiative.

For offline sync specifically, the best practical mitigation is already in place: the pending changes dataset is small and transient. Most pending changes are resolved within a single sync cycle (seconds to minutes after connectivity returns). The window of exposure (time during which pending changes exist and are at risk) is naturally minimized.

## Resolution

**Resolved as inherent platform limitation (2026-02-20).** The action plan's own assessment confirms: "This represents an inherent limitation of using Core Data (or any single-file local database), not a flaw in the offline sync implementation." Core Data SQLite corruption risk applies equally to ALL data in the store — `CipherData`, `FolderData`, `CollectionData`, etc. — and is not specific to or worsened by the offline sync feature. Offline sync adds a negligible number of records (typically 0-5) to the same store. iOS provides multiple layers of protection (APFS, WAL journaling, crash consistency). The proposed mitigations (backup files, separate stores) introduce significant complexity with their own failure modes, for an extremely unlikely scenario. This is categorically different from a code defect — it is the same platform reality every Core Data app faces.

## Dependencies

- This is an inherent platform limitation, not specific to the offline sync implementation.
- Any project-wide initiative to improve Core Data resilience (store corruption detection, backup/recovery) would automatically benefit the offline sync feature.
- **AP-R2-MAIN-7** (Issue #43): Limiting the number of pending changes would also reduce the blast radius of this issue by keeping the pending change dataset small.

## Resolution Details

Inherent platform limitation — applies to all Core Data entities equally; not specific to offline sync.

## Comments
