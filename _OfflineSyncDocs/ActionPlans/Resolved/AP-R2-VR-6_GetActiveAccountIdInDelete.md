# AP-R2-VR-6: getActiveAccountId() in handleOfflineDelete Could Throw

> **Issue:** #47 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Resolved (Hypothetical — sub-millisecond window cannot be triggered)
> **Source:** Review2/03_VaultRepository_Review.md (Reliability Concerns section)

## Problem Statement

The `handleOfflineDelete` and `handleOfflineSoftDelete` methods in `VaultRepository` call `stateService.getActiveAccountId()` as their first operation to obtain the current user ID. If the user has been logged out between the time the cipher operation was initiated and the time `handleOfflineDelete` is called (i.e., during the brief window where the server call was attempted and failed), `getActiveAccountId()` could throw an error indicating no active account exists. This would cause the offline delete handler to fail, and the user's delete intent would be lost.

## Current Code

**`handleOfflineDelete` at VaultRepository.swift:1123-1161:**
```swift
private func handleOfflineDelete(cipherId: String, originalError: Error) async throws {
    let userId = try await stateService.getActiveAccountId()  // Could throw if logged out
    // ... rest of the method uses userId
}
```

**`handleOfflineSoftDelete` at VaultRepository.swift:1169-1199:**
```swift
private func handleOfflineSoftDelete(cipherId: String, encryptedCipher: Cipher) async throws {
    let userId = try await stateService.getActiveAccountId()  // Could throw if logged out
    // ... rest of the method uses userId
}
```

In contrast, `handleOfflineAdd` and `handleOfflineUpdate` receive the `userId` as a parameter (derived from `cipherEncryptionContext.encryptedFor`):

**`handleOfflineAdd` at VaultRepository.swift:1031:**
```swift
private func handleOfflineAdd(encryptedCipher: Cipher, userId: String) async throws {
    // userId is passed in -- no stateService call needed
}
```

**`handleOfflineUpdate` at VaultRepository.swift:1058:**
```swift
private func handleOfflineUpdate(cipherView: CipherView, encryptedCipher: Cipher, userId: String) async throws {
    // userId is passed in -- no stateService call needed
}
```

The asymmetry exists because the delete/soft-delete callers (`deleteCipher` at line 662 and `softDeleteCipher` at line 929) do call `getActiveAccountId()` on the success path for orphaned pending change cleanup, but do not pass the userId to the offline handlers.

## Assessment

**Validity:** This issue is technically valid but the practical likelihood is extremely low. The scenario requires:

1. The user initiates a cipher delete operation (explicit UI action)
2. The server call fails (network error)
3. Between the server call failure and the `handleOfflineDelete` invocation (milliseconds apart, within the same async function), the user is logged out

This sequence is effectively impossible in practice because:
- The user cannot log out while an active operation is in progress (the UI would be showing the vault item view, not the login screen)
- `handleOfflineDelete` is called immediately after the server call fails -- there is no user interaction point between these two calls
- Logout requires explicit user action or session timeout, neither of which can occur during the sub-millisecond gap between the catch clause and the handler call
- Even if account lock occurred (e.g., background app timeout), the `stateService.getActiveAccountId()` returns the active account from stored state, not from an authentication check -- the account still exists even if the vault is locked

**Blast radius:** If `getActiveAccountId()` throws:
- The `handleOfflineDelete` method throws, propagating to the caller
- The caller (`deleteCipher`) already caught the original server error and entered the offline fallback
- The second throw (from `getActiveAccountId`) would propagate to the UI, showing an error
- The cipher would NOT be deleted locally and no pending change would be recorded
- The cipher remains in the vault unchanged -- no data is lost

**Likelihood:** Effectively zero. The time window between the catch and the handler call is sub-millisecond, and the state service returns stored account state (not authentication state).

## Options

### Option A: Pass userId from Caller (Recommended If Acting)
- **Effort:** Small (30 minutes)
- **Description:** Modify `handleOfflineDelete` and `handleOfflineSoftDelete` to accept `userId` as a parameter, consistent with `handleOfflineAdd` and `handleOfflineUpdate`. The callers (`deleteCipher` and `softDeleteCipher`) already call `getActiveAccountId()` on the success path -- move this call before the try/catch so it is available for both paths.
- **Pros:** Eliminates the theoretical race condition; makes all four offline helpers consistent in their parameter signatures; the userId is resolved once at the start of the operation
- **Cons:** Adds a `getActiveAccountId()` call to the happy path of `deleteCipher`/`softDeleteCipher` even when offline fallback is not needed (minor performance impact -- the call is very fast)
- **Implementation for `deleteCipher`:**
  ```swift
  func deleteCipher(_ id: String) async throws {
      let userId = try await stateService.getActiveAccountId()
      do {
          try await cipherService.deleteCipherWithServer(id: id)
          try await pendingCipherChangeDataStore.deletePendingChange(
              cipherId: id,
              userId: userId
          )
      } catch let error as ServerError {
          throw error
      // ... other catches ...
      } catch {
          guard await configService.getFeatureFlag(.offlineSyncEnableResolution),
                await configService.getFeatureFlag(.offlineSyncEnableOfflineChanges)
          else { throw error }
          try await handleOfflineDelete(cipherId: id, userId: userId, originalError: error)
      }
  }
  ```
  And similarly update `handleOfflineDelete` to accept `userId` instead of calling `getActiveAccountId()` internally.

### Option B: Cache userId at Operation Start
- **Effort:** Small (30 minutes)
- **Description:** Within `handleOfflineDelete`, catch the error from `getActiveAccountId()` and fall back to a stored/cached user ID. This preserves the current method signature.
- **Pros:** No changes to callers
- **Cons:** Introduces error swallowing that could mask real issues; adds complexity without clear benefit; the cached value could be stale

### Option C: Accept As-Is
- **Rationale:** The scenario is effectively impossible. The time window between the catch and the handler is sub-millisecond. The `stateService.getActiveAccountId()` returns stored state, not authentication state -- even if the vault locks, the active account ID is still available. The only way this would fail is if the user's account was fully deleted from the device between the catch and the handler, which requires explicit UI interaction that cannot occur during an active async operation. No data is lost even in the failure case -- the cipher remains unchanged in the vault.

## Recommendation

**Option C: Accept As-Is.** The scenario is not realistically possible. However, if any refactoring is done to the offline helpers for other reasons, **Option A** would be a clean improvement that makes all four helpers consistent in accepting `userId` as a parameter. It could be included as a minor cleanup during a larger change, but does not warrant a standalone change.

## Resolution

**Resolved as hypothetical (2026-02-20).** The action plan's own assessment confirms: "The scenario is not realistically possible." The time window between the catch and the handler is sub-millisecond. `stateService.getActiveAccountId()` returns stored state, not authentication state — even if the vault locks, the active account ID is still available. The only way this would fail is if the user's account was fully deleted from the device between the catch and the handler, which requires explicit UI interaction that cannot occur during an active async operation. No data is lost even in the failure case. This is the same class of hypothetical timing issue as P2-T2.

## Dependencies

- No dependencies on other issues. This is a self-contained concern about the `handleOfflineDelete`/`handleOfflineSoftDelete` method signatures.
