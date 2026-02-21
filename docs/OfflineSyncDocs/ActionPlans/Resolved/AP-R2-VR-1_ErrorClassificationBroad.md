# AP-R2-VR-1: Error Classification May Be Overly Broad

> **Issue:** #45 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Resolved (Design decision — catch-all bias toward data preservation is correct for password manager)
> **Source:** Review2/03_VaultRepository_Review.md (Error Classification Pattern section)

## Problem Statement

The error classification pattern in `VaultRepository`'s cipher CRUD methods uses a catch-all `catch` block that triggers offline fallback for ANY error not matching the three preceding typed catches (`ServerError`, `ResponseValidationError` with status < 500, `CipherAPIServiceError`). This means unexpected errors that are not network-related -- such as a programming error, a Swift runtime error, or an unrecognized error type from the SDK -- would silently trigger offline fallback instead of propagating to the caller.

While the bias toward data preservation is appropriate for a password manager, it means certain categories of bugs could be masked by the offline fallback, making them harder to detect and diagnose.

## Current Code

The pattern appears identically in four methods in `VaultRepository.swift`:

**`addCipher(_:)` at VaultRepository.swift:529-546:**
```swift
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
    else {
        throw error
    }
    try await handleOfflineAdd(...)
}
```

The same pattern is repeated at:
- `deleteCipher(_:)` at VaultRepository.swift:671-684
- `softDeleteCipher(_:)` at VaultRepository.swift:944-958
- `updateCipher(_:)` at VaultRepository.swift:992-1010

The error types being re-thrown are:
- `ServerError` (defined in `BitwardenKit/Core/Platform/Services/API/Errors/ServerError.swift:7`) -- structured server error response
- `ResponseValidationError` (defined in `BitwardenKit/Core/Platform/Services/API/Handlers/ResponseValidationHandler.swift:7`) with status < 500 -- client-side HTTP errors (4xx)
- `CipherAPIServiceError` (defined in `BitwardenShared/Core/Vault/Services/API/Cipher/CipherAPIService.swift:9`) -- cipher-specific API errors

Any other error type falls through to the offline fallback, including:
- `URLError` (network connectivity issues) -- **correctly** triggers offline fallback
- `ResponseValidationError` with status >= 500 -- **correctly** triggers offline fallback (server issues)
- Any SDK errors from `clientService.vault().ciphers().encrypt()` -- happens BEFORE the try/catch, so does NOT fall through
- `DecodingError` or `EncodingError` from JSON operations -- would **incorrectly** trigger offline fallback if they occurred within the do block
- Any unknown/future error type -- would trigger offline fallback

## Assessment

**Validity:** This issue is technically valid but the practical impact is very low. The three specific catch clauses cover all known server-processed error types. The remaining errors that would fall through to the catch-all are predominantly network errors (`URLError`, `NSURLError`, timeout errors), which are exactly the errors that should trigger offline fallback.

**Key mitigating factors:**

1. **The encryption happens before the do/catch block.** In `addCipher` (line 515-516) and `updateCipher` (line 979), the `clientService.vault().ciphers().encrypt()` call is outside the try/catch. SDK encryption errors propagate directly to the caller without triggering offline fallback. This is critical -- it means SDK errors during encryption do NOT fall through.

2. **The only code inside the do block is the server call and cleanup.** The server call (`addCipherWithServer`, `updateCipherWithServer`, etc.) and the pending change cleanup are the only operations inside the do block. The server calls are well-defined API operations with known error types. The cleanup (`deletePendingChange`) could theoretically throw a Core Data error, but this would only happen on the success path (after the server call succeeded), meaning the cipher was already saved server-side.

3. **The feature flags provide a kill switch.** Both `offlineSyncEnableResolution` and `offlineSyncEnableOfflineChanges` must be true for offline fallback to activate. If unexpected errors are observed, the flags can be disabled remotely.

4. **The conservative bias is correct for a password manager.** If an ambiguous error occurs during a vault save, it is better to preserve the user's data locally (even if unnecessarily) than to lose it by propagating an error that causes the edit to be discarded.

**Blast radius:** If an unexpected non-network error triggers offline fallback:
- The user's edit is saved locally (data preserved)
- A pending change record is created (will attempt resolution on next sync)
- The resolution will likely succeed or fail gracefully
- No data is lost; the worst case is an unnecessary pending change record

**Likelihood:** Very low. The code inside the do blocks is limited to well-defined API calls with known error types.

## Options

### Option A: Add URLError-Specific Catch Before Catch-All (Recommended If Acting)
- **Effort:** Small (1-2 hours)
- **Description:** Add an explicit `catch let error as URLError` clause before the catch-all. This makes the intent clearer -- network errors are the primary expected trigger for offline fallback. The catch-all remains but with a warning log for observability.
- **Pros:** Makes the intent explicit; provides observability for unexpected errors via logging; preserves the conservative fallback behavior
- **Cons:** Does not change behavior; adds one more catch clause to an already-long pattern
- **Implementation:**
  ```swift
  } catch let error as CipherAPIServiceError {
      throw error
  } catch let error as URLError {
      // Expected: network connectivity error triggers offline fallback
      guard !isOrgCipher, ... else { throw error }
      try await handleOffline...(...)
  } catch {
      // Unexpected error type — log for observability, still fall back to offline save
      Logger.application.warning("Unexpected error triggered offline fallback: \(error)")
      guard !isOrgCipher, ... else { throw error }
      try await handleOffline...(...)
  }
  ```

### Option B: Exhaustive Error Classification
- **Effort:** Medium (3-5 hours)
- **Description:** Replace the catch-all with explicit catches for all known error types that should trigger offline fallback (`URLError`, `NSURLError`, `ResponseValidationError` with status >= 500, `POSIXError` for socket errors). Any unrecognized error would be re-thrown.
- **Pros:** No unexpected errors trigger offline fallback; precise error handling
- **Cons:** Fragile -- any new error type from the networking layer would NOT trigger offline fallback, causing the user's edit to be lost; requires maintenance as error types evolve; violates the "preserve data first" principle
- **Risk:** This option introduces a regression risk. If a future SDK or OS update introduces a new network error type, it would not be caught, and users would lose their edits instead of falling back to offline save.

### Option C: Accept As-Is
- **Rationale:** The current pattern is deliberately conservative -- it catches known non-network errors and re-throws them, then falls back to offline save for everything else. This is the correct behavior for a password manager where data preservation is paramount. The encryption step happens outside the do block, so SDK errors are not affected. The feature flags provide a remote kill switch. The practical risk of an unexpected non-network error falling through is extremely low given the limited code inside the do blocks. Adding more catch clauses increases code complexity without meaningful safety improvement.

## Recommendation

**Option C: Accept As-Is.** The current error classification is appropriate for a password manager. The conservative fallback ensures user data is never lost due to ambiguous errors. The specific catches for `ServerError`, 4xx `ResponseValidationError`, and `CipherAPIServiceError` correctly exclude known business logic failures. The encryption step being outside the do block is a key design detail that prevents SDK errors from triggering offline fallback.

If observability is desired, a minimal enhancement would be to add `Logger.application.info()` in the catch-all block to log the error type, without changing behavior. This is lower effort than Option A and provides the same diagnostic benefit.

## Resolution

**Resolved as design decision (2026-02-20).** Deep error-path tracing confirmed that only 2 error types realistically reach the catch-all: `URLError` (network unavailability) and `ResponseValidationError` with status >= 500 (server down). Both correctly warrant offline fallback. The 4 other theoretical error types that could reach the catch-all are all hypothetical:

| Error Type | Why Hypothetical |
|---|---|
| `StateServiceError` | Same microsecond-window impossibility as R2-VR-6 — user can't reach vault UI without active account |
| `DecodingError` | Requires server to ship breaking API change; would break all app operations, not just offline sync |
| `NSError` (Core Data) | Same class as P2-T2 — Core Data writes on serial context don't realistically fail |
| `HTTPResponseError` | Requires fundamentally broken HTTP stack; `.invalidResponse`/`.noURL` never occur in production iOS apps |

The catch-all's bias toward data preservation (save offline rather than lose the edit) is the safer default for a password manager. Feature flags provide a remote kill switch if needed. The encryption step being outside the `do` block prevents SDK errors from triggering offline fallback.

An optional future refinement would be switching to an allowlist approach (`catch let error as URLError` + `catch let error as ResponseValidationError where statusCode >= 500`), but this is a style improvement, not a bug fix.

## Dependencies

- **AP-S8_FeatureFlag.md** (Issue S8, resolved): The server-controlled feature flags provide a safety net if unexpected errors cause problematic offline fallback behavior in production.
