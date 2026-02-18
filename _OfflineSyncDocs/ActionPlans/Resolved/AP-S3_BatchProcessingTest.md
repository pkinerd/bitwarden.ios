# Action Plan: S3 (RES-3) — No Batch Processing Test for OfflineSyncResolver

> **Status: [RESOLVED]** — All three recommended batch tests from Option B have been implemented in `OfflineSyncResolverTests.swift`: `test_processPendingChanges_batch_allSucceed` (3 change types processed in one batch), `test_processPendingChanges_batch_mixedFailure_successfulItemResolved` (catch-and-continue verified), and `test_processPendingChanges_batch_allFail` (all pending records retained on failure). The critical catch-and-continue reliability property is now fully tested.

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | S3 / RES-3 |
| **Component** | `OfflineSyncResolverTests` |
| **Severity** | ~~High~~ **Resolved** |
| **Type** | Test Gap |
| **File** | `BitwardenShared/Core/Vault/Services/OfflineSyncResolverTests.swift` |

## Description

All existing `OfflineSyncResolver` tests process a single pending change at a time. No test verifies the batch processing behavior where multiple pending changes are processed in a single `processPendingChanges` call, including scenarios where some items succeed and others fail. The catch-and-continue error handling in the processing loop is a critical behavior that should be verified: if change A succeeds and change B fails, change A's pending record should be deleted while change B's remains.

## Context

The `processPendingChanges` method iterates over all pending changes for a user, calling `resolve(pendingChange:userId:)` for each. Errors are caught per-item and logged via `Logger.application.error()`, with the loop continuing to the next item. This is a key reliability property — one failing item should not block resolution of others.

**Codebase test patterns:** The existing `OfflineSyncResolverTests` use an in-memory `DataStore` for real Core Data persistence in tests, a `MockCipherAPIServiceForOfflineSync` (inline, only implements `getCipher`), and standard project mocks (`MockCipherService`, `MockClientService`, `MockFolderService`, `MockStateService`). Tests follow the `test_method_scenario` naming convention and use `BitwardenTestCase` as the base class. The mock data store tracks method calls via arrays (e.g., `deletePendingChangeByIdCalledWith`).

---

## Options

### Option A: Add a Single Comprehensive Batch Test

Add one test that sets up multiple pending changes of different types (create, update, soft-delete) and verifies they are all processed correctly in a single `processPendingChanges` call.

**Approach:**
- Set up 3 pending changes: one `.create`, one `.update`, one `.softDelete`
- Configure mocks so all succeed
- Verify each was resolved appropriately (API calls made, pending records deleted)

**Pros:**
- Single test covers the batch iteration behavior
- Verifies the loop processes all items regardless of type
- Minimal test code added

**Cons:**
- Does not test mixed success/failure
- A single test covering multiple behaviors is harder to diagnose when it fails
- Does not exercise the catch-and-continue path

### Option B: Add Multiple Targeted Batch Tests (Recommended)

Add 2-3 tests covering distinct batch scenarios:

1. **Batch success** — Multiple changes of different types all resolve successfully
2. **Batch mixed failure** — Multiple changes where one fails (API throws); verify the successful items are resolved and the failed item's pending record remains
3. **Batch all-fail** — All items fail; verify all pending records remain and errors are logged

**Approach:**
- Test 1: 3 pending changes (create, update, softDelete) — all succeed. Assert all pending records deleted, all API calls made.
- Test 2: 2 pending changes. First succeeds (mock API returns success), second fails (mock API throws). Assert first pending record deleted, second remains.
- Test 3: 2 pending changes. Both fail. Assert both pending records remain.

**Pros:**
- Comprehensive coverage of the batch behavior
- Tests the critical catch-and-continue property
- Each test has a clear purpose and is easy to diagnose
- Validates that the `Logger.application` error logging occurs on failure (can verify via mock logger if available)

**Cons:**
- More test code (estimated ~80-120 lines per test)
- Requires more complex mock setup (multiple pending changes with different mock responses)
- May need to enhance `MockPendingCipherChangeDataStore` to track deletion calls more precisely

### Option C: Add Batch Tests with Ordering Verification

Extend Option B with additional tests that verify processing order (FIFO by `createdDate`).

**Approach:**
- All tests from Option B
- Additional test: 3 pending changes with specific `createdDate` values. Verify API calls are made in chronological order.

**Pros:**
- Verifies the FIFO ordering contract
- Most comprehensive coverage

**Cons:**
- Ordering verification may be brittle (depends on mock call tracking being ordered)
- Additional complexity for a property that is less critical than correctness

---

## Recommendation

**Option B** — Add multiple targeted batch tests. The catch-and-continue behavior is a critical reliability property that must be verified. Testing mixed success/failure is the most important scenario. Ordering verification (Option C) can be deferred.

## Estimated Impact

- **Files changed:** 1 (`OfflineSyncResolverTests.swift`)
- **Lines added:** ~200-300
- **Risk:** Very low — test-only changes

## Related Issues

- **S4 (RES-4)**: API failure during resolution test — the "mixed failure" test in Option B partially overlaps with S4. Implementing both together is efficient.
- **T5 (RES-6)**: Inline mock fragility — the batch tests will rely on `MockCipherAPIServiceForOfflineSync`, compounding the maintenance burden of the inline mock.
- **R3 (SS-5)**: Retry backoff — if retry backoff is implemented, the batch tests should verify that backed-off items are skipped.

## Updated Review Findings

The review confirms the original assessment. After reviewing the actual code:

1. **Code verification**: `OfflineSyncResolver.swift:121-137` shows the `processPendingChanges` method iterates with a for-loop, wrapping each `resolve()` call in do/catch. The catch block at line 132-134 logs via `Logger.application.error()` and continues. This catch-and-continue pattern is indeed the critical reliability property that needs testing.

2. **Test file verification**: `OfflineSyncResolverTests.swift` has 11 tests, all using a single pending change per test (confirmed by examining all test methods from lines 118-516). No test sets up multiple pending changes via `pendingCipherChangeDataStore.fetchPendingChangesResult`.

3. **Mock infrastructure review**: `MockPendingCipherChangeDataStore` tracks `deletePendingChangeByIdCalledWith` as an array, which naturally supports verifying selective deletions in batch scenarios. The `MockCipherAPIServiceForOfflineSync` inline mock (lines 11-62) only implements `getCipher` - S3 batch tests would need `addCipherWithServer` and `updateCipherWithServer` too, but those go through `MockCipherService` (not the API mock), so the infrastructure is adequate.

4. **Recommendation confirmed**: **Option B (multiple targeted batch tests)** remains the correct recommendation. The "batch with mixed failure" test is the highest-value single addition since it exercises both the batch iteration AND the catch-and-continue error handling in one scenario.

5. **Additional finding**: The processing order is determined by the order returned from `fetchPendingChanges`, which uses `fetchByUserIdRequest` with no sort descriptor. Consider whether tests should explicitly verify FIFO ordering or whether ordering is intentionally unspecified. Current recommendation: don't mandate ordering in tests unless the data store is updated to sort by `createdDate`.

6. **Dependency on T5**: If the inline mock `MockCipherAPIServiceForOfflineSync` is replaced (per T5), the batch tests benefit from cleaner mock setup. However, S3 should not be blocked on T5 - the existing mock infrastructure is sufficient.

**Updated conclusion**: Original recommendation stands. Implement Option B with 2-3 targeted batch tests covering: (1) all-success batch, (2) mixed success/failure batch, (3) all-fail batch. Priority remains High. Combine with S4 for efficiency.
