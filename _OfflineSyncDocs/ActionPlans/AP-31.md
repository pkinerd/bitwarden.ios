# AP-31: Repeated Error Classification do/catch Pattern in VaultRepository

> **Issue:** #31 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Triaged
> **Source:** Review2/00_Main_Review.md, Review2/03_VaultRepository_Review.md

## Problem Statement

The error classification do/catch pattern is repeated 4 times in `VaultRepository.swift`, once per CRUD operation (`addCipher`, `updateCipher`, `deleteCipher`, `softDeleteCipher`). Each instance follows the same structure: attempt a server operation, then catch specific error types to rethrow them (preventing offline fallback), and finally fall through to an offline handler for unclassified errors. The review suggests extracting a helper to reduce the ~60 lines of duplication (~15 lines per instance).

## Current Code

The pattern appears at these locations in `BitwardenShared/Core/Vault/Repositories/VaultRepository.swift`:

**`addCipher` (lines 517-546):**
```swift
do {
    try await cipherService.addCipherWithServer(...)
    // cleanup
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
    try await handleOfflineAdd(...)
}
```

**`deleteCipher` (lines 663-685):** Same pattern but no `isOrgCipher` guard (org check is inside `handleOfflineDelete`).

**`softDeleteCipher` (lines 936-958):** Same pattern with `isOrgCipher` guard.

**`updateCipher` (lines 980-1011):** Same pattern with `isOrgCipher` guard.

The catch clauses are identical across all 4 methods. The variations are:
1. The server operation called in the `do` block
2. The cleanup logic after a successful server call
3. Whether `isOrgCipher` is guarded in the catch-all (3 of 4 have it; `deleteCipher` checks org inside its handler)
4. The offline handler called and its parameters

## Assessment

**This issue is valid.** The 4-way catch pattern is indeed repeated verbatim across all four methods. However, there are practical considerations that make extraction non-trivial:

1. **Different server operations**: Each method calls a different `cipherService` method with different parameters.
2. **Different success-path cleanup**: Each has slightly different post-success logic (e.g., `addCipher` cleans up by cipher ID from encryption context; `deleteCipher` cleans up with the raw ID and user ID from state service).
3. **Different offline handlers**: Each method has a unique offline handler with different parameters.
4. **Feature flag guards**: The guard clauses in the catch-all are slightly different (`deleteCipher` omits the `isOrgCipher` check).
5. **Closures and async/await**: A generic higher-order function would need to accept async throwing closures for both the server operation (with cleanup) and the fallback, which is syntactically heavy in Swift.

The review itself acknowledges: "each catch block has slightly different parameters, making extraction somewhat awkward" and "the current explicit repetition is more readable."

**Impact of current state:** Low. The repetition is boilerplate-like but each instance is self-contained and easy to understand. Introducing a generic helper might reduce line count but could obscure the specific behavior of each method.

## Options

### Option A: Extract Higher-Order Function
- **Effort:** ~1-2 hours, ~40 lines added, ~60 lines removed (net ~20 line reduction)
- **Description:** Create a private generic helper method:
  ```swift
  private func withOfflineFallback(
      isOrgCipher: Bool = false,
      operation: () async throws -> Void,
      fallback: () async throws -> Void
  ) async throws {
      do {
          try await operation()
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
          try await fallback()
      }
  }
  ```
  Each CRUD method would call this with closures for `operation` and `fallback`.
- **Pros:** Eliminates repetition; centralizes the error classification logic so future changes (e.g., adding a new error type to rethrow) only need to be made in one place
- **Cons:** Closures make the call sites harder to read; obscures the linear flow of each method; `deleteCipher` has a different org check pattern that would need special handling; indirection adds a layer of abstraction for a pattern that is already clear

### Option B: Extract Just the Catch Clauses as a Classification Helper
- **Effort:** ~1 hour, ~20 lines added, ~40 lines removed
- **Description:** Instead of a full higher-order function, extract only the error classification logic:
  ```swift
  private func shouldFallbackOffline(for error: Error, isOrgCipher: Bool) async -> Bool {
      if error is ServerError { return false }
      if let responseError = error as? ResponseValidationError,
         responseError.response.statusCode < 500 { return false }
      if error is CipherAPIServiceError { return false }
      guard !isOrgCipher,
            await configService.getFeatureFlag(.offlineSyncEnableResolution),
            await configService.getFeatureFlag(.offlineSyncEnableOfflineChanges)
      else { return false }
      return true
  }
  ```
  Each CRUD method would have a simpler pattern:
  ```swift
  do { try await serverOp() }
  catch {
      guard await shouldFallbackOffline(for: error, isOrgCipher: isOrgCipher) else { throw error }
      try await handleOfflineAdd(...)
  }
  ```
- **Pros:** Less invasive than Option A; maintains linear flow in each method; centralizes classification logic; readable
- **Cons:** Still 4 separate `do/catch` blocks but significantly shorter; `deleteCipher` needs special treatment for org check

### Option C: Accept As-Is (Recommended)
- **Rationale:** The repetition is ~60 lines across 4 methods in a file that is already >1200 lines. Each instance is self-contained, immediately readable, and follows a clear pattern. The catch clauses are identical and easy to update in all 4 places. The review documents themselves note that "the current explicit repetition is more readable." The risk of introducing a bug during refactoring outweighs the minor DRY benefit.

## Recommendation

**Option C: Accept As-Is.** The repeated pattern is clear, readable, and self-contained. While Options A and B would reduce duplication, they introduce indirection that makes each method's error handling flow less immediately obvious. The current form is the standard approach in the Bitwarden iOS codebase, which generally favors explicit, local patterns over abstract helpers.

If a future change requires modifying the catch clause logic (e.g., adding a new error type to the rethrow list), Option B would be the preferred refactoring approach at that time, as it would prevent the risk of updating 3 of 4 instances and missing the 4th.

## Dependencies

None. This is a standalone code quality concern.
