# Review: Changes to Pre-Existing Test Code

## Scope

Three pre-existing test/mock files were modified since the fork at `0283b1f`:

| File | Type | Lines Removed | Lines Added |
|---|---|---|---|
| `ServiceContainer+Mocks.swift` | Mock factory | 0 | 4 |
| `VaultRepositoryTests.swift` | Test file | 0 | 108 |
| `SyncServiceTests.swift` | Test file | 0 | 67 |

**No existing test code was removed or modified.** All changes are purely additive:
new mock properties in setup/teardown plumbing and new test methods.

---

## File-by-File Summary

### 1. ServiceContainer+Mocks.swift (lines 48, 51, 126, 129)

Two new parameters added to the mock factory with defaults:
- `offlineSyncResolver: OfflineSyncResolver = MockOfflineSyncResolver()`
- `pendingCipherChangeDataStore: PendingCipherChangeDataStore = MockPendingCipherChangeDataStore()`

131 call sites across 17 test files now silently receive these mocks.

### 2. VaultRepositoryTests.swift

**Setup/teardown plumbing (4 insertions):** Added `pendingCipherChangeDataStore` mock property,
initialization, constructor wiring, and teardown.

**8 new test methods:**
- `test_addCipher_offlineFallback` / `test_addCipher_offlineFallback_orgCipher_throws`
- `test_deleteCipher_offlineFallback` / `test_deleteCipher_offlineFallback_orgCipher_throws`
- `test_updateCipher_offlineFallback` / `test_updateCipher_offlineFallback_orgCipher_throws`
- `test_softDeleteCipher_offlineFallback` / `test_softDeleteCipher_offlineFallback_orgCipher_throws`

### 3. SyncServiceTests.swift

**Setup/teardown plumbing (8 insertions):** Added `offlineSyncResolver` and
`pendingCipherChangeDataStore` mock properties with initialization, constructor wiring,
and teardown.

**4 new test methods:**
- `test_fetchSync_preSyncResolution_triggersPendingChanges`
- `test_fetchSync_preSyncResolution_skipsWhenVaultLocked`
- `test_fetchSync_preSyncResolution_noPendingChanges`
- `test_fetchSync_preSyncResolution_abortsWhenPendingChangesRemain`

---

## Deep Dive Findings

### DEEP DIVE 1: Catch-All Error Handling (CRITICAL)

**Severity: HIGH**

The production code was initially implemented (commit `fd4a60b`) with precise error filtering:
```swift
} catch let error as URLError where error.isNetworkConnectionError {
```

This was removed in commit `e13aefe` and simplified to a bare `catch`, meaning ALL errors
from `addCipherWithServer`, `updateCipherWithServer`, `deleteCipherWithServer`, and
`softDeleteCipherWithServer` are now caught and routed to offline fallback -- including
HTTP 401 (auth expired), 403 (forbidden), 400 (bad request), 404 (not found),
`DecodingError`, and `ResponseValidationError`.

**Impact on pre-existing tests:**
- `test_deleteCipher_idError_nil` (VaultRepositoryTests.swift:689) sets
  `deleteCipherWithServerResult = .failure(CipherAPIServiceError.updateMissingId)`.
  Pre-fork this propagated directly. Now it's caught and routed to `handleOfflineDelete()`,
  which fails on `stateService.getActiveAccountId()` (unconfigured) -- the test may pass
  but for the wrong reason.
- A pre-existing test `test_updateCipher_nonNetworkError_rethrows` was removed in commit
  `e13aefe` with rationale "no longer applicable."

**Conclusion:** The catch-all error handling is a production code design concern that
degrades correctness. The original `URLError.isNetworkConnectionError` filtering was safer.

---

### DEEP DIVE 2: Missing Negative Assertions in Happy-Path Tests (MODERATE)

**Severity: MODERATE**

Four existing happy-path tests now pass through new do/catch code paths but make no
assertion that offline handling was not triggered:

| Test | Line | Asserts server call? | Asserts no offline? |
|---|---|---|---|
| `test_addCipher` | 119 | Yes | No |
| `test_updateCipher` | 1436 | Partial | No |
| `test_deleteCipher` | 684 | Yes | No |
| `test_softDeleteCipher` | 1596 | Yes | No |

If a bug caused the server mock to throw unexpectedly, tests would still pass via
catch block + offline handler, because `MockPendingCipherChangeDataStore` defaults to
`.success(())`.

---

### DEEP DIVE 3: deleteCipher Queues .softDelete (INTENTIONAL)

**Severity: LOW (By Design)**

`handleOfflineDelete()` queues `changeType: .softDelete` for hard-delete operations.
`PendingCipherChangeType` has no `.delete` case -- only `.update`, `.create`, `.softDelete`.

Documented in `_OfflineSyncDocs/ActionPlans/AP-VR2_DeleteConvertedToSoftDelete.md`:
permanent deletes are converted to soft-deletes offline for data safety. Users must
empty trash after reconnecting.

**Conclusion:** Intentional and documented. Not a bug.

---

### DEEP DIVE 4: isVaultLocked Caching (LOW RISK)

**Severity: LOW**

The original `fetchSync` had one call to `isLocked()`. The fork adds a second usage of
the same cached value for the new offline resolution block. Code between usages includes
potentially long-running API calls.

`VaultTimeoutService.isLocked()` reads from a `CurrentValueSubject` dictionary -- it's
a synchronous cached read already. While vault lock status could theoretically change
during the API call, caching is consistent with original intent.

---

### DEEP DIVE 5: @MainActor Annotation (WORKAROUND)

**Severity: LOW-MODERATE**

`test_fetchSync_preSyncResolution_skipsWhenVaultLocked` (PR #9, commit `13d92fb`)
requires `@MainActor` because it mutates `vaultTimeoutService.isClientLocked` on
`MockVaultTimeoutService` implementing the `@MainActor`-isolated `VaultTimeoutService`
protocol.

Follows existing pattern: `test_fetchSync_organizations_vaultLocked` (line 909) uses
the same approach. Many other test files inconsistently access `isClientLocked` without
`@MainActor` -- a pre-existing issue.

---

### DEEP DIVE 6: Mock Default Silently Bypasses Abort Logic (MODERATE)

**Severity: MODERATE**

With default `pendingChangeCountResult = 0` and `processPendingChangesResult = .success(())`,
24 out of 25 pre-existing `fetchSync` tests now silently execute the new offline resolution
code. Only `test_fetchSync_organizations_vaultLocked` skips it.

None of these tests assert anything about offline resolution. If `pendingChangeCountResult`
were changed to any positive number, all 24 tests would break because `fetchSync` returns
early before reaching the sync logic they assert against.

**Tests affected:** test_fetchSync, test_fetchSync_failedParse, test_fetchSync_forceSync,
test_fetchSync_needsSync_lastSyncTime_older30MinsWithRevisions, and 20 others.

---

### DEEP DIVE 7: Narrow Error Type Coverage (CRITICAL)

**Severity: HIGH**

All 8 new offline fallback tests use only `URLError(.notConnectedToInternet)`. The
production catch block catches all error types. Error types NOT tested:

| Error Type | Should Trigger Offline? | Tested? |
|---|---|---|
| URLError(.notConnectedToInternet) | Yes | Yes |
| URLError(.timedOut) | Probably yes | No |
| URLError(.networkConnectionLost) | Yes | No |
| ServerError (HTTP 401) | **No** -- auth failure | No |
| ServerError (HTTP 403) | **No** -- permission denied | No |
| ServerError (HTTP 400) | **No** -- bad request | No |
| ServerError (HTTP 404) | **No** -- not found | No |
| DecodingError | **No** -- parse failure | No |
| ResponseValidationError | **No** -- protocol error | No |

The original implementation used `catch let error as URLError where error.isNetworkConnectionError`
which correctly limited offline fallback to ~10 specific URLError codes. The simplification
to bare `catch` (commit `e13aefe`) creates a critical correctness gap.

---

### DEEP DIVE 8: ServiceContainer Mock Defaults (LOW-MODERATE)

**Severity: LOW-MODERATE**

131 calls to `ServiceContainer.withMocks()` across 17 test files now silently receive
the new mocks. Zero customize them. ServiceContainer forwards both dependencies to
`DefaultVaultRepository` (line 849) and `DefaultSyncService` (lines 655, 657).

Primary risk is discoverability: future test authors may not know these dependencies
exist unless they inspect the factory signature.

---

## Overall Assessment

| Deep Dive | Severity | Quality Degraded? |
|---|---|---|
| 1. Catch-all error handling | **HIGH** | **Yes** -- errors that should propagate are silently caught |
| 2. Missing negative assertions | MODERATE | Partial -- tests pass but miss regression signals |
| 3. deleteCipher to softDelete | LOW | No -- intentional and documented |
| 4. isVaultLocked caching | LOW | No -- reasonable optimization |
| 5. @MainActor annotation | LOW-MOD | No -- follows existing pattern |
| 6. Mock default bypass | MODERATE | Partial -- tests fragile on mock defaults |
| 7. Narrow error type coverage | **HIGH** | **Yes** -- critical error types untested |
| 8. ServiceContainer wiring | LOW-MOD | No -- discoverability concern only |

**The two critical findings (1 and 7) are related:** The catch-all error handling
is a production code defect, and the narrow test coverage fails to catch it. Together
they represent the most significant quality regression: server-side errors (401, 403,
400, etc.) are silently swallowed into offline fallback, and no test verifies this
is wrong.

---

## Post-Review Test Changes on `dev`

Several PRs added test improvements on `dev`:

### PR #27: Close Test Coverage Gap (Commits `481ddc4`, `578a366`)

| Test File | What Was Added |
|-----------|---------------|
| `CipherServiceTests.swift` | URLError propagation tests verifying errors flow through `CipherService` → `APIService` → `HTTPService` chain |
| `AddEditItemProcessorTests.swift` | Network error alert tests documenting user-visible symptoms when offline fallback fails |
| (Both files) | Non-network error rethrow tests (`CipherAPIServiceError`, `ServerError`) verifying these propagate rather than trigger offline save |

### PR #33: Test Assertion Fix (Commit `a10fe15`)

Fixed `test_softDeleteCipher_pendingChangeCleanup` userId assertion from `"1"` to `"13512467-9cfe-43b0-969f-07534084764b"` to match `fixtureAccountLogin()`.

### Impact on Earlier Findings

- **Deep Dive 1 (catch-all error handling)** — **Partially addressed.** The production code now uses a denylist pattern (`catch ServerError`, `catch CipherAPIServiceError`, `catch ResponseValidationError < 500`) rather than bare `catch`. Client-side validation errors and 4xx HTTP errors are properly rethrown. PR #28 tests verify this behavior.
- **Deep Dive 7 (narrow error coverage)** — **Partially addressed.** PR #27 added non-network error rethrow tests, but most offline fallback tests still only use `URLError(.notConnectedToInternet)`.
- **Deep Dive 2 (missing negative assertions)** — Still relevant. No negative assertions added to happy-path tests.
