# Review: Changes to Pre-Existing Test Code

## Scope

Three pre-existing test/mock files were modified since the fork at `0283b1f`:

| File | Type | Lines Removed | Lines Added |
|---|---|---|---|
| `ServiceContainer+Mocks.swift` | Mock factory | 0 | 4 |
| `VaultRepositoryTests.swift` | Test file | 0 | ~590 (32 new test methods + setup/teardown plumbing) |
| `SyncServiceTests.swift` | Test file | 0 | ~79 (5 new test methods + setup/teardown plumbing) |

**No existing test code was removed or modified.** All changes are purely additive:
new mock properties in setup/teardown plumbing and new test methods.

---

## File-by-File Summary

### 1. ServiceContainer+Mocks.swift (lines 48, 51, 126, 129)

Two new parameters added to the mock factory with defaults:
- `offlineSyncResolver: OfflineSyncResolver = MockOfflineSyncResolver()`
- `pendingCipherChangeDataStore: PendingCipherChangeDataStore = MockPendingCipherChangeDataStore()`

131 call sites across 107 test files now silently receive these mocks.

### 2. VaultRepositoryTests.swift

**Setup/teardown plumbing (4 insertions):** Added `pendingCipherChangeDataStore` mock property,
initialization, constructor wiring, and teardown.

**32 new test methods** (24 offline fallback + 8 error rethrow):

Offline fallback — add:
- `test_addCipher_offlineFallback` / `test_addCipher_offlineFallback_newCipherGetsTempId`
- `test_addCipher_offlineFallback_orgCipher_throws` / `test_addCipher_offlineFallback_unknownError`
- `test_addCipher_offlineFallback_responseValidationError5xx`

Offline fallback — delete:
- `test_deleteCipher_offlineFallback` / `test_deleteCipher_offlineFallback_cleansUpOfflineCreatedCipher`
- `test_deleteCipher_offlineFallback_orgCipher_throws` / `test_deleteCipher_offlineFallback_unknownError`
- `test_deleteCipher_offlineFallback_responseValidationError5xx`

Offline fallback — update:
- `test_updateCipher_offlineFallback` / `test_updateCipher_offlineFallback_preservesCreateType`
- `test_updateCipher_offlineFallback_passwordChanged_incrementsCount`
- `test_updateCipher_offlineFallback_passwordUnchanged_zeroCount`
- `test_updateCipher_offlineFallback_subsequentEdit_passwordChanged_incrementsCount`
- `test_updateCipher_offlineFallback_subsequentEdit_passwordUnchanged_preservesCount`
- `test_updateCipher_offlineFallback_orgCipher_throws` / `test_updateCipher_offlineFallback_unknownError`
- `test_updateCipher_offlineFallback_responseValidationError5xx`

Offline fallback — soft delete:
- `test_softDeleteCipher_offlineFallback` / `test_softDeleteCipher_offlineFallback_cleansUpOfflineCreatedCipher`
- `test_softDeleteCipher_offlineFallback_orgCipher_throws` / `test_softDeleteCipher_offlineFallback_unknownError`
- `test_softDeleteCipher_offlineFallback_responseValidationError5xx`

Error rethrow (denylist verification):
- `test_addCipher_serverError_rethrows` / `test_addCipher_responseValidationError4xx_rethrows`
- `test_deleteCipher_serverError_rethrows` / `test_deleteCipher_responseValidationError4xx_rethrows`
- `test_updateCipher_serverError_rethrows` / `test_updateCipher_responseValidationError4xx_rethrows`
- `test_softDeleteCipher_serverError_rethrows` / `test_softDeleteCipher_responseValidationError4xx_rethrows`

### 3. SyncServiceTests.swift

**Setup/teardown plumbing (8 insertions):** Added `offlineSyncResolver` and
`pendingCipherChangeDataStore` mock properties with initialization, constructor wiring,
and teardown.

**5 new test methods:**
- `test_fetchSync_preSyncResolution_triggersPendingChanges`
- `test_fetchSync_preSyncResolution_skipsWhenVaultLocked`
- `test_fetchSync_preSyncResolution_noPendingChanges`
- `test_fetchSync_preSyncResolution_abortsWhenPendingChangesRemain`
- `test_fetchSync_preSyncResolution_resolverThrows_syncFails`

---

## Deep Dive Findings

### DEEP DIVE 1: Catch-All Error Handling (RESOLVED)

**Severity: HIGH (original) → LOW (current)**

The production code was initially implemented (commit `fd4a60b`) with precise error filtering:
```swift
} catch let error as URLError where error.isNetworkConnectionError {
```

This was temporarily simplified to a bare `catch` in commit `e13aefe`, but has since been
replaced with a denylist pattern in all four CRUD methods (`addCipher`, `deleteCipher`,
`updateCipher`, `softDeleteCipher`):
```swift
} catch let error as ServerError {
    throw error
} catch let error as ResponseValidationError where error.response.statusCode < 500 {
    throw error
} catch let error as CipherAPIServiceError {
    throw error
} catch {
    // Only reaches here for URLError, 5xx ResponseValidationError, etc.
    try await handleOffline...()
}
```

Client-side validation errors (`CipherAPIServiceError`), server errors (`ServerError`), and
4xx `ResponseValidationError` are now properly rethrown. Only truly transient failures
(network errors, 5xx server errors) fall through to offline handling.

**Impact on pre-existing tests:**
- `test_deleteCipher_idError_nil` (VaultRepositoryTests.swift:779) sets
  `deleteCipherWithServerResult = .failure(CipherAPIServiceError.updateMissingId)`.
  With the denylist pattern, `CipherAPIServiceError` is now rethrown correctly.
- New rethrow tests (`test_*_serverError_rethrows`, `test_*_responseValidationError4xx_rethrows`)
  verify the denylist behavior for all four CRUD operations.

**Conclusion:** This issue is resolved. The denylist pattern correctly filters error types.

---

### DEEP DIVE 2: Missing Negative Assertions in Happy-Path Tests (MODERATE)

**Severity: MODERATE**

Four existing happy-path tests now pass through new do/catch code paths but make no
assertion that offline handling was not triggered:

| Test | Line | Asserts server call? | Asserts no offline? |
|---|---|---|---|
| `test_addCipher` | 126 | Yes | No |
| `test_updateCipher` | 1694 | Partial | No |
| `test_deleteCipher` | 807 | Yes | No |
| `test_softDeleteCipher` | 2115 | Yes | No |

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

### DEEP DIVE 7: Narrow Error Type Coverage (PARTIALLY ADDRESSED)

**Severity: HIGH (original) → MODERATE (current)**

The offline fallback tests primarily use `URLError(.notConnectedToInternet)` as the trigger
error. However, the production code now uses a denylist pattern (not a bare `catch`), and
rethrow tests verify that non-network errors propagate correctly.

| Error Type | Should Trigger Offline? | Tested? |
|---|---|---|
| URLError(.notConnectedToInternet) | Yes | Yes (offline fallback tests) |
| URLError(.timedOut) | Probably yes | No |
| URLError(.networkConnectionLost) | Yes | No |
| ServerError | **No** -- rethrown by denylist | Yes (`test_*_serverError_rethrows`) |
| ResponseValidationError (4xx) | **No** -- rethrown by denylist | Yes (`test_*_responseValidationError4xx_rethrows`) |
| ResponseValidationError (5xx) | Yes -- falls through to offline | Yes (`test_*_offlineFallback_responseValidationError5xx`) |
| CipherAPIServiceError | **No** -- rethrown by denylist | Yes (pre-existing `test_*_idError_nil` tests) |
| DecodingError | Falls through to offline | No |

The denylist pattern addresses the most critical error types. Remaining gaps are limited to
`URLError` variants other than `.notConnectedToInternet` and `DecodingError`.

---

### DEEP DIVE 8: ServiceContainer Mock Defaults (LOW-MODERATE)

**Severity: LOW-MODERATE**

131 calls to `ServiceContainer.withMocks()` across 107 test files now silently receive
the new mocks. Zero customize them. ServiceContainer forwards both dependencies to
`DefaultVaultRepository` (line 848) and `DefaultSyncService` (lines 654, 656).

Primary risk is discoverability: future test authors may not know these dependencies
exist unless they inspect the factory signature.

---

## Overall Assessment

| Deep Dive | Severity | Quality Degraded? |
|---|---|---|
| 1. Catch-all error handling | ~~HIGH~~ → LOW | **Resolved** -- denylist pattern rethrows ServerError, CipherAPIServiceError, 4xx ResponseValidationError |
| 2. Missing negative assertions | MODERATE | Partial -- tests pass but miss regression signals |
| 3. deleteCipher to softDelete | LOW | No -- intentional and documented |
| 4. isVaultLocked caching | LOW | No -- reasonable optimization |
| 5. @MainActor annotation | LOW-MOD | No -- follows existing pattern |
| 6. Mock default bypass | MODERATE | Partial -- tests fragile on mock defaults |
| 7. Narrow error type coverage | ~~HIGH~~ → MODERATE | **Partially addressed** -- denylist rethrow tests added; URLError variants and DecodingError still untested |
| 8. ServiceContainer wiring | LOW-MOD | No -- discoverability concern only |

**The original two critical findings (1 and 7) have been substantially addressed.**
The denylist pattern ensures `ServerError`, `CipherAPIServiceError`, and 4xx
`ResponseValidationError` are rethrown rather than silently caught. Rethrow tests
(`test_*_serverError_rethrows`, `test_*_responseValidationError4xx_rethrows`) and 5xx
offline fallback tests (`test_*_responseValidationError5xx`) verify this behavior.
Remaining gaps are limited to untested `URLError` variants and `DecodingError`.

---

## Post-Review Test Changes on `dev`

Several PRs added test improvements on `dev`:

### PR #27: Close Test Coverage Gap (Commits `481ddc4`, `578a366`)

| Test File | What Was Added |
|-----------|---------------|
| `CipherServiceTests.swift` | URLError propagation tests (`test_addCipherWithServer_networkError_throwsURLError`, `test_updateCipherWithServer_networkError_throwsURLError`) verifying errors flow through `CipherService` → `APIService` → `HTTPService` chain |
| `AddEditItemProcessorTests.swift` | Network error alert tests (`test_perform_savePressed_networkError_showsErrorAlert`, `test_perform_savePressed_existing_networkError_showsErrorAlert`) documenting user-visible symptoms when offline fallback fails |
| `VaultRepositoryTests.swift` | Non-network error rethrow tests (`test_*_serverError_rethrows`, `test_*_responseValidationError4xx_rethrows`) verifying `ServerError` and 4xx `ResponseValidationError` propagate rather than trigger offline save; 5xx offline fallback tests (`test_*_offlineFallback_responseValidationError5xx`) verifying server errors do trigger offline handling |

### PR #33: Test Assertion Fix (Commit `a10fe15`)

Fixed `test_softDeleteCipher` (VaultRepositoryTests.swift:2115) userId assertion from `"1"` to `"13512467-9cfe-43b0-969f-07534084764b"` to match `fixtureAccountLogin()`.

### Impact on Earlier Findings

- **Deep Dive 1 (catch-all error handling)** — **Resolved.** The production code now uses a denylist pattern (`catch ServerError`, `catch CipherAPIServiceError`, `catch ResponseValidationError < 500`) rather than bare `catch`. Client-side validation errors and 4xx HTTP errors are properly rethrown. Rethrow tests in VaultRepositoryTests verify this behavior for all four CRUD operations.
- **Deep Dive 7 (narrow error coverage)** — **Partially addressed.** Rethrow tests (`test_*_serverError_rethrows`, `test_*_responseValidationError4xx_rethrows`) and 5xx fallback tests (`test_*_responseValidationError5xx`) were added to VaultRepositoryTests. URLError propagation tests were added to CipherServiceTests. However, most offline fallback tests still only use `URLError(.notConnectedToInternet)` as the trigger error.
- **Deep Dive 2 (missing negative assertions)** — Still relevant. No negative assertions added to happy-path tests.

### Branch-Only Changes: Backup Reorder and RES-2 404 Handling

Two additional commits on the `claude/fix-pending-change-cleanup-qCAnC` branch added tests to `OfflineSyncResolverTests.swift`:

| Commit | Test Added | What It Verifies |
|--------|-----------|-----------------|
| `e929511` | `test_processPendingChanges_update_cipherNotFound_recreates` | Update resolution where server returns 404 — cipher re-created via `addCipherWithServer`, pending change deleted |
| `e929511` | `test_processPendingChanges_softDelete_cipherNotFound_cleansUp` | Soft delete resolution where server returns 404 — local cipher deleted, pending change deleted |

These tests use `getCipherResult = .failure(OfflineSyncError.cipherNotFound)` to simulate a 404 response from `GetCipherRequest.validate`. The backup reorder commit (`93143f1`) changed behavior but did not add new tests — existing conflict resolution tests implicitly cover the reordered logic.
