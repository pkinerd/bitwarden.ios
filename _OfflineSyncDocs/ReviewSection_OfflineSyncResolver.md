# Detailed Review: OfflineSyncResolver

## Files Covered

| File | Type | Lines |
|------|------|-------|
| `BitwardenShared/Core/Vault/Services/OfflineSyncResolver.swift` | Service Protocol + Implementation | 354 |
| `BitwardenShared/Core/Vault/Services/OfflineSyncResolverTests.swift` | Tests | 940 |
| `BitwardenShared/Core/Vault/Services/TestHelpers/MockOfflineSyncResolver.swift` | Mock | 13 |

---

## End-to-End Walkthrough

### 1. Error Enum (`OfflineSyncError`)

Defines five error cases for offline sync operations:

| Error | Description | User-Facing Message |
|-------|-------------|---------------------|
| `.missingCipherData` | Pending change record has no `cipherData` | "The pending change record is missing cipher data." |
| `.missingCipherId` | Pending change record has no cipher ID | "The pending change record is missing a cipher ID." |
| `.vaultLocked` | Vault is locked; resolution cannot proceed | "The vault is locked. Please unlock to sync offline changes." |
| `.organizationCipherOfflineEditNotSupported` | Organization items cannot be edited offline | "Organization items cannot be edited while offline. Please try again when connected." |
| `.cipherNotFound` | The cipher was not found on the server (HTTP 404) | "The cipher was not found on the server." |

All errors conform to `LocalizedError` with `errorDescription` and to `Equatable` for test assertions.

**[Added]** `.cipherNotFound` is thrown by `GetCipherRequest.validate(_:)` when the server returns a 404. This is caught specifically in `resolveUpdate` and `resolveSoftDelete` to handle the case where a cipher is deleted on the server while the user has pending offline changes.

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

**Dependencies (5 total):** **[Updated]** `timeProvider` removed in commit `a52d379` (was unused — see resolved Issue RES-5/A3). **[Updated]** `folderService` removed — the dedicated "Offline Sync Conflicts" folder has been eliminated; backups now retain the original cipher's folder assignment.

| Dependency | Used For |
|------------|----------|
| `cipherAPIService: CipherAPIService` | Fetching server-side cipher state (`getCipher`) |
| `cipherService: CipherService` | Adding/updating/soft-deleting/deleting ciphers (server + local) |
| `clientService: ClientService` | Encrypt/decrypt operations via SDK |
| ~~`folderService: FolderService`~~ | ~~Creating/fetching the "Offline Sync Conflicts" folder~~ **[Removed]** |
| `pendingCipherChangeDataStore: PendingCipherChangeDataStore` | Fetching/deleting pending change records |
| `stateService: StateService` | Managing account state |

~~**Instance State:**~~

~~- `conflictFolderId: String?` — Cached folder ID for the "Offline Sync Conflicts" folder. Reset to `nil` at the start of each `processPendingChanges` batch. This avoids redundant folder lookups/creation when multiple conflicts are resolved in a single batch.~~

**[Updated]** The `conflictFolderId` cached state has been removed along with the conflict folder feature.

**Named Constant:**

- `static let softConflictPasswordChangeThreshold: Int16 = 4` — The minimum offline password change count that triggers a backup even without a server conflict. Extracted to a static named constant (addressed from earlier review feedback).

### 4. Resolution Flow

```
processPendingChanges(userId:)
│
├── Fetch all pending changes for the user
├── Guard: return early if none
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
2. Save tempId = cipher.id
3. Call cipherService.addCipherWithServer(cipher, encryptedFor: userId)
4. Delete the orphaned temp-ID cipher record via cipherService.deleteCipherWithLocalStorage(id: tempId)
5. Delete pending change record
```

**Important:** The create resolution does NOT replace the temporary client-generated ID with the server-assigned ID. The `addCipherWithServer` method on `CipherService` handles this internally: it pushes the cipher to the server, receives the server response (which contains the real ID), and updates local storage.

**[Updated]** The orphaned temp-ID record is now cleaned up explicitly. After `addCipherWithServer` creates a new `CipherData` record with the server-assigned ID, `resolveCreate` deletes the old record with the temp client-side ID via `deleteCipherWithLocalStorage(id: tempId)`. This prevents the orphan from persisting until the next full sync.

**Potential Issue RES-1:** If `addCipherWithServer` fails partway (e.g., the server accepts the cipher but the local storage update fails), the pending change is NOT deleted (the `deletePendingChange` line is reached only after `addCipherWithServer` completes). On retry, this could result in a duplicate cipher on the server. The server has no deduplication mechanism for client-generated UUIDs.

#### 5b. Update Resolution (`resolveUpdate`)

```
1. Decode local pending cipher data
2. Fetch server version via cipherAPIService.getCipher(withId:)
   — If 404 (OfflineSyncError.cipherNotFound):
     → Re-create cipher on server via addCipherWithServer
     → Delete pending change record
     → Return (skip conflict detection)
3. Compare server.revisionDate with pendingChange.originalRevisionDate
4. Determine if hasConflict (dates differ) or hasSoftConflict (4+ password changes)

   If hasConflict:
     → resolveConflict(localCipher, serverCipher, pendingChange, userId)

   If hasSoftConflict (no conflict, but 4+ password changes):
     → Create backup of server version
     → Push local to server via updateCipherWithServer

   Else (no conflict, <4 password changes):
     → Push local to server via updateCipherWithServer

5. Delete pending change record
```

**[Updated]** Local cipher is now decoded before the server fetch so it's available for the 404 fallback. The 404 path re-creates the cipher on the server, preserving the user's offline edits.

**[Updated]** For both hard conflict and soft conflict paths, the backup is now created *before* the push/update to ensure the losing version is preserved even if the subsequent operation fails.

**Conflict Resolution Logic (`resolveConflict`):**

```
1. Determine timestamps:
   - localTimestamp = pendingChange.updatedDate ?? pendingChange.createdDate ?? Date.distantPast
   - serverTimestamp = serverCipher.revisionDate

2. If localTimestamp > serverTimestamp (local is newer):
   → Create backup of server version
   → Push local to server (updateCipherWithServer)

3. If serverTimestamp >= localTimestamp (server is newer or same):
   → Create backup of local version
   → Update local storage with server version (updateCipherWithLocalStorage)
```

**[Updated]** Backup is now created *before* the push/update in both branches. If `createBackupCipher` fails, the error propagates and the pending change record is NOT deleted — resolution will be retried on the next sync with no data loss.

**Important Design Note:** The timestamp comparison uses `>` (strict greater-than). If timestamps are equal (`localTimestamp == serverTimestamp`), the server version wins. This is a conservative choice — in the case of ambiguity, preserving the server state and backing up the local state ensures no data loss.

#### 5c. Soft Delete Resolution (`resolveSoftDelete`)

```
1. Fetch server version via cipherAPIService.getCipher(withId:)
   — If 404 (OfflineSyncError.cipherNotFound):
     → Delete local cipher record via deleteCipherWithLocalStorage
     → Delete pending change record
     → Return (cipher already gone, user's delete intent satisfied)
2. Compare server.revisionDate with pendingChange.originalRevisionDate

   If hasConflict (dates differ):
     → Create backup of server version BEFORE deleting

3. Decode local pending cipher data
4. Call cipherService.softDeleteCipherWithServer(id: cipherId, localCipher)
5. Delete pending change record
```

**[Updated]** 404 handling added. If the server returns 404, the cipher is already deleted — no server operation needed. Local cleanup and pending change deletion are sufficient.

**Design Note:** The soft delete always proceeds, even when there's a conflict. The rationale is that the user explicitly chose to delete the item. The backup preserves the server version (which may have been edited by another user or device) so nothing is lost.

### 6. Backup Cipher Creation (`createBackupCipher`)

```
1. Decrypt the source cipher via clientService.vault().ciphers().decrypt(cipher:)
2. Format timestamp as "yyyy-MM-dd HH:mm:ss"
3. Construct backup name: "{originalName} - {timestamp}"
4. Create backup CipherView via CipherView.update(name:) — sets id=nil, key=nil; retains original folderId
5. Encrypt the backup via clientService.vault().ciphers().encrypt(cipherView:) → returns EncryptionContext
6. Push to server via cipherService.addCipherWithServer(encryptionContext.cipher, encryptedFor: encryptionContext.encryptedFor)
```

**[Updated]** The `getOrCreateConflictFolder` step has been removed. Backup ciphers now retain the original cipher's folder assignment instead of being placed in a dedicated "Offline Sync Conflicts" folder. This simplifies the resolver by removing the `FolderService` dependency, the `conflictFolderId` cache, and the folder lookup/creation logic (including the folder encryption fix from PR #29).

**Key Properties of the Backup:**

- `id` is set to `nil` (new cipher, server assigns ID)
- `key` is set to `nil` (SDK generates a new encryption key)
- `attachments` are set to `nil` (attachments are not duplicated)
- `attachmentDecryptionFailures` are set to `nil`
- `folderId` retains the original cipher's folder assignment
- All other fields (login, notes, card, identity, secureNote, sshKey, password history, fields) are preserved

### ~~7. Conflict Folder Management (`getOrCreateConflictFolder`)~~ **[Removed]**

~~The `getOrCreateConflictFolder` method and the "Offline Sync Conflicts" folder concept have been removed entirely.~~ Backup ciphers now retain the original cipher's folder assignment. This eliminates:
- The `FolderService` dependency
- The `conflictFolderId` cached state
- The O(n) folder decryption lookup
- The folder encryption fix (PR #29) — no longer applicable
- The English-only folder name concern (see U4)
- The `conflictFolderId` thread safety concern (see R2)

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
| ~~Conflict folder name encrypted~~ | ~~**Pass**~~ | ~~**[Fixed in PR #29]** Folder name now encrypted via SDK before `addFolderWithServer`. Original code passed plaintext, causing crash.~~ **[Removed]** — Conflict folder eliminated; no longer applicable. |

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
| ~~`test_processPendingChanges_update_conflict_createsConflictFolder`~~ | ~~Verifies folder creation and backup cipher assignment~~ **[Removed]** — Conflict folder eliminated |
| `test_processPendingChanges_update_cipherNotFound_recreates` | Update where server returns 404 — re-creates cipher on server |
| `test_processPendingChanges_softDelete_cipherNotFound_cleansUp` | Soft delete where server returns 404 — cleans up locally |
| `test_offlineSyncError_localizedDescription` | Error description verification |
| `test_offlineSyncError_vaultLocked_localizedDescription` | Error description verification |
| `test_processPendingChanges_update_conflict_localNewer_preservesPasswordHistory` | **[New]** Hard conflict (local wins) preserves separate password histories |
| `test_processPendingChanges_update_conflict_serverNewer_preservesPasswordHistory` | **[New]** Hard conflict (server wins) preserves separate password histories |
| `test_processPendingChanges_update_softConflict_preservesPasswordHistory` | **[New]** Soft conflict preserves accumulated local password history |
| `test_processPendingChanges_create_apiFailure_pendingRecordRetained` | **[New]** Create API failure retains pending record |
| `test_processPendingChanges_update_serverFetchFailure_pendingRecordRetained` | **[New]** Update server fetch failure retains pending record |
| `test_processPendingChanges_softDelete_apiFailure_pendingRecordRetained` | **[New]** Soft delete API failure retains pending record |
| `test_processPendingChanges_update_backupFailure_pendingRecordRetained` | **[New]** Backup creation failure retains pending record, blocks main update |
| `test_processPendingChanges_batch_allSucceed` | **[New]** Batch with create, update, soft delete — all succeed, all records cleaned up |
| `test_processPendingChanges_batch_mixedFailure_successfulItemResolved` | **[New]** Batch with mixed success/failure — only successful records cleaned up |
| `test_processPendingChanges_batch_allFail` | **[New]** Batch where all items fail — no records cleaned up |

**Coverage Assessment:** Good coverage of the main resolution paths. **[Updated]** Two tests added for 404 handling in `resolveUpdate` and `resolveSoftDelete`. Conflict folder creation test removed — folder no longer created. **[Updated]** Three password history preservation tests, four API failure tests, and three batch processing tests have been added, significantly improving coverage. Former Issues RES-3 (batch processing) and RES-4 (API failure) are now addressed by these tests.

---

## Issues and Observations

### Issue RES-1: Potential Duplicate Cipher on Create Retry (Medium)

If `cipherService.addCipherWithServer` succeeds on the server but the local storage update fails, the pending change record is NOT deleted. On the next sync, `resolveCreate` will attempt to add the cipher again, potentially creating a duplicate on the server. The server has no deduplication by client-generated UUID.

**Mitigation:** Low probability in practice because `addCipherWithServer` handles both the API call and local storage update, and local storage writes rarely fail. The user would see a duplicate cipher but would not lose data.

### ~~Issue RES-2: `conflictFolderId` Thread Safety (Low)~~ **[Resolved]**

~~`DefaultOfflineSyncResolver` is a `class` (reference type) with a mutable `var conflictFolderId`. There is no actor isolation, lock, or other synchronization.~~ **[Resolved]** `DefaultOfflineSyncResolver` converted from `class` to `actor`, providing compiler-enforced isolation for `conflictFolderId`. See [AP-R2](ActionPlans/AP-R2_ConflictFolderIdThreadSafety.md). **[Updated]** `conflictFolderId` has since been removed entirely along with the conflict folder feature — the actor conversion remains beneficial for general thread safety.

### ~~Issue RES-3: No Test for Batch Processing with Mixed Results (Medium)~~ **[Resolved]**

~~All tests process a single pending change. No test verifies behavior when the batch contains multiple changes where some succeed and some fail.~~ **[Resolved]** Three batch processing tests have been added: `test_processPendingChanges_batch_allSucceed`, `test_processPendingChanges_batch_mixedFailure_successfulItemResolved`, and `test_processPendingChanges_batch_allFail`. These cover the all-succeed, mixed success/failure, and all-fail scenarios respectively.

### ~~Issue RES-4: No Test for API Failure During Resolution (Medium)~~ **[Resolved]**

~~No test verifies what happens when `addCipherWithServer` or `updateCipherWithServer` throws during resolution.~~ **[Resolved]** Four API failure tests have been added: `test_processPendingChanges_create_apiFailure_pendingRecordRetained`, `test_processPendingChanges_update_serverFetchFailure_pendingRecordRetained`, `test_processPendingChanges_softDelete_apiFailure_pendingRecordRetained`, and `test_processPendingChanges_update_backupFailure_pendingRecordRetained`. These verify that pending records are retained on failure and that downstream operations are blocked when upstream steps fail.

### ~~Issue RES-5: `timeProvider` Dependency Unused~~ [Resolved]

~~The `timeProvider` is injected but never referenced in the implementation.~~ **[Resolved]** — The unused `timeProvider` dependency was removed in commit `a52d379`. **[Updated]** Combined with the removal of `folderService`, the dependency count has been reduced from 7 to 5.

### Issue RES-6: `MockCipherAPIServiceForOfflineSync` is Fragile (Low) **[Updated]**

**[Updated]** The mock has been extracted from the test file into its own file at `BitwardenShared/Core/Vault/Services/TestHelpers/MockCipherAPIServiceForOfflineSync.swift`. It implements `CipherAPIService` with `fatalError()` stubs for 15 unused methods. Any change to the `CipherAPIService` protocol will require updating this mock at compile time. The file includes a DocC comment explaining why the manual mock exists (no `// sourcery: AutoMockable` annotation on `CipherAPIService`) and a `// MARK: Unused stubs - required by protocol` section.

**Recommendation:** Consider adding `// sourcery: AutoMockable` to `CipherAPIService` to eliminate this manual maintenance, as suggested in the mock file's documentation.

### Observation RES-7: Backup Ciphers Don't Include Attachments

`CipherView.update(name:)` sets `attachments` to `nil` on the backup copy. This is documented with a comment: "Attachments are not duplicated to backup copies." This is a reasonable limitation — attachments are binary blobs stored separately and duplicating them would be complex and storage-intensive. However, users should be aware that backup copies will not have the original's attachments.

### ~~Observation RES-8: Conflict Folder Name is Hardcoded in English~~ **[Superseded]**

~~The conflict folder name "Offline Sync Conflicts" is a hardcoded English string, not localized via the app's localization system. This means non-English users will see an English folder name in their vault. However, since the folder name is encrypted and synced to the server (not displayed via the app's localization layer), localization would be complex and inconsistent across devices with different locale settings.~~

**[Updated]** The dedicated "Offline Sync Conflicts" folder has been removed entirely. Backup ciphers now retain their original folder assignment. This observation is no longer applicable. See [AP-U4](ActionPlans/AP-U4_EnglishOnlyConflictFolderName.md).

### Observation RES-9: `resolveSoftDelete` Requires `cipherData` but Creates Should Use Only `cipherId`

For soft delete resolution, the implementation decodes `cipherData` to get a local `Cipher` for the `softDeleteCipherWithServer(id:, localCipher)` call. If `cipherData` is nil, it throws `missingCipherData`. This means the `handleOfflineSoftDelete` caller must always provide cipher data. This is guaranteed by the current `VaultRepository` implementation but is an implicit contract.
