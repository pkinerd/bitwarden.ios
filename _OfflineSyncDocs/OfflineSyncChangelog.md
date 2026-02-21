# Offline Sync for Vault Cipher Operations — Detailed Changelog

> **Reconciliation Note (2026-02-21):** This changelog has been reviewed against the actual codebase
> and corrected for accuracy. Inline annotations marked `[Corrected 2026-02-21]` indicate places
> where the original changelog text diverged from the final implementation. Key corrections:
> 1. `HasPendingCipherChangeDataStore` is NOT in the `Services` typealias -- only `HasOfflineSyncResolver` is; the data store is passed directly via initializers.
> 2. `changeTypeRaw` Core Data type changed from `Integer 16` to `String` (optional); `PendingCipherChangeType` raw type changed from `Int16` to `String`. `offlinePasswordChangeCount` changed from `Integer 16` to `Integer 64` (`Int64`).
> 3. `DefaultOfflineSyncResolver` has 4 dependencies (not 5) -- `stateService` was removed.
> 4. Test counts updated: ~119 offline sync tests across 7 test files (previously understated).

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
│   ├─ .softDelete → no conflict: soft delete on server          │
│   │                conflict: restore server version locally     │
│   └─ .hardDelete → no conflict: permanent delete on server     │
│                    conflict: restore server version locally     │
│   Backup → retains original cipher's folder assignment         │
└─────────────────────────────────────────────────────────────────┘
```

### Data Flow

1. **Offline edit** → `VaultRepository` catches API failure → persists cipher locally + queues `PendingCipherChangeData`
2. **Reconnect sync** → `SyncService.fetchSync()` → `OfflineSyncResolver.processPendingChanges()` → resolves each pending change against server
3. **Conflict** → backup cipher created (retains original folder) → winner version pushed to server
4. **All resolved** → normal sync proceeds with `replaceCiphers()`

**Related documents:**
- [OfflineSyncPlan.md](./OfflineSyncPlan.md) — Full implementation plan
- [OfflineSyncCodeReview.md](./OfflineSyncCodeReview.md) — Comprehensive code review

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
| `changeTypeRaw` | Integer 16 | Yes | `0` | Enum: `0` = update, `1` = create, `2` = softDelete, `3` = hardDelete | **[Corrected 2026-02-21]** Final type is `String` (optional). The enum `PendingCipherChangeType` uses `String` raw values (not `Int16`). See resolved issues CD-TYPE-1 and CD-TYPE-2.
| `cipherData` | Binary | No | — | JSON-encoded encrypted `CipherDetailsResponseModel` |
| `originalRevisionDate` | Date | No | — | Server `revisionDate` at time of first offline edit |
| `createdDate` | Date | No | — | Timestamp of first queued change |
| `updatedDate` | Date | No | — | Timestamp of most recent update to this record |
| `offlinePasswordChangeCount` | Integer 16 | Yes | `0` | Number of password changes while offline | **[Corrected 2026-02-21]** Final type is `Integer 64` (`Int64` in Swift). See resolved issue CD-TYPE-2.

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

**Related issues:** [AP-PCDS1](./ActionPlans/AP-PCDS1_IdOptionalRequiredMismatch.md), [AP-PCDS2](./ActionPlans/AP-PCDS2_DatesOptionalButAlwaysSet.md), [AP-R1](./ActionPlans/AP-R1_DataFormatVersioning.md)
**Review section:** [ReviewSection_PendingCipherChangeDataStore.md](./ReviewSection_PendingCipherChangeDataStore.md)

---

## 4. PendingCipherChangeData Model & PendingCipherChangeDataStore

### 4a. PendingCipherChangeData NSManagedObject

**File:** `BitwardenShared/Core/Vault/Models/Data/PendingCipherChangeData.swift` (new, 193 lines)

#### PendingCipherChangeType Enum (line 8)

```swift
// [Corrected 2026-02-21] Original changelog showed Int16 raw type with numeric values.
// Final implementation uses String raw type. See resolved issues CD-TYPE-1 and CD-TYPE-2.
enum PendingCipherChangeType: String {
    case update
    case create
    case softDelete
    case hardDelete
}
```

Four change types representing the operations a user can perform on vault items. `hardDelete` distinguishes permanent delete intent from soft delete so the resolver can call the correct server API. **[Corrected 2026-02-21]** The raw type was changed from `Int16` (with numeric values 0-3) to `String` (with implicit string values matching the case names). The Core Data attribute `changeTypeRaw` is stored as an optional `String` rather than `Integer 16`.

#### NSManagedObject Subclass (line 27)

The `PendingCipherChangeData` class uses `@NSManaged` properties matching the Core Data schema. Key details:

- **Computed `changeType` property** (line 60): Converts between raw `String?` and the `PendingCipherChangeType` enum. **[Corrected 2026-02-21]** Originally documented as `Int16`; final implementation uses `String?` (`changeTypeRaw` is an optional String, resolved via `flatMap(PendingCipherChangeType.init(rawValue:))` with a fallback to `.update`).
- **Convenience initializer** (line 83): Sets `id = UUID().uuidString`, `createdDate` and `updatedDate` to current time.
- **Static predicate helpers** (lines 108–142): `userIdPredicate`, `userIdAndCipherIdPredicate`, `idPredicate` — used by fetch/delete requests.
- **Static fetch request helpers** (lines 144–180): `fetchByUserIdRequest` (sorted by `createdDate` ascending), `fetchByCipherIdRequest`, `fetchByIdRequest`.
- **Static delete helper** (line 187): `deleteByUserIdRequest` for batch cleanup on logout.

### 4b. PendingCipherChangeDataStore

**File:** `BitwardenShared/Core/Vault/Services/Stores/PendingCipherChangeDataStore.swift` (new, 156 lines)

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
    try await backgroundContext.performAndSave {
        let existing = try self.backgroundContext.fetch(fetchByCipherId).first
        if let existing {
            // UPDATE: preserves originalRevisionDate, updates data & count
            existing.cipherData = cipherData
            existing.changeTypeRaw = changeType.rawValue
            existing.updatedDate = Date()
            existing.offlinePasswordChangeCount = offlinePasswordChangeCount
            // Do NOT overwrite originalRevisionDate
        } else {
            // INSERT: creates new record with all fields
            _ = PendingCipherChangeData(context:, cipherId:, userId:, ...)
        }
    }
}
```

The upsert **intentionally preserves `originalRevisionDate`** on update — this is the server revision date captured on the first offline edit and serves as the baseline for conflict detection. Overwriting it on subsequent edits would make conflict detection unreliable.

**Related issues:** [AP-PCDS1](./ActionPlans/AP-PCDS1_IdOptionalRequiredMismatch.md), [AP-PCDS2](./ActionPlans/AP-PCDS2_DatesOptionalButAlwaysSet.md)
**Review section:** [ReviewSection_PendingCipherChangeDataStore.md](./ReviewSection_PendingCipherChangeDataStore.md)

---

## 5. CipherView+OfflineSync Extension Helpers

**File:** `BitwardenShared/Core/Vault/Extensions/CipherView+OfflineSync.swift` (new, 105 lines)

Two public extension methods on `CipherView` support offline sync operations by creating modified copies. Both delegate to a single private `makeCopy(id:key:name:attachments:attachmentDecryptionFailures:)` helper (line 66) so that the full `CipherView` initializer is called in exactly one place within the file.

### 5a. ~~`Cipher.withTemporaryId(_:)`~~ → `CipherView.withId(_:)` **[Replaced]**

~~`Cipher.withTemporaryId()` operated after encryption and set `data: nil`, causing the VI-1 bug.~~ **[RESOLVED]** Replaced by `CipherView.withId()` (commit `3f7240a`) which operates **before** encryption. The ID is baked into the encrypted content, so it survives the decrypt round-trip without special handling. Called by `addCipher()` (not `handleOfflineAdd()`) to assign a temporary client-generated UUID before the encrypt step.

```swift
extension CipherView {
    func withId(_ id: String) -> CipherView {
        makeCopy(
            id: id,
            key: key,
            name: name,
            attachments: attachments,
            attachmentDecryptionFailures: attachmentDecryptionFailures
        )
    }
}
```

### 5b. `CipherView.update(name:)` (line 34) **[Updated]**

Creates a backup copy of a decrypted `CipherView` with a modified name, retaining the original folder assignment:

```swift
extension CipherView {
    func update(name: String) -> CipherView {
        makeCopy(
            id: nil,
            key: nil,
            name: name,
            attachments: nil,
            attachmentDecryptionFailures: nil
        )
    }
}
```

**Purpose:** Used by `OfflineSyncResolver.createBackupCipher()` to create conflict backup copies. The backup has:
- `id` set to `nil` (server assigns a new ID)
- `key` set to `nil` (SDK generates a fresh encryption key)
- `attachments` and `attachmentDecryptionFailures` set to `nil` (attachments are not duplicated — see [AP-RES7](./ActionPlans/AP-RES7_BackupCiphersLackAttachments.md))
- `name` modified with a timestamp suffix (e.g., `"Login - 2026-02-18 13:55:26"`)
- `folderId` retains the original cipher's folder assignment (no longer placed in a dedicated conflict folder)

### 5c. `makeCopy(id:key:name:attachments:attachmentDecryptionFailures:)` (line 66) **[New]**

A private helper that both `withId(_:)` and `update(name:)` delegate to, consolidating the full `CipherView` initializer call in one place. This reduces the maintenance burden when the SDK adds new properties — only this method needs updating.

```swift
private func makeCopy(
    id: String?,
    key: String?,
    name: String,
    attachments: [AttachmentView]?,
    attachmentDecryptionFailures: [AttachmentView]?
) -> CipherView {
    CipherView(
        id: id,
        organizationId: organizationId,
        folderId: folderId,
        collectionIds: collectionIds,
        key: key,
        name: name,
        notes: notes,
        type: type,
        login: login,
        identity: identity,
        card: card,
        secureNote: secureNote,
        sshKey: sshKey,
        favorite: favorite,
        reprompt: reprompt,
        organizationUseTotp: organizationUseTotp,
        edit: edit,
        permissions: permissions,
        viewPassword: viewPassword,
        localData: localData,
        attachments: attachments,
        attachmentDecryptionFailures: attachmentDecryptionFailures,
        fields: fields,
        passwordHistory: passwordHistory,
        creationDate: creationDate,
        deletedDate: deletedDate,
        revisionDate: revisionDate,
        archivedDate: archivedDate
    )
}
```

**Fragility concern:** The `makeCopy` helper manually copies all 28 `CipherView` properties. If the SDK adds new properties with non-nil defaults, they will be silently dropped. A companion guard test (`test_cipherView_propertyCount_matchesExpected` in `CipherViewOfflineSyncTests.swift`) uses `Mirror` to detect property count changes and alert developers. See [AP-CS2](./ActionPlans/AP-CS2_FragileSDKCopyMethods.md).

**[Updated]** The `folderId` parameter was removed from `CipherView.update(name:folderId:)` → `CipherView.update(name:)`. Backup ciphers now retain the original cipher's folder assignment instead of being placed in a dedicated "Offline Sync Conflicts" folder. Both public methods were refactored to delegate to the shared `makeCopy` helper.

**Review section:** [ReviewSection_SupportingExtensions.md](./ReviewSection_SupportingExtensions.md)

---

## 6. VaultRepository Offline Fallback Handlers

**File:** `BitwardenShared/Core/Vault/Repositories/VaultRepository.swift`
**Change type:** Modified (+213 / −10 lines)

### What Changed

Four existing public methods were modified to catch API failures and delegate to new offline handler methods. Four new private handler methods were added.

### 6a. Modified Public Methods

Each public method follows the same pattern: encrypt the cipher, attempt the API call in a `do/catch`, and on failure delegate to the offline handler. On success, any orphaned pending change from a prior offline attempt is cleaned up. Organization ciphers are checked before the offline handler is called — for org ciphers, the original error is rethrown rather than triggering offline save.

#### `addCipher(_:)` (line 505) **[Updated]**

```swift
func addCipher(_ cipher: CipherView) async throws {
    let isOrgCipher = cipher.organizationId != nil
    // Assign temp ID BEFORE encryption (CipherView.withId)
    let cipherToEncrypt = cipher.id == nil ? cipher.withId(UUID().uuidString) : cipher
    let cipherEncryptionContext = try await clientService.vault().ciphers()
        .encrypt(cipherView: cipherToEncrypt)
    do {
        try await cipherService.addCipherWithServer(
            cipherEncryptionContext.cipher,
            encryptedFor: cipherEncryptionContext.encryptedFor,
        )
        // On success: clean up any orphaned pending change from prior offline add
        if let cipherId = cipherEncryptionContext.cipher.id {
            try await pendingCipherChangeDataStore.deletePendingChange(
                cipherId: cipherId,
                userId: cipherEncryptionContext.encryptedFor
            )
        }
    } catch let error as ServerError { throw error }
    catch let error as ResponseValidationError where error.response.statusCode < 500 { throw error }
    catch let error as CipherAPIServiceError { throw error }
    catch {
        guard !isOrgCipher else {
            throw error  // Rethrow original error for org ciphers
        }
        try await handleOfflineAdd(
            encryptedCipher: cipherEncryptionContext.cipher,
            userId: cipherEncryptionContext.encryptedFor
        )
    }
}
```

**Key change:** Temp ID assignment moved from `handleOfflineAdd` to `addCipher` and now operates on `CipherView` before encryption (via `CipherView.withId()`), resolving the VI-1 root cause.

#### `updateCipher(_:)` (line 959)

Same pattern — encrypts via `clientService.vault().ciphers().encrypt()`, tries API via `cipherService.updateCipherWithServer()`, on success cleans up orphaned pending changes, catches failure with the denylist pattern, checks org cipher (rethrows original error for org ciphers), calls `handleOfflineUpdate(cipherView:encryptedCipher:userId:)`.

#### `softDeleteCipher(_:)` (line 921)

Same pattern — updates `deletedDate`, encrypts via `encryptAndUpdateCipher()` (which returns a `Cipher` rather than an encryption context), tries API via `cipherService.softDeleteCipherWithServer(id:_:)`, on success cleans up orphaned pending changes, catches failure with the denylist pattern, checks org cipher (rethrows original error for org ciphers), calls `handleOfflineSoftDelete(cipherId:encryptedCipher:)`.

#### `deleteCipher(_:)` (line 659) **[Updated]**

Uses the same denylist error handling pattern as the other methods. On success, cleans up orphaned pending changes. The handler receives the original error so it can rethrow it for organization ciphers:

```swift
func deleteCipher(_ id: String) async throws {
    do {
        try await cipherService.deleteCipherWithServer(id: id)
        // Clean up any orphaned pending change from a prior offline operation.
        let userId = try await stateService.getActiveAccountId()
        try await pendingCipherChangeDataStore.deletePendingChange(
            cipherId: id,
            userId: userId
        )
    } catch let error as ServerError {
        throw error
    } catch let error as ResponseValidationError where error.response.statusCode < 500 {
        throw error
    } catch let error as CipherAPIServiceError {
        throw error
    } catch {
        try await handleOfflineDelete(cipherId: id, originalError: error)
    }
}
```

**Design note:** `deleteCipher` queues a **`.hardDelete`** pending change and removes the CipherData record locally via `deleteCipherWithLocalStorage`. On sync, the resolver performs a permanent delete on the server when no conflict is detected, or restores the server version locally if the cipher was modified on the server while offline. See [AP-VR2](./ActionPlans/Resolved/AP-VR2_DeleteConvertedToSoftDelete.md).

### 6b. New Offline Handlers

#### `handleOfflineAdd(encryptedCipher:userId:)` (line 1007)

1. Guards that `encryptedCipher.id` is non-nil (temp ID already assigned by `addCipher` before encryption via `CipherView.withId()`)
2. Persists the cipher to local Core Data via `cipherService.updateCipherWithLocalStorage()`
3. Encodes the cipher as `CipherDetailsResponseModel` → JSON `Data`
4. Queues a `.create` pending change record

#### `handleOfflineUpdate(cipherView:encryptedCipher:userId:)` (line 1034)

1. Persists the updated cipher locally
2. Encodes it as JSON
3. Fetches any existing pending change for this cipher
4. **Password change detection** (lines 1055–1073):
   - If there's an existing pending change: decrypts the previous pending cipher data and compares `login?.password` with the new cipher's password
   - If first offline edit: fetches the local cipher, decrypts it, and compares passwords
   - Increments `offlinePasswordChangeCount` if different
5. Preserves `originalRevisionDate` from existing record (or captures current `revisionDate` for first edit)
6. Preserves `.create` change type if this cipher was originally created offline and hasn't been synced yet (ensures it's POSTed, not PUT)
7. Upserts the pending change record

**Security note:** Password comparison is done entirely in-memory using the SDK's decrypt operations. No plaintext passwords are persisted.

#### `handleOfflineDelete(cipherId:originalError:)` (line 1099) **[Updated]**

1. Gets active user ID from `stateService`
2. **[Updated]** If a pending `.create` change exists for this cipher, cleans up locally (deletes local cipher + pending record) and returns — no server operation needed for a cipher that never existed on the server
3. Fetches the cipher from local storage (to preserve its data for conflict resolution)
4. Guards against organization ciphers (rethrows the `originalError` passed from `deleteCipher`)
5. Removes the CipherData record locally via `cipherService.deleteCipherWithLocalStorage()`
6. Queues a `.hardDelete` pending change (server-side operation will be a permanent delete on sync when no conflict is detected)

**Note:** The org cipher guard is inside this handler (not in the public method) because `deleteCipher` only takes an ID parameter — the cipher must be fetched to check `organizationId`. The `originalError` parameter allows the original network error to be rethrown for organization ciphers rather than silently swallowing it.

#### `handleOfflineSoftDelete(cipherId:encryptedCipher:)` (line 1145) **[Updated]**

1. Gets active user ID
2. **[Updated]** If a pending `.create` change exists for this cipher, cleans up locally (deletes local cipher + pending record) and returns — no server operation needed for a cipher that never existed on the server
3. Persists the already-soft-deleted cipher locally (it has `deletedDate` set)
4. Queues a `.softDelete` pending change

### Organization Cipher Protection

All four public methods guard against organization ciphers. For `addCipher`, `updateCipher`, and `softDeleteCipher`, the `isOrgCipher` check is in the public method's catch block — the original error is rethrown rather than a custom `OfflineSyncError`. For `deleteCipher`, the org cipher check is inside `handleOfflineDelete` (since `deleteCipher` only receives an ID — the cipher must be fetched to check `organizationId`); it rethrows the `originalError` passed from the caller. The rationale for blocking org ciphers:
- Organization ciphers require server-side policy checks and access control validation
- Offline edits to shared items could create inconsistencies across organization members
- This is a security boundary documented in the [OfflineSyncPlan](./OfflineSyncPlan.md)

### Error Handling Design

The original implementation used `URLError` classification to determine which errors should trigger offline fallback. This was **simplified in commit `e13aefe`** to remove the `URLError+NetworkConnection` extension, and then **refined via PRs #26–#28** to use a **denylist pattern**: specific known error types (`ServerError`, `ResponseValidationError` with status < 500, `CipherAPIServiceError`) are rethrown, while all other errors trigger offline save. The rationale:
- `ServerError` and 4xx `ResponseValidationError` indicate the server received and rejected the request (not a connectivity issue)
- `CipherAPIServiceError` indicates client-side validation failures (programming errors)
- All other errors (including 5xx, `URLError`, unknown errors) appropriately trigger offline save
- On successful online operations, orphaned pending change records from prior offline attempts are cleaned up

**Related issues:** [AP-U1](./ActionPlans/AP-U1_OrgCipherErrorTiming.md), [AP-U2](./ActionPlans/AP-U2_InconsistentOfflineSupport.md), [AP-VR2](./ActionPlans/AP-VR2_DeleteConvertedToSoftDelete.md)
**Review section:** [ReviewSection_VaultRepository.md](./ReviewSection_VaultRepository.md)

---

## 7. OfflineSyncResolver Conflict Resolution Engine

**File:** `BitwardenShared/Core/Vault/Services/OfflineSyncResolver.swift` (new, 349 lines)

The core conflict resolution engine that processes pending offline changes when connectivity returns.

### 7a. OfflineSyncError Enum (line 9) **[Updated]**

```swift
enum OfflineSyncError: LocalizedError, Equatable {
    case missingCipherData
    case missingCipherId
    case vaultLocked
    case cipherNotFound
}
```

Four error types with `LocalizedError` and `Equatable` conformance for user-facing messages and test assertions. The `.cipherNotFound` case was added in commit `e929511` (RES-2 fix) to handle server 404 responses during conflict resolution.

**[Updated]** The `.organizationCipherOfflineEditNotSupported` case has been removed. Organization cipher protection is now handled in `VaultRepository` by rethrowing the original error rather than using a custom `OfflineSyncError` case.

### 7b. OfflineSyncResolver Protocol (line 40)

```swift
protocol OfflineSyncResolver {
    func processPendingChanges(userId: String) async throws
}
```

Single-method protocol following the existing service pattern.

### 7c. DefaultOfflineSyncResolver (line 55)

Declared as an `actor` (not a `class`) for thread safety.

#### Dependencies (4) **[Updated] [Corrected 2026-02-21]** Originally documented as 5 dependencies; `stateService` was removed (commit `a52d379` removed unused `timeProvider`, and `stateService` was also removed as it is not used by the resolver -- userId is passed as a parameter). The actual dependency count is 4.

- `cipherAPIService` — fetches current server cipher for conflict comparison
- `cipherService` — adds/updates/soft-deletes ciphers locally and with server
- `clientService` — SDK encryption/decryption for conflict resolution
- ~~`folderService` — creates/finds the "Offline Sync Conflicts" folder~~ **[Removed]** — Conflict folder eliminated
- `pendingCipherChangeDataStore` — fetches and deletes resolved pending changes
- ~~`stateService` — user state management~~ **[Corrected 2026-02-21]** Not present in the final implementation. The userId is passed as a parameter to `processPendingChanges(userId:)` rather than being retrieved from `stateService`.

#### Constants

- `softConflictPasswordChangeThreshold: Int64 = 4` (line 60) — number of password changes that triggers a precautionary backup even without a server conflict **[Corrected 2026-02-21]** Originally documented as `Int16`; final type is `Int64` to match the `offlinePasswordChangeCount` property type.

~~#### Cached State~~

~~- `conflictFolderId: String?` (line 83) — cached per resolution batch to avoid repeated folder lookups~~

**[Updated]** The `conflictFolderId` cached state has been removed along with the conflict folder feature.

### Resolution Flow

#### `processPendingChanges(userId:)` (line 106)

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

**Design:** Uses catch-and-continue so that one failing change doesn't prevent resolving others. Unresolved changes remain in the store and are retried on the next sync.

#### `resolve(pendingChange:userId:)` (line 129)

Routes to the appropriate resolver based on `changeType`:
- `.create` → `resolveCreate()`
- `.update` → `resolveUpdate()`
- `.softDelete` → `resolveDelete(permanent: false)`
- `.hardDelete` → `resolveDelete(permanent: true)`

#### `resolveCreate(pendingChange:userId:)` (line 151)

1. Decodes `cipherData` to `CipherDetailsResponseModel`
2. Calls `cipherService.addCipherWithServer()` to push to server
3. Deletes the old cipher record that used the temporary client-side ID (the server assigns a new ID via `addCipherWithServer`, so the temp-ID record is now orphaned)
4. Deletes the pending change record

For creates, there is no conflict scenario — the cipher didn't exist on the server before.

#### `resolveUpdate(pendingChange:cipherId:userId:)` (line 175)

The most complex resolution path:

```
1. Decode local cipher from pending cipherData
2. Fetch current server cipher via cipherAPIService.getCipher()
   └─ If 404 → re-create cipher via addCipherWithServer, delete record, return
3. Check for HARD CONFLICT:
   originalRevisionDate ≠ server.revisionDate?
   ├─ YES → resolveConflict() (timestamp-based winner)
   └─ NO → Check for SOFT CONFLICT:
           offlinePasswordChangeCount ≥ 4?
           ├─ YES → Backup server version, push local
           └─ NO → Push local version (no backup needed)
4. Delete pending change record
```

**Conflict detection** (line 206): The `originalRevisionDate` captured during the first offline edit is compared with the server's current `revisionDate`. If they differ, someone else edited the cipher on the server while the user was offline.

**Soft conflict** (line 217): Even without a server revision change, if the user made 4+ password changes offline, a backup is created as a safety measure. This protects against the edge case where password history (capped at 5 entries by Bitwarden) would lose intermediate passwords.

#### `resolveConflict(localCipher:serverCipher:pendingChange:userId:)` (line 237)

Timestamp-based winner determination:

```swift
let localTimestamp = pendingChange.updatedDate ?? pendingChange.createdDate ?? Date.distantPast
let serverTimestamp = serverCipher.revisionDate

if localTimestamp > serverTimestamp {
    // Local wins: backup server FIRST, then push local
    try await createBackupCipher(from: serverCipher, timestamp: serverTimestamp, userId: userId)
    try await cipherService.updateCipherWithServer(localCipher, ...)
} else {
    // Server wins (or equal): backup local FIRST, then update local storage
    try await createBackupCipher(from: localCipher, timestamp: localTimestamp, userId: userId)
    try await cipherService.updateCipherWithLocalStorage(serverCipher)
}
```

**Note:** Uses strict `>` comparison — if timestamps are equal, the server version wins (conservative choice).

#### ~~`resolveSoftDelete(pendingChange:cipherId:userId:)`~~ → `resolveDelete(pendingChange:cipherId:userId:permanent:)` (line 271) **[Refactored]**

**[Updated]** `resolveSoftDelete` has been refactored into a unified `resolveDelete(permanent:)` method that handles both `.softDelete` and `.hardDelete` pending changes. The `permanent` parameter determines whether the server API call is a soft delete or permanent delete.

1. Fetches current server cipher via `cipherAPIService.getCipher(withId:)`
   - If 404 → cleans up local cipher record and pending change, then returns (user's delete intent already satisfied)
2. Compares `originalRevisionDate` with server `revisionDate`
3. If conflict exists: restores the server version to local storage via `updateCipherWithLocalStorage` and drops the pending delete (user can review and re-decide)
4. If no conflict: calls the appropriate server delete API
   - `permanent == true` → `cipherAPIService.deleteCipher(withID:)` (permanent delete)
   - `permanent == false` → `cipherAPIService.softDeleteCipher(withID:)` (soft delete)
5. Deletes pending change record

**[Updated]** The conflict behavior has changed: instead of creating a backup of the server version and then completing the delete, the resolver now restores the server version locally and drops the pending delete. This prevents data loss when the server version was modified while offline — the user sees the updated cipher reappear and can decide whether to delete it again.

#### `createBackupCipher(from:timestamp:userId:)` (line 325) **[Updated]**

Creates a backup copy for the losing side of a conflict:

1. Decrypts the cipher via SDK
2. Formats a timestamp string (`yyyy-MM-dd HH:mm:ss`)
3. Modifies the name: `"{original name} - {timestamp}"`
4. Creates the backup with `CipherView.update(name:)` (nullifies id, key, attachments; retains original folderId)
5. Encrypts via `clientService.vault().ciphers().encrypt()` and pushes to server via `cipherService.addCipherWithServer(encryptionContext.cipher, encryptedFor: encryptionContext.encryptedFor)`

**[Updated]** The `getOrCreateConflictFolder()` step has been removed. Backup ciphers now retain the original cipher's folder assignment instead of being placed in a dedicated "Offline Sync Conflicts" folder.

#### ~~`getOrCreateConflictFolder()` (line 328)~~ **[Removed]**

~~Finds or creates the "Offline Sync Conflicts" folder.~~ This method and the entire conflict folder concept have been removed. Backup ciphers now retain their original folder assignment. This eliminates the `FolderService` dependency, the `conflictFolderId` cache, and the O(n) folder decryption lookup.

**Related issues:** [AP-RES1](./ActionPlans/AP-RES1_DuplicateCipherOnCreateRetry.md), [AP-RES7](./ActionPlans/AP-RES7_BackupCiphersLackAttachments.md), [AP-RES9](./ActionPlans/AP-RES9_ImplicitCipherDataContract.md), [AP-R2](./ActionPlans/AP-R2_ConflictFolderIdThreadSafety.md), [AP-R3](./ActionPlans/AP-R3_RetryBackoff.md), [AP-U4](./ActionPlans/AP-U4_EnglishOnlyConflictFolderName.md)
**Review section:** [ReviewSection_OfflineSyncResolver.md](./ReviewSection_OfflineSyncResolver.md)

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

### Pre-Sync Resolution Logic (line 325)

Inserted at the beginning of `fetchSync()`, before the existing `needsSync` check:

```swift
// 1. Get user context
let account = try await stateService.getActiveAccount()
let userId = account.profile.userId

// 2. Check vault lock (new: computed once, reused below)
let isVaultLocked = await vaultTimeoutService.isLocked(userId: userId)

// 3. Resolve pending changes (only if vault unlocked AND pending changes exist)
if !isVaultLocked {
    let pendingCount = try await pendingCipherChangeDataStore.pendingChangeCount(userId: userId)
    if pendingCount > 0 {
        try await offlineSyncResolver.processPendingChanges(userId: userId)
        let remainingCount = try await pendingCipherChangeDataStore.pendingChangeCount(userId: userId)
        if remainingCount > 0 {
            return  // ABORT: protect local offline edits
        }
    }
}

// 4. Continue with normal sync (existing code)
guard try await needsSync(forceSync:, isPeriodic:, userId:) else { return }
```

### Design Decisions

**Vault lock check:** Resolution is skipped when the vault is locked because the SDK crypto context is needed for decryption during conflict resolution. The sync itself can still proceed (it replaces encrypted data without needing to decrypt).

**Early-abort pattern:** If `remainingCount > 0` after resolution, the sync aborts entirely. This prevents `replaceCiphers()` from overwriting locally-stored offline edits with stale server state. The pending changes will be retried on the next sync attempt.

**Optimization:** The `isVaultLocked` result is computed once and reused for the existing `organizationService.initializeOrganizationCrypto()` guard (line 359), eliminating a redundant async call.

**Related issues:** [AP-R4](./ActionPlans/AP-R4_SilentSyncAbort.md), [AP-SS2](./ActionPlans/AP-SS2_TOCTOURaceCondition.md)
**Review section:** [ReviewSection_SyncService.md](./ReviewSection_SyncService.md)

---

## 9. Dependency Injection Wiring

### 9a. Services.swift

**File:** `BitwardenShared/Core/Platform/Services/Services.swift`
**Change type:** Modified (+16 lines)

Two new `Has*` protocols were added. **[Corrected 2026-02-21]** Only `HasOfflineSyncResolver` is included in the `Services` typealias. `HasPendingCipherChangeDataStore` exists as a standalone protocol but is NOT part of the `Services` typealias -- the data store is instead passed directly via initializers to the components that need it (`DefaultSyncService`, `DefaultVaultRepository`, `DefaultOfflineSyncResolver`).

```swift
typealias Services = ...
    & HasOfflineSyncResolver
    // [Corrected 2026-02-21] HasPendingCipherChangeDataStore is NOT in this typealias.
    // The original changelog incorrectly showed it here. The data store is passed
    // directly via initializers, not through the Services typealias.
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

`HasOfflineSyncResolver` follows the existing `Has*` protocol pattern used by all services in the project and is included in the `Services` typealias. `HasPendingCipherChangeDataStore` is defined but not included in the `Services` typealias -- it is used for direct dependency injection via initializers.

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
    try await backgroundContext.perform {
        try self.backgroundContext.executeAndMergeChanges(
            batchDeleteRequests: [
                // ... existing deletes ...
                PendingCipherChangeData.deleteByUserIdRequest(userId: userId),
            ]
        )
    }
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

**Related issues:** [AP-DI1](./ActionPlans/AP-DI1_DataStoreExposedToUILayer.md)
**Review section:** [ReviewSection_DIWiring.md](./ReviewSection_DIWiring.md)

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
| `test_fetchPendingChanges_sortedByCreatedDate` | **[Corrected 2026-02-21]** Missing from original table. Results sorted by createdDate ascending |
| `test_deleteDataForUser_deletesPendingCipherChanges` | **[Corrected 2026-02-21]** Missing from original table. User data cleanup deletes pending changes |

**Key assertion in upsert test:** The `originalRevisionDate` from the first insert is preserved after the second upsert — this is critical for correct conflict detection.

---

## 11. Test Coverage: CipherViewOfflineSyncTests

**File:** `BitwardenShared/Core/Vault/Extensions/CipherViewOfflineSyncTests.swift` (new, 171 lines)

Tests the cipher extension helpers used for offline sync operations.

| Test | What It Verifies |
|------|-----------------|
| ~~`test_withTemporaryId_setsNewId`~~ → `test_withId_setsId` | ID correctly assigned to cipher view |
| ~~`test_withTemporaryId_preservesOtherProperties`~~ → `test_withId_preservesOtherProperties` | Key properties preserved during ID assignment |
| (New) `test_withId_replacesExistingId` | Can replace an existing non-nil ID |
| ~~`test_update_setsNameAndFolderId`~~ → `test_update_setsNameAndPreservesFolderId` | Name correctly updated and original folderId retained for backup copies |
| `test_update_setsIdToNil` | Backup cipher has nil ID (server assigns new) |
| `test_update_setsKeyToNil` | Backup cipher has nil key (SDK generates fresh) |
| `test_update_setsAttachmentsToNil` | Attachments excluded from backup copies |
| `test_update_preservesPasswordHistory` | Password history preserved in backup copies |
| `test_cipherView_propertyCount_matchesExpected` | Guards against undetected SDK property additions in `CipherView` (expects 28 properties) |
| `test_loginView_propertyCount_matchesExpected` | Guards against undetected SDK property additions in `LoginView` (expects 7 properties) |

The first 8 are pure model unit tests with no mock dependencies. The last 2 are SDK property count guard tests (see [AP-CS2](./ActionPlans/AP-CS2_FragileSDKCopyMethods.md)) that use `Mirror` reflection to detect when the SDK adds new properties, alerting developers to update all manual copy methods.

---

## 12. Test Coverage: VaultRepositoryTests Offline Fallback

**File:** `BitwardenShared/Core/Vault/Repositories/VaultRepositoryTests.swift`
**Change type:** Modified (41 new offline fallback test functions) **[Corrected 2026-02-21]** Originally documented as 32 test functions; actual count is 41 (includes feature flag tests, resolution flag tests, cipher-not-found no-op, and additional edge cases added in later commits).

Tests the offline fallback behavior in `VaultRepository` for all four CRUD operations. Each operation has tests for personal ciphers (success path), organization ciphers (rejection path), error type denylist handling (ServerError rethrow, 4xx ResponseValidationError rethrow), feature flag gating, resolution flag gating, and additional edge cases including password change detection and cleanup of offline-created ciphers.

| Test | Operation | Expected Behavior |
|------|-----------|-------------------|
| `test_addCipher_offlineFallback` | Create | Local save + `.create` pending change |
| `test_addCipher_offlineFallback_newCipherGetsTempId` | Create | Temp ID assigned before encryption |
| `test_addCipher_offlineFallback_orgCipher_throws` | Create | Org cipher rethrows original error (no offline save) |
| `test_addCipher_offlineFallback_unknownError` | Create | Unknown errors trigger offline save |
| `test_addCipher_offlineFallback_responseValidationError5xx` | Create | 5xx errors trigger offline save |
| `test_addCipher_serverError_rethrows` | Create | `ServerError` rethrown (server reachable, rejected request) |
| `test_addCipher_responseValidationError4xx_rethrows` | Create | 4xx `ResponseValidationError` rethrown |
| `test_addCipher_offlineFallback_disabledByFeatureFlag` | Create | **[Corrected 2026-02-21]** Missing from original table. Offline save skipped when feature flag disabled |
| `test_addCipher_offlineFallback_disabledByResolutionFlag` | Create | **[Corrected 2026-02-21]** Missing from original table. Offline save skipped when resolution flag disabled |
| `test_deleteCipher_offlineFallback` | Delete | Local delete + `.hardDelete` pending change |
| `test_deleteCipher_offlineFallback_cleansUpOfflineCreatedCipher` | Delete | Cleans up locally for never-synced cipher |
| `test_deleteCipher_offlineFallback_unknownError` | Delete | Unknown errors trigger offline save |
| `test_deleteCipher_offlineFallback_responseValidationError5xx` | Delete | 5xx errors trigger offline save |
| `test_deleteCipher_offlineFallback_cipherNotFound_noOp` | Delete | **[Corrected 2026-02-21]** Missing from original table. No-op when cipher not found locally |
| `test_deleteCipher_offlineFallback_orgCipher_throws` | Delete | Org cipher rethrows original error (no offline save) |
| `test_deleteCipher_offlineFallback_disabledByFeatureFlag` | Delete | **[Corrected 2026-02-21]** Missing from original table. Offline save skipped when feature flag disabled |
| `test_deleteCipher_offlineFallback_disabledByResolutionFlag` | Delete | **[Corrected 2026-02-21]** Missing from original table. Offline save skipped when resolution flag disabled |
| `test_deleteCipher_serverError_rethrows` | Delete | `ServerError` rethrown |
| `test_deleteCipher_responseValidationError4xx_rethrows` | Delete | 4xx `ResponseValidationError` rethrown |
| `test_updateCipher_offlineFallback` | Update | Local update + `.update` pending change |
| `test_updateCipher_offlineFallback_preservesCreateType` | Update | Preserves `.create` type for never-synced cipher |
| `test_updateCipher_offlineFallback_passwordChanged_incrementsCount` | Update | Password change detection increments count |
| `test_updateCipher_offlineFallback_passwordUnchanged_zeroCount` | Update | Unchanged password keeps count at 0 |
| `test_updateCipher_offlineFallback_subsequentEdit_passwordChanged_incrementsCount` | Update | Subsequent edit detects password change |
| `test_updateCipher_offlineFallback_subsequentEdit_passwordUnchanged_preservesCount` | Update | Subsequent edit preserves count when unchanged |
| `test_updateCipher_offlineFallback_orgCipher_throws` | Update | Org cipher rethrows original error (no offline save) |
| `test_updateCipher_offlineFallback_unknownError` | Update | Unknown errors trigger offline save |
| `test_updateCipher_offlineFallback_responseValidationError5xx` | Update | 5xx errors trigger offline save |
| `test_updateCipher_offlineFallback_disabledByFeatureFlag` | Update | **[Corrected 2026-02-21]** Missing from original table. Offline save skipped when feature flag disabled |
| `test_updateCipher_offlineFallback_disabledByResolutionFlag` | Update | **[Corrected 2026-02-21]** Missing from original table. Offline save skipped when resolution flag disabled |
| `test_updateCipher_serverError_rethrows` | Update | `ServerError` rethrown |
| `test_updateCipher_responseValidationError4xx_rethrows` | Update | 4xx `ResponseValidationError` rethrown |
| `test_softDeleteCipher_offlineFallback` | Soft Delete | Local update + `.softDelete` pending change |
| `test_softDeleteCipher_offlineFallback_cleansUpOfflineCreatedCipher` | Soft Delete | Cleans up locally for never-synced cipher |
| `test_softDeleteCipher_offlineFallback_orgCipher_throws` | Soft Delete | Org cipher rethrows original error (no offline save) |
| `test_softDeleteCipher_offlineFallback_unknownError` | Soft Delete | Unknown errors trigger offline save |
| `test_softDeleteCipher_offlineFallback_responseValidationError5xx` | Soft Delete | 5xx errors trigger offline save |
| `test_softDeleteCipher_offlineFallback_disabledByFeatureFlag` | Soft Delete | **[Corrected 2026-02-21]** Missing from original table. Offline save skipped when feature flag disabled |
| `test_softDeleteCipher_offlineFallback_disabledByResolutionFlag` | Soft Delete | **[Corrected 2026-02-21]** Missing from original table. Offline save skipped when resolution flag disabled |
| `test_softDeleteCipher_serverError_rethrows` | Soft Delete | `ServerError` rethrown |
| `test_softDeleteCipher_responseValidationError4xx_rethrows` | Soft Delete | 4xx `ResponseValidationError` rethrown |

All tests trigger the offline path by configuring `MockCipherService` to throw `URLError(.notConnectedToInternet)` or other appropriate errors for the server API call. The `_serverError_rethrows` and `_responseValidationError4xx_rethrows` tests verify that denylist errors (indicating the server received and rejected the request) are properly propagated instead of triggering offline save.

---

## 13. Test Coverage: OfflineSyncResolverTests

**File:** `BitwardenShared/Core/Vault/Services/OfflineSyncResolverTests.swift` (new, 933 lines)

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
| `test_processPendingChanges_update_conflict_localNewer_preservesPasswordHistory` | Conflict (local wins): password history preserved in backup |
| `test_processPendingChanges_update_conflict_serverNewer_preservesPasswordHistory` | Conflict (server wins): password history preserved in backup |
| `test_processPendingChanges_update_softConflict_preservesPasswordHistory` | Soft conflict: password history preserved in backup |
| `test_processPendingChanges_softDelete_conflict` | Soft delete conflict: restores server version locally, drops pending delete |
| `test_processPendingChanges_hardDelete_noConflict` | **[New]** Hard delete: no conflict → permanent delete on server |
| `test_processPendingChanges_hardDelete_conflict` | **[New]** Hard delete conflict: restores server version locally, drops pending delete |
| `test_processPendingChanges_hardDelete_cipherNotFound_cleansUp` | **[New]** Hard delete where server returns 404 — cleans up locally |
| `test_processPendingChanges_hardDelete_apiFailure_pendingRecordRetained` | **[New]** Hard delete API failure: pending record retained for retry |
| ~~`test_processPendingChanges_update_conflict_createsConflictFolder`~~ | ~~Verifies "Offline Sync Conflicts" folder creation~~ **[Removed]** — Conflict folder eliminated |
| `test_processPendingChanges_update_cipherNotFound_recreates` | Update where server returns 404 — re-creates cipher on server |
| `test_processPendingChanges_softDelete_cipherNotFound_cleansUp` | Soft delete where server returns 404 — cleans up locally |
| `test_offlineSyncError_vaultLocked_localizedDescription` | Error message for vault locked state |
| `test_processPendingChanges_create_apiFailure_pendingRecordRetained` | Create API failure: pending record retained for retry |
| `test_processPendingChanges_update_serverFetchFailure_pendingRecordRetained` | Update server fetch failure: pending record retained for retry |
| `test_processPendingChanges_softDelete_apiFailure_pendingRecordRetained` | Soft delete API failure: pending record retained for retry |
| `test_processPendingChanges_update_backupFailure_pendingRecordRetained` | Update backup failure: pending record retained for retry |
| `test_processPendingChanges_batch_allSucceed` | Batch: all items resolved successfully |
| `test_processPendingChanges_batch_mixedFailure_successfulItemResolved` | Batch: mixed success/failure — successful items still resolved |
| `test_processPendingChanges_batch_allFail` | Batch: all items fail — all pending records retained |
| `test_processPendingChanges_create_corruptCipherData_skipsAndRetains` | **[Corrected 2026-02-21]** Missing from original table. Corrupt cipher data: skips and retains pending record |
| `test_processPendingChanges_update_corruptCipherData_skipsAndRetains` | **[Corrected 2026-02-21]** Missing from original table. Corrupt cipher data on update: skips and retains |
| `test_processPendingChanges_batch_corruptAndValid_validItemResolves` | **[Corrected 2026-02-21]** Missing from original table. Mixed corrupt/valid batch: valid item still resolves |
| `test_processPendingChanges_create_nilCipherData_skipsAndRetains` | **[Corrected 2026-02-21]** Missing from original table. Nil cipher data on create: skips and retains |
| `test_processPendingChanges_update_nilCipherData_skipsAndRetains` | **[Corrected 2026-02-21]** Missing from original table. Nil cipher data on update: skips and retains |
| `test_processPendingChanges_update_nilOriginalRevisionDate_noConflict` | **[Corrected 2026-02-21]** Missing from original table. Nil original revision date treated as no conflict |
| `test_processPendingChanges_update_conflict_backupNameFormat` | **[Corrected 2026-02-21]** Missing from original table. Backup name format validation |
| `test_processPendingChanges_update_conflict_emptyNameBackup` | **[Corrected 2026-02-21]** Missing from original table. Empty name cipher backup handling |

**Notable test patterns:**
- Conflict detection tested with matching vs. mismatching `revisionDate` values
- Timestamp-based winner determination tested with explicit past/future dates
- Soft conflict threshold tested with `offlinePasswordChangeCount = 4`
- Password history preservation tested in all three conflict paths (local wins, server wins, soft conflict)
- API failure retention tests verify catch-and-continue behavior (pending records not deleted on failure)
- Batch processing tests verify that one failing item does not prevent resolving others
- Mock call tracking verifies correct API methods called (add vs. update vs. softDelete)

---

## 14. Test Coverage: SyncServiceTests Pre-Sync Resolution

**File:** `BitwardenShared/Core/Vault/Services/SyncServiceTests.swift`
**Change type:** Modified (+66 lines, 7 new test functions) **[Corrected 2026-02-21]** Originally documented as 5 test functions; actual count is 7 (includes feature flag tests added in later commits).

Tests the pre-sync resolution integration in `fetchSync()`.

| Test | Scenario | Key Assertion |
|------|----------|---------------|
| `test_fetchSync_preSyncResolution_triggersPendingChanges` | Normal flow | `processPendingChanges` called, sync proceeds |
| `test_fetchSync_preSyncResolution_skipsWhenVaultLocked` | Vault locked | `processPendingChanges` NOT called, sync proceeds |
| `test_fetchSync_preSyncResolution_noPendingChanges` | Empty queue | Pre-count check returns 0, resolver NOT called (optimization), sync proceeds |
| `test_fetchSync_preSyncResolution_abortsWhenPendingChangesRemain` | Unresolved changes | Sync ABORTED — no HTTP request made |
| `test_fetchSync_preSyncResolution_resolverThrows_syncFails` | Resolver error | Error propagated — sync fails |
| `test_fetchSync_preSyncResolution_stillResolvesWhenOfflineSyncFlagDisabled` | **[Corrected 2026-02-21]** Missing from original table. Resolution still runs even when offline sync changes flag is disabled | Resolution proceeds (resolution flag controls resolution, not the changes flag) |
| `test_fetchSync_preSyncResolution_skipsWhenResolutionFlagDisabled` | **[Corrected 2026-02-21]** Missing from original table. Resolution skipped when resolution-specific flag disabled | `processPendingChanges` NOT called, sync proceeds |

The abort test is the most critical — it verifies that `replaceCiphers()` is never called when pending changes remain, preventing data loss. The resolver-throws test verifies that hard errors from `processPendingChanges()` propagate correctly instead of being silently swallowed.

---

## 15. Test Helpers: Mocks

### MockPendingCipherChangeDataStore

**File:** `BitwardenShared/Core/Vault/Services/Stores/TestHelpers/MockPendingCipherChangeDataStore.swift` (new, 78 lines)

Full mock implementation of `PendingCipherChangeDataStore` with:
- **Result properties**: Configurable return values for each method (e.g., `fetchPendingChangesResult`, `pendingChangeCountResult`)
- **Call tracking arrays**: Records all calls with parameters (e.g., `upsertPendingChangeCalledWith`, `deletePendingChangeByIdCalledWith`)

### MockOfflineSyncResolver

**File:** `BitwardenShared/Core/Vault/Services/TestHelpers/MockOfflineSyncResolver.swift` (new, 13 lines)

Minimal mock of `OfflineSyncResolver` with:
- `processPendingChangesCalledWith: [String]` — tracks userId parameters
- `processPendingChangesResult: Result<Void, Error>` — controls success/failure

Both mocks are injected via `ServiceContainer.withMocks()` as default parameters.

---

## 16. Post-Implementation Fixes

Three initial follow-up commits addressed issues identified during code review, followed by additional fixes via PRs and subsequent commits:

### Commit `e13aefe`: Simplify Error Handling

**Removed:** `URLError+NetworkConnection.swift` and its tests — an extension that classified 10 `URLError` codes as "network connection errors."

**Changed:** `VaultRepository` offline handlers now use denylist catch blocks (rethrow `ServerError`, `CipherAPIServiceError`, `ResponseValidationError` < 500; all other errors trigger offline save) instead of `catch let error as URLError where error.isNetworkConnectionError`. See also PRs #26–#28 for the subsequent refinement.

**Rationale:** The URLError classification was unnecessary and too narrow. The initial simplification to plain `catch` was subsequently refined to the denylist pattern to ensure client-side validation errors and 4xx server rejections propagate correctly while all other errors (5xx, transport, unknown) trigger offline save. This also resolved three action plan issues:
- [AP-SEC1](./ActionPlans/Resolved/AP-SEC1_SecureConnectionFailedClassification.md) — TLS failures triggering offline save (superseded)
- [AP-EXT1](./ActionPlans/Resolved/AP-EXT1_TimedOutClassification.md) — Timeout errors too broad (superseded)
- [AP-T6](./ActionPlans/Resolved/AP-T6_IncompleteURLErrorTestCoverage.md) — Incomplete URLError test coverage (resolved by deletion)

### Commit `a52d379`: Remove Unused Dependencies

**Removed:** `timeProvider` dependency from `DefaultOfflineSyncResolver` — it was injected but never used (timestamp formatting uses `Date()` directly).

**Removed:** A stray blank line in `Services.swift`.

This resolved [AP-A3](./ActionPlans/Resolved/AP-A3_UnusedTimeProvider.md) and [AP-CS1](./ActionPlans/Resolved/AP-CS1_StrayBlankLine.md).

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

### Commit `9415019`: Convert DefaultOfflineSyncResolver from Class to Actor (R2)

Changed `DefaultOfflineSyncResolver` from `class` to `actor` to provide compiler-enforced thread safety. This follows the established project pattern (7 existing actor-based services). No protocol, caller, or test changes were needed since all interfaces already use `async/await`. This resolved [AP-R2](./ActionPlans/AP-R2_ConflictFolderIdThreadSafety.md).

### Commit `4d65465`: Add Test Coverage for S3, S4, S6, T5, T8

Added 12 new unit tests and 1 maintenance improvement addressing 5 testing-only issues from the code review:

- **S3**: 3 batch processing tests in `OfflineSyncResolverTests` verifying catch-and-continue behavior (all-succeed, mixed-failure, all-fail)
- **S4**: 4 API failure tests in `OfflineSyncResolverTests` verifying pending records are retained when resolution fails
- **S6**: 4 password change counting tests in `VaultRepositoryTests` covering first-edit and subsequent-edit paths
- **T5**: Maintenance comment added to inline `MockCipherAPIServiceForOfflineSync`
- **T8**: 1 pre-sync resolution failure test in `SyncServiceTests` verifying error propagation

This resolved [AP-S3](./ActionPlans/Resolved/AP-S3_BatchProcessingTest.md), [AP-S4](./ActionPlans/Resolved/AP-S4_APIFailureDuringResolutionTest.md), [AP-S6](./ActionPlans/Resolved/AP-S6_PasswordChangeCountingTest.md), [AP-T5](./ActionPlans/Resolved/AP-T5_InlineMockFragility.md), and [AP-T8](./ActionPlans/Resolved/AP-T8_HardErrorInPreSyncResolution.md).

### Commits `31bc7be`, `cd73efd`: Remove Conflict Folder, Simplify Backup Naming

Removed the "Offline Sync Conflicts" folder feature entirely. Backup ciphers now retain the original cipher's folder assignment. Simplified backup naming to `"{name} - {timestamp}"` format. This also superseded [AP-U4](./ActionPlans/AP-U4_EnglishOnlyConflictFolderName.md).

### Commit `0ce7e41`: Re-throw Original Error for Org Cipher Offline Failures

Changed organization cipher offline fallback guards to re-throw the original network error instead of replacing it with `OfflineSyncError.organizationCipherOfflineEditNotSupported`. This preserves the existing alert behavior -- `URLError` types are handled by `Alert.networkResponseError()` to show specific messages like "Internet Connection Required" with retry, rather than a generic error. Updated `deleteCipher` to pass `originalError` to `handleOfflineDelete(cipherId:originalError:)`. The guard's purpose is to prevent the offline fallback path (local save + pending change queue), not to change the error type.

### Commit `4b64e9b`: Remove Dead `organizationCipherOfflineEditNotSupported` Enum Case

Removed `OfflineSyncError.organizationCipherOfflineEditNotSupported` since it is no longer thrown by any production code after the previous commit. The `OfflineSyncError` enum now has 4 cases: `missingCipherData`, `missingCipherId`, `vaultLocked`, and `cipherNotFound`.

### Commit `1effe90`: Consolidate Fragile CipherView Copy Methods (CS-2)

Addressed [AP-CS2](./ActionPlans/AP-CS2_FragileSDKCopyMethods.md) by extracting a private `makeCopy` helper in `CipherView+OfflineSync.swift` so the full `CipherView` initializer is called in one place instead of two. Added Mirror-based property count guard tests for `CipherView` (28 properties) and `LoginView` (7 properties) that fail when the SDK type gains new properties. Added `Important` DocC comments documenting the property count and SDK update review requirement.

### Commit `f906711`: Fix `attachmentDecryptionFailures` Type Mismatch

The SDK changed `attachmentDecryptionFailures` from `[String]?` to `[AttachmentView]?`, but `makeCopy`'s parameter was not updated to match. Fixed the parameter type in `CipherView+OfflineSync.swift`.

### Commit `34b6c24`: Add `.hardDelete` Pending Change Type; Refactor Delete Conflict Resolution

Three related changes:

1. **New `PendingCipherChangeType.hardDelete` (raw value 3):** Distinguishes permanent delete intent from soft delete in the pending changes queue. `handleOfflineDelete` now stores `.hardDelete` instead of `.softDelete`, so the resolver calls the correct server API (`deleteCipher` for permanent, `softDeleteCipher` for trash).

2. **Unified `resolveDelete(permanent:)` method:** `resolveSoftDelete` has been refactored into a shared `resolveDelete(pendingChange:cipherId:userId:permanent:)` method. The `permanent` parameter controls which server API is called in the no-conflict path. This eliminates duplication between the soft delete and hard delete resolution paths.

3. **New delete conflict behavior:** When a conflict is detected (server `revisionDate` differs from `originalRevisionDate`), the resolver now **restores the server version locally** via `updateCipherWithLocalStorage` and drops the pending delete. This replaces the previous behavior of creating a backup and completing the delete. The user sees the updated cipher reappear and can decide whether to delete it again. This applies to both `.softDelete` and `.hardDelete` pending changes.

   **Rationale:** The previous approach (backup + delete) could result in data loss if the backup lacked attachments (RES-7) or if the user didn't notice the backup copy. Restoring the server version is safer — the user explicitly re-evaluates rather than having data silently moved to a backup.

**Files changed:** 6 (PendingCipherChangeData, VaultRepository, OfflineSyncResolver, OfflineSyncResolverTests, VaultRepositoryTests, MockCipherAPIServiceForOfflineSync)

**Tests:** Updated 3 existing assertions from `.softDelete` to `.hardDelete` in VaultRepositoryTests. Updated soft delete conflict test to assert restore behavior. Added 4 new hard delete tests: no-conflict, conflict, 404, and API failure. Updated `MockCipherAPIServiceForOfflineSync` to track `deleteCipher(withID:)` calls.

This resolves [AP-VR2](./ActionPlans/Resolved/AP-VR2_DeleteConvertedToSoftDelete.md) Option B — permanent deletes are now honored on sync when no conflict exists.

---

## 17. Documentation Artifacts

The implementation includes extensive documentation in `_OfflineSyncDocs/`:

### Planning Documents

| Document | Description |
|----------|-------------|
| [OfflineSyncPlan.md](./OfflineSyncPlan.md) | Full implementation plan with architecture, security considerations, and phased approach |

### Code Review Documents

| Document | Description |
|----------|-------------|
| [OfflineSyncCodeReview.md](./OfflineSyncCodeReview.md) | Comprehensive review: 30 findings across architecture, security, test coverage, and UX |
| [OfflineSyncCodeReview_Phase2.md](./OfflineSyncCodeReview_Phase2.md) | Phase 2 code review for bug fixes and improvements |
| [ReviewSection_DIWiring.md](./ReviewSection_DIWiring.md) | Detailed review of dependency injection changes |
| [ReviewSection_OfflineSyncResolver.md](./ReviewSection_OfflineSyncResolver.md) | Detailed review of conflict resolution engine |
| [ReviewSection_PendingCipherChangeDataStore.md](./ReviewSection_PendingCipherChangeDataStore.md) | Detailed review of data persistence layer |
| [ReviewSection_SupportingExtensions.md](./ReviewSection_SupportingExtensions.md) | Detailed review of cipher extension helpers |
| [ReviewSection_SyncService.md](./ReviewSection_SyncService.md) | Detailed review of sync integration |
| [ReviewSection_TestChanges.md](./ReviewSection_TestChanges.md) | Detailed review of test changes |
| [ReviewSection_VaultRepository.md](./ReviewSection_VaultRepository.md) | Detailed review of offline fallback handlers |

### Action Plans (15 Active + 12 Resolved + 1 Superseded)

**Phase 1 -- Must-Address (Test Gaps): [All Resolved]**

| ID | Title | Status |
|----|-------|--------|
| ~~[S3](./ActionPlans/Resolved/AP-S3_BatchProcessingTest.md)~~ | ~~No batch processing test with mixed success/failure~~ | **[Resolved]** in commit `4d65465` |
| ~~[S4](./ActionPlans/Resolved/AP-S4_APIFailureDuringResolutionTest.md)~~ | ~~No API failure during resolution test~~ | **[Resolved]** in commit `4d65465` |

**Phase 2 — Should-Address:**

| ID | Title | Priority |
|----|-------|----------|
| ~~[VI-1](./ActionPlans/AP-VI1_OfflineCreatedCipherViewFailure.md)~~ | ~~Offline-created cipher view failure~~ — **[Resolved]** Root cause fixed by `CipherView.withId()` (commit `3f7240a`); all 5 recommended fixes implemented in Phase 2 | ~~Medium~~ N/A |
| ~~[S6](./ActionPlans/Resolved/AP-S6_PasswordChangeCountingTest.md)~~ | ~~No password change counting test~~ -- **[Resolved]** in commit `4d65465` | ~~Medium~~ N/A |
| [S7](./ActionPlans/Resolved/AP-S7_CipherNotFoundPathTest.md) | No cipher-not-found path test — **Partially Resolved** (resolver-level tests added; VaultRepository gap remains) | Medium |
| ~~[S8](./ActionPlans/AP-S8_FeatureFlag.md)~~ | ~~No feature flag for remote disable~~ — **[Resolved]** Two server-controlled flags added (`.offlineSyncEnableResolution`, `.offlineSyncEnableOfflineChanges`), both defaulting to `false` (server-controlled rollout) | ~~Medium~~ N/A |
| [R4](./ActionPlans/AP-R4_SilentSyncAbort.md) | Silent sync abort (no logging) | Medium |

**Phase 3 — Nice-to-Have:**

| ID | Title | Priority |
|----|-------|----------|
| ~~[R2](./ActionPlans/AP-R2_ConflictFolderIdThreadSafety.md)~~ | ~~`conflictFolderId` thread safety~~ — **[Resolved]** `DefaultOfflineSyncResolver` converted from `class` to `actor` | ~~Low~~ N/A |
| [R3](./ActionPlans/AP-R3_RetryBackoff.md) | No retry backoff for permanently failing items | Low |
| [R1](./ActionPlans/AP-R1_DataFormatVersioning.md) | No data format versioning | Low |
| ~~[CS-2](./ActionPlans/AP-CS2_FragileSDKCopyMethods.md)~~ | ~~Fragile SDK copy methods~~ -- **[Resolved]** Consolidated via `makeCopy` helper + Mirror guard tests (commit `1effe90`) | ~~Low~~ N/A |
| ~~[T5](./ActionPlans/Resolved/AP-T5_InlineMockFragility.md)~~ | ~~Inline mock fragility~~ -- **[Resolved]** in commit `4d65465` | ~~Low~~ N/A |
| ~~[T7](./ActionPlans/Resolved/AP-T7_SubsequentOfflineEditTest.md)~~ | ~~No subsequent offline edit test~~ **[Resolved]** — See Resolved/Superseded table below | ~~Low~~ |
| ~~[T8](./ActionPlans/Resolved/AP-T8_HardErrorInPreSyncResolution.md)~~ | ~~No hard error in pre-sync resolution test~~ -- **[Resolved]** in commit `4d65465` | ~~Low~~ N/A |
| [DI-1](./ActionPlans/AP-DI1_DataStoreExposedToUILayer.md) | DataStore exposed to UI layer | Low |

**Phase 4 — Accept/Future:**

| ID | Title | Priority |
|----|-------|----------|
| [U1](./ActionPlans/AP-U1_OrgCipherErrorTiming.md) | Org cipher error after timeout | Informational |
| [U2](./ActionPlans/AP-U2_InconsistentOfflineSupport.md) | Inconsistent offline support (archive, etc.) | Informational |
| [U3](./ActionPlans/AP-U3_NoPendingChangesIndicator.md) | No pending changes UI indicator | Informational |
| ~~[U4](./ActionPlans/AP-U4_EnglishOnlyConflictFolderName.md)~~ | ~~English-only conflict folder name~~ — **[Superseded]** Conflict folder removed | ~~Informational~~ N/A |
| [VR-2](./ActionPlans/AP-VR2_DeleteConvertedToSoftDelete.md) | Permanent delete → soft delete conversion | Informational |
| ~~[RES-1](./ActionPlans/Resolved/AP-RES1_DuplicateCipherOnCreateRetry.md)~~ | ~~Potential duplicate on create retry~~ **[Resolved]** — Hypothetical; same class as P2-T2 | ~~Informational~~ |
| [RES-7](./ActionPlans/AP-RES7_BackupCiphersLackAttachments.md) | Backup ciphers lack attachments | Informational |
| [RES-9](./ActionPlans/AP-RES9_ImplicitCipherDataContract.md) | Implicit cipherData contract for soft delete | Informational |
| [PCDS-1](./ActionPlans/AP-PCDS1_IdOptionalRequiredMismatch.md) | id optional/required mismatch | Informational |
| [PCDS-2](./ActionPlans/AP-PCDS2_DatesOptionalButAlwaysSet.md) | Dates optional but always set | Informational |
| [SS-2](./ActionPlans/AP-SS2_TOCTOURaceCondition.md) | TOCTOU race condition | Informational |

**Resolved/Superseded:**

| ID | Title | Resolution |
|----|-------|------------|
| [A3](./ActionPlans/Resolved/AP-A3_UnusedTimeProvider.md) | Unused timeProvider | Removed in `a52d379` |
| [CS-1](./ActionPlans/Resolved/AP-CS1_StrayBlankLine.md) | Stray blank line | Removed in `a52d379` |
| [SEC-1](./ActionPlans/Resolved/AP-SEC1_SecureConnectionFailedClassification.md) | TLS failure classification | Superseded by URLError removal |
| [EXT-1](./ActionPlans/Resolved/AP-EXT1_TimedOutClassification.md) | Timeout classification | Superseded by URLError removal |
| [T6](./ActionPlans/Resolved/AP-T6_IncompleteURLErrorTestCoverage.md) | URLError test coverage | Resolved by deletion |
| [S3](./ActionPlans/Resolved/AP-S3_BatchProcessingTest.md) | Batch processing test | **Resolved** -- 3 tests added in commit `4d65465` |
| [S4](./ActionPlans/Resolved/AP-S4_APIFailureDuringResolutionTest.md) | API failure during resolution test | **Resolved** -- 4 tests added in commit `4d65465` |
| [S6](./ActionPlans/Resolved/AP-S6_PasswordChangeCountingTest.md) | Password change counting test | **Resolved** -- 4 tests added in commit `4d65465` |
| [S7](./ActionPlans/Resolved/AP-S7_CipherNotFoundPathTest.md) | Cipher-not-found path test | **Partially Resolved** -- resolver-level 404 tests added (commit `e929511`); VaultRepository-level `handleOfflineDelete` guard clause test gap remains |
| [T5](./ActionPlans/Resolved/AP-T5_InlineMockFragility.md) | Inline mock fragility | **Resolved** -- maintenance comment added in commit `4d65465` |
| [T7](./ActionPlans/Resolved/AP-T7_SubsequentOfflineEditTest.md) | Subsequent offline edit test | **Resolved** -- Covered by `test_updateCipher_offlineFallback_preservesCreateType` (Phase 2, commit `12cb225`) |
| [T8](./ActionPlans/Resolved/AP-T8_HardErrorInPreSyncResolution.md) | Hard error in pre-sync resolution test | **Resolved** -- test added in commit `4d65465` |
| [VI-1](./ActionPlans/AP-VI1_OfflineCreatedCipherViewFailure.md) | Offline-created cipher view failure | **Resolved** -- spinner fixed via UI fallback (PR #31); root cause (`data: nil`) **fixed** by `CipherView.withId()` (commit `3f7240a`); all 5 recommended fixes implemented in Phase 2 |

**Superseded:**

| ID | Title | Resolution |
|----|-------|------------|
| [URLError Review](ActionPlans/Superseded/AP-URLError_NetworkConnectionReview.md) | URLError+NetworkConnection extension review | **Superseded** — File deleted in commit `e13aefe`; historical review preserved |

**Cross-reference:** [AP-00_CrossReferenceMatrix.md](./ActionPlans/AP-00_CrossReferenceMatrix.md), [AP-00_OverallRecommendations.md](./ActionPlans/AP-00_OverallRecommendations.md)

---

## File Index

### New Files (13 source + 40 docs)

| File | Lines | Purpose |
|------|-------|---------|
| `Core/Vault/Extensions/CipherView+OfflineSync.swift` | 104 | Cipher copy helpers |
| `Core/Vault/Extensions/CipherViewOfflineSyncTests.swift` | 171 | Extension tests |
| `Core/Vault/Models/Data/PendingCipherChangeData.swift` | 192 | Core Data entity |
| `Core/Vault/Services/OfflineSyncResolver.swift` | 349 | Conflict resolution engine |
| `Core/Vault/Services/OfflineSyncResolverTests.swift` | 933 | Resolver tests |
| `Core/Vault/Services/Stores/PendingCipherChangeDataStore.swift` | 155 | Data store protocol + impl |
| `Core/Vault/Services/Stores/PendingCipherChangeDataStoreTests.swift` | 286 | Data store tests |
| `Core/Vault/Services/Stores/TestHelpers/MockPendingCipherChangeDataStore.swift` | 78 | Data store mock |
| `Core/Vault/Services/TestHelpers/MockOfflineSyncResolver.swift` | 13 | Resolver mock |

### Modified Files (8)

| File | Added | Removed | Purpose |
|------|-------|---------|---------|
| `Core/Platform/Services/ServiceContainer.swift` | +28 | 0 | DI container wiring |
| `Core/Platform/Services/Services.swift` | +16 | 0 | Has* protocol declarations |
| `Core/Platform/Services/Stores/DataStore.swift` | +1 | 0 | User data cleanup |
| `Core/Platform/Services/TestHelpers/ServiceContainer+Mocks.swift` | +4 | 0 | Mock defaults |
| `Core/Vault/Repositories/VaultRepository.swift` | +213 | −10 | Offline fallback handlers |
| `Core/Vault/Repositories/VaultRepositoryTests.swift` | +590 | 0 | Offline fallback tests (41 test methods **[Corrected 2026-02-21]**; initial +132, expanded across Phase 2 commits including feature flag and resolution flag tests) |
| `Core/Vault/Services/SyncService.swift` | +27 | −1 | Pre-sync resolution |
| `Core/Vault/Services/SyncServiceTests.swift` | +81 | 0 | Pre-sync tests (7 test methods **[Corrected 2026-02-21]**; initial +66, expanded by T8 resolution and feature flag tests) |
| `Bitwarden.xcdatamodel/contents` | +17 | 0 | Core Data entity |
