# Offline Sync Implementation Plan

## Overview

Add support for saving vault items locally while offline, with automatic syncing on reconnection. Conflict resolution preserves data faithfully - no silent data loss.

**Scope:** Client-side only. No server, API, or data model changes required.

**Initial scope exclusions:** Organisation-owned ciphers are excluded from offline editing. A clear user-facing message is shown when attempting to edit an org item offline.

---

## Principles

1. All password changes (including multiple successive offline changes) must be preserved in password history
2. The latest version (by timestamp) wins as the active item
3. Conflicting older versions are preserved as backup copies for manual user resolution
4. No password history merging in conflict cases - each item retains its own faithful history
5. No server-side or API changes required
6. Organisation-owned ciphers excluded from offline editing in initial implementation
7. **Security: Encrypt before queue** - cipher data MUST be encrypted via the SDK before being stored in the pending changes queue. The pending queue stores encrypted data only - never plaintext `CipherView` objects
8. **Security: Zero-knowledge preservation** - all encryption/decryption remains client-side. No new plaintext is transmitted or stored at rest

---

## Architecture

### Component Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Save Flow                                │
│                                                                 │
│  AddEditItemProcessor.saveItem()                                │
│       │                                                         │
│       ▼                                                         │
│  VaultRepository.updateCipher()                                 │
│       │                                                         │
│       ├── API call succeeds ──► Normal flow (unchanged)         │
│       │                                                         │
│       └── API call fails ──► Offline save flow                  │
│               │                                                 │
│               ├── Save locally via updateCipherWithLocalStorage  │
│               └── Queue PendingCipherChange                     │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│                    Reconnect Flow                                │
│                                                                 │
│  Existing sync triggers (periodic, foreground, pull-to-refresh) │
│       │                                                         │
│       ▼                                                         │
│  SyncService.fetchSync()                                        │
│       │                                                         │
│       ├── Vault locked? ──► Yes ──► Skip resolution, sync       │
│       │                                                         │
│       └── processPendingChanges() (handles empty case internally)│
│                       │                                         │
│                       ├── All resolved ──► Normal sync           │
│                       │                                         │
│                       └── Some remain ──► Abort sync (early     │
│                           return to protect local offline edits) │
└─────────────────────────────────────────────────────────────────┘
```

---

## 1. Offline Detection

### Approach

**[Updated]** Offline state is detected by **actual API call failure**. The VaultRepository catch blocks use plain `catch` — any server API call failure triggers offline save. The `URLError+NetworkConnection` extension (which classified specific `URLError` codes as network errors) has been removed.

**Rationale for simplification:** The networking stack separates transport errors (`URLError`) from HTTP errors (`ServerError`, `ResponseValidationError`) at a different layer. The fine-grained URLError classification was solving a problem that doesn't exist: there is no realistic scenario where the server is online and reachable but a pending change is permanently invalid. If the server is unreachable, the entire sync fails naturally. If the server is reachable, pending changes will resolve. The encrypt step happens outside the do-catch, so SDK errors propagate normally.

### Modified File: `BitwardenShared/Core/Vault/Repositories/VaultRepository.swift`

**Changes to `updateCipher()`: [Updated]**

```
1. Check if cipher is organisation-owned
   → If yes AND API fails: show error "Organisation items cannot be edited offline"
   → If yes AND online: proceed with normal flow (unchanged)

2. Attempt normal flow: encrypt → API call → local persist
   SECURITY NOTE: Encryption via clientService.vault().ciphers().encrypt()
   occurs BEFORE the API call attempt (outside the do-catch block). The
   encrypted Cipher object is available regardless of whether the API call
   succeeds or fails. SDK encryption errors propagate normally.

3. If API call fails (any error — plain catch):
   a. Persist the ENCRYPTED Cipher locally via updateCipherWithLocalStorage()
   b. Queue a PendingCipherChange record with the ENCRYPTED cipher data (see Section 3)
   c. Return success to the UI (user sees their edit applied locally)
```

**Changes to `addCipher()`: [Updated]**

```
1. If API call fails (any error — plain catch):
   a. Generate a client-side temporary UUID for the cipher (Swift UUID() uses /dev/urandom)
   b. Encrypt the CipherView via SDK, then persist encrypted cipher locally
   c. Queue a PendingCipherChange with changeType = .create
   d. Return success to the UI

2. On sync (see Section 6):
   a. Create on server via addCipherWithServer()
   b. Server returns real ID
   c. Atomically update ALL local references with server-assigned ID:
      - CipherData record in Core Data
      - PendingCipherChangeData.cipherId
      - Any other local references
   d. Delete pending change record
```

**Changes to `deleteCipher()`: [Updated]**

```
1. If API call fails (any error — plain catch):
   a. Soft-delete locally (move to trash in local storage)
   b. Queue a PendingCipherChange with changeType = .softDelete
   c. Return success to the UI

2. On sync (see Section 6):
   a. Fetch server version to check for conflicts
   b. If server version unchanged: sync soft delete to server
   c. If server version changed (conflict):
      → Create backup of server version in conflict folder
      → Complete the soft delete on server
```

---

## 3. Pending Changes Queue

### New File: `BitwardenShared/Core/Vault/Models/Data/PendingCipherChangeData.swift`

**Core Data entity `PendingCipherChangeData`:**

| Attribute | Type | Description |
|-----------|------|-------------|
| `id` | `UUID` | Primary key for the pending change record |
| `cipherId` | `String` | The cipher's ID (or temporary client ID for new items) |
| `userId` | `String` | Active user ID |
| `changeType` | `Int16` | Enum: `.update`, `.create`, `.softDelete` |
| `cipherData` | `Data` | JSON-encoded **encrypted** `CipherDetailsResponseModel` snapshot (see Security note below) |
| `originalRevisionDate` | `Date?` | The cipher's `revisionDate` before the first offline edit (nil for new items) |
| `createdDate` | `Date` | When this pending change was first queued |
| `updatedDate` | `Date` | When this pending change was last updated |
| `offlinePasswordChangeCount` | `Int16` | Number of password changes made across offline edits for this cipher |

**Security: `cipherData` stores encrypted data only.** This field contains the same JSON-encoded `CipherDetailsResponseModel` format used by the existing `CipherData` entity (see `CipherData.swift:8`). All sensitive fields (name, login, notes, password history, custom fields) are encrypted by the SDK before storage. The metadata fields on the `PendingCipherChangeData` entity itself (`offlinePasswordChangeCount`, `originalRevisionDate`, `changeType`) are non-sensitive and comparable to metadata already exposed by `CipherData`.

**Core Data model changes:**
- Add `PendingCipherChangeData` entity to `Bitwarden.xcdatamodeld`

### New File: `BitwardenShared/Core/Vault/Services/Stores/PendingCipherChangeDataStore.swift`

**Protocol:**

```swift
/// Manages persistence of pending cipher changes queued during offline editing.
protocol PendingCipherChangeDataStore {
    /// Fetches all pending changes for a user.
    func fetchPendingChanges(userId: String) async throws -> [PendingCipherChangeData]

    /// Fetches a pending change for a specific cipher and user, if one exists.
    func fetchPendingChange(cipherId: String, userId: String) async throws -> PendingCipherChangeData?

    /// Inserts or updates a pending change record. Upserts by (cipherId, userId).
    func upsertPendingChange(_ change: PendingCipherChangeData) async throws

    /// Deletes a pending change record after successful sync.
    func deletePendingChange(id: UUID) async throws

    /// Deletes all pending changes for a user.
    func deleteAllPendingChanges(userId: String) async throws

    /// Returns the count of pending changes for a user.
    func pendingChangeCount(userId: String) async throws -> Int
}
```

### Queueing Behaviour

When a cipher is saved offline:

- **First offline edit:** Create a new `PendingCipherChangeData` record. Capture `originalRevisionDate` from the cipher's current `revisionDate`. Set `offlinePasswordChangeCount` to 1 if password changed, 0 otherwise.
- **Subsequent offline edits to the same cipher:** Update the existing record. Replace `cipherData` with the latest encrypted cipher snapshot. Increment `offlinePasswordChangeCount` if the password changed. Preserve `originalRevisionDate` (do not overwrite - this is the baseline for conflict detection). Update `updatedDate`.

### Vault Lock/Unlock During Offline Period

If the vault locks while offline (timeout, user-initiated, device restart), the SDK's in-memory crypto context is cleared. Pending change records survive in Core Data because they contain **encrypted** data that doesn't depend on the in-memory context.

When the user unlocks the vault and makes a subsequent offline edit to the **same** cipher that already has a pending change, the following decrypt-compare-encrypt cycle is required:

```
1. User saves an edit to cipher X (which already has a pending change record)
2. Decrypt the existing pending cipher data via SDK (SDK context restored after unlock)
3. Compare the previous password with the new password to detect password changes
4. If password changed: increment offlinePasswordChangeCount
5. Encrypt the new CipherView via SDK to produce an updated encrypted Cipher
6. Update the PendingCipherChangeData record with:
   - New encrypted cipherData
   - Updated offlinePasswordChangeCount
   - Updated updatedDate
   - Preserved originalRevisionDate (unchanged)
```

This ensures accurate tracking of offline password change count even across vault lock/unlock cycles.

### Registration

- New protocol: `HasPendingCipherChangeDataStore` in `Services.swift`
- Added to `Services` typealias composition
- Instantiated in `ServiceContainer`

---

## 4. Sync-on-Reconnect Trigger

### Modified File: `BitwardenShared/Core/Vault/Services/SyncService.swift`

Offline change resolution is embedded directly in `fetchSync()`, so all existing sync triggers (periodic sync, foreground sync, pull-to-refresh) automatically attempt to resolve pending changes before syncing.

**Trigger flow within `fetchSync()`: [Updated]**

```
1. Guard: Is the vault unlocked? (SDK crypto context available)
   → If vault is locked: skip resolution, proceed to normal sync
   → This prevents sync resolution from failing due to inability to decrypt/encrypt
2. Call offlineSyncResolver.processPendingChanges()
   → Resolver handles the empty case internally (no pre-count check needed)
3. Check remaining pending count (post-resolution)
   a. If remaining > 0 → abort sync (early return to protect local offline edits)
   b. If remaining == 0 → proceed to normal fetchSync()
```

**[Updated]** The pre-count check was removed. The resolver is now always called when the vault is unlocked; it handles the empty case internally. Only the post-resolution count check remains as a guard before `replaceCiphers`.

This approach leverages existing sync mechanisms rather than introducing a separate connectivity monitor. The tradeoff is that sync resolution may be delayed by up to one sync interval (~30 minutes) compared to an immediate connectivity-based trigger, but this is acceptable given that users can always trigger resolution via pull-to-refresh.

---

## 5. Protection During `fetchSync()`

### Problem

The current `fetchSync()` calls `replaceCiphers()` which overwrites all local ciphers with server data. This would destroy pending offline edits if a background sync occurs before pending changes are resolved.

### Modified File: `BitwardenShared/Core/Vault/Services/SyncService.swift`

**Solution: Early-abort pattern**

```
1. Before syncing, attempt to resolve all pending changes
2. If any pending changes remain after resolution (e.g. server unreachable):
   → Abort the sync entirely (return early)
   → Local offline edits are preserved because replaceCiphers() never runs
3. If all pending changes are resolved:
   → Proceed with normal sync (replaceCiphers, etc.)
   → Safe because all offline edits have been synced to the server
```

This protects offline work by never calling `replaceCiphers()` while unresolved pending changes exist. The tradeoff is that users with unresolvable pending changes won't receive server-side updates until those changes are cleared, but this is preferable to data loss.

---

## 6. Conflict Resolution

### New File: `BitwardenShared/Core/Vault/Services/OfflineSyncResolver.swift`

**Protocol:**

```swift
/// Resolves pending offline cipher changes against server state and syncs.
protocol OfflineSyncResolver {
    /// Processes all pending changes for the active user.
    func processPendingChanges(userId: String) async throws

    /// Resolves a single pending change against server state.
    func resolve(pendingChange: PendingCipherChangeData, userId: String) async throws
}
```

### Decision Matrix

| Scenario | Winner | Backup created? | Password history |
|----------|--------|-----------------|------------------|
| No conflict, 0-3 offline password changes | Local | No | Local's own (normal 5-item cap) |
| No conflict, 4+ offline password changes (soft conflict) | Local | Yes (server snapshot) | Each keeps own |
| Conflict, local newer | Local | Yes (server snapshot) | Each keeps own |
| Conflict, server newer | Server | Yes (local snapshot) | Each keeps own |

**Conflict** = server's `revisionDate` differs from `pendingChange.originalRevisionDate` (server was edited while we were offline).

**Soft conflict** = no server-side changes, but 4+ offline password changes indicates unusual activity warranting a server backup.

### Resolution Algorithm

```
For each PendingCipherChangeData:

1. DETERMINE CHANGE TYPE

   If changeType == .create (new item):
     → Create on server via addCipherWithServer()
     → Update local cipher with server-assigned ID (replace temp ID)
     → Delete pending change record
     → Done

   If changeType == .softDelete:
     → Fetch server version
     → If server revisionDate == originalRevisionDate (no conflict):
       → Sync soft delete to server
     → If server revisionDate != originalRevisionDate (conflict):
       → Create backup of server version in conflict folder
       → Sync soft delete to server
     → Delete pending change record
     → Done

   If changeType == .update:
     → Continue to step 2

2. FETCH SERVER STATE
   Fetch current server version of the cipher (from sync response or GET /ciphers/{id})

3. DETECT CONFLICT
   Compare pendingChange.originalRevisionDate with server cipher's revisionDate

4. RESOLVE

   CASE A: No conflict (revisionDates match)

     If offlinePasswordChangeCount <= 3:
       → Push local version to server via updateCipherWithServer()
       → Local cipher's own password history synced as-is (normal 5-item cap)
       → No backup created
       → Delete pending change record

     If offlinePasswordChangeCount >= 4 (soft conflict):
       → Push local version to server via updateCipherWithServer()
       → Create backup of server version:
         - Title: "{original name} - offline conflict {yyyy-MM-dd HHmmss}"
         - Timestamp in title: server's revisionDate
         - All fields and password history preserved from server version
         - Added to "Offline Sync Conflicts" folder (created if needed)
       → Push backup as new cipher via addCipherWithServer()
       → Delete pending change record

   CASE B: Conflict (revisionDates differ)

     Determine winner by timestamp:
     - Local timestamp = pendingChange.updatedDate
     - Server timestamp = server cipher's revisionDate

     If local is newer (updatedDate > server.revisionDate):
       → Winner = local version
       → Push local version to server via updateCipherWithServer()
       → Create backup of SERVER version:
         - Title: "{original name} - offline conflict {yyyy-MM-dd HHmmss}"
         - Timestamp in title: server's revisionDate
         - All fields and password history preserved from server version
         - Added to "Offline Sync Conflicts" folder
       → Push backup as new cipher via addCipherWithServer()
       → Delete pending change record

     If server is newer (server.revisionDate > updatedDate):
       → Winner = server version (already on server, no push needed)
       → Create backup of LOCAL version:
         - Title: "{original name} - offline conflict {yyyy-MM-dd HHmmss}"
         - Timestamp in title: pendingChange.updatedDate
         - All fields and password history preserved from local version
         - Added to "Offline Sync Conflicts" folder
       → Push backup as new cipher via addCipherWithServer()
       → Update local storage to match server version
       → Delete pending change record

5. CLEAN UP
   → Delete pending change record
   → Local data store updated via normal upsert flow
   → UI updates reactively via CipherChange publisher
```

---

## 7. Conflict Backup Folder

### Purpose

All conflict backup copies are placed in a dedicated vault folder for easy discovery and bulk management by the user.

### Implementation

**Modified File: `BitwardenShared/Core/Vault/Services/OfflineSyncResolver.swift`**

When creating the first conflict backup during a sync resolution:

```
1. Check if folder named "Offline Sync Conflicts" exists for the user
2. If not, create it via FolderService.addFolderWithServer(name:)
3. Assign the backup cipher to this folder's ID
4. Cache the folder ID for subsequent backups in the same sync batch
```

### Backup Naming Convention

```
{original item name} - offline conflict {yyyy-MM-dd HHmmss}
```

- Timestamp is the `revisionDate` (server version) or `updatedDate` (local version) of the **losing** item
- Format: `yyyy-MM-dd HHmmss` (e.g. `2026-02-07 143052`)
- Example: `GitHub Login - offline conflict 2026-02-07 143052`

---

## 8. Organisation Cipher Exclusion

### Rationale

Organisation-owned ciphers have complications that make offline editing risky:
- Read-only permissions for some users
- Other org members (especially admins) likely to edit shared items
- Collection access controls could change while offline
- Organisation policies could change while offline
- Organisation key rotation would invalidate locally encrypted data

### Implementation

**Modified File: `BitwardenShared/Core/Vault/Repositories/VaultRepository.swift`**

In the modified `updateCipher()` flow:

```
1. Before attempting the API call, check cipher.organizationId
2. If organizationId != nil AND API call fails with network error:
   → Do NOT queue as pending change
   → Surface user-facing error: "Organisation items cannot be edited while offline.
     Please reconnect to save changes to this item."
3. If organizationId == nil: proceed with offline queue as described above
```

This cleanly excludes org ciphers without affecting any other flow.

---

## 9. New and Modified Files Summary

### New Files

| File | Location | Purpose |
|------|----------|---------|
| `PendingCipherChangeData.swift` | `BitwardenShared/Core/Vault/Models/Data/` | Core Data entity for queued offline changes |
| `PendingCipherChangeDataStore.swift` | `BitwardenShared/Core/Vault/Services/Stores/` | CRUD operations for pending changes |
| `PendingCipherChangeDataStoreTests.swift` | `BitwardenShared/Core/Vault/Services/Stores/` | Unit tests |
| `MockPendingCipherChangeDataStore.swift` | Test helpers | Mock for testing |
| `OfflineSyncResolver.swift` | `BitwardenShared/Core/Vault/Services/` | Conflict resolution and sync logic |
| `OfflineSyncResolverTests.swift` | `BitwardenShared/Core/Vault/Services/` | Unit tests |
| `MockOfflineSyncResolver.swift` | Test helpers | Mock for testing |

### Modified Files

| File | Location | Changes |
|------|----------|---------|
| `Bitwarden.xcdatamodeld` | `BitwardenShared/Core/Platform/Services/Stores/` | Add `PendingCipherChangeData` entity |
| `Services.swift` | `BitwardenShared/Core/Platform/Services/` | Add `HasPendingCipherChangeDataStore`, `HasOfflineSyncResolver` protocols; add to `Services` typealias |
| `ServiceContainer.swift` | `BitwardenShared/Core/Platform/Services/` | Register new services, add properties and init params |
| `VaultRepository.swift` | `BitwardenShared/Core/Vault/Repositories/` | Offline-aware `updateCipher()`, `addCipher()`, `deleteCipher()` with API failure catch-and-queue |
| `SyncService.swift` | `BitwardenShared/Core/Vault/Services/` | Add early-abort pattern: resolve pending changes before `fetchSync()`, abort if unresolved to protect offline edits |
| `CipherService.swift` | `BitwardenShared/Core/Vault/Services/` | Expose helpers needed by resolver (if not already public) |
| `FolderService.swift` | `BitwardenShared/Core/Vault/Services/` | Minor - used by resolver to create conflict folder (existing API sufficient) |
| `AddEditItemProcessor.swift` | `BitwardenShared/UI/Vault/VaultItem/AddEditItem/` | Handle offline error state, show org cipher offline restriction message |

### Test Files (New)

All new services and modified flows require corresponding test files following the patterns in `Docs/Testing.md`. Mocks follow the established `MockXxx` naming convention in the existing test helper directories.

---

## 10. Security Considerations

### Encryption at Rest

All cipher data in the pending changes queue is stored in the **same encrypted form** as the existing vault cache:

- **Existing `CipherData`**: JSON-encoded `CipherDetailsResponseModel` with all sensitive fields encrypted by the SDK (`CipherData.swift:8`)
- **New `PendingCipherChangeData.cipherData`**: Identical format - JSON-encoded `CipherDetailsResponseModel` with all sensitive fields encrypted by the SDK

Both entities reside in the same Core Data SQLite database at `{AppGroupContainer}/Bitwarden.sqlite`. The pending queue introduces no reduction in encryption or protection level.

### Core Data Protection Level

The Core Data store does not configure explicit `NSFileProtectionComplete` (`DataStore.swift:50-83`). It relies on:
1. **iOS default file protection** (Complete Until First User Authentication at the filesystem level)
2. **Application-level encryption** - all sensitive cipher fields are encrypted by the SDK before storage
3. **Application sandbox** - the database is within the app's security group container

This is an existing architectural characteristic, unchanged by this feature. The pending queue inherits the same protection.

### Zero-Knowledge Architecture

The offline sync feature preserves zero-knowledge:
- All encryption/decryption is performed client-side by the BitwardenSdk
- No plaintext is transmitted to the server - the API receives the same encrypted `CipherRequestModel` as normal
- Backup conflict copies are encrypted identically to any other cipher
- The conflict folder name ("Offline Sync Conflicts") is encrypted by the SDK like any folder name
- No new plaintext is stored at rest

### Encrypt-Before-Queue Invariant

**Critical implementation requirement:** The cipher MUST be encrypted via `clientService.vault().ciphers().encrypt()` before being stored in `PendingCipherChangeData.cipherData`. This is naturally satisfied by the save flow (encryption occurs before the API call attempt), but must be explicitly maintained in any future modifications.

The flow is:
```
CipherView (decrypted, in-memory only)
    → SDK encrypt() → Cipher (encrypted)
        → API call attempt
            → Success: normal flow
            → Failure: store encrypted Cipher in pending queue ✓
```

A `CipherView` (decrypted) must **never** be serialised to `PendingCipherChangeData.cipherData`.

### Vault Lock/Unlock Resilience

| Scenario | Behaviour |
|----------|-----------|
| Vault locks while offline | Pending encrypted records survive in Core Data. SDK crypto context cleared from memory. No data loss. |
| User unlocks vault while still offline | SDK crypto context restored. User can continue editing. Subsequent edits to pending ciphers use decrypt-compare-encrypt cycle (Section 3). |
| Connectivity resumes while vault is locked | Sync is deferred. Guard in `fetchSync()` skips resolution when vault is locked. Resolution triggers on next sync after vault unlock. |
| Connectivity resumes while vault is unlocked | Next sync trigger (periodic, foreground, pull-to-refresh) resolves pending changes. |

### Temporary IDs for Offline-Created Items

- Generated via Swift `UUID()` which uses `/dev/urandom` (cryptographically secure)
- Replaced atomically with server-assigned IDs on sync to prevent orphaned references
- The temporary cipher is encrypted before local storage (same encrypt-before-queue rule)

### Conflict Backup Security

Backup copies created during conflict resolution:
- Are encrypted via the SDK before being pushed to the server (they go through `addCipherWithServer()` which requires an encrypted `Cipher`)
- Contain encrypted data at rest, identical to any other vault item
- Are placed in an encrypted folder (folder names are encrypted by the SDK)

### Metadata Exposure

The `PendingCipherChangeData` entity exposes non-sensitive metadata in plaintext:
- `offlinePasswordChangeCount` - reveals number of offline password changes
- `originalRevisionDate` - reveals when the cipher was last synced
- `changeType` - reveals the type of pending operation
- `createdDate` / `updatedDate` - reveals timing of offline edits

This is comparable to metadata already exposed by `CipherData` (which stores `id`, `userId`, and the `revisionDate` within its JSON). The metadata reveals activity patterns but no sensitive vault content.

---

## 11. Implementation Order

### Phase 1: Foundation
1. `PendingCipherChangeData` + Core Data model update
2. `PendingCipherChangeDataStore` - CRUD for pending changes
3. Service registration in `ServiceContainer` / `Services.swift`

### Phase 2: Offline Save Flow
4. Modify `VaultRepository.updateCipher()` - catch API failures, queue pending changes
5. Modify `VaultRepository.addCipher()` - offline creation with temp IDs
6. Modify `VaultRepository.deleteCipher()` - offline soft delete queueing
7. Organisation cipher exclusion in save flow
8. Modify `AddEditItemProcessor` - handle offline state in UI

### Phase 3: Sync Resolution
9. `OfflineSyncResolver` - conflict resolution algorithm
10. Conflict backup folder creation via `FolderService`
11. Backup cipher creation with naming convention

### Phase 4: Reconnect Flow
12. Modify `SyncService` - embed early-abort resolution in `fetchSync()` so all sync triggers automatically resolve pending changes
13. Manual sync integration (pull-to-refresh triggers pending change processing via `fetchSync()`)

### Phase 5: Testing
14. Unit tests for all new services
15. Unit tests for modified flows
16. Integration tests for end-to-end offline → reconnect → resolve scenarios
