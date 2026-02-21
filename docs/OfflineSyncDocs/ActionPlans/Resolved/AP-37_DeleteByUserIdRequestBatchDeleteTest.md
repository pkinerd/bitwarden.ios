# AP-37: PendingCipherChangeData.deleteByUserIdRequest Batch Delete Test

> **Issue:** #37 from ConsolidatedOutstandingIssues.md
> **Severity:** Medium | **Complexity:** Low
> **Status:** Resolved
> **Source:** Review2/08_TestCoverage_Review.md

## Problem Statement

The `PendingCipherChangeData.deleteByUserIdRequest(userId:)` method at `BitwardenShared/Core/Vault/Models/Data/PendingCipherChangeData.swift:187-191` was added to the batch delete array in `DataStore.deleteDataForUser(userId:)` at `BitwardenShared/Core/Platform/Services/Stores/DataStore.swift:105`. This ensures that when a user's data is purged (e.g., account logout, account deletion), their pending cipher change records are also cleaned up.

There is no explicit test verifying that `PendingCipherChangeData` records are deleted as part of `deleteDataForUser`. The addition relies on the existing `DataStore` test infrastructure to cover this, but no test explicitly asserts that pending cipher changes are removed during user data deletion.

## Current Test Coverage

- **`PendingCipherChangeDataStoreTests.swift`:** Tests `deleteAllPendingChanges(userId:)` which uses its own fetch-and-delete pattern, NOT the batch delete in `DataStore.deleteDataForUser`. The store-level `deleteAllPendingChanges` is a separate code path from the `DataStore` batch delete.
- **`DataStore` tests:** There is no `DataStoreTests.swift` file in the project. The `DataStore.deleteDataForUser` method is tested indirectly through higher-level service tests, but none specifically assert on `PendingCipherChangeData` cleanup.
- **`deleteByUserIdRequest` static method:** The method itself is straightforward (creates an `NSBatchDeleteRequest` with a user ID predicate) and follows the exact same pattern as `CipherData.deleteByUserIdRequest`, `FolderData.deleteByUserIdRequest`, etc.

## Missing Coverage

1. `DataStore.deleteDataForUser(userId:)` deletes `PendingCipherChangeData` records for the specified user.
2. `PendingCipherChangeData` records for OTHER users are NOT deleted.

## Assessment

**Still valid:** Yes. No test explicitly verifies that `PendingCipherChangeData` is included in the batch delete.

**Risk of not having the test:** Low.
- The `deleteByUserIdRequest` follows the exact same pattern as the 8 other entity types already in the batch delete array.
- The batch delete is a simple array of `NSBatchDeleteRequest` objects. The risk of accidentally removing `PendingCipherChangeData` from the array is minimal.
- If it WERE accidentally removed, pending changes for logged-out users would remain orphaned in the database. This is a minor data hygiene issue, not a functional or security problem -- the records contain only encrypted data and non-sensitive metadata.
- The code at `DataStore.swift:105` is visually obvious in the array of delete requests.

**Priority:** Low. The code pattern is well-established and the risk of regression is minimal.

## Options

### Option A: Add Integration Test for deleteDataForUser (Recommended if Effort Justified)
- **Effort:** ~1 hour
- **Description:** Create a test (or add to an existing test class that uses `DataStore`) that:
  1. Inserts `PendingCipherChangeData` records for user "1" and user "2" into an in-memory `DataStore`.
  2. Calls `deleteDataForUser(userId: "1")`.
  3. Asserts that user "1"'s records are deleted.
  4. Asserts that user "2"'s records are preserved.
- **Test scenarios:**
  - `test_deleteDataForUser_deletesPendingCipherChangeData` -- user's records removed
  - `test_deleteDataForUser_preservesOtherUserData` -- other user's records untouched
- **Pros:** Direct verification. Catches accidental removal from batch delete array.
- **Cons:** Requires a test file for `DataStore` (none exists). Moderate effort for low-risk coverage.

### Option B: Add Targeted Unit Test for deleteByUserIdRequest
- **Effort:** ~30 minutes
- **Description:** Test the static `deleteByUserIdRequest(userId:)` method in isolation. Verify it creates an `NSBatchDeleteRequest` with the correct entity name and predicate.
- **Test scenarios:**
  - `test_deleteByUserIdRequest_hasCorrectEntityName` -- entity name is "PendingCipherChangeData"
  - `test_deleteByUserIdRequest_hasCorrectPredicate` -- predicate filters by userId
- **Pros:** Tests the static method logic.
- **Cons:** Does NOT verify that `DataStore.deleteDataForUser` actually includes this request in its batch. Only tests the request construction.

### Option C: Accept As-Is
- **Rationale:** The `deleteByUserIdRequest` follows the exact same pattern as 8 other entity types. The batch delete array in `DataStore.deleteDataForUser` is a simple, visually obvious list. The risk of accidental removal is minimal. The consequence of missing this cleanup is minor (orphaned encrypted records). No other entity type's batch delete inclusion is explicitly tested either -- this is a general project gap, not specific to offline sync.

## Recommendation

**Option C (Accept As-Is).** The risk-to-effort ratio does not justify adding a test. The code follows an established pattern, the consequence of regression is minor, and no other entity type has this level of verification. If a `DataStoreTests.swift` file is ever created for other reasons, this assertion should be included as part of a comprehensive `deleteDataForUser` test.

## Dependencies

- None. This is a standalone concern.
