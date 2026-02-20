# Review: VaultRepository Offline Changes

## Files Reviewed

| File | Status | Lines Changed |
|------|--------|--------------|
| `BitwardenShared/Core/Vault/Repositories/VaultRepository.swift` | Modified | +304/-5 |
| `BitwardenShared/Core/Vault/Repositories/VaultRepositoryTests.swift` | Modified | +671 |

## Overview

The `VaultRepository` is the primary repository for vault operations and sits at the outermost layer of the core layer (per `Architecture.md`). The offline sync changes modify four existing methods (`addCipher`, `updateCipher`, `deleteCipher`, `softDeleteCipher`) to catch network failures and fall back to local-only storage, and add four new private helper methods (`handleOfflineAdd`, `handleOfflineUpdate`, `handleOfflineDelete`, `handleOfflineSoftDelete`).

## Architecture Compliance

### Repository Role (Architecture.md)

- **Compliant**: Repositories "synthesize data from multiple sources and combine various asynchronous requests." The offline fallback logic fits this description — the repository decides whether to persist locally when server communication fails.
- **Compliant**: The repository uses injected services (`cipherService`, `clientService`, `pendingCipherChangeDataStore`, `stateService`) through its initializer, following DI patterns.
- **Compliant**: The new `pendingCipherChangeDataStore` dependency is added through the initializer and documented with DocC.

### Error Classification Pattern

Each modified method uses the same error classification pattern:

```swift
do {
    try await <serverOperation>
    // Clean up any orphaned pending change
} catch let error as ServerError {
    throw error
} catch let error as ResponseValidationError where error.response.statusCode < 500 {
    throw error
} catch let error as CipherAPIServiceError {
    throw error
} catch {
    // Offline fallback
    try await handleOffline<Operation>(...)
}
```

**Assessment**:
- **Good**: Client errors (4xx) and known `ServerError`/`CipherAPIServiceError` types are re-thrown immediately — these indicate actual business logic failures (auth, permissions, validation) that should NOT trigger offline fallback.
- **Good**: Only unclassified errors (network failures, 5xx server errors) trigger offline fallback.
- **Concern — Error classification may be overly broad**: The catch-all `catch` block will catch ANY error not matching the preceding patterns. This includes potentially unexpected errors that aren't network-related. However, the conservative approach is to save locally rather than lose the user's edit, so this bias toward data preservation is appropriate for a password manager.
- **Concern — Organization cipher restriction**: Organization ciphers are excluded from offline editing (`guard !isOrgCipher else { throw error }`). This is documented and deliberate — organization ciphers have additional access control and policy requirements that can't be enforced offline. The error message could be improved (currently just re-throws the original network error rather than a specific "org ciphers can't be edited offline" error).

## Detailed Method Analysis

### `addCipher(_:)` — Lines 503-546

**Changes**:
1. Assigns a temporary UUID to new ciphers (`cipher.withId(UUID().uuidString)`) before encryption
2. Wraps `addCipherWithServer` in try/catch with offline fallback
3. On success: cleans up any orphaned pending change
4. On failure: calls `handleOfflineAdd`

**Assessment**:
- **Critical — Temporary ID assignment**: This is the key enabler for offline-created ciphers. Without an ID, the encrypted cipher can't be decrypted later (the ID is baked into the encryption). The comment explains this well.
- **Good**: The temp ID is a UUID, guaranteeing uniqueness and avoiding collision with server-assigned IDs.
- **Good**: On successful online add, any existing pending change for the cipher is cleaned up (handles the case where a previously offline-created cipher is now successfully synced via direct retry).

### `updateCipher(_:)` — Lines 957-994

**Changes**:
1. Checks if cipher is organization-owned
2. Wraps `updateCipherWithServer` in try/catch
3. On success: cleans up pending change
4. On failure: calls `handleOfflineUpdate`

**Assessment**: Follows the same pattern as `addCipher`. No concerns beyond the general ones noted above.

### `deleteCipher(_:)` — Lines 657-679

**Changes**:
1. Wraps `deleteCipherWithServer` in try/catch
2. On success: cleans up pending change
3. On failure: calls `handleOfflineDelete`

**Assessment**:
- **Design decision — Hard delete now uses `.hardDelete` pending change**: **[Updated]** When a hard delete fails offline, `handleOfflineDelete` performs a local deletion and records a `.hardDelete` pending change. On sync, the resolver calls the permanent delete API when no conflict exists, or restores the server version locally when a conflict is detected. This replaces the previous behavior of converting to `.softDelete`. See resolved [AP-VR2](../ActionPlans/Resolved/AP-VR2_DeleteConvertedToSoftDelete.md).
- **Good**: If the cipher was created offline and hasn't been synced, the delete just cleans up locally (no server operation needed).

### `softDeleteCipher(_:)` — Lines 920-951

**Changes**: Same pattern as other methods, delegating to `handleOfflineSoftDelete`.

### `handleOfflineAdd` — Lines 1002-1029

1. Guards for cipher ID
2. Persists encrypted cipher locally via `cipherService.updateCipherWithLocalStorage`
3. Creates `CipherDetailsResponseModel` from the encrypted cipher, JSON-encodes it
4. Upserts pending change with `.create` type

**Assessment**:
- **Good**: Uses `updateCipherWithLocalStorage` which writes directly to Core Data without server communication.
- **Good**: The `CipherDetailsResponseModel` encoding ensures the stored format matches what the resolver expects when processing.
- **Concern — `CipherDetailsResponseModel(cipher:)` constructor**: This constructor builds a response model from a `Cipher` object. If there's a mismatch between the `Cipher` properties and `CipherDetailsResponseModel` properties (e.g., after an SDK update), this could silently drop data. This is documented in `AP-RES9_ImplicitCipherDataContract.md`.

### `handleOfflineUpdate` — Lines 1038-1094

1. Guards for cipher ID
2. Persists locally
3. Checks for existing pending change to determine password change count
4. Detects password changes by comparing decrypted passwords
5. Preserves `.create` change type if the cipher was originally created offline
6. Upserts pending change

**Assessment**:
- **Good**: Password change detection compares decrypted values, ensuring accuracy.
- **Good**: The `.create` type preservation is important — if a cipher was created offline and then edited offline, it should still be treated as a create (POST) rather than update (PUT) when resolved.
- **Good**: The `originalRevisionDate` is preserved from the existing pending change (if any) to maintain the conflict detection baseline.
- **Concern — Performance**: For each offline update, the method decrypts the previous version to compare passwords. If offline edits are frequent, this could be a performance concern. However, for typical usage patterns (editing a single cipher), this is negligible.

### `handleOfflineDelete` — Lines 1105-1143

1. Checks if cipher was created offline → if so, just clean up locally
2. Fetches the current cipher data to preserve it
3. Guards against organization ciphers
4. Deletes locally
5. Records `.softDelete` pending change with the cipher's data

**Assessment**:
- **Good**: The offline-created cipher cleanup is efficient — no need to record a server operation for something the server doesn't know about.
- **Good**: Preserves the cipher data in the pending change record so the resolver can detect conflicts.

### `handleOfflineSoftDelete` — Lines 1151-1180

Similar to `handleOfflineDelete` but uses `updateCipherWithLocalStorage` (to mark as soft-deleted) instead of `deleteCipherWithLocalStorage`.

## Security Assessment

- **Compliant**: All cipher data flowing through the offline helpers is already encrypted by the SDK. The repository doesn't handle any encryption keys directly.
- **Compliant**: The `pendingCipherChangeDataStore` stores the same encrypted format as the main cipher storage.
- **Good**: Organization cipher restrictions prevent offline editing of shared items, which could have policy implications that can't be enforced locally.

## Code Style Compliance

- **Compliant**: MARK comments for the new `// MARK: Offline Helpers` section
- **Compliant**: DocC documentation on all new methods (both public modifications and private helpers)
- **Compliant**: Error handling follows Swift conventions
- **Minor**: The error classification pattern is repeated four times (once per modified method). This could be extracted into a helper, but the repetition is acceptable given the different parameters and handling in each case.

## Data Safety (User Data Loss Prevention)

This is the most critical assessment for the VaultRepository changes:

1. **Never lose user input**: When a server operation fails, the user's edit is ALWAYS saved locally before recording the pending change. The order is: (a) save to local Core Data, (b) record pending change. If step (b) fails after (a) succeeds, the user's data is still in local storage (it just won't be synced until the next online save).

2. **On-success cleanup is safe**: When a server operation succeeds, the pending change record is cleaned up. If the cleanup fails, the orphaned pending change will be processed on next sync but won't cause data loss (the resolver will see the change was already applied and clean up).

3. **Temp ID for new ciphers**: Critical for allowing offline-created ciphers to be decrypted and displayed. Without this, the user would create a cipher offline and be unable to see it.

4. **Password change tracking**: The password change counter ensures that even without server conflicts, heavy offline editing triggers backups during sync resolution.

## Reliability Concerns

1. **JSON encoding could fail**: The `try JSONEncoder().encode(cipherResponseModel)` in the offline helpers could theoretically fail. If it does, the entire offline save fails, and the user's edit is still in local Core Data but without a pending change record. This is a low-risk scenario.

2. **State service call in delete**: `handleOfflineDelete` calls `stateService.getActiveAccountId()` to get the user ID. If the user is logged out between the operation start and this call, it could throw. However, this is extremely unlikely in practice.

## Test Coverage

The `VaultRepositoryTests.swift` adds 671 lines of test coverage:

- `addCipher` offline fallback (network error triggers local save)
- `addCipher` with server error (4xx not caught for offline)
- `updateCipher` offline fallback
- `deleteCipher` offline fallback (converted to soft-delete)
- `softDeleteCipher` offline fallback
- Offline-created cipher subsequently deleted offline (clean up only)
- Organization cipher offline edit rejection
- Pending change cleanup on successful online operation
- Password change counting across multiple offline edits

**Assessment**: Tests cover the key scenarios including happy paths, offline fallback triggers, error classification, and organization cipher restrictions.

## Simplification Opportunities

1. **Extract error classification**: The four-way `do/catch` pattern is repeated in `addCipher`, `updateCipher`, `deleteCipher`, and `softDeleteCipher`. This could be extracted into a generic higher-order function:
   ```swift
   private func withOfflineFallback<T>(
       operation: () async throws -> T,
       fallback: () async throws -> T
   ) async throws -> T
   ```
   However, the different method signatures and fallback parameters make this somewhat awkward. The current explicit repetition is more readable.

2. **Consolidate `handleOfflineDelete` and `handleOfflineSoftDelete`**: These methods share the same pattern (check for offline-created, clean up or record pending change). The only difference is `deleteCipherWithLocalStorage` vs `updateCipherWithLocalStorage`. A shared method with a parameter could reduce duplication, but again the current explicit form is clearer.

## Summary

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Architecture compliance | **Good** | Proper repository-level integration |
| Error classification | **Good** | Conservative: 4xx/known errors re-thrown, unknown → offline |
| Security | **Good** | All data encrypted, org ciphers excluded |
| Code style | **Good** | DocC, MARK comments, naming conventions |
| Data safety | **Good** | Save-locally-first pattern, temp IDs for new ciphers |
| Test coverage | **Good** | Key scenarios well covered |
| Reliability | **Good** | Defensive error handling |
