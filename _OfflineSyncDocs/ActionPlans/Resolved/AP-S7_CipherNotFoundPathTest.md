# Action Plan: S7 (T4, VR-5) — Cipher-Not-Found Path in handleOfflineDelete Not Tested

> **Status: [PARTIALLY RESOLVED]** — The resolver-level cipher-not-found path is now tested via two new tests in `OfflineSyncResolverTests.swift`: `test_processPendingChanges_update_cipherNotFound_recreates` and `test_processPendingChanges_softDelete_cipherNotFound_cleansUp`. These were added as part of the RES-2 fix (server 404 handling). The VaultRepository-level test gap (`handleOfflineDelete` guard clause when `fetchCipher` returns nil) remains open.

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | S7 / T4 / VR-5 |
| **Component** | `VaultRepositoryTests` |
| **Severity** | Medium |
| **Type** | Test Gap |
| **File** | `BitwardenShared/Core/Vault/Repositories/VaultRepositoryTests.swift` |

## Description

`VaultRepository.handleOfflineDelete` has a guard clause that returns silently when `cipherService.fetchCipher(withId:)` returns `nil`. This code path — where a cipher deletion fails due to network error, and then the cipher cannot be found locally — is not tested. The silent return means the delete operation completes without error and without queuing a pending change.

## Context

The not-found scenario is an edge case but possible if:
- The cipher was already deleted locally by another process (e.g., a sync that completed just before the network dropped)
- A race condition where two delete attempts happen simultaneously
- Data inconsistency between the UI state and local storage

The current behavior (silent return) is reasonable for this edge case, but it should be verified by a test.

---

## Options

### Option A: Add a Single Targeted Test (Recommended)

Add one test that configures `cipherService.fetchCipher(withId:)` to return `nil` when the delete offline handler runs, and verify:
- No pending change is created
- No error is thrown
- No local cipher operations are performed

**Approach:**
```
test_deleteCipher_offlineFallback_cipherNotFound_noOp:
1. Configure mock cipherService.deleteCipherWithServer to throw URLError(.notConnectedToInternet)
2. Configure mock cipherService.fetchCipher(withId:) to return nil
3. Call repository.deleteCipher(id)
4. Assert: no pending change upserted
5. Assert: no local delete called
6. Assert: no error thrown
```

**Pros:**
- Simple, focused test
- Verifies the guard clause behavior
- Minimal code (~30-40 lines)

**Cons:**
- Only covers the nil-return case, not other potential edge cases
- Does not test whether this scenario should perhaps throw an error instead

### Option B: Add Multiple Edge Case Tests

Add tests for the not-found case plus related edge cases in `handleOfflineDelete`:

1. `test_deleteCipher_offlineFallback_cipherNotFound_noOp` — cipher not found locally
2. `test_deleteCipher_offlineFallback_fetchCipherThrows` — `fetchCipher` throws an error (Core Data issue)
3. `test_deleteCipher_offlineFallback_cipherAlreadyPending` — cipher already has a pending change

**Pros:**
- More comprehensive edge case coverage
- Tests error propagation from `fetchCipher`
- Tests interaction with existing pending records

**Cons:**
- More test code for low-severity edge cases
- The `fetchCipherThrows` and `cipherAlreadyPending` scenarios may not be worth testing separately

### Option C: Change Behavior to Throw Instead of Silent Return

Instead of silently returning when the cipher is not found, throw a descriptive error so the caller knows the delete could not be queued offline.

**Approach:**
- Replace `return` with `throw OfflineSyncError.missingCipherData` (or a new error case)
- Add a test verifying the error is thrown

**Pros:**
- More explicit error handling — no silent failures
- Caller can handle or display the error

**Cons:**
- Changes existing behavior — could affect UX (user sees an error for an already-deleted cipher)
- The cipher IS already gone locally, so the user's intent (delete) is effectively satisfied
- Unnecessary error for a benign scenario

---

## Recommendation

**Option A** — Add a single targeted test for the not-found case. The current silent-return behavior is correct for this edge case (the cipher is already gone), and it just needs test coverage. No behavioral change is warranted.

## Estimated Impact

- **Files changed:** 1 (`VaultRepositoryTests.swift`)
- **Lines added:** ~30-40
- **Risk:** Very low — test-only change

## Related Issues

- **VR-2**: Delete converted to soft delete — the not-found test is in the context of `handleOfflineDelete`, which performs a soft delete. Understanding this design decision provides context.
- **S6 (T3)**: Password change counting — similar category of "untested edge case in VaultRepository offline handlers."
- **T7**: Subsequent offline edit test — both are VaultRepository offline handler test gaps.

## Updated Review Findings

The review confirms the original assessment. After reviewing the implementation:

1. **Code verification**: `VaultRepository.swift:1048-1073` shows `handleOfflineDelete`:
   - Line 1052: `guard let cipher = try await cipherService.fetchCipher(withId: cipherId) else { return }` - the silent return on nil
   - This guard means: if the cipher is not found locally, the method returns without error and without queuing any pending change
   - The subsequent org check at line 1055 and soft-delete at line 1060 are never reached

2. **Trigger context**: This method is called from `deleteCipher` at `VaultRepository.swift:643-646`, inside a `catch let error as URLError where error.isNetworkConnectionError` block. The flow is: API delete fails → catch network error → call `handleOfflineDelete` → cipher not found locally → silent return → `deleteCipher` returns normally (no error thrown to caller)

3. **Silent return implications**: The user initiated a delete, the server call failed, and the cipher can't be found locally either. The silent return means:
   - No error shown to the user
   - No pending change queued
   - The user's delete intent is effectively lost
   - However, if the cipher isn't in local storage, it's likely already deleted (by sync or another process), so the intent is effectively already satisfied

4. **Test mock setup**: `MockCipherService` has `fetchCipherResult` which can be set to `nil`. The existing offline delete test (`test_deleteCipher_offlineFallback`) presumably sets `fetchCipherResult` to a valid cipher. Setting it to `nil` tests the guard clause.

5. **Recommendation confirmed**: **Option A (single targeted test)** is correct and sufficient. The behavior (silent no-op) is reasonable for this edge case and just needs verification coverage.

**Updated conclusion**: Original recommendation stands. One test is sufficient to verify the guard clause behavior. Priority remains Medium for coverage completeness.

