> **Reconciliation Note (2026-02-21):** This document has been corrected to reflect the actual
> codebase. `stateService` has been removed from `DefaultOfflineSyncResolver` — the resolver now
> has 4 dependencies, not 5. All references to `stateService` as a dependency have been updated.
> The simplification opportunity to remove it is now marked as already done.

# Review: OfflineSyncResolver

## Files Reviewed

| File | Status | Lines Changed |
|------|--------|--------------|
| `BitwardenShared/Core/Vault/Services/OfflineSyncResolver.swift` | **New** | +349 |
| `BitwardenShared/Core/Vault/Services/OfflineSyncResolverTests.swift` | **New** | +933 |
| `BitwardenShared/Core/Vault/Services/TestHelpers/MockOfflineSyncResolver.swift` | **New** | +13 |
| `BitwardenShared/Core/Vault/Services/TestHelpers/MockCipherAPIServiceForOfflineSync.swift` | **New** | +68 |

## Overview

The `OfflineSyncResolver` is the core conflict resolution engine. It processes pending offline changes against the server state, handling creates, updates, and soft-deletes with conflict detection and backup creation. It is implemented as a Swift `actor` for thread safety.

## Architecture Compliance

### Service Layer Placement (Architecture.md)

- **Compliant**: The resolver is a service with a single discrete responsibility — resolving offline changes. It depends on lower-level services (`CipherAPIService`, `CipherService`, `ClientService`) and the data store, which aligns with the architecture's description of services as the "middle layer of the core layer."
- **Compliant**: Exposed via protocol (`OfflineSyncResolver`) with a default implementation (`DefaultOfflineSyncResolver`), following the project's protocol-oriented design.
- **Compliant**: Uses dependency injection — all dependencies are injected through the initializer.

### Actor Design

- **Good**: Using `actor` instead of `class` provides automatic serialization of method calls, preventing data races during concurrent sync resolution. This is appropriate since resolution involves multiple async operations that should not interleave.
- **Note**: The actor isolation means all methods are implicitly `async`. Since the protocol method `processPendingChanges` is already `async`, this is seamless.

## Conflict Resolution Logic

### Processing Flow

```
processPendingChanges(userId:)
  ├── fetchPendingChanges(userId:)
  └── for each change:
      ├── .create     → resolveCreate()
      ├── .update     → resolveUpdate()
      ├── .softDelete → resolveDelete(permanent: false)
      └── .hardDelete → resolveDelete(permanent: true)
```

### resolveCreate

1. Decodes the stored cipher from the pending change's `cipherData`
2. Calls `addCipherWithServer` to upload the cipher
3. Deletes the orphaned local record with the temporary client-side ID
4. Deletes the pending change record

**Assessment**:
- **Good**: Handles the temp-ID cleanup correctly. The server assigns a new ID, so the old temp-ID record must be removed.
- **Risk — Duplicate cipher on retry**: If `addCipherWithServer` succeeds but the cleanup step fails (e.g., app crash), the next sync attempt will try to `addCipherWithServer` again, creating a duplicate on the server. The cipher won't have a server-assigned ID match, so the server will create another copy. This is a known concern documented in `AP-RES1_DuplicateCipherOnCreateRetry.md`.
- **Mitigation**: The user would see a duplicate that they could manually delete. The data is not lost.

### resolveUpdate

1. Decodes the local cipher from pending change
2. Fetches current server version via `getCipher(withId:)`
3. If server returns 404: Re-creates the cipher (preserving user edits)
4. Checks for conflict: `originalRevisionDate != serverRevisionDate`
5. Checks for soft conflict: `offlinePasswordChangeCount >= 4`
6. If conflict: `resolveConflict()` (backs up the losing version, pushes the winning version)
7. If soft conflict (no server change, 4+ password changes): Backs up server version, pushes local
8. Otherwise: Pushes local version directly

**Assessment**:
- **Good**: The 404 handling preserves user data by re-creating the cipher.
- **Good**: The conflict resolution creates backups before overwriting, preventing data loss.
- **Concern — Conflict resolution timestamp comparison**: `resolveConflict` uses `localTimestamp > serverTimestamp` to determine which version "wins." The `localTimestamp` is derived from `pendingChange.updatedDate ?? pendingChange.createdDate ?? Date.distantPast`. This is a client-side timestamp, which may not be reliable (device clock could be wrong). However, this is a reasonable heuristic — the key point is that both versions are preserved as backups, so no data is lost regardless of which "wins."
- **Good**: The soft conflict threshold (4 password changes) ensures that even without server-side changes, heavy offline editing triggers a backup for safety.

### ~~resolveSoftDelete~~ → resolveDelete(permanent:) **[Refactored]**

1. Fetches current server version
2. If 404: Cipher already deleted on server — clean up local
3. If conflict: Restores server version locally, drops pending delete (user can review and re-decide)
4. If no conflict: Calls the appropriate server delete API (`deleteCipher` for permanent, `softDeleteCipher` for soft)

**Assessment**:
- **Good**: Handles all edge cases (already deleted, conflict, no conflict)
- **Good**: Conflict behavior changed from backup+delete to restore — safer for the user
- **Good**: Unified method avoids duplication between soft and hard delete paths

### createBackupCipher

1. Decrypts the cipher
2. Appends timestamp to name: `"<name> - 2024-01-15 14:30:00"`
3. Creates a new cipher with `id: nil` and `key: nil` (server will assign new ID and key)
4. Encrypts and uploads as a new cipher

**Assessment**:
- **Good**: Setting `id: nil` and `key: nil` ensures the backup is treated as a completely new cipher by the server.
- **Concern — Attachments not duplicated**: The backup is created with `attachments: nil`. This means if the original cipher had attachments, they won't be present in the backup. This is documented in `AP-RES7_BackupCiphersLackAttachments.md`. For a password manager, this is a reasonable trade-off (attachment duplication would be complex and potentially expensive in server storage).
- **Minor — Date format is locale-independent**: Uses `DateFormatter` with explicit format `"yyyy-MM-dd HH:mm:ss"`, which is good — it won't change based on user locale. However, it uses the device's default timezone, so the timestamp may not match server time. This is cosmetic only.
- **Minor — English-only backup naming**: The backup name pattern `"<name> - <timestamp>"` uses a hardcoded English format. This has been flagged as superseded in `AP-U4_EnglishOnlyConflictFolderName.md` — the simpler naming scheme (just appending timestamp) is considered acceptable since it doesn't use English words.

## Error Handling

- **Good**: Each pending change is processed independently in a `do/catch` block. Failure to resolve one change doesn't prevent processing of subsequent changes. Errors are logged via `Logger.application.error()`.
- **Concern — Silently swallowed errors**: When a single change resolution fails, the error is logged but the pending change remains in the store for the next sync attempt. This is reasonable for transient errors but could lead to permanently stuck changes if the error is structural (e.g., corrupted `cipherData`). There's no retry limit or escalation mechanism.
- **Note**: The `OfflineSyncError` enum provides clear, meaningful error cases (`missingCipherData`, `missingCipherId`, `vaultLocked`, `cipherNotFound`). These are `LocalizedError` compliant and `Equatable` for testing.

## Security Assessment

- **Compliant**: The resolver operates on already-encrypted data. It decrypts ciphers only through the Bitwarden SDK's `clientService.vault().ciphers().decrypt()`, maintaining the zero-knowledge architecture.
- **Compliant**: No encryption keys are stored or handled directly.
- **Compliant**: The resolver doesn't bypass any authentication or authorization checks — it uses the same `CipherAPIService` and `CipherService` that the online code paths use.

## Code Style Compliance

- **Compliant**: MARK comments properly structured (Constants, Properties, Initialization, OfflineSyncResolver, Private)
- **Compliant**: DocC documentation on all public and private methods
- **Compliant**: Alphabetical ordering within sections
- **Compliant**: Protocol + default implementation pattern

## Data Safety (User Data Loss Prevention)

This is the most critical component for data safety. Assessment:

1. **Backup-before-overwrite pattern**: When conflicts are detected, the resolver ALWAYS creates a backup before overwriting. The backup creation happens BEFORE the overwrite operation. This is the key safety property — if the overwrite succeeds but subsequent operations fail, the backup still exists.

2. **404 handling preserves data**: When a cipher was deleted on the server while offline, the `resolveUpdate` method re-creates it rather than silently discarding the user's edits. This is the correct data-preserving behavior.

3. **Pending changes persist until resolved**: Changes remain in Core Data until explicitly deleted after successful resolution. If the app crashes mid-resolution, the pending change persists for the next attempt.

4. **No destructive cleanup on failure**: If resolution fails (network error, etc.), the pending change is NOT deleted — it remains for retry.

## Reliability Concerns

1. **No retry backoff**: If a pending change repeatedly fails to resolve (e.g., server returns 500), it will be retried on every sync attempt without any backoff. This could lead to excessive API calls. Documented in `AP-R3_RetryBackoff.md`.

2. **No data format versioning**: If the format of `cipherData` (the JSON-encoded `CipherDetailsResponseModel`) changes between app versions, old pending changes may fail to decode. There's no version field to detect this. Documented in `AP-R1_DataFormatVersioning.md`.

3. **Batch processing is sequential**: All pending changes are processed one-by-one in a `for` loop. If a user has many pending changes, this could be slow. However, this is simpler and avoids complex concurrent conflict resolution.

## Cross-Component Dependencies

The resolver depends on 4 services:
- `CipherAPIService` — for fetching server state (`getCipher`)
- `CipherService` — for local storage operations and server upload
- `ClientService` — for SDK encryption/decryption
- `PendingCipherChangeDataStore` — for managing pending changes

**Assessment**: These dependencies are all within the Vault domain or Platform services. No cross-domain coupling is introduced. The dependency set is minimal and well-scoped — each dependency serves a clear purpose in the resolution flow.

## Test Coverage

The `OfflineSyncResolverTests.swift` file (933 lines) covers:

- **resolveCreate**: Success path, temp-ID cleanup
- **resolveUpdate**: No conflict (push local), conflict with local newer (backup server, push local), conflict with server newer (backup local, keep server), soft conflict (4+ password changes), cipher not found on server (re-create)
- **resolveSoftDelete**: No conflict, conflict (backup then delete), cipher already deleted on server
- **Batch processing**: Multiple pending changes processed sequentially
- **API failure during resolution**: Error logged, subsequent changes still processed
- **Password change counting**: Threshold-based backup triggering
- **Cipher not found path**: 404 handling

**Assessment**: Test coverage is thorough. Tests use the `MockCipherAPIServiceForOfflineSync` which is a dedicated mock for the `getCipher` API call, allowing fine-grained control over server responses.

## Simplification Opportunities

1. ~~**Remove unused `stateService` dependency**~~ — **Already done**: `stateService` has been removed from the resolver. The initializer now takes only 4 parameters.
2. **Consider making `softConflictPasswordChangeThreshold` configurable**: Currently hardcoded to 4 as a `static let`. If this needs tuning based on user feedback, it would need a code change.
3. **The `resolveConflict` method could be simplified**: The local-newer and server-newer branches have symmetric structure (backup loser, apply winner). This could be abstracted but the current explicit form is more readable.

## Summary

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Architecture compliance | **Good** | Proper service layer placement, protocol-based DI |
| Conflict resolution correctness | **Good** | Backup-before-overwrite, 404 preservation |
| Security | **Good** | Uses SDK encryption, no key handling |
| Code style | **Good** | Follows all conventions |
| Data safety | **Good** | Critical backup-first pattern consistently applied |
| Error handling | **Adequate** | Per-change isolation, but no retry limits |
| Reliability | **Adequate** | No backoff, no data versioning |
| Test coverage | **Good** | Comprehensive scenario coverage |
| Thread safety | **Good** | Actor provides serialization |
