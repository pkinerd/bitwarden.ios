# Detailed Review: OfflineSyncResolver

## Files Covered

| File | Type | Lines |
|------|------|-------|
| `BitwardenShared/Core/Vault/Services/OfflineSyncResolver.swift` | Service Protocol + Implementation | 360 |
| `BitwardenShared/Core/Vault/Services/OfflineSyncResolverTests.swift` | Tests | 517 |
| `BitwardenShared/Core/Vault/Services/TestHelpers/MockOfflineSyncResolver.swift` | Mock | 11 |

---

## End-to-End Walkthrough

### 1. Error Enum (`OfflineSyncError`)

Defines four error cases for offline sync operations:

| Error | Description | User-Facing Message |
|-------|-------------|---------------------|
| `.missingCipherData` | Pending change record has no `cipherData` | "The pending change record is missing cipher data." |
| `.missingCipherId` | Pending change record has no cipher ID | "The pending change record is missing a cipher ID." |
| `.vaultLocked` | Vault is locked; resolution cannot proceed | "The vault is locked. Please unlock to sync offline changes." |
| `.organizationCipherOfflineEditNotSupported` | Organization items cannot be edited offline | "Organization items cannot be edited while offline. Please try again when connected." |

All errors conform to `LocalizedError` with `errorDescription` and to `Equatable` for test assertions.

**Note:** The `.vaultLocked` error is defined but never thrown in the current code. The vault-locked guard is in `SyncService.fetchSync()` where it returns early rather than throwing. This error case appears to be defensive, reserved for potential future use.

### 2. Protocol (`OfflineSyncResolver`)

A minimal protocol with a single method:

```swift
protocol OfflineSyncResolver {
    func processPendingChanges(userId: String) async throws
}
```

The protocol's simplicity is a deliberate design choice: the resolver exposes only a batch-processing entry point. Individual change resolution is an internal implementation detail of `DefaultOfflineSyncResolver`.

### 3. Implementation (`DefaultOfflineSyncResolver`)

**Dependencies (6 total):** **[Updated]** `timeProvider` removed in commit `a52d379` (was unused — see resolved Issue RES-5/A3).

| Dependency | Used For |
|------------|----------|
| `cipherAPIService: CipherAPIService` | Fetching server-side cipher state (`getCipher`) |
| `cipherService: CipherService` | Adding/updating/soft-deleting ciphers (server + local) |
| `clientService: ClientService` | Encrypt/decrypt operations via SDK |
| `folderService: FolderService` | Creating/fetching the "Offline Sync Conflicts" folder |
| `pendingCipherChangeDataStore: PendingCipherChangeDataStore` | Fetching/deleting pending change records |
| `stateService: StateService` | Managing account state |

**Instance State:**

- `conflictFolderId: String?` — Cached folder ID for the "Offline Sync Conflicts" folder. Reset to `nil` at the start of each `processPendingChanges` batch. This avoids redundant folder lookups/creation when multiple conflicts are resolved in a single batch.

**Named Constant:**

- `softConflictPasswordChangeThreshold: Int16 = 4` — The minimum offline password change count that triggers a backup even without a server conflict. Extracted to a named constant (addressed from earlier review feedback).

### 4. Resolution Flow

```
processPendingChanges(userId:)
│
├── Fetch all pending changes for the user
├── Guard: return early if none
├── Reset conflictFolderId to nil
│
└── For each pendingChange:
    ├── try resolve(pendingChange:userId:)
    └── catch: Log error via Logger.application, continue to next
```

**Error handling in the loop is catch-and-continue:** If resolving one pending change fails (e.g., API error, decode failure), the error is logged and the loop proceeds to the next change. The failed change remains in the store and will be retried on the next sync. This is the correct behavior — one failure should not block resolution of other independent changes.

### 5. Resolution by Change Type

#### 5a. Create Resolution (`resolveCreate`)

```
1. Decode cipherData → CipherDetailsResponseModel → Cipher
2. Call cipherService.addCipherWithServer(cipher, encryptedFor: userId)
3. Delete pending change record
```

**Important:** The create resolution does NOT replace the temporary client-generated ID with the server-assigned ID. The `addCipherWithServer` method on `CipherService` handles this internally: it pushes the cipher to the server, receives the server response (which contains the real ID), and updates local storage.

**Known gap — orphaned temp-ID record:** After `addCipherWithServer` creates a new `CipherData` record with the server-assigned ID, the old record with the temp client-side ID becomes orphaned. This orphan persists until the next full sync's `replaceCiphers()` call cleans it up. While not harmful, it represents unnecessary data in Core Data between resolution and the next full sync.

**Potential Issue RES-1:** If `addCipherWithServer` fails partway (e.g., the server accepts the cipher but the local storage update fails), the pending change is NOT deleted (the `deletePendingChange` line is reached only after `addCipherWithServer` completes). On retry, this could result in a duplicate cipher on the server. The server has no deduplication mechanism for client-generated UUIDs.

#### 5b. Update Resolution (`resolveUpdate`)

```
1. Fetch server version via cipherAPIService.getCipher(withId:)
2. Decode local pending cipher data
3. Compare server.revisionDate with pendingChange.originalRevisionDate
4. Determine if hasConflict (dates differ) or hasSoftConflict (4+ password changes)

   If hasConflict:
     → resolveConflict(localCipher, serverCipher, pendingChange, userId)

   If hasSoftConflict (no conflict, but 4+ password changes):
     → Push local to server via updateCipherWithServer
     → Create backup of server version

   Else (no conflict, <4 password changes):
     → Push local to server via updateCipherWithServer

5. Delete pending change record
```

**Conflict Resolution Logic (`resolveConflict`):**

```
1. Determine timestamps:
   - localTimestamp = pendingChange.updatedDate ?? pendingChange.createdDate ?? Date.distantPast
   - serverTimestamp = serverCipher.revisionDate

2. If localTimestamp > serverTimestamp (local is newer):
   → Push local to server (updateCipherWithServer)
   → Create backup of server version

3. If serverTimestamp >= localTimestamp (server is newer or same):
   → Update local storage with server version (updateCipherWithLocalStorage)
   → Create backup of local version
```

**Important Design Note:** The timestamp comparison uses `>` (strict greater-than). If timestamps are equal (`localTimestamp == serverTimestamp`), the server version wins. This is a conservative choice — in the case of ambiguity, preserving the server state and backing up the local state ensures no data loss.

#### 5c. Soft Delete Resolution (`resolveSoftDelete`)

```
1. Fetch server version via cipherAPIService.getCipher(withId:)
2. Compare server.revisionDate with pendingChange.originalRevisionDate

   If hasConflict (dates differ):
     → Create backup of server version BEFORE deleting

3. Decode local pending cipher data
4. Call cipherService.softDeleteCipherWithServer(id:, localCipher)
5. Delete pending change record
```

**Design Note:** The soft delete always proceeds, even when there's a conflict. The rationale is that the user explicitly chose to delete the item. The backup preserves the server version (which may have been edited by another user or device) so nothing is lost.

### 6. Backup Cipher Creation (`createBackupCipher`)

```
1. Get or create the "Offline Sync Conflicts" folder (cached per batch)
2. Decrypt the source cipher via clientService.vault().ciphers().decrypt()
3. Format timestamp as "yyyy-MM-dd HHmmss"
4. Construct backup name: "{originalName} - offline conflict {timestamp}"
5. Create backup CipherView via CipherView.update(name:folderId:) — sets id=nil, key=nil
6. Encrypt the backup via clientService.vault().ciphers().encrypt()
7. Push to server via cipherService.addCipherWithServer()
```

**Key Properties of the Backup:**

- `id` is set to `nil` (new cipher, server assigns ID)
- `key` is set to `nil` (SDK generates a new encryption key)
- `attachments` are set to `nil` (attachments are not duplicated)
- All other fields (login, notes, card, identity, password history, fields) are preserved
- The backup is placed in the "Offline Sync Conflicts" folder

### 7. Conflict Folder Management (`getOrCreateConflictFolder`)

```
1. If conflictFolderId is cached → return it
2. Fetch all folders via folderService.fetchAllFolders()
3. For each folder: decrypt and check if name == "Offline Sync Conflicts"
4. If found: cache ID and return
5. If not found:
   a. Create FolderView with name "Offline Sync Conflicts"
   b. Encrypt via clientService.vault().folders().encrypt(folder:)
   c. Create via folderService.addFolderWithServer(name: encryptedFolder.name)
6. Cache new ID and return
```

**[Updated — PR #29 fix]** The folder creation now properly encrypts the folder name before sending to the server. The original code passed the plaintext name "Offline Sync Conflicts" directly to `addFolderWithServer(name:)`, which expects an encrypted string. This caused the Bitwarden SDK to crash (Rust panic) when later trying to decrypt plaintext as ciphertext during folder fetch.

**Performance Note:** This decrypts every folder to find the conflict folder by name. For users with many folders, this is O(n) decryption operations. The caching per-batch mitigates repeated lookups within a single sync, but each sync batch starts fresh. A more efficient approach would be to store the conflict folder ID in `AppSettingsStore`, but the current approach is simpler and the folder count per user is typically small.

---

## Compliance Assessment

### Architecture Compliance

| Guideline | Status | Details |
|-----------|--------|---------|
| Protocol-based service abstraction | **Pass** | `OfflineSyncResolver` protocol with `DefaultOfflineSyncResolver` implementation |
| Single responsibility | **Pass** | Resolver only handles conflict resolution and pending change processing |
| DI via ServiceContainer | **Pass** | Registered via `HasOfflineSyncResolver` in `Services` typealias |
| No circular dependencies | **Pass** | Clean dependency flow into existing services |

### Code Style Compliance

| Guideline | Status | Details |
|-----------|--------|---------|
| MARK comments | **Pass** | `// MARK: Constants`, `// MARK: Properties`, `// MARK: Initialization`, `// MARK: OfflineSyncResolver`, `// MARK: Private` |
| DocC documentation | **Pass** | All public and private methods documented |
| Named constant for magic number | **Pass** | `softConflictPasswordChangeThreshold` extracted |
| American English | **Pass** | "organization" used consistently |
| Error enum conforms to `LocalizedError` | **Pass** | `errorDescription` provided for all cases |

### Security Compliance

| Principle | Status | Details |
|-----------|--------|---------|
| Encrypt before persist (backup) | **Pass** | Backup ciphers are encrypted via SDK before `addCipherWithServer` |
| No plaintext in transit | **Pass** | API calls use encrypted `Cipher` objects |
| Decrypt only in-memory | **Pass** | Decryption for name modification and password comparison is ephemeral |
| Conflict folder name encrypted | **Pass** | **[Fixed in PR #29]** Folder name now encrypted via SDK before `addFolderWithServer`. Original code passed plaintext, causing crash. |

### Test Coverage

| Test | Scenario |
|------|----------|
| `test_processPendingChanges_noPendingChanges` | Empty state — verifies no API calls made |
| `test_processPendingChanges_create` | Create resolution — adds to server, deletes pending record |
| `test_processPendingChanges_update_noConflict` | Update with matching revision dates, <4 password changes |
| `test_processPendingChanges_softDelete_noConflict` | Soft delete with matching revision dates |
| `test_processPendingChanges_update_conflict_localNewer` | Conflict where local wins — pushes local, backs up server |
| `test_processPendingChanges_update_conflict_serverNewer` | Conflict where server wins — updates local, backs up local |
| `test_processPendingChanges_update_softConflict` | Soft conflict (4+ password changes, no server change) |
| `test_processPendingChanges_softDelete_conflict` | Soft delete with server-side changes — backs up server, then deletes |
| `test_processPendingChanges_update_conflict_createsConflictFolder` | Verifies folder creation and backup cipher assignment |
| `test_offlineSyncError_localizedDescription` | Error description verification |
| `test_offlineSyncError_vaultLocked_localizedDescription` | Error description verification |

**Coverage Assessment:** Good coverage of the main resolution paths. The conflict folder creation and naming convention are verified.

---

## Issues and Observations

### Issue RES-1: Potential Duplicate Cipher on Create Retry (Medium)

If `cipherService.addCipherWithServer` succeeds on the server but the local storage update fails, the pending change record is NOT deleted. On the next sync, `resolveCreate` will attempt to add the cipher again, potentially creating a duplicate on the server. The server has no deduplication by client-generated UUID.

**Mitigation:** Low probability in practice because `addCipherWithServer` handles both the API call and local storage update, and local storage writes rarely fail. The user would see a duplicate cipher but would not lose data.

### Issue RES-2: `conflictFolderId` Thread Safety (Low)

`DefaultOfflineSyncResolver` is a `class` (reference type) with a mutable `var conflictFolderId`. There is no actor isolation, lock, or other synchronization. Currently safe because `processPendingChanges` is called sequentially from `SyncService.fetchSync()`, but fragile if the resolver were ever called concurrently.

**Recommendation:** Consider using `actor` instead of `class`, or add a comment documenting the serial-call-only requirement.

### Issue RES-3: No Test for Batch Processing with Mixed Results (Medium)

All tests process a single pending change. No test verifies behavior when the batch contains multiple changes where some succeed and some fail. For example: change A succeeds → change B fails → change A's pending record should be deleted, change B's should remain.

### Issue RES-4: No Test for API Failure During Resolution (Medium)

No test verifies what happens when `addCipherWithServer` or `updateCipherWithServer` throws during resolution. The implementation catches errors and continues, but this path is untested.

### ~~Issue RES-5: `timeProvider` Dependency Unused~~ [Resolved]

~~The `timeProvider` is injected but never referenced in the implementation.~~ **[Resolved]** — The unused `timeProvider` dependency was removed in commit `a52d379`. Dependency count reduced from 7 to 6.

### Issue RES-6: Inline `MockCipherAPIServiceForOfflineSync` is Fragile (Low)

The test file defines an inline `MockCipherAPIServiceForOfflineSync` that implements `CipherAPIService` with `fatalError()` stubs for 15+ unused methods. Any change to the `CipherAPIService` protocol will require updating this mock at compile time. This pattern is acknowledged in the test file with a `// MARK: Unused stubs - required by protocol` comment.

**Recommendation:** If the project has a mechanism for auto-generating mocks (Sourcery `@AutoMockable`), consider using it instead. If not, the inline mock is acceptable given the constraint.

### Observation RES-7: Backup Ciphers Don't Include Attachments

`CipherView.update(name:folderId:)` sets `attachments` to `nil` on the backup copy. This is documented with a comment: "Attachments are not duplicated to backup copies." This is a reasonable limitation — attachments are binary blobs stored separately and duplicating them would be complex and storage-intensive. However, users should be aware that backup copies in the "Offline Sync Conflicts" folder will not have the original's attachments.

### Observation RES-8: Conflict Folder Name is Hardcoded in English

The conflict folder name "Offline Sync Conflicts" is a hardcoded English string, not localized via the app's localization system. This means non-English users will see an English folder name in their vault. However, since the folder name is encrypted and synced to the server (not displayed via the app's localization layer), localization would be complex and inconsistent across devices with different locale settings.

### Observation RES-9: `resolveSoftDelete` Requires `cipherData` but Creates Should Use Only `cipherId`

For soft delete resolution, the implementation decodes `cipherData` to get a local `Cipher` for the `softDeleteCipherWithServer(id:, localCipher)` call. If `cipherData` is nil, it throws `missingCipherData`. This means the `handleOfflineSoftDelete` caller must always provide cipher data. This is guaranteed by the current `VaultRepository` implementation but is an implicit contract.
