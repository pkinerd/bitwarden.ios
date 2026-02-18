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

**[Updated]** Offline state is detected by **actual API call failure**. The VaultRepository catch blocks use a **denylist pattern**: specific known error types (`ServerError`, `ResponseValidationError` with HTTP status < 500, `CipherAPIServiceError`) are rethrown to the caller, while all other errors (including 5xx server errors, `URLError` transport failures, and unknown errors) trigger offline save. The `URLError+NetworkConnection` extension (which classified specific `URLError` codes as network errors) has been removed.

**Rationale for denylist approach:** `ServerError` and 4xx `ResponseValidationError` indicate the server received and rejected the request (not a connectivity issue), so they should propagate. `CipherAPIServiceError` indicates client-side validation failures (programming errors). All other errors — including 5xx (server-side failures like 502 Bad Gateway from CDN), `URLError` (transport failures), and unknown errors — appropriately trigger offline save. The encrypt step happens outside the do-catch, so SDK errors propagate normally.

### Modified File: `BitwardenShared/Core/Vault/Repositories/VaultRepository.swift`

**Changes to `updateCipher()`: [Updated to reflect current code]**

```
1. Check if cipher is organisation-owned (isOrgCipher flag set before try block)

2. Encrypt via clientService.vault().ciphers().encrypt()
   SECURITY NOTE: Encryption occurs BEFORE the API call attempt (outside the
   do-catch block). The encrypted Cipher object is available regardless of
   whether the API call succeeds or fails. SDK encryption errors propagate normally.

3. Attempt API call (updateCipherWithServer)

4. On success: clean up any orphaned pending change from a prior offline save
   (deletePendingChange by cipherId + userId)

5. If API call fails (denylist pattern — rethrow ServerError, CipherAPIServiceError,
   ResponseValidationError < 500; all other errors trigger offline save):
   a. Guard against organization ciphers (throw if org-owned)
   b. Persist the ENCRYPTED Cipher locally via updateCipherWithLocalStorage()
   c. Queue a PendingCipherChange record with the ENCRYPTED cipher data (see Section 3)
   d. Preserve .create type if this cipher was originally created offline
   e. Return success to the UI (user sees their edit applied locally)
```

**Changes to `addCipher()`: [Updated to reflect current code]**

```
1. Check if cipher is organisation-owned (isOrgCipher flag set before try block)
2. Assign a temporary client-side UUID via CipherView.withId(UUID().uuidString) BEFORE
   encryption if the cipher has no ID. This ensures the ID is baked into the encrypted
   content and survives the decrypt round-trip.
3. Encrypt the CipherView via SDK
4. Attempt API call (addCipherWithServer)
5. On success: clean up any orphaned pending change from a prior offline add
   (deletePendingChange by cipherId + userId)
6. If API call fails (denylist pattern — rethrow ServerError, CipherAPIServiceError,
   ResponseValidationError < 500; all other errors trigger offline save):
   a. Guard against organization ciphers (throw if org-owned)
   b. Persist encrypted cipher locally via updateCipherWithLocalStorage()
   c. Queue a PendingCipherChange with changeType = .create
   d. Return success to the UI

Note: [Resolved — VI-1] The cipher detail view infinite spinner bug has been fixed.
CipherView.withId() (operating before encryption) replaced Cipher.withTemporaryId() (which
set data: nil). Offline-created ciphers now encrypt correctly. A UI fallback
(fetchCipherDetailsDirectly) remains as defense-in-depth. See AP-VI1.

7. On sync (see Section 6):
   a. Create on server via addCipherWithServer()
   b. Server returns real ID; addCipherWithServer creates new CipherData record with server ID
   c. Delete the old temp-ID cipher record from local Core Data
   d. Delete pending change record
```

**Changes to `deleteCipher()` (hard delete): [Updated to reflect current code]**

```
1. Attempt API call (deleteCipherWithServer)
2. On success: clean up any orphaned pending change from a prior offline operation
3. If API call fails (denylist pattern — rethrow ServerError, CipherAPIServiceError,
   ResponseValidationError < 500; all other errors trigger offline save):
   a. If cipher was created offline (.create pending change), clean up locally only
      (delete local record + pending change) — no server operation needed
   b. Guard against organization ciphers (throw if org-owned)
   c. Otherwise: hard-delete locally via deleteCipherWithLocalStorage()
   d. Queue a PendingCipherChange with changeType = .softDelete
   e. Return success to the UI

Note: deleteCipher() uses deleteCipherWithLocalStorage (removes the CipherData record)
rather than updating it with a deletedDate. The pending change still uses .softDelete
changeType so the server-side operation is a soft delete on sync.
```

**Changes to `softDeleteCipher()` (move to trash): [Updated to reflect current code]**

```
1. Guard against missing cipher ID
2. Set deletedDate on cipher, encrypt via encryptAndUpdateCipher()
3. Attempt API call (softDeleteCipherWithServer)
4. On success: clean up any orphaned pending change from a prior offline operation
5. If API call fails (denylist pattern — rethrow ServerError, CipherAPIServiceError,
   ResponseValidationError < 500; all other errors trigger offline save):
   a. Guard against organization ciphers (throw if org-owned)
   b. If cipher was created offline (.create pending change), clean up locally only
      (delete local record + pending change) — no server operation needed
   c. Otherwise: persist soft-deleted cipher locally via updateCipherWithLocalStorage()
      (cipher appears in trash with deletedDate set)
   d. Queue a PendingCipherChange with changeType = .softDelete
   e. Return success to the UI

Note: Unlike deleteCipher(), softDeleteCipher() uses updateCipherWithLocalStorage to
preserve the cipher record with its deletedDate, so it appears in the user's trash.
```

**Both delete methods — On sync (see Section 6):**

```
1. Fetch server version to check for conflicts
   → If server returns 404: cipher already deleted; clean up locally and done
2. If server version unchanged: sync soft delete to server
3. If server version changed (conflict):
   → Create backup of server version (retains original folder)
   → Complete the soft delete on server
```

---

## 3. Pending Changes Queue

### New File: `BitwardenShared/Core/Vault/Models/Data/PendingCipherChangeData.swift`

**Core Data entity `PendingCipherChangeData`: [Updated to reflect current code — optional types match `@NSManaged` declarations]**

| Attribute | Type | Description |
|-----------|------|-------------|
| `id` | `String?` | Primary key for the pending change record (UUID string, set via convenience init) |
| `cipherId` | `String?` | The cipher's ID (or temporary client ID for new items) |
| `userId` | `String?` | Active user ID |
| `changeTypeRaw` | `Int16` | Stored as raw value; accessed via computed property `changeType` (enum: `.update`, `.create`, `.softDelete`) |
| `cipherData` | `Data?` | JSON-encoded **encrypted** `CipherDetailsResponseModel` snapshot (see Security note below) |
| `originalRevisionDate` | `Date?` | The cipher's `revisionDate` before the first offline edit (nil for new items) |
| `createdDate` | `Date?` | When this pending change was first queued (set via convenience init) |
| `updatedDate` | `Date?` | When this pending change was last updated (set via convenience init) |
| `offlinePasswordChangeCount` | `Int16` | Number of password changes made across offline edits for this cipher |

Note: Core Data `@NSManaged` properties for `String` and `Date` types are declared as optionals (`String?`, `Date?`) per Core Data conventions, even though the convenience initializer always provides non-nil values. The `changeType` enum is accessed via a computed property that wraps `changeTypeRaw` (defaulting to `.update` if the raw value is unrecognized).

**Security: `cipherData` stores encrypted data only.** This field contains the same JSON-encoded `CipherDetailsResponseModel` format used by the existing `CipherData` entity (see `CipherData.swift:8`). All sensitive fields (name, login, notes, password history, custom fields) are encrypted by the SDK before storage. The metadata fields on the `PendingCipherChangeData` entity itself (`offlinePasswordChangeCount`, `originalRevisionDate`, `changeType`) are non-sensitive and comparable to metadata already exposed by `CipherData`.

**Core Data model changes:**
- Add `PendingCipherChangeData` entity to `Bitwarden.xcdatamodeld`

### New File: `BitwardenShared/Core/Vault/Services/Stores/PendingCipherChangeDataStore.swift`

**Protocol: [Updated]**

```swift
/// Manages persistence of pending cipher changes queued during offline editing.
protocol PendingCipherChangeDataStore: AnyObject {
    /// Fetches all pending changes for a user.
    func fetchPendingChanges(userId: String) async throws -> [PendingCipherChangeData]

    /// Fetches a pending change for a specific cipher and user, if one exists.
    func fetchPendingChange(cipherId: String, userId: String) async throws -> PendingCipherChangeData?

    /// Inserts or updates a pending change record. Upserts by (cipherId, userId).
    func upsertPendingChange(
        cipherId: String, userId: String, changeType: PendingCipherChangeType,
        cipherData: Data?, originalRevisionDate: Date?, offlinePasswordChangeCount: Int16
    ) async throws

    /// Deletes a pending change record by its record ID.
    func deletePendingChange(id: String) async throws

    /// Deletes a pending change for a specific cipher and user.
    func deletePendingChange(cipherId: String, userId: String) async throws

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
2. Pre-count check: pendingChangeCount(userId:)
   → If 0: skip resolution entirely (optimization — avoids unnecessary resolver call)
   → If > 0: proceed to step 3
3. Call offlineSyncResolver.processPendingChanges()
4. Post-resolution count check: pendingChangeCount(userId:)
   a. If remaining > 0 → abort sync (early return to protect local offline edits)
   b. If remaining == 0 → proceed to normal fetchSync()
```

**[Updated]** A pre-count check was re-added as an optimization so the common case (no pending changes) skips the resolver entirely. The resolver is only called when pending changes actually exist. Both pre-count and post-resolution count checks use `pendingCipherChangeDataStore.pendingChangeCount(userId:)`.

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

**Protocol: [Updated]**

```swift
/// Resolves pending offline cipher changes against server state and syncs.
protocol OfflineSyncResolver {
    /// Processes all pending changes for the active user.
    func processPendingChanges(userId: String) async throws
}
```

**Note:** The `resolve(pendingChange:userId:)` method is a private implementation detail of `DefaultOfflineSyncResolver`, not part of the public protocol. The protocol exposes only the batch-processing entry point.

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
     → Delete old temp-ID cipher record from local Core Data
     → Delete pending change record
     → Done

   If changeType == .softDelete:
     → Fetch server version via getCipher()
       → If server returns 404: cipher already deleted; clean up locally and done
     → If server revisionDate == originalRevisionDate (no conflict):
       → Sync soft delete to server
     → If server revisionDate != originalRevisionDate (conflict):
       → Create backup of server version FIRST (retains original folder)
       → Then sync soft delete to server
     → Delete pending change record
     → Done

   If changeType == .update:
     → Continue to step 2

2. FETCH SERVER STATE
   Fetch current server version of the cipher via GET /ciphers/{id}
   → If server returns 404: re-create cipher on server via addCipherWithServer()
     to preserve the user's offline edits. Delete pending change record. Done.

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
       → Create backup of server version FIRST:
         (backup before push ensures server version is preserved even if push fails)
         - Title: "{original name} - {yyyy-MM-dd HH:mm:ss}"
         - Timestamp in title: server's revisionDate
         - All fields and password history preserved from server version
         - Backup retains the original cipher's folder assignment
       → Push backup as new cipher via addCipherWithServer()
       → Then push local version to server via updateCipherWithServer()
       → Delete pending change record

   CASE B: Conflict (revisionDates differ)

     Determine winner by timestamp:
     - Local timestamp = pendingChange.updatedDate
     - Server timestamp = server cipher's revisionDate

     If local is newer (updatedDate > server.revisionDate):
       → Winner = local version
       → Create backup of SERVER version FIRST:
         - Title: "{original name} - {yyyy-MM-dd HH:mm:ss}"
         - Timestamp in title: server's revisionDate
         - All fields and password history preserved from server version
         - Backup retains the original cipher's folder assignment
       → Push backup as new cipher via addCipherWithServer()
       → Then push local version to server via updateCipherWithServer()
       → Delete pending change record

     If server is newer (server.revisionDate >= updatedDate):
       → Winner = server version (already on server, no push needed)
       → Create backup of LOCAL version FIRST:
         - Title: "{original name} - {yyyy-MM-dd HH:mm:ss}"
         - Timestamp in title: pendingChange.updatedDate
         - All fields and password history preserved from local version
         - Backup retains the original cipher's folder assignment
       → Push backup as new cipher via addCipherWithServer()
       → Then update local storage to match server version
       → Delete pending change record

5. CLEAN UP
   → Delete pending change record
   → Local data store updated via normal upsert flow
   → UI updates reactively via CipherChange publisher
```

---

## 7. ~~Conflict Backup Folder~~ Backup Naming Convention **[Updated]**

~~### Purpose~~

~~All conflict backup copies are placed in a dedicated vault folder for easy discovery and bulk management by the user.~~

**[Updated]** The dedicated "Offline Sync Conflicts" folder has been removed. Backup ciphers now retain the original cipher's folder assignment. This simplifies the resolver by removing the `FolderService` dependency, the `getOrCreateConflictFolder()` method, and the `conflictFolderId` cache. Backups are identifiable by their name suffix.

### Backup Naming Convention

```
{original item name} - {yyyy-MM-dd HH:mm:ss}
```

- Timestamp is the `revisionDate` (server version) or `updatedDate` (local version) of the **losing** item
- Format: `yyyy-MM-dd HH:mm:ss` (e.g. `2026-02-18 13:55:26`)
- Example: `GitHub Login - 2026-02-18 13:55:26`

---

## 8. Organisation Cipher Exclusion

### Rationale

Organisation-owned ciphers have complications that make offline editing risky:
- Read-only permissions for some users
- Other org members (especially admins) likely to edit shared items
- Collection access controls could change while offline
- Organisation policies could change while offline
- Organisation key rotation would invalidate locally encrypted data

### Implementation [Updated to reflect current code]

**Modified File: `BitwardenShared/Core/Vault/Repositories/VaultRepository.swift`**

Organisation cipher exclusion is applied in all offline-capable methods:

- **`updateCipher()`**: Checks `organizationId` before the API call. If org-owned and API fails: throws `OfflineSyncError.organizationCipherOfflineEditNotSupported`.
- **`addCipher()`**: Checks `organizationId` before the API call. If org-owned and API fails: throws `OfflineSyncError.organizationCipherOfflineEditNotSupported`.
- **`softDeleteCipher()`**: Checks `organizationId` before the API call. If org-owned and API fails: throws `OfflineSyncError.organizationCipherOfflineEditNotSupported`.
- **`deleteCipher()`** (hard delete): The org check is inside `handleOfflineDelete`, which checks `cipher.organizationId` after fetching the cipher from local storage. If org-owned: throws `OfflineSyncError.organizationCipherOfflineEditNotSupported`.

In all cases, the error propagates through existing generic error handling in the UI layer.

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
| `VaultRepository.swift` | `BitwardenShared/Core/Vault/Repositories/` | Offline-aware `updateCipher()`, `addCipher()`, `deleteCipher()`, `softDeleteCipher()` with API failure catch-and-queue |
| `SyncService.swift` | `BitwardenShared/Core/Vault/Services/` | Add early-abort pattern: resolve pending changes before `fetchSync()`, abort if unresolved to protect offline edits |
| ~~`CipherService.swift`~~ | ~~`BitwardenShared/Core/Vault/Services/`~~ | **[Not modified]** — Existing protocol methods were sufficient. No changes needed. |
| ~~`FolderService.swift`~~ | ~~`BitwardenShared/Core/Vault/Services/`~~ | **[Not modified]** — ~~Existing API sufficient for conflict folder creation.~~ **[Updated]** `FolderService` is no longer used by the resolver; the conflict backup folder has been removed. |
| ~~`AddEditItemProcessor.swift`~~ | ~~`BitwardenShared/UI/Vault/VaultItem/AddEditItem/`~~ | **[Not modified]** — `OfflineSyncError.organizationCipherOfflineEditNotSupported` propagates through existing generic error handling. |

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
- ~~The conflict folder name ("Offline Sync Conflicts") is encrypted by the SDK like any folder name~~ **[Updated]** The dedicated conflict folder has been removed; backup ciphers retain their original folder assignment
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
- Retain the original cipher's folder assignment (no special conflict folder)

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
10. ~~Conflict backup folder creation via `FolderService`~~ **[Removed]** — Backup ciphers now retain their original folder assignment
11. Backup cipher creation with naming convention

### Phase 4: Reconnect Flow
12. Modify `SyncService` - embed early-abort resolution in `fetchSync()` so all sync triggers automatically resolve pending changes
13. Manual sync integration (pull-to-refresh triggers pending change processing via `fetchSync()`)

### Phase 5: Testing
14. Unit tests for all new services
15. Unit tests for modified flows
16. Integration tests for end-to-end offline → reconnect → resolve scenarios
