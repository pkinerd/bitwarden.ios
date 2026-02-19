# AP-P2-T3: Orphaned Pending Change Cleanup Failure After Server Success

> **Issue:** #52 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Triaged
> **Source:** OfflineSyncCodeReview_Phase2.md (Section 2.3, Test Gaps P2-T3)

## Problem Statement

In `VaultRepository`, when a cipher operation succeeds on the server (e.g., `addCipherWithServer`, `deleteCipherWithServer`, `updateCipherWithServer`, `softDeleteCipherWithServer`), the code immediately attempts to delete any orphaned pending change record for that cipher. This cleanup call (`pendingCipherChangeDataStore.deletePendingChange`) is inside the same `do/catch` block as the server call.

If the cleanup call fails (throws an error), the error falls through the typed catch clauses (`ServerError`, `ResponseValidationError`, `CipherAPIServiceError`) -- since it's a Core Data error, it doesn't match any of them. It then reaches the catch-all block, which attempts to perform an offline fallback. This means:

1. The server operation has already succeeded (the cipher was created/updated/deleted on the server)
2. The pending change cleanup fails
3. The catch-all block tries to save the cipher offline again (creating a new pending change or performing an offline operation)
4. The caller sees an error even though the server operation was successful

This creates a confusing state where a successful operation appears to fail to the UI, and may result in a duplicate pending change record.

## Current Code

**Example in `addCipher` at VaultRepository.swift:517-546:**
```swift
do {
    try await cipherService.addCipherWithServer(                    // Step 1: Server call (succeeds)
        cipherEncryptionContext.cipher,
        encryptedFor: cipherEncryptionContext.encryptedFor,
    )
    // Clean up any orphaned pending change from a prior offline add.
    if let cipherId = cipherEncryptionContext.cipher.id {
        try await pendingCipherChangeDataStore.deletePendingChange( // Step 2: Cleanup (could fail)
            cipherId: cipherId,
            userId: cipherEncryptionContext.encryptedFor
        )
    }
} catch let error as ServerError {
    throw error
} catch let error as ResponseValidationError where error.response.statusCode < 500 {
    throw error
} catch let error as CipherAPIServiceError {
    throw error
} catch {                                                           // Step 3: Cleanup failure caught here
    guard !isOrgCipher,
          await configService.getFeatureFlag(.offlineSyncEnableResolution),
          await configService.getFeatureFlag(.offlineSyncEnableOfflineChanges)
    else {
        throw error
    }
    try await handleOfflineAdd(...)                                  // Step 4: Offline fallback triggered incorrectly
}
```

The same pattern exists in:
- `deleteCipher` at VaultRepository.swift:662-685 (lines 664-670 for server + cleanup)
- `softDeleteCipher` at VaultRepository.swift:929-958 (lines 937-943 for server + cleanup)
- `updateCipher` at VaultRepository.swift:970-1011 (lines 981-991 for server + cleanup)

In `deleteCipher`, there's an additional complication: `stateService.getActiveAccountId()` at line 666 is also inside the do block. If THIS call fails, the same cascade occurs.

## Assessment

**Validity:** This issue is technically valid. The cleanup call is inside the do/catch block, and its failure would be caught by the catch-all, triggering an incorrect offline fallback. However, the practical likelihood and impact are extremely low:

1. **`deletePendingChange(cipherId:userId:)` is a simple Core Data delete.** It fetches records matching a predicate and deletes them. The fetch is a simple equality predicate on indexed fields. The delete is a standard Core Data operation. Core Data delete failures on in-memory objects are extremely rare.

2. **If no pending change exists, the delete is a no-op.** The method at `PendingCipherChangeDataStore.swift:135-143` fetches matching records and deletes them in a loop. If no records match, nothing happens -- no error.

3. **The offline fallback would be mostly harmless.** If triggered incorrectly:
   - For `addCipher`: `handleOfflineAdd` would save the cipher locally (it already exists from the server response) and create a pending change. On next sync, `resolveCreate` would attempt to add it again, potentially creating a server duplicate. However, the feature flag guards would prevent this unless both flags are enabled.
   - For `updateCipher`: `handleOfflineUpdate` would save locally and create a pending change. On next sync, `resolveUpdate` would fetch the server version (which was just updated), find no conflict (same revision date), and push the local version again -- a no-op overwrite.
   - For `deleteCipher`/`softDeleteCipher`: The offline handler would attempt to save a soft-delete pending change. On next sync, the resolver would find the cipher already deleted/soft-deleted and clean up.

4. **The UI would show an error message.** The caller (typically an AddEditItemProcessor or ViewItemProcessor) would display a generic error, even though the operation succeeded. This is the most user-facing impact.

**Blast radius:**
- The server operation already succeeded -- no data loss
- A spurious pending change record may be created
- The UI shows an error for a successful operation
- On next sync, the pending change is resolved (possibly creating a duplicate for add operations)

**Likelihood:** Extremely low. Core Data delete operations on properly-initialized contexts with valid predicates do not fail.

## Options

### Option A: Move Cleanup Outside the Do/Catch Block (Recommended)
- **Effort:** Small (1-2 hours)
- **Description:** Move the `deletePendingChange` call after the do/catch block, so it only executes on the success path and its failure does not trigger the offline fallback. Use a separate do/catch for the cleanup to handle its errors independently.
- **Pros:** Prevents the incorrect offline fallback; makes the control flow clearer; the cleanup error can be logged without affecting the user experience
- **Cons:** Slightly changes the structure of four methods; the cleanup error is swallowed (but this is acceptable since the server operation already succeeded)
- **Implementation for `addCipher`:**
  ```swift
  func addCipher(_ cipher: CipherView) async throws {
      let isOrgCipher = cipher.organizationId != nil
      let cipherToEncrypt = cipher.id == nil ? cipher.withId(UUID().uuidString) : cipher
      let cipherEncryptionContext = try await clientService.vault().ciphers()
          .encrypt(cipherView: cipherToEncrypt)

      do {
          try await cipherService.addCipherWithServer(
              cipherEncryptionContext.cipher,
              encryptedFor: cipherEncryptionContext.encryptedFor,
          )
      } catch let error as ServerError {
          throw error
      } catch let error as ResponseValidationError where error.response.statusCode < 500 {
          throw error
      } catch let error as CipherAPIServiceError {
          throw error
      } catch {
          guard !isOrgCipher,
                await configService.getFeatureFlag(.offlineSyncEnableResolution),
                await configService.getFeatureFlag(.offlineSyncEnableOfflineChanges)
          else { throw error }
          try await handleOfflineAdd(
              encryptedCipher: cipherEncryptionContext.cipher,
              userId: cipherEncryptionContext.encryptedFor
          )
          return  // Don't proceed to cleanup -- we're in offline mode
      }

      // Server operation succeeded -- clean up any orphaned pending change.
      // Failure here is non-critical; the pending change will be cleaned up
      // on next sync resolution.
      if let cipherId = cipherEncryptionContext.cipher.id {
          try? await pendingCipherChangeDataStore.deletePendingChange(
              cipherId: cipherId,
              userId: cipherEncryptionContext.encryptedFor
          )
      }
  }
  ```

### Option B: Add a Success Flag Pattern
- **Effort:** Small (1-2 hours)
- **Description:** Add a `var serverSucceeded = false` flag before the do block. Set it to `true` after the server call. In the catch-all, check this flag before triggering offline fallback.
- **Pros:** Minimal structural change; explicit about what happened
- **Cons:** Introduces mutable state; slightly less clean than Option A; the flag pattern is a code smell
- **Implementation:**
  ```swift
  var serverSucceeded = false
  do {
      try await cipherService.addCipherWithServer(...)
      serverSucceeded = true
      // ... cleanup ...
  } catch ... {
  } catch {
      if serverSucceeded {
          // Server succeeded but cleanup failed -- log and continue
          Logger.application.warning("Pending change cleanup failed after successful server operation: \(error)")
          return
      }
      // ... offline fallback ...
  }
  ```

### Option C: Accept As-Is
- **Rationale:** The `deletePendingChange` call cannot realistically fail. It's a simple Core Data delete with a basic predicate on an in-memory context. Core Data delete failures are extremely rare -- they would require a corrupted context or an invalid managed object, neither of which can occur in normal operation. Even if the cleanup did fail and the catch-all was triggered, the impact is minimal: the server operation already succeeded, and the spurious pending change would be cleaned up on the next sync. The user would see a confusing error message, but no data would be lost. The effort to restructure four methods for an effectively-impossible failure scenario is not justified.

## Recommendation

**Option A: Move Cleanup Outside the Do/Catch Block** is the recommended approach if any changes are made. It is a clean, low-effort refactor that makes the control flow explicit and prevents the incorrect offline fallback cascade. The `try?` pattern for cleanup errors is appropriate since the server operation already succeeded.

However, **Option C: Accept As-Is** is also reasonable given the extremely low likelihood of the scenario. If the team prefers minimal changes, this issue can be deferred without practical risk.

## Dependencies

- **AP-R2-VR-6** (Issue #47): The `getActiveAccountId()` call in `deleteCipher` (line 666) has a related concern -- it's also inside the do block. If moved, it should be moved together with the `deletePendingChange` call.
- No other dependencies.
