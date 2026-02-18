# Offline Sync for Vault Cipher Operations — Detailed Changelog

> **Feature**: Client-side offline vault sync with conflict resolution
> **Fork base**: `0283b1f` (Update SDK to 9b59b09)
> **Commits**: 5 (initial) + 8 (post-review fixes on dev: PRs #26-#33) + 2 (branch-only: backup reorder + RES-2 404 handling)
> **Scope**: 18 files changed (+2,310/−11 initial) + multiple post-review fixes
> **Documentation**: 40+ files

---

## Table of Contents

1. [Overview](#1-overview)
2. [Architecture Summary](#2-architecture-summary)
3. [Core Data Model: PendingCipherChangeData Entity](#3-core-data-model-pendingcipherchangedata-entity)
4. [PendingCipherChangeData Model & PendingCipherChangeDataStore](#4-pendingcipherchangedata-model--pendingcipherchangedatastore)
5. [CipherView+OfflineSync Extension Helpers](#5-cipherviewofflinesync-extension-helpers)
6. [VaultRepository Offline Fallback Handlers](#6-vaultrepository-offline-fallback-handlers)
7. [OfflineSyncResolver Conflict Resolution Engine](#7-offlinesyncresolver-conflict-resolution-engine)
8. [SyncService Pre-Sync Resolution Integration](#8-syncservice-pre-sync-resolution-integration)
9. [Dependency Injection Wiring](#9-dependency-injection-wiring)
10. [Test Coverage: PendingCipherChangeDataStoreTests](#10-test-coverage-pendingcipherchangedatastoretests)
11. [Test Coverage: CipherViewOfflineSyncTests](#11-test-coverage-cipherviewofflinesynctests)
12. [Test Coverage: VaultRepositoryTests Offline Fallback](#12-test-coverage-vaultrepositorytests-offline-fallback)
13. [Test Coverage: OfflineSyncResolverTests](#13-test-coverage-offlineresolvertests)
14. [Test Coverage: SyncServiceTests Pre-Sync Resolution](#14-test-coverage-syncservicetests-pre-sync-resolution)
15. [Test Helpers: Mocks](#15-test-helpers-mocks)
16. [Post-Implementation Fixes](#16-post-implementation-fixes)
17. [Documentation Artifacts](#17-documentation-artifacts)

---

## 1. Overview

This changeset implements **offline vault sync** — the ability for users to create, update, and delete personal vault ciphers while the device is offline. Changes are queued locally in Core Data, and when connectivity returns, the `SyncService` resolves pending changes against the server state before pulling fresh data.

### Design Principles

- **No silent data loss**: Every conflict produces a backup cipher (retaining the original cipher's folder assignment).
- **Encrypt-before-queue**: Cipher data is encrypted via the SDK before being written to the pending changes store.
- **Organization cipher exclusion**: Only personal vault items support offline editing (org ciphers require server-side validation).
- **Early-abort sync**: If pending changes fail to resolve, the sync is aborted entirely to prevent `replaceCiphers()` from overwriting local edits.
- **Timestamp-based conflict resolution**: The cipher's `revisionDate` is used as the conflict detection baseline.

### Commit History (chronological)

| Commit | Description |
|--------|-------------|
| `fd4a60b` | Main implementation: all source, tests, Core Data model, documentation |
| `e13aefe` | Simplify error handling by removing `URLError` classification — all API errors trigger offline save |
| `a52d379` | Remove unused `timeProvider` dependency and stray blank lines |
| `a90ff46` | Update documentation to reflect resolved issues |
| `f626ab4` | Move resolved/superseded action plans to `Resolved/` subdirectory |

---

## 2. Architecture Summary

```
┌─────────────────────────────────────────────────────────────────┐
│                        User Action                              │
│              (add / update / delete cipher)                      │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                     VaultRepository                             │
│   Encrypt via SDK → try server API → on failure:                │
│   handleOfflineAdd / handleOfflineUpdate / handleOfflineDelete  │
│   handleOfflineSoftDelete                                       │
│   ├─ Persist cipher to local Core Data (CipherService)          │
│   └─ Queue PendingCipherChangeData record                       │
└────────────────────────┬────────────────────────────────────────┘
                         │
              (later, on reconnect)
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                       SyncService                               │
│   fetchSync() {                                                 │
│     1. Check vault lock (skip resolution if locked)             │
│     2. offlineSyncResolver.processPendingChanges()              │
│     3. Check remaining pending count                            │
│     4. If count > 0 → ABORT (protect local edits)              │
│     5. Otherwise → continue normal sync                         │
│   }                                                             │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                   OfflineSyncResolver                           │
│   For each pending change:                                      │
│   ├─ .create  → push to server, delete record                  │
│   ├─ .update  → compare revisionDates:                         │
│   │   ├─ no conflict, <4 pw changes → push local               │
│   │   ├─ no conflict, ≥4 pw changes → push local + backup srv  │
│   │   └─ conflict → timestamp winner, backup loser             │
│   └─ .softDelete → check conflict, backup if needed, delete    │
│   Backup → retains original cipher's folder assignment         │
└─────────────────────────────────────────────────────────────────┘
```

### Data Flow

1. **Offline edit** → `VaultRepository` catches API failure → persists cipher locally + queues `PendingCipherChangeData`
2. **Reconnect sync** → `SyncService.fetchSync()` → `OfflineSyncResolver.processPendingChanges()` → resolves each pending change against server
3. **Conflict** → backup cipher created (retains original folder) → winner version pushed to server
4. **All resolved** → normal sync proceeds with `replaceCiphers()`

**Related documents:**
- [OfflineSyncPlan.md](./_OfflineSyncDocs/OfflineSyncPlan.md) — Full implementation plan
- [OfflineSyncCodeReview.md](./_OfflineSyncDocs/OfflineSyncCodeReview.md) — Comprehensive code review

---

## 3. Core Data Model: PendingCipherChangeData Entity

**File:** `BitwardenShared/Core/Platform/Services/Stores/Bitwarden.xcdatamodeld/Bitwarden.xcdatamodel/contents`
**Change type:** New entity added to existing Core Data model

### What Changed

A new `PendingCipherChangeData` entity was added to the Core Data model with the following schema:

| Attribute | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `id` | String | Yes | — | Primary key for the pending change record |
| `cipherId` | String | Yes | — | Cipher ID (temporary UUID for creates, server ID for updates/deletes) |
| `userId` | String | Yes | — | Active user ID for multi-user isolation |
| `changeTypeRaw` | Integer 16 | Yes | `0` | Enum: `0` = update, `1` = create, `2` = softDelete |
| `cipherData` | Binary | No | — | JSON-encoded encrypted `CipherDetailsResponseModel` |
| `originalRevisionDate` | Date | No | — | Server `revisionDate` at time of first offline edit |
| `createdDate` | Date | No | — | Timestamp of first queued change |
| `updatedDate` | Date | No | — | Timestamp of most recent update to this record |
| `offlinePasswordChangeCount` | Integer 16 | Yes | `0` | Number of password changes while offline |

### Uniqueness Constraint

```xml
<uniquenessConstraint>
    <constraint value="userId"/>
    <constraint value="cipherId"/>
</uniquenessConstraint>
```

This ensures **one pending change record per cipher per user**. Subsequent edits to the same cipher upsert (update) the existing record rather than creating duplicates.

### Design Decisions

- **`originalRevisionDate` preserved on upsert**: When a user makes multiple offline edits to the same cipher, the `originalRevisionDate` from the first edit is preserved. This is the baseline for conflict detection during resolution — if the server's `revisionDate` differs from this value, a conflict exists.
- **`cipherData` stores the encrypted form**: The cipher is encrypted by the SDK before the API call attempt, and the same encrypted form is stored in `cipherData`. This maintains the zero-knowledge security invariant.
- **`offlinePasswordChangeCount` tracks credential rotation risk**: If a user changes a login password 4+ times while offline, the resolver creates a precautionary backup even without a server conflict.

**Related issues:** [AP-PCDS1](./_OfflineSyncDocs/ActionPlans/AP-PCDS1_IdOptionalRequiredMismatch.md), [AP-PCDS2](./_OfflineSyncDocs/ActionPlans/AP-PCDS2_DatesOptionalButAlwaysSet.md), [AP-R1](./_OfflineSyncDocs/ActionPlans/AP-R1_DataFormatVersioning.md)
**Review section:** [ReviewSection_PendingCipherChangeDataStore.md](./_OfflineSyncDocs/ReviewSection_PendingCipherChangeDataStore.md)

---

## 4. PendingCipherChangeData Model & PendingCipherChangeDataStore

### 4a. PendingCipherChangeData NSManagedObject

**File:** `BitwardenShared/Core/Vault/Models/Data/PendingCipherChangeData.swift` (new, 192 lines)

#### PendingCipherChangeType Enum (line 8)

```swift
enum PendingCipherChangeType: Int16, Sendable {
    case update = 0
    case create = 1
    case softDelete = 2
}
```

Three change types representing the operations a user can perform on vault items. `update` is `0` for backwards compatibility with the Core Data default value.

#### NSManagedObject Subclass (line 27)

The `PendingCipherChangeData` class uses `@NSManaged` properties matching the Core Data schema. Key details:

- **Computed `changeType` property** (line 71): Converts between raw `Int16` and the `PendingCipherChangeType` enum.
- **Convenience initializer** (line 83): Sets `id = UUID().uuidString`, `createdDate` and `updatedDate` to current time.
- **Static predicate helpers** (lines 108–142): `userIdPredicate`, `userIdAndCipherIdPredicate`, `idPredicate` — used by fetch/delete requests.
- **Static fetch request helpers** (lines 144–180): `fetchByUserIdRequest` (sorted by `createdDate` ascending), `fetchByCipherIdRequest`, `fetchByIdRequest`.
- **Static delete helper** (line 187): `deleteByUserIdRequest` for batch cleanup on logout.

### 4b. PendingCipherChangeDataStore

**File:** `BitwardenShared/Core/Vault/Services/Stores/PendingCipherChangeDataStore.swift` (new, 155 lines)

#### Protocol (line 9)

```swift
protocol PendingCipherChangeDataStore: AnyObject {
    func fetchPendingChanges(userId: String) async throws -> [PendingCipherChangeData]
    func fetchPendingChange(cipherId: String, userId: String) async throws -> PendingCipherChangeData?
    func upsertPendingChange(cipherId:userId:changeType:cipherData:originalRevisionDate:offlinePasswordChangeCount:) async throws
    func deletePendingChange(id: String) async throws
    func deletePendingChange(cipherId: String, userId: String) async throws
    func deleteAllPendingChanges(userId: String) async throws
    func pendingChangeCount(userId: String) async throws -> Int
}
```

Seven methods covering full CRUD plus count. The protocol follows the existing pattern used by `CipherDataStore`, `FolderDataStore`, etc.

#### DataStore Extension (line 75)

The protocol is implemented as an extension on the existing `DataStore` class, reusing its `backgroundContext` for all Core Data operations. This follows the established pattern in the codebase.

**Critical upsert behavior** (lines 91–123):

```swift
func upsertPendingChange(...) async throws {
    try await backgroundContext.perform {
        let existing = try context.fetch(fetchByCipherId)
        if let existingChange = existing.first {
            // UPDATE: preserves originalRevisionDate, updates data & count
            existingChange.cipherData = cipherData
            existingChange.changeType = changeType
            existingChange.updatedDate = Date()
            existingChange.offlinePasswordChangeCount = offlinePasswordChangeCount
        } else {
            // INSERT: creates new record with all fields
            _ = PendingCipherChangeData(context:, id:, cipherId:, userId:, ...)
        }
        try context.save()
    }
}
```

The upsert **intentionally preserves `originalRevisionDate`** on update — this is the server revision date captured on the first offline edit and serves as the baseline for conflict detection. Overwriting it on subsequent edits would make conflict detection unreliable.

**Related issues:** [AP-PCDS1](./_OfflineSyncDocs/ActionPlans/AP-PCDS1_IdOptionalRequiredMismatch.md), [AP-PCDS2](./_OfflineSyncDocs/ActionPlans/AP-PCDS2_DatesOptionalButAlwaysSet.md)
**Review section:** [ReviewSection_PendingCipherChangeDataStore.md](./_OfflineSyncDocs/ReviewSection_PendingCipherChangeDataStore.md)

---

## 5. CipherView+OfflineSync Extension Helpers

**File:** `BitwardenShared/Core/Vault/Extensions/CipherView+OfflineSync.swift` (new, 95 lines)

Two extension methods support offline sync operations by creating modified copies of cipher objects.

### 5a. `Cipher.withTemporaryId(_:)`

```swift
extension Cipher {
    func withTemporaryId(_ id: String) -> Cipher {
        Cipher(
            id: id,           // ← Replaced with specified ID
            organizationId: organizationId,
            folderId: folderId,
            // ... ~25 more properties copied verbatim ...
            data: nil,        // ← Known issue: sets data to nil
        )
    }
}
```

**Purpose:** Assigns a temporary client-generated UUID to a newly created cipher *after encryption*. Called by `handleOfflineAdd()` when the encrypted cipher has no ID (which is always the case for new ciphers, since the server assigns IDs).

~~**Known issue (VI-1 root cause):** The method sets `data: nil`. The `data` field contains the raw encrypted content needed for decryption. This causes the detail view's `streamCipherDetails` publisher to fail when trying to decrypt the cipher. Mitigated via UI-level fallback (`fetchCipherDetailsDirectly()` in PR #31) but root cause remains.~~ **[RESOLVED]** This method has been replaced by `CipherView.withId()` operating before encryption (commit `3f7240a`). The `data: nil` problem no longer exists. See [AP-VI1](ActionPlans/AP-VI1_OfflineCreatedCipherViewFailure.md).

### 5b. `CipherView.update(name:)` (line 63) **[Updated]**

Creates a backup copy of a decrypted `CipherView` with a modified name, retaining the original folder assignment:

```swift
extension CipherView {
    func update(name: String) -> CipherView {
        CipherView(
            id: nil,          // ← Nil so server assigns new ID
            organizationId: organizationId,
            folderId: folderId, // ← Retains original folder
            // ... other properties ...
            name: name,        // ← Modified with conflict timestamp
            key: nil,          // ← Nil so SDK generates fresh key
            attachments: nil,  // ← Excluded from backup
        )
    }
}
```

**Purpose:** Used by `OfflineSyncResolver.createBackupCipher()` to create conflict backup copies. The backup has:
- `id` set to `nil` (server assigns a new ID)
- `key` set to `nil` (SDK generates a fresh encryption key)
- `attachments` set to `nil` (attachments are not duplicated — see [AP-RES7](./_OfflineSyncDocs/ActionPlans/AP-RES7_BackupCiphersLackAttachments.md))
- `name` modified with a timestamp suffix (e.g., `"Login - 2026-02-18 13:55:26"`)
- `folderId` retains the original cipher's folder assignment (no longer placed in a dedicated conflict folder)

**Fragility concern:** Both methods manually copy 24–26 properties. If the SDK adds new properties with non-nil defaults, they will be silently dropped. See [AP-CS2](./_OfflineSyncDocs/ActionPlans/AP-CS2_FragileSDKCopyMethods.md).

**[Updated]** The `folderId` parameter was removed from `CipherView.update(name:folderId:)` → `CipherView.update(name:)`. Backup ciphers now retain the original cipher's folder assignment instead of being placed in a dedicated "Offline Sync Conflicts" folder.

**Review section:** [ReviewSection_SupportingExtensions.md](./_OfflineSyncDocs/ReviewSection_SupportingExtensions.md)

---

## 6. VaultRepository Offline Fallback Handlers

**File:** `BitwardenShared/Core/Vault/Repositories/VaultRepository.swift`
**Change type:** Modified (+213 / −10 lines)

### What Changed

Four existing public methods were modified to catch API failures and delegate to new offline handler methods. Four new private handler methods were added.

### 6a. Modified Public Methods

Each public method follows the same pattern: encrypt the cipher, attempt the API call in a `do/catch`, and on failure delegate to the offline handler. Organization ciphers are checked before the offline handler is called.

#### `addCipher(_:)` (line 503)

```swift
func addCipher(_ cipher: CipherView) async throws {
    let isOrgCipher = cipher.organizationId != nil
    let cipherEncryptionContext = try await clientService.vault().ciphers().encrypt(cipherView: cipher)
    do {
        try await cipherService.addCipherWithServer(...)
    } catch {
        guard !isOrgCipher else {
            throw OfflineSyncError.organizationCipherOfflineEditNotSupported
        }
        try await handleOfflineAdd(encryptedCipher:, userId:)
    }
}
```

#### `updateCipher(_:)` (line 913)

Same pattern — encrypts, tries API, catches failure, checks org cipher, calls `handleOfflineUpdate`.

#### `softDeleteCipher(_:)` (line 888)

Same pattern — updates `deletedDate`, encrypts, tries API, catches failure, checks org cipher, calls `handleOfflineSoftDelete`.

#### `deleteCipher(_:)` (line 637)

Slightly different — permanent deletes don't have a pre-encrypted cipher, so the handler fetches the cipher first:

```swift
func deleteCipher(_ id: String) async throws {
    do {
        try await cipherService.deleteCipherWithServer(id: id)
    } catch {
        try await handleOfflineDelete(cipherId: id)
    }
}
```

**Design note:** `deleteCipher` performs a **soft delete** offline rather than a permanent delete. This is intentional — it preserves the cipher data for conflict resolution. See [AP-VR2](./_OfflineSyncDocs/ActionPlans/AP-VR2_DeleteConvertedToSoftDelete.md).

### 6b. New Offline Handlers

#### `handleOfflineAdd(encryptedCipher:userId:)` (line 950)

1. Assigns a temporary `UUID().uuidString` if the cipher has no ID
2. Persists the cipher to local Core Data via `cipherService.updateCipherWithLocalStorage()`
3. Encodes the cipher as `CipherDetailsResponseModel` → JSON `Data`
4. Queues a `.create` pending change record

#### `handleOfflineUpdate(cipherView:encryptedCipher:userId:)` (line 989)

1. Persists the updated cipher locally
2. Encodes it as JSON
3. Fetches any existing pending change for this cipher
4. **Password change detection** (lines 1012–1035):
   - If there's an existing pending change: decrypts the previous pending cipher data and compares `login?.password` with the new cipher's password
   - If first offline edit: fetches the local cipher, decrypts it, and compares passwords
   - Increments `offlinePasswordChangeCount` if different
5. Preserves `originalRevisionDate` from existing record (or captures current `revisionDate` for first edit)
6. Upserts the pending change record

**Security note:** Password comparison is done entirely in-memory using the SDK's decrypt operations. No plaintext passwords are persisted.

#### `handleOfflineDelete(cipherId:)` (line 1046)

1. Gets active user ID from `stateService`
2. Fetches the cipher from local storage (to preserve its data for conflict resolution)
3. Guards against organization ciphers (throws `OfflineSyncError.organizationCipherOfflineEditNotSupported`)
4. Soft-deletes locally via `cipherService.deleteCipherWithLocalStorage()`
5. Queues a `.softDelete` pending change

**Note:** The org cipher guard is inside this handler (not in the public method) because `deleteCipher` only takes an ID parameter — the cipher must be fetched to check `organizationId`.

#### `handleOfflineSoftDelete(cipherId:encryptedCipher:)` (line 1079)

1. Gets active user ID
2. Persists the already-soft-deleted cipher locally (it has `deletedDate` set)
3. Queues a `.softDelete` pending change

### Organization Cipher Protection

All four handlers guard against organization ciphers. The rationale:
- Organization ciphers require server-side policy checks and access control validation
- Offline edits to shared items could create inconsistencies across organization members
- This is a security boundary documented in the [OfflineSyncPlan](./_OfflineSyncDocs/OfflineSyncPlan.md)

### Error Handling Design

The original implementation used `URLError` classification to determine which errors should trigger offline fallback. This was **simplified in commit `e13aefe`** to use plain `catch` blocks — any API failure triggers offline save. The rationale:
- The networking stack separates transport errors from HTTP status errors
- Fine-grained URLError filtering was unnecessary and introduced maintenance burden
- All errors that reach the catch block indicate the server call failed, making offline save appropriate

**Related issues:** [AP-U1](./_OfflineSyncDocs/ActionPlans/AP-U1_OrgCipherErrorTiming.md), [AP-U2](./_OfflineSyncDocs/ActionPlans/AP-U2_InconsistentOfflineSupport.md), [AP-VR2](./_OfflineSyncDocs/ActionPlans/AP-VR2_DeleteConvertedToSoftDelete.md)
**Review section:** [ReviewSection_VaultRepository.md](./_OfflineSyncDocs/ReviewSection_VaultRepository.md)

---

## 7. OfflineSyncResolver Conflict Resolution Engine

**File:** `BitwardenShared/Core/Vault/Services/OfflineSyncResolver.swift` (new, 385 lines)

The core conflict resolution engine that processes pending offline changes when connectivity returns.

### 7a. OfflineSyncError Enum (line 9)

```swift
enum OfflineSyncError: LocalizedError {
    case missingCipherData
    case missingCipherId
    case vaultLocked
    case organizationCipherOfflineEditNotSupported
    case cipherNotFound
}
```

Five error types with `LocalizedError` conformance for user-facing messages. The `.cipherNotFound` case was added in commit `e929511` (RES-2 fix) to handle server 404 responses during conflict resolution.

### 7b. OfflineSyncResolver Protocol (line 40)

```swift
protocol OfflineSyncResolver {
    func processPendingChanges(userId: String) async throws
}
```

Single-method protocol following the existing service pattern.

### 7c. DefaultOfflineSyncResolver (line 55)

#### Dependencies (5) **[Updated]**

- `cipherAPIService` — fetches current server cipher for conflict comparison
- `cipherService` — adds/updates/soft-deletes ciphers locally and with server
- `clientService` — SDK encryption/decryption for conflict resolution
- ~~`folderService` — creates/finds the "Offline Sync Conflicts" folder~~ **[Removed]** — Conflict folder eliminated
- `pendingCipherChangeDataStore` — fetches and deletes resolved pending changes
- `stateService` — user state management

#### Constants

- `softConflictPasswordChangeThreshold: Int16 = 4` (line 60) — number of password changes that triggers a precautionary backup even without a server conflict

~~#### Cached State~~

~~- `conflictFolderId: String?` (line 83) — cached per resolution batch to avoid repeated folder lookups~~

**[Updated]** The `conflictFolderId` cached state has been removed along with the conflict folder feature.

### Resolution Flow

#### `processPendingChanges(userId:)` (line 115)

```swift
func processPendingChanges(userId: String) async throws {
    let pendingChanges = try await pendingCipherChangeDataStore.fetchPendingChanges(userId: userId)
    for pendingChange in pendingChanges {
        do {
            try await resolve(pendingChange: pendingChange, userId: userId)
        } catch {
            // Catch-and-continue: individual failures don't block other changes
        }
    }
}
```

**Design:** Uses catch-and-continue so that one failing change doesn't prevent resolving others. Unresolved changes remain in the store and are retried on the next sync.

#### `resolve(pendingChange:userId:)` (line 141)

Routes to the appropriate resolver based on `changeType`:
- `.create` → `resolveCreate()`
- `.update` → `resolveUpdate()`
- `.softDelete` → `resolveSoftDelete()`

#### `resolveCreate(pendingChange:userId:)` (line 157)

1. Decodes `cipherData` to `CipherDetailsResponseModel`
2. Calls `cipherService.addCipherWithServer()` to push to server
3. Deletes the pending change record

For creates, there is no conflict scenario — the cipher didn't exist on the server before.

#### `resolveUpdate(pendingChange:cipherId:userId:)` (line 173)

The most complex resolution path:

```
1. Decode local cipher from pending cipherData
2. Fetch current server cipher via cipherAPIService.getCipher()
3. Check for HARD CONFLICT:
   originalRevisionDate ≠ server.revisionDate?
   ├─ YES → resolveConflict() (timestamp-based winner)
   └─ NO → Check for SOFT CONFLICT:
           offlinePasswordChangeCount ≥ 4?
           ├─ YES → Backup server version, push local
           └─ NO → Push local version (no backup needed)
4. Delete pending change record
```

**Conflict detection** (line 192): The `originalRevisionDate` captured during the first offline edit is compared with the server's current `revisionDate`. If they differ, someone else edited the cipher on the server while the user was offline.

**Soft conflict** (line 199): Even without a server revision change, if the user made 4+ password changes offline, a backup is created as a safety measure. This protects against the edge case where password history (capped at 5 entries by Bitwarden) would lose intermediate passwords.

#### `resolveConflict(localCipher:serverCipher:pendingChange:userId:)` (line 222)

Timestamp-based winner determination:

```swift
let localTimestamp = pendingChange.updatedDate ?? pendingChange.createdDate ?? Date.distantPast
let serverTimestamp = serverCipher.revisionDate

if localTimestamp >= serverTimestamp {
    // Local wins: push local to server, backup server version
    try await cipherService.updateCipherWithServer(localCipher, ...)
    try await createBackupCipher(from: serverCipher, timestamp: serverTimestamp, userId: userId)
} else {
    // Server wins: keep server version, backup local version
    try await createBackupCipher(from: localCipher, timestamp: localTimestamp, userId: userId)
}
```

#### `resolveSoftDelete(pendingChange:cipherId:userId:)` (line 252)

1. Fetches current server cipher
2. Compares `originalRevisionDate` with server `revisionDate`
3. If conflict exists: creates backup of the server version before deleting
4. Calls `cipherService.softDeleteCipherWithServer()`
5. Deletes pending change record

#### `createBackupCipher(from:timestamp:userId:)` (line 293) **[Updated]**

Creates a backup copy for the losing side of a conflict:

1. Decrypts the cipher via SDK
2. Formats a timestamp string (`yyyy-MM-dd HH:mm:ss`)
3. Modifies the name: `"{original name} - {timestamp}"`
4. Creates the backup with `CipherView.update(name:)` (nullifies id, key, attachments; retains original folderId)
5. Encrypts and pushes to server via `addCipherWithServer()`

**[Updated]** The `getOrCreateConflictFolder()` step has been removed. Backup ciphers now retain the original cipher's folder assignment instead of being placed in a dedicated "Offline Sync Conflicts" folder.

#### ~~`getOrCreateConflictFolder()` (line 328)~~ **[Removed]**

~~Finds or creates the "Offline Sync Conflicts" folder.~~ This method and the entire conflict folder concept have been removed. Backup ciphers now retain their original folder assignment. This eliminates the `FolderService` dependency, the `conflictFolderId` cache, and the O(n) folder decryption lookup.

**Related issues:** [AP-RES1](./_OfflineSyncDocs/ActionPlans/AP-RES1_DuplicateCipherOnCreateRetry.md), [AP-RES7](./_OfflineSyncDocs/ActionPlans/AP-RES7_BackupCiphersLackAttachments.md), [AP-RES9](./_OfflineSyncDocs/ActionPlans/AP-RES9_ImplicitCipherDataContract.md), [AP-R2](./_OfflineSyncDocs/ActionPlans/AP-R2_ConflictFolderIdThreadSafety.md), [AP-R3](./_OfflineSyncDocs/ActionPlans/AP-R3_RetryBackoff.md), [AP-U4](./_OfflineSyncDocs/ActionPlans/AP-U4_EnglishOnlyConflictFolderName.md)
**Review section:** [ReviewSection_OfflineSyncResolver.md](./_OfflineSyncDocs/ReviewSection_OfflineSyncResolver.md)

---

## 8. SyncService Pre-Sync Resolution Integration

**File:** `BitwardenShared/Core/Vault/Services/SyncService.swift`
**Change type:** Modified (+27 / −1 lines)

### What Changed

The `fetchSync(forceSync:isPeriodic:)` method in `DefaultSyncService` was modified to resolve pending offline changes before proceeding with a normal server sync.

### New Dependencies

Two new properties added to `DefaultSyncService`:

- `offlineSyncResolver: OfflineSyncResolver` (line 157)
- `pendingCipherChangeDataStore: PendingCipherChangeDataStore` (line 163)

### Pre-Sync Resolution Logic (line 326)

Inserted at the beginning of `fetchSync()`, before the existing `needsSync` check:

```swift
// 1. Get user context
let account = try await stateService.getActiveAccount()
let userId = account.profile.userId

// 2. Check vault lock (new: computed once, reused below)
let isVaultLocked = await vaultTimeoutService.isLocked(userId: userId)

// 3. Resolve pending changes (only if vault unlocked)
if !isVaultLocked {
    try await offlineSyncResolver.processPendingChanges(userId: userId)
    let remainingCount = try await pendingCipherChangeDataStore.pendingChangeCount(userId: userId)
    if remainingCount > 0 {
        return  // ABORT: protect local offline edits
    }
}

// 4. Continue with normal sync (existing code)
guard try await needsSync(forceSync:, isPeriodic:, userId:) else { return }
```

### Design Decisions

**Vault lock check:** Resolution is skipped when the vault is locked because the SDK crypto context is needed for decryption during conflict resolution. The sync itself can still proceed (it replaces encrypted data without needing to decrypt).

**Early-abort pattern:** If `remainingCount > 0` after resolution, the sync aborts entirely. This prevents `replaceCiphers()` from overwriting locally-stored offline edits with stale server state. The pending changes will be retried on the next sync attempt.

**Optimization:** The `isVaultLocked` result is computed once and reused for the existing `organizationService.initializeOrganizationCrypto()` guard (line 353), eliminating a redundant async call.

**Related issues:** [AP-R4](./_OfflineSyncDocs/ActionPlans/AP-R4_SilentSyncAbort.md), [AP-SS2](./_OfflineSyncDocs/ActionPlans/AP-SS2_TOCTOURaceCondition.md)
**Review section:** [ReviewSection_SyncService.md](./_OfflineSyncDocs/ReviewSection_SyncService.md)

---

## 9. Dependency Injection Wiring

### 9a. Services.swift

**File:** `BitwardenShared/Core/Platform/Services/Services.swift`
**Change type:** Modified (+16 lines)

Two new `Has*` protocols added in alphabetical order within the `Services` typealias:

```swift
typealias Services = ...
    & HasOfflineSyncResolver
    & HasPendingCipherChangeDataStore
    & ...
```

Each protocol provides a single property:

```swift
protocol HasOfflineSyncResolver {
    var offlineSyncResolver: OfflineSyncResolver { get }
}

protocol HasPendingCipherChangeDataStore {
    var pendingCipherChangeDataStore: PendingCipherChangeDataStore { get }
}
```

This follows the existing `Has*` protocol pattern used by all services in the project.

### 9b. ServiceContainer.swift

**File:** `BitwardenShared/Core/Platform/Services/ServiceContainer.swift`
**Change type:** Modified (+28 lines)

Two new stored properties added:

```swift
let offlineSyncResolver: OfflineSyncResolver       // line 134
let pendingCipherChangeDataStore: PendingCipherChangeDataStore  // line 143
```

Both are wired in the `defaultServices()` factory method with proper initialization:
- `pendingCipherChangeDataStore` is set to `dataStore` (since `DataStore` conforms via extension)
- `offlineSyncResolver` is initialized as `DefaultOfflineSyncResolver(...)` with all required dependencies
- Both are passed to `DefaultSyncService` and `DefaultVaultRepository` initializers

### 9c. DataStore.swift Cleanup

**File:** `BitwardenShared/Core/Platform/Services/Stores/DataStore.swift`
**Change type:** Modified (+1 line)

Added `PendingCipherChangeData` to the user data cleanup in `deleteDataForUser()`:

```swift
func deleteDataForUser(userId: String) async throws {
    // ... existing deletes ...
    try executeBatchDelete(PendingCipherChangeData.deleteByUserIdRequest(userId: userId))
}
```

This ensures pending changes are cleaned up when a user logs out or their data is deleted.

### 9d. ServiceContainer+Mocks.swift

**File:** `BitwardenShared/Core/Platform/Services/TestHelpers/ServiceContainer+Mocks.swift`
**Change type:** Modified (+4 lines)

Two new parameters added to `withMocks()`:

```swift
static func withMocks(
    // ... existing parameters ...
    offlineSyncResolver: OfflineSyncResolver = MockOfflineSyncResolver(),
    pendingCipherChangeDataStore: PendingCipherChangeDataStore = MockPendingCipherChangeDataStore(),
    // ... existing parameters ...
)
```

**Related issues:** [AP-DI1](./_OfflineSyncDocs/ActionPlans/AP-DI1_DataStoreExposedToUILayer.md)
**Review section:** [ReviewSection_DIWiring.md](./_OfflineSyncDocs/ReviewSection_DIWiring.md)

---

## 10. Test Coverage: PendingCipherChangeDataStoreTests

**File:** `BitwardenShared/Core/Vault/Services/Stores/PendingCipherChangeDataStoreTests.swift` (new, 286 lines)

Tests the Core Data persistence layer for pending cipher changes. Uses a real in-memory `DataStore` (`.memory` store type) rather than mocks.

| Test | What It Verifies |
|------|-----------------|
| `test_fetchPendingChanges_empty` | Empty results for user with no changes |
| `test_fetchPendingChanges_returnsUserChanges` | Multi-user isolation — only returns changes for the specified userId |
| `test_fetchPendingChange_byId` | Single-cipher lookup by cipherId+userId; returns nil for non-existent |
| `test_upsertPendingChange_insert` | INSERT: all fields persisted correctly (id, dates, changeType, cipherData, count) |
| `test_upsertPendingChange_update` | UPSERT: updates data and count but **preserves originalRevisionDate** |
| `test_deletePendingChange_byId` | Deletion by record ID |
| `test_deletePendingChange_byCipherId` | Deletion by cipherId+userId preserves other records |
| `test_deleteAllPendingChanges` | Bulk delete per user without affecting other users |
| `test_pendingChangeCount` | Count accuracy with multi-user isolation |

**Key assertion in upsert test:** The `originalRevisionDate` from the first insert is preserved after the second upsert — this is critical for correct conflict detection.

---

## 11. Test Coverage: CipherViewOfflineSyncTests

**File:** `BitwardenShared/Core/Vault/Extensions/CipherViewOfflineSyncTests.swift` (new, 128 lines)

Tests the cipher extension helpers used for offline sync operations.

| Test | What It Verifies |
|------|-----------------|
| ~~`test_withTemporaryId_setsNewId`~~ → `test_withId_setsId` | ID correctly assigned to cipher view |
| ~~`test_withTemporaryId_preservesOtherProperties`~~ → `test_withId_preservesOtherProperties` | Key properties preserved during ID assignment |
| (New) `test_withId_replacesExistingId` | Can replace an existing non-nil ID |
| ~~`test_update_setsNameAndFolderId`~~ → `test_update_setsName` | Name correctly updated for backup copies (folderId retained from original) |
| `test_update_setsIdToNil` | Backup cipher has nil ID (server assigns new) |
| `test_update_setsKeyToNil` | Backup cipher has nil key (SDK generates fresh) |
| `test_update_setsAttachmentsToNil` | Attachments excluded from backup copies |
| `test_update_preservesPasswordHistory` | Password history preserved in backup copies |

These are pure model unit tests with no mock dependencies.

---

## 12. Test Coverage: VaultRepositoryTests Offline Fallback

**File:** `BitwardenShared/Core/Vault/Repositories/VaultRepositoryTests.swift`
**Change type:** Modified (+132 lines, 8 new test functions)

Tests the offline fallback behavior in `VaultRepository` for all four CRUD operations. Each operation has two tests: one for personal ciphers (success path) and one for organization ciphers (rejection path).

| Test | Operation | Cipher Type | Expected Behavior |
|------|-----------|-------------|-------------------|
| `test_addCipher_offlineFallback` | Create | Personal | Local save + `.create` pending change |
| `test_addCipher_offlineFallback_orgCipher_throws` | Create | Organization | Throws `organizationCipherOfflineEditNotSupported` |
| `test_deleteCipher_offlineFallback` | Delete | Personal | Local delete + `.softDelete` pending change |
| `test_deleteCipher_offlineFallback_orgCipher_throws` | Delete | Organization | Throws `organizationCipherOfflineEditNotSupported` |
| `test_updateCipher_offlineFallback` | Update | Personal | Local update + `.update` pending change |
| `test_updateCipher_offlineFallback_orgCipher_throws` | Update | Organization | Throws `organizationCipherOfflineEditNotSupported` |
| `test_softDeleteCipher_offlineFallback` | Soft Delete | Personal | Local update + `.softDelete` pending change |
| `test_softDeleteCipher_offlineFallback_orgCipher_throws` | Soft Delete | Organization | Throws `organizationCipherOfflineEditNotSupported` |

All tests trigger the offline path by configuring `MockCipherService` to throw `URLError(.notConnectedToInternet)` for the server API call.

---

## 13. Test Coverage: OfflineSyncResolverTests

**File:** `BitwardenShared/Core/Vault/Services/OfflineSyncResolverTests.swift` (new, 589 lines)

Comprehensive tests for the conflict resolution engine. Includes a custom `MockCipherAPIServiceForOfflineSync` that provides a minimal mock for `getCipher(withId:)`.

| Test | Scenario |
|------|----------|
| `test_processPendingChanges_noPendingChanges` | Empty queue — graceful no-op |
| `test_processPendingChanges_create` | Create: pushes to server, deletes record |
| `test_processPendingChanges_update_noConflict` | Update: no revision mismatch → push local |
| `test_processPendingChanges_softDelete_noConflict` | Soft delete: no conflict → complete delete |
| `test_processPendingChanges_update_conflict_localNewer` | Conflict: local timestamp wins → push local, backup server |
| `test_processPendingChanges_update_conflict_serverNewer` | Conflict: server timestamp wins → keep server, backup local |
| `test_processPendingChanges_update_softConflict` | Soft conflict: 4+ password changes → push local, backup server |
| `test_processPendingChanges_softDelete_conflict` | Soft delete conflict: backup server before deleting |
| ~~`test_processPendingChanges_update_conflict_createsConflictFolder`~~ | ~~Verifies "Offline Sync Conflicts" folder creation~~ **[Removed]** — Conflict folder eliminated |
| `test_processPendingChanges_update_cipherNotFound_recreates` | Update where server returns 404 — re-creates cipher on server |
| `test_processPendingChanges_softDelete_cipherNotFound_cleansUp` | Soft delete where server returns 404 — cleans up locally |
| `test_offlineSyncError_localizedDescription` | Error message for org cipher restriction |
| `test_offlineSyncError_vaultLocked_localizedDescription` | Error message for vault locked state |

**Notable test patterns:**
- Conflict detection tested with matching vs. mismatching `revisionDate` values
- Timestamp-based winner determination tested with explicit past/future dates
- Soft conflict threshold tested with `offlinePasswordChangeCount = 4`
- Mock call tracking verifies correct API methods called (add vs. update vs. softDelete)

---

## 14. Test Coverage: SyncServiceTests Pre-Sync Resolution

**File:** `BitwardenShared/Core/Vault/Services/SyncServiceTests.swift`
**Change type:** Modified (+66 lines, 4 new test functions)

Tests the pre-sync resolution integration in `fetchSync()`.

| Test | Scenario | Key Assertion |
|------|----------|---------------|
| `test_fetchSync_preSyncResolution_triggersPendingChanges` | Normal flow | `processPendingChanges` called, sync proceeds |
| `test_fetchSync_preSyncResolution_skipsWhenVaultLocked` | Vault locked | `processPendingChanges` NOT called, sync proceeds |
| `test_fetchSync_preSyncResolution_noPendingChanges` | Empty queue | Resolver called (handles empty internally), sync proceeds |
| `test_fetchSync_preSyncResolution_abortsWhenPendingChangesRemain` | Unresolved changes | Sync ABORTED — no HTTP request made |

The abort test is the most critical — it verifies that `replaceCiphers()` is never called when pending changes remain, preventing data loss.

---

## 15. Test Helpers: Mocks

### MockPendingCipherChangeDataStore

**File:** `BitwardenShared/Core/Vault/Services/Stores/TestHelpers/MockPendingCipherChangeDataStore.swift` (new, 72 lines)

Full mock implementation of `PendingCipherChangeDataStore` with:
- **Result properties**: Configurable return values for each method (e.g., `fetchPendingChangesResult`, `pendingChangeCountResult`)
- **Call tracking arrays**: Records all calls with parameters (e.g., `upsertPendingChangeCalledWith`, `deletePendingChangeByIdCalledWith`)

### MockOfflineSyncResolver

**File:** `BitwardenShared/Core/Vault/Services/TestHelpers/MockOfflineSyncResolver.swift` (new, 11 lines)

Minimal mock of `OfflineSyncResolver` with:
- `processPendingChangesCalledWith: [String]` — tracks userId parameters
- `processPendingChangesResult: Result<Void, Error>` — controls success/failure

Both mocks are injected via `ServiceContainer.withMocks()` as default parameters.

---

## 16. Post-Implementation Fixes

Three follow-up commits addressed issues identified during code review:

### Commit `e13aefe`: Simplify Error Handling

**Removed:** `URLError+NetworkConnection.swift` and its tests — an extension that classified 10 `URLError` codes as "network connection errors."

**Changed:** `VaultRepository` offline handlers now use plain `catch` blocks instead of `catch let error as URLError where error.isNetworkConnectionError`.

**Rationale:** The distinction was unnecessary. Any error reaching the catch block means the server call failed, making offline save the correct response regardless of error type. This also resolved three action plan issues:
- [AP-SEC1](./_OfflineSyncDocs/ActionPlans/Resolved/AP-SEC1_SecureConnectionFailedClassification.md) — TLS failures triggering offline save (superseded)
- [AP-EXT1](./_OfflineSyncDocs/ActionPlans/Resolved/AP-EXT1_TimedOutClassification.md) — Timeout errors too broad (superseded)
- [AP-T6](./_OfflineSyncDocs/ActionPlans/Resolved/AP-T6_IncompleteURLErrorTestCoverage.md) — Incomplete URLError test coverage (resolved by deletion)

### Commit `a52d379`: Remove Unused Dependencies

**Removed:** `timeProvider` dependency from `DefaultOfflineSyncResolver` — it was injected but never used (timestamp formatting uses `Date()` directly).

**Removed:** A stray blank line in `Services.swift`.

This resolved [AP-A3](./_OfflineSyncDocs/ActionPlans/Resolved/AP-A3_UnusedTimeProvider.md) and [AP-CS1](./_OfflineSyncDocs/ActionPlans/Resolved/AP-CS1_StrayBlankLine.md).

### Commits `a90ff46` & `f626ab4`: Documentation Cleanup

Updated documentation to reflect the resolved issues and moved resolved/superseded action plans to a `Resolved/` subdirectory.

### PR #26 (Commit `207065c`): Fix 5xx HTTP Errors Not Triggering Offline Save

5xx HTTP errors (e.g., 502 Bad Gateway from CDN) threw `ResponseValidationError` which wasn't caught. Switched from URLError allowlist to denylist pattern: catch all errors by default, only rethrow `ServerError` and `ResponseValidationError` with statusCode < 500.

### PR #27 (Commits `481ddc4`, `578a366`): Close Test Coverage Gap

Added tests for URLError propagation through `CipherService`/`APIService`/`HTTPService` chain, network error alert tests in processors, and non-network error rethrow tests for offline sync catch blocks.

### PR #28 (Commit `7ff2fd8`): Rethrow CipherAPIServiceError

Added `CipherAPIServiceError` to the rethrow list in offline fallback catch blocks — client-side validation errors should propagate, not trigger offline save.

### PR #29 (Commit `266bffa`): ~~Fix Conflict Folder Encryption~~ **[Superseded]**

~~`getOrCreateConflictFolder()` was passing plaintext "Offline Sync Conflicts" to `addFolderWithServer(name:)`. Fixed by encrypting via `clientService.vault().folders().encrypt()` before sending. The original code caused a Rust panic when the SDK tried to decrypt plaintext as ciphertext.~~

**[Updated]** This fix is no longer applicable — the conflict folder feature and `getOrCreateConflictFolder()` method have been removed entirely. Backup ciphers now retain the original cipher's folder assignment.

### PR #31 (Commits `86b9104`, `01070eb`): VI-1 ~~Mitigation~~ Resolution — Direct Fetch Fallback

~~Mitigated~~ Addressed the VI-1 infinite spinner bug via a UI-level fallback in `ViewItemProcessor`:
1. Extracted `buildViewItemState(from:)` helper from existing `buildState(for:)`
2. Added `fetchCipherDetailsDirectly()` fallback when publisher stream fails
3. On decrypt failure: catches error → calls fallback → shows item or error message (not spinner)

~~**Note:** This mitigates the symptom but the root cause remains — `Cipher.withTemporaryId()` still sets `data: nil`.~~ **[UPDATE]** Root cause subsequently fixed by `CipherView.withId()` (commit `3f7240a`). The `data: nil` problem no longer exists. This fallback remains as defense-in-depth.

### Commit `93143f1`: Reorder Conflict Resolution — Backup Before Push

Reordered the conflict resolution logic in `DefaultOfflineSyncResolver` so that backup ciphers are always created *before* the destructive push/update operation. Previously, the backup was created after the push — if backup creation failed (e.g., network error during `addCipherWithServer` for the backup), the losing version would already be overwritten on the server with no recovery.

Three code paths changed in `OfflineSyncResolver.swift`:
1. **`resolveConflict` — local wins**: Backup of server version now created before `updateCipherWithServer` pushes local version
2. **`resolveConflict` — server wins**: Backup of local version now created before `updateCipherWithLocalStorage` overwrites local
3. **`resolveUpdate` — soft conflict**: Backup of server version now created before `updateCipherWithServer` pushes local version

### Commit `e929511`: Handle Server 404 in resolveUpdate and resolveSoftDelete (RES-2)

Added handling for the case where `cipherAPIService.getCipher(withId:)` returns a 404 (cipher deleted on server while user was offline). Previously, this error propagated unhandled, leaving the pending change stuck and blocking all future syncs via the early-abort in `SyncService.fetchSync`.

Changes:
1. **`OfflineSyncError.cipherNotFound`** — New error case for 404 responses
2. **`GetCipherRequest.validate(_:)`** — New validation method (following `CheckLoginRequestRequest` pattern) that intercepts 404 before `ResponseValidationHandler` processes the response
3. **`resolveUpdate` 404 handling** — Re-creates the cipher on the server via `addCipherWithServer`, preserving the user's offline edits
4. **`resolveSoftDelete` 404 handling** — Cleans up local cipher record and pending change (user's delete intent already satisfied)
5. **Two new tests** — `test_processPendingChanges_update_cipherNotFound_recreates` and `test_processPendingChanges_softDelete_cipherNotFound_cleansUp`

### Commit `dd3bc38`: Orphaned Pending Change Cleanup

After successful online operations, orphaned pending change records from prior offline attempts are cleaned up. Added count check in `SyncService` so the common case (no pending changes) skips `processPendingChanges()`.

### PR #33 (Commit `a10fe15`): Test userId Fix

Fixed test assertion from `"1"` to `"13512467-9cfe-43b0-969f-07534084764b"` to match `fixtureAccountLogin()`.

---

## 17. Documentation Artifacts

The implementation includes extensive documentation in `_OfflineSyncDocs/`:

### Planning Documents

| Document | Description |
|----------|-------------|
| [OfflineSyncPlan.md](./_OfflineSyncDocs/OfflineSyncPlan.md) | Full implementation plan with architecture, security considerations, and phased approach |

### Code Review Documents

| Document | Description |
|----------|-------------|
| [OfflineSyncCodeReview.md](./_OfflineSyncDocs/OfflineSyncCodeReview.md) | Comprehensive review: 30 findings across architecture, security, test coverage, and UX |
| [ReviewSection_DIWiring.md](./_OfflineSyncDocs/ReviewSection_DIWiring.md) | Detailed review of dependency injection changes |
| [ReviewSection_OfflineSyncResolver.md](./_OfflineSyncDocs/ReviewSection_OfflineSyncResolver.md) | Detailed review of conflict resolution engine |
| [ReviewSection_PendingCipherChangeDataStore.md](./_OfflineSyncDocs/ReviewSection_PendingCipherChangeDataStore.md) | Detailed review of data persistence layer |
| [ReviewSection_SupportingExtensions.md](./_OfflineSyncDocs/ReviewSection_SupportingExtensions.md) | Detailed review of cipher extension helpers |
| [ReviewSection_SyncService.md](./_OfflineSyncDocs/ReviewSection_SyncService.md) | Detailed review of sync integration |
| [ReviewSection_VaultRepository.md](./_OfflineSyncDocs/ReviewSection_VaultRepository.md) | Detailed review of offline fallback handlers |

### Action Plans (22 Active + 7 Resolved + 1 Superseded)

**Phase 1 — Must-Address (Test Gaps):**

| ID | Title | Priority |
|----|-------|----------|
| [S3](./_OfflineSyncDocs/ActionPlans/AP-S3_BatchProcessingTest.md) | No batch processing test with mixed success/failure | High |
| [S4](./_OfflineSyncDocs/ActionPlans/AP-S4_APIFailureDuringResolutionTest.md) | No API failure during resolution test | High |

**Phase 2 — Should-Address:**

| ID | Title | Priority |
|----|-------|----------|
| ~~[VI-1](./_OfflineSyncDocs/ActionPlans/AP-VI1_OfflineCreatedCipherViewFailure.md)~~ | ~~Offline-created cipher view failure~~ — **[Resolved]** Root cause fixed by `CipherView.withId()` (commit `3f7240a`); all 5 recommended fixes implemented in Phase 2 | ~~Medium~~ N/A |
| [S6](./_OfflineSyncDocs/ActionPlans/AP-S6_PasswordChangeCountingTest.md) | No password change counting test | Medium |
| [S7](./_OfflineSyncDocs/ActionPlans/Resolved/AP-S7_CipherNotFoundPathTest.md) | No cipher-not-found path test — **Partially Resolved** (resolver-level tests added; VaultRepository gap remains) | Medium |
| [S8](./_OfflineSyncDocs/ActionPlans/AP-S8_FeatureFlag.md) | No feature flag for remote disable | Medium |
| [R4](./_OfflineSyncDocs/ActionPlans/AP-R4_SilentSyncAbort.md) | Silent sync abort (no logging) | Medium |

**Phase 3 — Nice-to-Have:**

| ID | Title | Priority |
|----|-------|----------|
| ~~[R2](./_OfflineSyncDocs/ActionPlans/AP-R2_ConflictFolderIdThreadSafety.md)~~ | ~~`conflictFolderId` thread safety~~ — **[Resolved]** `DefaultOfflineSyncResolver` converted from `class` to `actor` | ~~Low~~ N/A |
| [R3](./_OfflineSyncDocs/ActionPlans/AP-R3_RetryBackoff.md) | No retry backoff for permanently failing items | Low |
| [R1](./_OfflineSyncDocs/ActionPlans/AP-R1_DataFormatVersioning.md) | No data format versioning | Low |
| [CS-2](./_OfflineSyncDocs/ActionPlans/AP-CS2_FragileSDKCopyMethods.md) | Fragile SDK copy methods | Low |
| [T5](./_OfflineSyncDocs/ActionPlans/AP-T5_InlineMockFragility.md) | Inline mock fragility | Low |
| ~~[T7](./_OfflineSyncDocs/ActionPlans/Resolved/AP-T7_SubsequentOfflineEditTest.md)~~ | ~~No subsequent offline edit test~~ **[Resolved]** — See Resolved/Superseded table below | ~~Low~~ |
| [T8](./_OfflineSyncDocs/ActionPlans/AP-T8_HardErrorInPreSyncResolution.md) | No hard error in pre-sync resolution test | Low |
| [DI-1](./_OfflineSyncDocs/ActionPlans/AP-DI1_DataStoreExposedToUILayer.md) | DataStore exposed to UI layer | Low |

**Phase 4 — Accept/Future:**

| ID | Title | Priority |
|----|-------|----------|
| [U1](./_OfflineSyncDocs/ActionPlans/AP-U1_OrgCipherErrorTiming.md) | Org cipher error after timeout | Informational |
| [U2](./_OfflineSyncDocs/ActionPlans/AP-U2_InconsistentOfflineSupport.md) | Inconsistent offline support (archive, etc.) | Informational |
| [U3](./_OfflineSyncDocs/ActionPlans/AP-U3_NoPendingChangesIndicator.md) | No pending changes UI indicator | Informational |
| ~~[U4](./_OfflineSyncDocs/ActionPlans/AP-U4_EnglishOnlyConflictFolderName.md)~~ | ~~English-only conflict folder name~~ — **[Superseded]** Conflict folder removed | ~~Informational~~ N/A |
| [VR-2](./_OfflineSyncDocs/ActionPlans/AP-VR2_DeleteConvertedToSoftDelete.md) | Permanent delete → soft delete conversion | Informational |
| [RES-1](./_OfflineSyncDocs/ActionPlans/AP-RES1_DuplicateCipherOnCreateRetry.md) | Potential duplicate on create retry | Informational |
| [RES-7](./_OfflineSyncDocs/ActionPlans/AP-RES7_BackupCiphersLackAttachments.md) | Backup ciphers lack attachments | Informational |
| [RES-9](./_OfflineSyncDocs/ActionPlans/AP-RES9_ImplicitCipherDataContract.md) | Implicit cipherData contract for soft delete | Informational |
| [PCDS-1](./_OfflineSyncDocs/ActionPlans/AP-PCDS1_IdOptionalRequiredMismatch.md) | id optional/required mismatch | Informational |
| [PCDS-2](./_OfflineSyncDocs/ActionPlans/AP-PCDS2_DatesOptionalButAlwaysSet.md) | Dates optional but always set | Informational |
| [SS-2](./_OfflineSyncDocs/ActionPlans/AP-SS2_TOCTOURaceCondition.md) | TOCTOU race condition | Informational |

**Resolved/Superseded:**

| ID | Title | Resolution |
|----|-------|------------|
| [A3](./_OfflineSyncDocs/ActionPlans/Resolved/AP-A3_UnusedTimeProvider.md) | Unused timeProvider | Removed in `a52d379` |
| [CS-1](./_OfflineSyncDocs/ActionPlans/Resolved/AP-CS1_StrayBlankLine.md) | Stray blank line | Removed in `a52d379` |
| [SEC-1](./_OfflineSyncDocs/ActionPlans/Resolved/AP-SEC1_SecureConnectionFailedClassification.md) | TLS failure classification | Superseded by URLError removal |
| [EXT-1](./_OfflineSyncDocs/ActionPlans/Resolved/AP-EXT1_TimedOutClassification.md) | Timeout classification | Superseded by URLError removal |
| [T6](./_OfflineSyncDocs/ActionPlans/Resolved/AP-T6_IncompleteURLErrorTestCoverage.md) | URLError test coverage | Resolved by deletion |
| [S7](./_OfflineSyncDocs/ActionPlans/Resolved/AP-S7_CipherNotFoundPathTest.md) | Cipher-not-found path test | **Partially Resolved** — resolver-level 404 tests added (commit `e929511`); VaultRepository-level `handleOfflineDelete` guard clause test gap remains |
| [T7](./_OfflineSyncDocs/ActionPlans/Resolved/AP-T7_SubsequentOfflineEditTest.md) | Subsequent offline edit test | **Resolved** — Covered by `test_updateCipher_offlineFallback_preservesCreateType` (Phase 2, commit `12cb225`) |
| [VI-1](./_OfflineSyncDocs/ActionPlans/AP-VI1_OfflineCreatedCipherViewFailure.md) | Offline-created cipher view failure | **Resolved** — spinner fixed via UI fallback (PR #31); root cause (`data: nil`) **fixed** by `CipherView.withId()` (commit `3f7240a`); all 5 recommended fixes implemented in Phase 2 |

**Superseded:**

| ID | Title | Resolution |
|----|-------|------------|
| [URLError Review](ActionPlans/Superseded/AP-URLError_NetworkConnectionReview.md) | URLError+NetworkConnection extension review | **Superseded** — File deleted in commit `e13aefe`; historical review preserved |

**Cross-reference:** [AP-00_CrossReferenceMatrix.md](./_OfflineSyncDocs/ActionPlans/AP-00_CrossReferenceMatrix.md), [AP-00_OverallRecommendations.md](./_OfflineSyncDocs/ActionPlans/AP-00_OverallRecommendations.md)

---

## File Index

### New Files (13 source + 40 docs)

| File | Lines | Purpose |
|------|-------|---------|
| `Core/Vault/Extensions/CipherView+OfflineSync.swift` | 95 | Cipher copy helpers |
| `Core/Vault/Extensions/CipherViewOfflineSyncTests.swift` | 128 | Extension tests |
| `Core/Vault/Models/Data/PendingCipherChangeData.swift` | 192 | Core Data entity |
| `Core/Vault/Services/OfflineSyncResolver.swift` | 385 | Conflict resolution engine |
| `Core/Vault/Services/OfflineSyncResolverTests.swift` | 589 | Resolver tests |
| `Core/Vault/Services/Stores/PendingCipherChangeDataStore.swift` | 155 | Data store protocol + impl |
| `Core/Vault/Services/Stores/PendingCipherChangeDataStoreTests.swift` | 286 | Data store tests |
| `Core/Vault/Services/Stores/TestHelpers/MockPendingCipherChangeDataStore.swift` | 72 | Data store mock |
| `Core/Vault/Services/TestHelpers/MockOfflineSyncResolver.swift` | 11 | Resolver mock |

### Modified Files (8)

| File | Added | Removed | Purpose |
|------|-------|---------|---------|
| `Core/Platform/Services/ServiceContainer.swift` | +28 | 0 | DI container wiring |
| `Core/Platform/Services/Services.swift` | +16 | 0 | Has* protocol declarations |
| `Core/Platform/Services/Stores/DataStore.swift` | +1 | 0 | User data cleanup |
| `Core/Platform/Services/TestHelpers/ServiceContainer+Mocks.swift` | +4 | 0 | Mock defaults |
| `Core/Vault/Repositories/VaultRepository.swift` | +213 | −10 | Offline fallback handlers |
| `Core/Vault/Repositories/VaultRepositoryTests.swift` | +132 | 0 | Offline fallback tests |
| `Core/Vault/Services/SyncService.swift` | +27 | −1 | Pre-sync resolution |
| `Core/Vault/Services/SyncServiceTests.swift` | +66 | 0 | Pre-sync tests |
| `Bitwarden.xcdatamodel/contents` | +17 | 0 | Core Data entity |
