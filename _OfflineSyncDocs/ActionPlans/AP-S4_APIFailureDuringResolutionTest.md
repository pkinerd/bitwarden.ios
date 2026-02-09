# Action Plan: S4 (RES-4) — No API Failure During Resolution Test

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | S4 / RES-4 |
| **Component** | `OfflineSyncResolverTests` |
| **Severity** | High |
| **Type** | Test Gap |
| **File** | `BitwardenShared/Core/Vault/Services/OfflineSyncResolverTests.swift` |

## Description

No test verifies the behavior when API calls within the resolution process fail. The `DefaultOfflineSyncResolver.processPendingChanges` method catches per-item errors via a `do/catch` in the loop and logs them via `Logger.application`, then continues to the next item. This catch-and-continue behavior is untested. Specifically, no test verifies what happens when `cipherService.addCipherWithServer`, `cipherService.updateCipherWithServer`, or `cipherAPIService.getCipher` throw during resolution.

## Context

During resolution, multiple API calls can fail:
- `cipherAPIService.getCipher(withId:)` — fetching server state for conflict detection
- `cipherService.addCipherWithServer` — pushing a new cipher
- `cipherService.updateCipherWithServer` — pushing an update
- `cipherService.softDeleteCipherWithServer` — performing server soft-delete
- `folderService.addFolderWithServer` — creating the conflict folder
- `cipherService.addCipherWithServer` (backup) — creating a backup cipher

Each of these can throw, and the resolver should catch, log, and continue.

---

## Options

### Option A: Add Tests for Each API Failure Point

Create individual tests for each API call that can fail during resolution:

1. `test_processPendingChanges_create_apiFailure` — `addCipherWithServer` throws
2. `test_processPendingChanges_update_getCipherFails` — `getCipher` throws during update
3. `test_processPendingChanges_update_updateCipherFails` — `updateCipherWithServer` throws
4. `test_processPendingChanges_softDelete_getCipherFails` — `getCipher` throws during soft delete
5. `test_processPendingChanges_softDelete_softDeleteFails` — `softDeleteCipherWithServer` throws
6. `test_processPendingChanges_backup_folderCreationFails` — `addFolderWithServer` throws
7. `test_processPendingChanges_backup_addBackupFails` — backup `addCipherWithServer` throws

**Pros:**
- Exhaustive coverage of all failure points
- Each test is clear about what it verifies
- Easy to diagnose when a specific failure path breaks

**Cons:**
- 7 additional tests — significant test code volume (~500+ lines)
- Many require complex mock configuration to fail at a specific point
- Some failure paths are trivial (the error propagates the same way)

### Option B: Add Representative Failure Tests (Recommended)

Create 3-4 tests covering the representative failure scenarios:

1. `test_processPendingChanges_create_apiFailure_pendingRecordRetained` — Create resolution API failure. Verify the pending record is NOT deleted and the error is logged.
2. `test_processPendingChanges_update_serverFetchFailure_pendingRecordRetained` — Update resolution where `getCipher` fails. Verify pending record retained.
3. `test_processPendingChanges_softDelete_apiFailure_pendingRecordRetained` — Soft-delete resolution API failure. Verify pending record retained.
4. `test_processPendingChanges_backupCreation_failure_pendingRecordRetained` — Conflict detected but backup creation fails. Verify the main cipher is NOT pushed and the pending record is retained.

**Pros:**
- Covers the three change types plus backup failure
- Each test verifies the critical invariant: failed items retain their pending records
- Practical coverage without excessive tests

**Cons:**
- Does not test every individual API failure point
- Backup failure test requires careful mock setup (getCipher succeeds, conflict detected, but addCipherWithServer for backup fails)

### Option C: Combine with S3 Batch Tests

Rather than separate API failure tests, incorporate API failures into the batch processing tests from S3. For example: in a batch of 3 items, configure item 2 to fail at the API level. Verify items 1 and 3 resolve, item 2 remains pending.

**Pros:**
- Efficient — tests batch processing and API failure handling simultaneously
- Fewer total tests
- Tests the most realistic scenario (mixed batch with some failures)

**Cons:**
- Combined tests are harder to diagnose when they fail
- May not cover all failure paths (only tests one type of API failure in the batch)
- If S3 is deferred, this doesn't get implemented either

---

## Recommendation

**Option B** — Add representative failure tests for each change type plus backup failure. This provides practical coverage of the critical error-handling behavior without excessive test volume. Consider combining the create API failure test with S3's batch mixed-failure test for efficiency.

## Estimated Impact

- **Files changed:** 1 (`OfflineSyncResolverTests.swift`)
- **Lines added:** ~200-300
- **Risk:** Very low — test-only changes

## Related Issues

- **S3 (RES-3)**: Batch processing test gap — the mixed-failure batch test overlaps with this issue. Implementing together is efficient.
- **T5 (RES-6)**: Inline mock fragility — API failure tests require configuring mock API to throw, adding more code to the inline mock.
- **R3 (SS-5)**: Retry backoff — if implemented, failure tests should verify the retry/backoff behavior.
- **RES-1**: Duplicate on create retry — the create failure test could also verify the retry scenario behavior.

## Updated Review Findings

The review confirms the original assessment. After reviewing the actual implementation:

1. **Code verification**: The `resolve()` method at `OfflineSyncResolver.swift:147-160` dispatches to three type-specific methods: `resolveCreate` (line 163), `resolveUpdate` (line 179), and `resolveSoftDelete` (line 258). Each of these makes multiple async API calls that can throw.

2. **Failure points verified in code**:
   - `resolveCreate` (line 171): `cipherService.addCipherWithServer` can throw
   - `resolveUpdate` (line 189): `cipherAPIService.getCipher` can throw (server fetch)
   - `resolveUpdate` (line 211/219): `cipherService.updateCipherWithServer` can throw
   - `resolveSoftDelete` (line 264): `cipherAPIService.getCipher` can throw
   - `resolveSoftDelete` (line 285): `cipherService.softDeleteCipherWithServer` can throw
   - `createBackupCipher` (line 324): `cipherService.addCipherWithServer` for backup can throw
   - `getOrCreateConflictFolder` (line 353): `folderService.addFolderWithServer` can throw

3. **Error handling verification**: The per-item catch at `processPendingChanges` (lines 129-135) catches errors from `resolve()` and logs them. The critical invariant is that `deletePendingChange` (lines 173-175, 222-224, 287-289) is called AFTER the resolution succeeds. If `resolve()` throws, the pending record is NOT deleted - this is the correct behavior that should be tested.

4. **Mock capability**: `MockCipherService` already supports configuring `addCipherWithServerResult` and `updateCipherWithServerResult` to throw. The `MockCipherAPIServiceForOfflineSync` has `getCipherResult: Result<CipherDetailsResponseModel, Error>` which can be set to `.failure(...)`. The infrastructure is adequate for failure tests.

5. **Recommendation confirmed**: **Option B (representative failure tests)** remains correct. Testing one failure per change type (create, update, soft-delete) plus one backup creation failure covers the critical paths without exhaustive testing of every failure point. The key assertion in each test: pending record is NOT deleted when resolution fails.

6. **Overlap with S3**: The S3 "batch mixed failure" test naturally covers the S4 catch-and-continue behavior. However, dedicated single-item failure tests are still valuable for isolating failure diagnostics. Recommend implementing both: S3 batch tests confirm batch behavior, S4 single-item tests confirm per-type error handling.

**Updated conclusion**: Original recommendation stands. Implement Option B with 3-4 representative failure tests. Priority remains High. Can be efficiently combined with S3 batch tests.
