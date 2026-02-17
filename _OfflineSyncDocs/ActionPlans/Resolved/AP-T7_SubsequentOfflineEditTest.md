# Action Plan: T7 — No Test for `handleOfflineUpdate` with Existing Pending Record

> **Status: [RESOLVED]** — Covered by `test_updateCipher_offlineFallback_preservesCreateType` in Phase 2 (commit `12cb225`). The subsequent-edit code path is exercised by this test, which verifies that an existing `.create` pending record is found and the change type is preserved on update.

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | T7 |
| **Component** | `VaultRepositoryTests` |
| **Severity** | Low |
| **Type** | Test Gap |
| **File** | `BitwardenShared/Core/Vault/Repositories/VaultRepositoryTests.swift` |

## Description

No test verifies the behavior of `handleOfflineUpdate` when a pending change record already exists for the same cipher (subsequent offline edit scenario). The upsert logic should update the existing record, preserve `originalRevisionDate`, and correctly handle `offlinePasswordChangeCount` accumulation. This path exercises different code from the "first offline edit" path.

## Context

The subsequent offline edit path differs from the first edit in:
1. `fetchPendingChange(cipherId:userId:)` returns an existing record (not nil)
2. `offlinePasswordChangeCount` starts from the existing record's count
3. Password comparison is done against the existing pending record's `cipherData` (not local storage)
4. `originalRevisionDate` is preserved from the existing record

---

## Options

### Option A: Add a Dedicated Subsequent Edit Test (Recommended)

Add a test that performs two sequential offline updates and verifies the second correctly updates the existing pending record.

**Approach:**
```
test_updateCipher_offlineFallback_subsequentEdit_updatesExistingRecord:
1. Configure mock cipherService.updateCipherWithServer to throw URLError
2. Configure mock pendingCipherChangeDataStore.fetchPendingChange to return an existing record
3. Call repository.updateCipher(cipherView)
4. Assert: upsert called with existing record's originalRevisionDate
5. Assert: offlinePasswordChangeCount starts from existing record's count
6. Assert: cipherData is updated to the new edit's data
```

**Pros:**
- Directly tests the subsequent-edit code path
- Verifies the critical `originalRevisionDate` preservation
- Verifies password count accumulation
- Clear, focused test

**Cons:**
- Requires careful mock setup for the existing pending record
- ~50-80 lines of test code

### Option B: Combine with S6 Password Change Tests

Include the subsequent-edit scenario as part of the password change counting tests (AP-S6).

**Pros:**
- Avoids duplicate mock setup
- Tests both subsequent edit and password counting together

**Cons:**
- Combined test is harder to diagnose
- If S6 is deferred, this test is also deferred

---

## Recommendation

**Option A** — Add a dedicated test. The subsequent-edit path is distinct from the first-edit path and warrants its own verification. This can be implemented alongside S6 (password change tests) for efficiency, but should be a separate test method.

## Estimated Impact

- **Files changed:** 1 (`VaultRepositoryTests.swift`)
- **Lines added:** ~50-80
- **Risk:** Very low — test-only change

## Related Issues

- **S6 (T3)**: Password change counting — the subsequent-edit test overlaps with password counting verification.
- **S7 (VR-5)**: Cipher-not-found test — both are VaultRepository offline handler test gaps.
- **R1 (PCDS-3)**: Data format versioning — the subsequent edit test exercises the `cipherData` decode path from an existing pending record.

## Updated Review Findings

The review confirms the original assessment with code-level detail. After reviewing the implementation:

1. **Code verification**: `VaultRepository.swift:1007-1032` shows the two distinct paths in `handleOfflineUpdate`:
   - **Subsequent edit path** (lines 1015-1021): `if let existingData = existing?.cipherData` — decodes existing pending record, decrypts, compares passwords
   - **First edit path** (lines 1022-1030): `else` — fetches from local storage via `cipherService.fetchCipher`, decrypts, compares
   - Line 1032: `originalRevisionDate = existing?.originalRevisionDate ?? encryptedCipher.revisionDate` — preserves from existing record

2. **Key properties to verify in the subsequent edit test**:
   - `originalRevisionDate` is preserved from the FIRST edit's record (not overwritten with the current cipher's revisionDate)
   - `cipherData` is updated to the NEW edit's encrypted data
   - `offlinePasswordChangeCount` accumulates from the existing record's count
   - `changeType` remains `.update`

3. **Mock setup requirements**: The test needs:
   - `MockPendingCipherChangeDataStore.fetchPendingChangeResult` set to return an existing pending record with known `originalRevisionDate`, `cipherData`, and `offlinePasswordChangeCount`
   - `MockCipherService.updateCipherWithServerResult` set to throw `URLError(.notConnectedToInternet)` to trigger offline path
   - `MockClientCiphers` configured to return specific decrypt results for password comparison

4. **Overlap with S6**: The subsequent-edit test naturally verifies password counting behavior. Tests 3 and 4 from S6 (subsequent edit with password changed/unchanged) directly overlap with T7. Recommend implementing them as separate test methods but in the same test session.

**Updated conclusion**: Original recommendation (Option A - dedicated test) confirmed. The test directly validates the `originalRevisionDate` preservation invariant which is critical for conflict detection. Priority: Low but important for coverage of the upsert-update code path.

