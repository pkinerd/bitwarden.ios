---
id: 61
title: "[S6] No password change counting test"
status: closed
created: 2026-02-21
author: claude
labels: [bug]
priority: low
closed: 2026-02-21
---

## Description

**Resolution:** 4 tests added. Commit: `4d65465`

**Disposition:** Resolved / Superseded

## Action Plan

*Source: `ActionPlans/Resolved/AP-S6_PasswordChangeCountingTest.md`*

> **Status: [RESOLVED]** — All four recommended tests from Option A have been implemented in `VaultRepositoryTests.swift`: `test_updateCipher_offlineFallback_passwordChanged_incrementsCount` (first edit, password changed, count = 1), `test_updateCipher_offlineFallback_passwordUnchanged_zeroCount` (first edit, unchanged, count = 0), `test_updateCipher_offlineFallback_subsequentEdit_passwordChanged_incrementsCount` (subsequent edit, changed, count = existing + 1), and `test_updateCipher_offlineFallback_subsequentEdit_passwordUnchanged_preservesCount` (subsequent edit, unchanged, count preserved). Both the first-edit and subsequent-edit code paths are now fully covered.

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | S6 / T3 |
| **Component** | `VaultRepositoryTests` |
| **Severity** | ~~Medium~~ **Resolved** |
| **Type** | Test Gap |
| **File** | `BitwardenShared/Core/Vault/Repositories/VaultRepositoryTests.swift` |

## Description

The `handleOfflineUpdate` method in `VaultRepository` contains password change detection logic that compares decrypted passwords between the current edit and the previous version (either from an existing pending record or from local storage). This logic increments `offlinePasswordChangeCount`, which drives the soft-conflict threshold (backup created when count >= 4). Despite being a critical safety mechanism, this logic is not directly tested.

## Context

The password change detection flow:
1. If an existing pending record exists with `cipherData` — decode it, decrypt, compare `login?.password`
2. If no existing pending record — fetch cipher from local storage, decrypt, compare `login?.password`
3. If passwords differ — increment `offlinePasswordChangeCount`

This logic involves decrypt operations (via `clientService.vault().ciphers().decrypt()`), JSON decode of pending cipher data, and conditional counting. The complexity warrants direct testing.

**Codebase test pattern:** `VaultRepositoryTests.swift` uses `MockClientCiphers` (assigned to `clientCiphers` in setUp) to control encrypt/decrypt results. The mock captures `encryptCipherViews` and can be configured with `decryptResult`. The `MockPendingCipherChangeDataStore` tracks `upsertPendingChangeCalledWith` tuples, which include `offlinePasswordChangeCount` for assertion. Existing offline tests (e.g., `test_updateCipher_offlineFallback`) demonstrate the pattern for configuring `cipherService.updateCipherWithServerResult` to throw `URLError(.notConnectedToInternet)`.

---

## Options

### Option A: Add Dedicated Password Change Detection Tests (Recommended)

Add 3-4 focused tests that directly exercise the password change counting:

1. `test_updateCipher_offlineFallback_passwordChanged_incrementsCount` — First offline edit changes password. Verify `offlinePasswordChangeCount == 1`.
2. `test_updateCipher_offlineFallback_passwordUnchanged_zeroCount` — First offline edit does NOT change password. Verify `offlinePasswordChangeCount == 0`.
3. `test_updateCipher_offlineFallback_subsequentEdit_passwordChanged_incrementsCount` — Second offline edit (existing pending record) changes password. Verify count increments from existing value.
4. `test_updateCipher_offlineFallback_subsequentEdit_passwordUnchanged_preservesCount` — Second offline edit does NOT change password. Verify count preserved from existing value.

**Pros:**
- Directly tests the decrypt-and-compare logic
- Covers both first-edit and subsequent-edit paths
- Verifies the count is correctly passed to the upsert call
- Tests the mock wiring for decrypt operations

**Cons:**
- Requires configuring mock `clientService` to return specific decrypted values for comparison
- May need to enhance `MockClientService` or cipher-related mocks to support decrypt with specific password values
- ~100-150 lines of test code

### Option B: Add End-to-End Threshold Test

Rather than testing the counting mechanism directly, test the end-to-end behavior: perform 4 offline updates changing the password each time, then trigger sync and verify a backup is created (soft conflict).

**Pros:**
- Tests the full pipeline from password change through threshold to backup creation
- More realistic scenario
- Verifies the integration between VaultRepository counting and OfflineSyncResolver threshold

**Cons:**
- Complex setup — requires 4 sequential offline update calls plus sync mock configuration
- Hard to diagnose which step fails if the test breaks
- Doesn't test the negative case (password unchanged)
- Crosses component boundaries (VaultRepository + OfflineSyncResolver)

### Option C: Add Unit Tests with Mocked Decrypt

Same as Option A but explicitly mock the decrypt responses to isolate the comparison logic from actual SDK decryption.

**Approach:**
- Configure `MockClientService` to return specific `CipherView` objects with known `login.password` values
- Set up existing pending record (or local cipher) with a known password
- Call `updateCipher` with a cipher whose password differs
- Assert the `offlinePasswordChangeCount` in the upsert call

**Pros:**
- Same as Option A with explicit isolation from SDK
- Deterministic — no reliance on actual encryption/decryption
- Faster test execution

**Cons:**
- Same as Option A — primarily a mock configuration effort
- If decrypt mocking is already established in the test suite, this is straightforward

---

## Recommendation

**Option A / Option C** (functionally equivalent depending on existing mock infrastructure). Add dedicated tests for both the first-edit and subsequent-edit paths, verifying both password-changed and password-unchanged scenarios. This is the most targeted approach and directly validates the counting logic.

## Estimated Impact

- **Files changed:** 1 (`VaultRepositoryTests.swift`)
- **Lines added:** ~100-150
- **Risk:** Very low — test-only changes

## Related Issues

- **T7**: No test for `handleOfflineUpdate` with existing pending record — the subsequent-edit password test (test 3 above) partially addresses T7.
- **VR-3**: Password detection compares only `login?.password` — if the detection scope is expanded, these tests need updating.
- **S3 (RES-3)**: Batch processing — the soft-conflict threshold behavior should also be tested in the resolver with batch scenarios.

## Updated Review Findings

The review confirms the original assessment with additional code-level detail. After reviewing the implementation:

1. **Code verification**: `VaultRepository.swift:991-1042` shows `handleOfflineUpdate` with password change detection logic:
   - Lines 1007-1010: Fetches existing pending change via `pendingCipherChangeDataStore.fetchPendingChange(cipherId:userId:)`
   - Line 1012: Initializes `passwordChangeCount` from existing record's count (or 0 if no existing)
   - Lines 1015-1021: **Subsequent edit path** - decodes existing pending record's `cipherData`, decrypts, compares `login?.password`
   - Lines 1022-1030: **First edit path** - fetches cipher from local storage via `cipherService.fetchCipher`, decrypts, compares `login?.password`
   - Line 1032: Preserves `originalRevisionDate` from existing record or uses current cipher's `revisionDate`
   - Lines 1034-1041: Upserts with computed `passwordChangeCount`

2. **Decrypt mock infrastructure**: The code calls `clientService.vault().ciphers().decrypt(cipher:)` which in tests goes through `MockClientService` → `MockVault` → `MockClientCiphers`. The `MockClientCiphers` has `decryptResult` which returns a configurable `CipherView`. This infrastructure is already used in existing tests but the decrypt result needs to be configured with specific `login.password` values for comparison.

3. **Two distinct code paths**: The password comparison has two branches:
   - **With existing pending record** (lines 1015-1021): Decodes from `cipherData`, uses different decrypt call
   - **Without existing pending record** (lines 1022-1030): Uses `cipherService.fetchCipher`, different decrypt call

   Both paths should be tested independently since they exercise different mock configurations.

4. **Key assertion target**: `MockPendingCipherChangeDataStore` tracks `upsertPendingChange` calls. The `offlinePasswordChangeCount` parameter is directly available for assertion, confirming the count was correctly computed.

5. **Recommendation confirmed**: **Option A (dedicated tests)** remains correct. 4 focused tests are warranted:
   - First edit, password changed → count = 1
   - First edit, password unchanged → count = 0
   - Subsequent edit, password changed → count = existing + 1
   - Subsequent edit, password unchanged → count = existing (preserved)

**Updated conclusion**: Original recommendation stands. The two distinct code paths (first edit vs subsequent edit) with two conditions each (changed vs unchanged) give 4 clear test cases. Priority remains Medium. Implementation overlaps with T7 (subsequent edit test).

## Resolution Details

4 password change detection tests added: `_passwordChanged_incrementsCount`, `_passwordUnchanged_zeroCount`, `_subsequentEdit_passwordChanged_incrementsCount`, `_subsequentEdit_passwordUnchanged_preservesCount`. Commit: `4d65465`.

## Comments
