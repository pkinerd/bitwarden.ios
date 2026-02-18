# Detailed Review: VaultRepository Offline Changes

## Files Covered

| File | Type | Lines Changed |
|------|------|---------------|
| `BitwardenShared/Core/Vault/Repositories/VaultRepository.swift` | Repository (modified) | +225 lines |
| `BitwardenShared/Core/Vault/Repositories/VaultRepositoryTests.swift` | Tests (modified) | +145 lines |

---

## End-to-End Walkthrough

### Overview

`VaultRepository` is the central repository for vault operations. The offline sync changes modify four existing methods (`addCipher`, `updateCipher`, `deleteCipher`, `softDeleteCipher`) to catch network errors and fall back to offline storage, and add four new private helper methods (`handleOfflineAdd`, `handleOfflineUpdate`, `handleOfflineDelete`, `handleOfflineSoftDelete`).

A new dependency `pendingCipherChangeDataStore: PendingCipherChangeDataStore` is added to the repository.

### 1. Modified Method: `addCipher(_ cipher: CipherView)`

**Before:**
```
encrypt(cipherView) → addCipherWithServer(encrypted) → done
```

**After: [Updated]**
```
1. Check if cipher has organizationId (isOrgCipher)
2. encrypt(cipherView) → try addCipherWithServer(encrypted)
3. [New] On success: clean up any orphaned pending change from a prior offline add
4. catch (denylist pattern):
   a. Rethrow ServerError, CipherAPIServiceError, ResponseValidationError < 500
   b. If isOrgCipher → throw organizationCipherOfflineEditNotSupported
   c. Otherwise → handleOfflineAdd(encryptedCipher, userId)
```

**[Updated]** The catch block evolved from `catch let error as URLError where error.isNetworkConnectionError` through bare `catch` to the current denylist pattern: rethrow `ServerError`, `CipherAPIServiceError`, and `ResponseValidationError` with status < 500; all other errors (including 5xx and `URLError`) trigger offline save.

**[Updated]** On successful server add, orphaned pending change records from prior offline attempts are cleaned up via `pendingCipherChangeDataStore.deletePendingChange(cipherId:userId:)`. This prevents false conflicts on the next sync.

**Security Flow:** The encryption step (`clientService.vault().ciphers().encrypt(cipherView:)`) occurs BEFORE the server call attempt. The encrypted cipher is available in the catch block, so no additional encryption is needed for offline storage. This preserves the encrypt-before-queue invariant.

**Organization Guard:** The org check captures `isOrgCipher` before the API call but only evaluates it in the catch block. This means org ciphers will still attempt the API call first, and only fail with the offline error if the API call fails. When online, org ciphers proceed normally through `addCipherWithServer`.

### 2. Modified Method: `updateCipher(_ cipherView: CipherView)`

**Before:**
```
encrypt(cipherView) → updateCipherWithServer(encrypted) → done
```

**After: [Updated]**
```
1. Check if cipher has organizationId (isOrgCipher)
2. encrypt(cipherView) → try updateCipherWithServer(encrypted)
3. [New] On success: clean up any orphaned pending change from a prior offline save
4. catch (denylist pattern):
   a. Rethrow ServerError, CipherAPIServiceError, ResponseValidationError < 500
   b. If isOrgCipher → throw organizationCipherOfflineEditNotSupported
   c. Otherwise → handleOfflineUpdate(cipherView, encryptedCipher, userId)
```

**[Updated]** Error handling evolved from `catch let error as URLError where error.isNetworkConnectionError` to the current denylist pattern: rethrow `ServerError`, `CipherAPIServiceError`, `ResponseValidationError < 500`; all other errors trigger offline save.

**[Updated]** On successful server update, orphaned pending change records from prior offline attempts are cleaned up via `pendingCipherChangeDataStore.deletePendingChange(cipherId:userId:)`. This mirrors the same cleanup pattern in `addCipher`.

**Notable:** `handleOfflineUpdate` receives both the decrypted `cipherView` (for password change detection) and the encrypted cipher (for local storage). The decrypted view is never persisted — it's used only for an in-memory comparison.

### 3. Modified Method: `deleteCipher(_ id: String)`

**Before:**
```
deleteCipherWithServer(id:) → done
```

**After: [Updated]**
```
1. try deleteCipherWithServer(id:)
2. [New] On success: clean up any orphaned pending change from a prior offline operation
3. catch (denylist pattern):
   a. Rethrow ServerError, CipherAPIServiceError, ResponseValidationError < 500
   b. Otherwise → handleOfflineDelete(cipherId: id)
```

**[Updated]** Error handling evolved from `catch let error as URLError where error.isNetworkConnectionError` to the current denylist pattern: rethrow `ServerError`, `CipherAPIServiceError`, `ResponseValidationError < 500`; all other errors trigger offline save.

**[Updated]** On successful server delete, orphaned pending change records from prior offline attempts are cleaned up via `pendingCipherChangeDataStore.deletePendingChange(cipherId:userId:)`. This mirrors the cleanup pattern in `addCipher` and `updateCipher`.

**Notable:** Unlike the other methods, `deleteCipher` does not have the encrypted cipher available in the catch block (the original method only takes an `id` parameter). The `handleOfflineDelete` helper must fetch the cipher from local storage to get the encrypted data for the pending change record.

### 4. Modified Method: `softDeleteCipher(_ cipher: CipherView)`

**Before:**
```
create softDeletedCipher (with deletedDate) → encrypt → softDeleteCipherWithServer(id, encrypted) → done
```

**After: [Updated]**
```
1. Check if cipher has organizationId (isOrgCipher)
2. create softDeletedCipher (with deletedDate) → encrypt via encryptAndUpdateCipher
3. try softDeleteCipherWithServer(id, encrypted)
4. [New] On success: clean up any orphaned pending change from a prior offline operation
5. catch (denylist pattern):
   a. Rethrow ServerError, CipherAPIServiceError, ResponseValidationError < 500
   b. If isOrgCipher → throw organizationCipherOfflineEditNotSupported
   c. Otherwise → handleOfflineSoftDelete(cipherId, encryptedCipher)
```

**[Updated]** Error handling evolved from `catch let error as URLError where error.isNetworkConnectionError` to the current denylist pattern: rethrow `ServerError`, `CipherAPIServiceError`, `ResponseValidationError < 500`; all other errors trigger offline save.

**[Updated]** On successful server soft-delete, orphaned pending change records from prior offline attempts are cleaned up via `pendingCipherChangeDataStore.deletePendingChange(cipherId:userId:)`. This mirrors the cleanup pattern in the other modified methods.

### 5. New Helper: `handleOfflineAdd` **[Updated]**

```
Parameters: encryptedCipher: Cipher, userId: String

1. Guard let cipherId = encryptedCipher.id (temp ID already assigned by addCipher via CipherView.withId())
2. Persist locally via cipherService.updateCipherWithLocalStorage(cipher)
3. Convert to CipherDetailsResponseModel → JSON-encode
4. Upsert pending change: changeType = .create, passwordChangeCount = 0
```

**Temporary ID Generation:** The temporary UUID is assigned in `addCipher()` **before encryption** via `CipherView.withId(UUID().uuidString)`. This ensures the ID is baked into the encrypted content and survives the decrypt round-trip. `handleOfflineAdd` receives the already-encrypted cipher with the ID set.

~~**Known issue (VI-1 root cause):** `Cipher.withTemporaryId()` sets `data: nil` on the copy.~~ **[RESOLVED]** `Cipher.withTemporaryId()` has been replaced by `CipherView.withId()` operating before encryption (commit `3f7240a`). The `data: nil` problem no longer exists — the cipher is encrypted with the temp ID already set, so all fields (including `data`) are properly populated. The UI fallback (`fetchCipherDetailsDirectly()`) remains as defense-in-depth. See [AP-VI1](ActionPlans/AP-VI1_OfflineCreatedCipherViewFailure.md).

**Why `updateCipherWithLocalStorage` instead of `addCipherWithLocalStorage`?** The method name suggests an update, but it's used for a new cipher. This is because `CipherService.updateCipherWithLocalStorage` performs an upsert (insert-or-update) on the local Core Data store. For a cipher with a new (temporary) ID, this effectively inserts.

### 6. New Helper: `handleOfflineUpdate`

```
Parameters: cipherView: CipherView, encryptedCipher: Cipher, userId: String

1. Guard let cipherId = encryptedCipher.id
2. Persist locally via cipherService.updateCipherWithLocalStorage(encryptedCipher)
3. Convert to CipherDetailsResponseModel → JSON-encode
4. Fetch existing pending change for this cipher/user
5. Get current passwordChangeCount from existing record (or 0)
6. Password change detection:
   a. If existing pending record has cipherData:
      → Decode → Cipher → decrypt → compare passwords
      → If different: increment count
   b. Else (first offline edit):
      → Fetch cipher from local storage → decrypt → compare passwords
      → If different: increment count
7. originalRevisionDate = existing?.originalRevisionDate ?? encryptedCipher.revisionDate
8. [New] Determine changeType: if existing pending record has changeType == .create, preserve .create; otherwise use .update
9. Upsert pending change: changeType = determined type, with updated data and counts
```

**[Updated] `.create` Type Preservation:** If the cipher was originally created offline and hasn't been synced to the server yet (existing pending change has `changeType == .create`), the update preserves the `.create` type instead of overwriting it to `.update`. From the server's perspective, this cipher is still new and needs to be POSTed, not PUTted. This prevents the resolver from trying to GET the cipher by its temporary ID.

**Password Change Detection Logic (lines 1055-1073):**

This is the most complex part of the offline handling. It needs to determine if the current edit changed the password from the previous version. There are two cases:

- **Subsequent offline edit (existing pending record):** Decodes the previous pending cipher data, decrypts it, and compares `login?.password` with the new `cipherView.login?.password`.
- **First offline edit (no existing pending record):** Fetches the current cipher from local storage, decrypts it, and compares.

Both comparisons happen entirely in-memory. The decrypted values are not persisted.

**Note on `originalRevisionDate`:** When this is the first offline edit, `originalRevisionDate` is set to `encryptedCipher.revisionDate` (the cipher's revision date at the time of the edit). For subsequent edits, the existing pending record's `originalRevisionDate` is preserved (via the fallback to `existing?.originalRevisionDate`). However, the upsert call still passes the value, and the `PendingCipherChangeDataStore.upsertPendingChange` implementation ignores it for updates (it preserves the existing value). This is a belt-and-suspenders approach.

### 7. New Helper: `handleOfflineDelete`

```
Parameters: cipherId: String

1. Get active account userId via stateService
2. Fetch cipher from local storage via cipherService.fetchCipher(withId:)
3. If cipher not found → return (silent no-op)
4. If cipher has organizationId → throw organizationCipherOfflineEditNotSupported
5. Soft-delete locally via cipherService.deleteCipherWithLocalStorage(id:)
6. Convert cipher to CipherDetailsResponseModel → JSON-encode
7. Upsert pending change: changeType = .softDelete, originalRevisionDate = cipher.revisionDate
```

~~**Known gap:** If a cipher was created offline (pending type `.create`) and the user deletes it before sync, a `.softDelete` pending change is queued for a temp-ID that doesn't exist on the server.~~ **[RESOLVED]** A `.create`-check cleanup has been added: if the existing pending change has `changeType == .create`, the method deletes the local cipher and pending record and returns — no server operation is queued for a cipher that never existed on the server.

**Important Design Decision:** `deleteCipher` (permanent delete) is converted to a soft delete in offline mode. This is because a permanent delete cannot be undone, and if there's a conflict (server version was edited), the resolver needs the ability to create a backup. By soft-deleting locally, the cipher moves to trash rather than being permanently removed, giving the resolver more options during conflict resolution.

**Organization Guard:** Unlike the other methods where the org check happens in the public method before the offline handler, `handleOfflineDelete` checks `cipher.organizationId` internally. This is because `deleteCipher(_:)` only receives an ID (not a `CipherView`), so the org check must happen after fetching the cipher.

**Silent Return on Not-Found:** If `cipherService.fetchCipher(withId:)` returns `nil`, the method returns silently. This could happen if the cipher was already deleted locally (race condition or double-tap). No pending change is queued.

### 8. New Helper: `handleOfflineSoftDelete`

```
Parameters: cipherId: String, encryptedCipher: Cipher

1. Get active account userId via stateService
2. Persist soft-deleted cipher locally via cipherService.updateCipherWithLocalStorage(encryptedCipher)
3. Convert to CipherDetailsResponseModel → JSON-encode
4. Upsert pending change: changeType = .softDelete
```

~~**Same gap as `handleOfflineDelete`:** No `.create`-check cleanup.~~ **[RESOLVED]** Same `.create`-check cleanup as `handleOfflineDelete` has been added. If the existing pending change has `changeType == .create`, the method deletes the local cipher and pending record and returns — no server operation is queued.

**Note:** The `encryptedCipher` already has `deletedDate` set (this was done in `softDeleteCipher` before the API call). So persisting it locally correctly shows the cipher in the trash UI.

### 9. Methods NOT Modified (Scope Exclusions)

The following `VaultRepository` methods are NOT offline-aware:

| Method | Lines | Impact |
|--------|-------|--------|
| `archiveCipher(_:)` | 546-553 | Generic network error if offline |
| `unarchiveCipher(_:)` | 950-957 | Generic network error if offline |
| `updateCipherCollections(_:)` | 994-997 | Generic network error if offline |
| `shareCipher(...)` | Various | Not applicable (requires network for org encryption) |
| `restoreCipher(_:)` | Various | Generic network error if offline |

This creates an inconsistency: add, update, delete, and soft-delete work offline, but archive, unarchive, collection assignment, and restore do not. Users performing these operations offline receive a generic error rather than an offline-specific message.

---

## Compliance Assessment

### Architecture Compliance

| Guideline | Status | Details |
|-----------|--------|---------|
| Repository synthesizes data from services | **Pass** | Orchestrates cipherService, clientService, pendingCipherChangeDataStore |
| DI via ServiceContainer | **Pass** | `pendingCipherChangeDataStore` added as init parameter |
| No new UI-layer dependencies | **Pass** | All changes are in the core layer repository |
| Existing method signatures unchanged | **Pass** | Public API unchanged; offline handling is internal |

### Code Style Compliance

| Guideline | Status | Details |
|-----------|--------|---------|
| MARK comments | **Pass** | `// MARK: Offline Helpers` groups the new private methods |
| DocC documentation | **Pass** | All four private helper methods have DocC with parameter docs |
| Guard clauses for early returns | **Pass** | Used in `handleOfflineAdd` (cipherId guard), `handleOfflineDelete` (nil guard, org guard) |
| American English | **Pass** | "organization" used consistently |
| Error handling pattern | **Pass** | **[Updated]** Denylist catch pattern: rethrow `ServerError`, `CipherAPIServiceError`, `ResponseValidationError < 500`; all other errors trigger offline save. The encrypt step occurs outside the do-catch, so SDK errors propagate normally. |

### Security Compliance

| Principle | Status | Details |
|-----------|--------|---------|
| Encrypt-before-queue | **Pass** | All offline handlers receive already-encrypted ciphers from the encrypt step before the API call |
| No plaintext persistence | **Pass** | `cipherData` stored in pending record is encrypted JSON |
| Password comparison in-memory only | **Pass** | Decrypted values for password change detection are not persisted |
| Organization cipher restriction | **Pass** | Consistently enforced across all four operations |

### Test Coverage

**[Updated]** Test coverage has expanded significantly since the initial review. The table below reflects all current offline-related tests.

| Test | Scenario |
|------|----------|
| `test_addCipher_offlineFallback` | Network error → local save + pending change created |
| `test_addCipher_offlineFallback_newCipherGetsTempId` | New cipher (nil ID) gets temp UUID before encryption |
| `test_addCipher_offlineFallback_orgCipher_throws` | Org cipher + network error → throws, no local save |
| `test_addCipher_offlineFallback_unknownError` | Unknown error → falls back to offline save |
| `test_addCipher_offlineFallback_responseValidationError5xx` | 5xx response → falls back to offline save |
| `test_addCipher_serverError_rethrows` | ServerError → rethrown, no offline fallback |
| `test_addCipher_responseValidationError4xx_rethrows` | 4xx response → rethrown, no offline fallback |
| `test_deleteCipher_offlineFallback` | Network error → local soft-delete + pending change |
| `test_deleteCipher_offlineFallback_unknownError` | Unknown error → falls back to offline save |
| `test_deleteCipher_offlineFallback_cleansUpOfflineCreatedCipher` | Existing `.create` pending → deletes local cipher + pending record |
| `test_deleteCipher_offlineFallback_responseValidationError5xx` | 5xx response → falls back to offline save |
| `test_deleteCipher_offlineFallback_orgCipher_throws` | Org cipher + network error → throws, no local delete |
| `test_deleteCipher_serverError_rethrows` | ServerError → rethrown, no offline fallback |
| `test_deleteCipher_responseValidationError4xx_rethrows` | 4xx response → rethrown, no offline fallback |
| `test_updateCipher_offlineFallback` | Network error → local save + pending change created |
| `test_updateCipher_offlineFallback_preservesCreateType` | Existing `.create` pending → preserves `.create` type on update |
| `test_updateCipher_offlineFallback_passwordChanged_incrementsCount` | First offline edit, password changed → count = 1 |
| `test_updateCipher_offlineFallback_passwordUnchanged_zeroCount` | First offline edit, password unchanged → count = 0 |
| `test_updateCipher_offlineFallback_subsequentEdit_passwordChanged_incrementsCount` | Subsequent offline edit, password changed → count incremented |
| `test_updateCipher_offlineFallback_subsequentEdit_passwordUnchanged_preservesCount` | Subsequent offline edit, password unchanged → count preserved |
| `test_updateCipher_offlineFallback_orgCipher_throws` | Org cipher + network error → throws, no local save |
| `test_updateCipher_offlineFallback_unknownError` | Unknown error → falls back to offline save |
| `test_updateCipher_offlineFallback_responseValidationError5xx` | 5xx response → falls back to offline save |
| `test_updateCipher_serverError_rethrows` | ServerError → rethrown, no offline fallback |
| `test_updateCipher_responseValidationError4xx_rethrows` | 4xx response → rethrown, no offline fallback |
| `test_softDeleteCipher_offlineFallback` | Network error → local save + pending change |
| `test_softDeleteCipher_offlineFallback_cleansUpOfflineCreatedCipher` | Existing `.create` pending → deletes local cipher + pending record |
| `test_softDeleteCipher_offlineFallback_orgCipher_throws` | Org cipher + network error → throws |
| `test_softDeleteCipher_offlineFallback_unknownError` | Unknown error → falls back to offline save |
| `test_softDeleteCipher_offlineFallback_responseValidationError5xx` | 5xx response → falls back to offline save |
| `test_softDeleteCipher_serverError_rethrows` | ServerError → rethrown, no offline fallback |
| `test_softDeleteCipher_responseValidationError4xx_rethrows` | 4xx response → rethrown, no offline fallback |

**Coverage Assessment:** **[Updated]** Coverage has improved substantially. The following areas previously flagged as missing now have dedicated tests:

- `handleOfflineUpdate` password change detection: Covered by four dedicated tests (first edit changed/unchanged, subsequent edit changed/unchanged)
- `handleOfflineUpdate` with existing pending record: Covered by subsequent edit tests and `preservesCreateType` test
- `handleOfflineAdd` temporary ID assignment: Covered by `test_addCipher_offlineFallback_newCipherGetsTempId`
- Denylist error handling: Covered by `serverError_rethrows`, `responseValidationError4xx_rethrows`, `unknownError`, and `responseValidationError5xx` tests for each operation
- `.create` type cleanup: Covered by `cleansUpOfflineCreatedCipher` tests for delete and soft-delete
- `.create` type preservation: Covered by `preservesCreateType` test for update

**Remaining gap:**

- `handleOfflineDelete` cipher-not-found path (silent return when `fetchCipher` returns `nil`) — no dedicated test

---

## Issues and Observations

### Issue VR-1: Org Cipher Check Timing for `addCipher` and `softDeleteCipher` (Low)

The organization cipher check happens before the offline handler but **after** the network request fails. This means the user must wait for the network timeout (potentially 30-60 seconds for `URLError.timedOut`) before seeing the "organization ciphers not supported offline" error.

**Possible improvement:** Check connectivity proactively before the API call. However, this requires knowing the connectivity state upfront, which the current architecture deliberately avoids (it detects offline by actual API failure). The timing issue is a UX concern, not a correctness issue.

### Issue VR-2: `handleOfflineDelete` Converts Permanent Delete to Soft Delete (Informational)

`deleteCipher` is meant to permanently delete a cipher, but the offline handler performs a soft delete (`deleteCipherWithLocalStorage`). This means the cipher appears in the trash locally rather than being permanently removed. The resolver then performs a soft delete on the server, not a permanent delete.

**Implication:** If a user permanently deletes a cipher while offline, the cipher ends up in trash (locally and server-side) rather than being permanently removed. The user would need to empty trash or delete again after reconnecting.

**Assessment:** This is a reasonable safety compromise. Permanent deletes are irreversible, and in an offline scenario where conflicts can occur, converting to soft delete gives the resolver flexibility to create backups if needed.

### Issue VR-3: `handleOfflineUpdate` Password Detection Compares Only `login?.password` (Low)

The password change detection only compares `login?.password`. It does not detect changes to other sensitive fields like notes, card numbers, identity SSN, or SSH keys. The `offlinePasswordChangeCount` threshold only tracks password changes.

**Assessment:** This is by design — the soft conflict threshold is specifically about password changes, which are the highest-risk field for drift accumulation. Changes to other fields are still synced correctly; they just don't contribute to the soft conflict threshold.

### Issue VR-4: No User Feedback on Successful Offline Save (Informational)

When a cipher is saved offline, the operation completes silently — the user has no indication that their change was saved locally but not yet synced to the server. There's no toast, badge, or other indicator.

**Assessment:** This is an intentional UX decision for the initial implementation. The sync happens automatically on reconnection, so the user doesn't need to take action. A future enhancement could add a subtle indicator when pending offline changes exist.

### Issue VR-5: `handleOfflineDelete` Silent Return on Cipher Not Found (Low)

If `cipherService.fetchCipher(withId:)` returns `nil`, `handleOfflineDelete` returns silently without throwing an error. This means a `deleteCipher` call that fails due to network error and then can't find the cipher locally will complete without error and without queuing a pending change.

**Assessment:** This is a valid edge case but unlikely in practice. The cipher should exist locally because it was visible in the UI when the user initiated the delete.
