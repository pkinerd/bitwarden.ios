# AP-39: resolveCreate Partial Failure -- Duplicate Cipher Scenario Test

> **Issue:** #39 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Medium
> **Status:** Triaged
> **Source:** OfflineSyncCodeReview_Phase2.md (P2-T2)

## Problem Statement

In `DefaultOfflineSyncResolver.resolveCreate` at `OfflineSyncResolver.swift:145-166`, the resolution sequence is:

1. `addCipherWithServer(cipher, encryptedFor: userId)` -- creates cipher on server (line 154)
2. `deleteCipherWithLocalStorage(id: tempId)` -- deletes temp-ID local record (line 160)
3. `deletePendingChange(id: recordId)` -- removes the pending change (line 164)

If step 1 succeeds but step 2 (`deleteCipherWithLocalStorage`) fails, the cipher has been created on the server with a new server-assigned ID, but the local temp-ID record remains. The pending change record also remains (step 3 never executes). On the next sync, `processPendingChanges` will retry `resolveCreate` for this pending change, calling `addCipherWithServer` again -- creating a **duplicate cipher** on the server.

This is the same issue documented as RES-1 in the original review (accepted as low priority). The issue here is specifically that there is no test verifying this behavior or documenting it.

## Current Test Coverage

- **`test_processPendingChanges_create`** at `OfflineSyncResolverTests.swift:65-86`: Tests the happy path where all steps succeed.
- **`test_processPendingChanges_create_apiFailure_pendingRecordRetained`** at `OfflineSyncResolverTests.swift:619-642`: Tests the case where `addCipherWithServer` fails (step 1 fails). Verifies the pending record is NOT deleted.
- **No test for step 2 failure:** There is no test where `addCipherWithServer` succeeds but `deleteCipherWithLocalStorage` fails.
- **No test for the duplicate scenario:** There is no test demonstrating that retrying after a partial failure creates a duplicate.

## Missing Coverage

1. `resolveCreate` where `addCipherWithServer` succeeds but `deleteCipherWithLocalStorage` throws -- error propagates, pending change record retained.
2. On retry, `resolveCreate` calls `addCipherWithServer` again with the same cipher data, creating a duplicate.
3. The temp-ID record persists alongside the new server-ID record after partial failure.

## Assessment

**Still valid:** Yes. No test covers partial failure in `resolveCreate`.

**Risk of not having the test:** Low.
- `deleteCipherWithLocalStorage` is a Core Data delete-by-ID operation. Core Data deletes almost never fail in practice.
- The consequence (duplicate cipher) is annoying but not data loss -- both copies contain the same data.
- The user can manually delete the duplicate.
- This is the same issue as RES-1, already accepted as low priority.

**Priority:** Low. The scenario is extremely unlikely and the consequence is non-catastrophic.

## Options

### Option A: Add Partial Failure Test (Recommended)
- **Effort:** ~45 minutes, ~50 lines
- **Description:** Add a test to `OfflineSyncResolverTests.swift` that configures `cipherService.addCipherWithServerResult = .success(())` and `cipherService.deleteCipherWithLocalStorageResult = .failure(...)`, then verifies:
  - The error propagates (or is caught by the batch processor).
  - The pending change record is NOT deleted.
  - `addCipherWithServer` WAS called (the cipher was created on the server).
- **Test scenarios:**
  - `test_processPendingChanges_create_localCleanupFails_pendingRecordRetained` -- step 1 succeeds, step 2 fails, pending record retained
  - Optionally: `test_processPendingChanges_create_retry_afterPartialFailure_createsDuplicate` -- call `processPendingChanges` twice with the same setup to demonstrate the duplicate (this requires more complex mock setup to simulate "server already has the cipher")
- **Pros:** Documents the known limitation. Provides regression coverage. Can serve as a test case for future idempotency improvements.
- **Cons:** The mock setup requires checking whether `MockCipherService` supports configuring `deleteCipherWithLocalStorage` to fail (may need mock enhancement).

### Option B: Add Documentation-Only Test
- **Effort:** ~20 minutes, ~25 lines
- **Description:** Add a single test documenting that step 2 failure leaves the pending record in place.
- **Pros:** Documents the behavior with minimal effort.
- **Cons:** Does not demonstrate the duplicate scenario.

### Option C: Accept As-Is
- **Rationale:** This is the same issue as RES-1, already accepted as low priority. The failure scenario (Core Data delete fails) is extremely unlikely. The consequence (duplicate cipher) is minor. The test would document a known limitation but not fix it.

## Recommendation

**Option B.** A single test documenting the partial failure behavior is sufficient. It documents the known limitation (RES-1) and provides a test anchor for future idempotency work. The full duplicate-demonstration test (Option A, second scenario) adds complexity without proportional value.

## Dependencies

- **RES-1 (#14):** Accepted as-is. If idempotency is ever addressed, these tests would need updating.
- **R3 (#1):** Retry backoff. A failed `resolveCreate` is another case where retry backoff would help, though the duplicate issue remains.
- Mock enhancement may be needed: verify `MockCipherService` supports `deleteCipherWithLocalStorageResult` or similar.
