# AP-35: GetCipherRequest 404 Validation Unit Test

> **Issue:** #35 from ConsolidatedOutstandingIssues.md
> **Severity:** Medium | **Complexity:** Low
> **Status:** Resolved
> **Source:** Review2/08_TestCoverage_Review.md

## Problem Statement

The `GetCipherRequest.validate(_:)` method at `BitwardenShared/Core/Vault/Services/API/Cipher/Requests/GetCipherRequest.swift:28-32` throws `OfflineSyncError.cipherNotFound` when the HTTP response has a 404 status code. This validation logic has no direct unit test. While it is exercised indirectly through `OfflineSyncResolverTests` (which mocks the `CipherAPIService` layer above this request), there is no test that directly verifies the `validate(_:)` method behavior on `GetCipherRequest` itself.

The project has an established pattern of testing `validate(_:)` methods on request types. `CheckLoginRequestRequestTests.swift` at `BitwardenShared/Core/Auth/Services/API/Auth/Requests/CheckLoginRequestRequestTests.swift:41-49` tests an identical pattern (`test_validate` verifying 404 throws, other status codes do not).

## Current Test Coverage

- **Indirect coverage:** `OfflineSyncResolverTests.swift:540-603` tests `test_processPendingChanges_update_cipherNotFound_recreates` and `test_processPendingChanges_softDelete_cipherNotFound_cleansUp` use `getCipherResult = .failure(OfflineSyncError.cipherNotFound)` to simulate the 404. This mocks at the `CipherAPIService` level, not at the `GetCipherRequest` level.
- **No test file exists:** There is no `GetCipherRequestTests.swift` file in `BitwardenShared/Core/Vault/Services/API/Cipher/Requests/`. Other request types in this directory (e.g., `DeleteCipherRequestTests.swift`, `UpdateCipherRequestTests.swift`) do have test files.
- **Existing pattern:** `CheckLoginRequestRequestTests.swift:41-49` provides the exact pattern to follow for testing `validate(_:)`.

## Missing Coverage

1. `validate(_:)` does NOT throw for a 200 response.
2. `validate(_:)` does NOT throw for a 400 response.
3. `validate(_:)` does NOT throw for a 500 response.
4. `validate(_:)` DOES throw `OfflineSyncError.cipherNotFound` for a 404 response.

## Assessment

**Still valid:** Yes. No `GetCipherRequestTests.swift` file exists. The test gap is real.

**Risk of not having the test:** Low-to-Medium. The `validate(_:)` method is simple (3 lines) and unlikely to regress on its own. However:
- It is the only place in the codebase that translates HTTP 404 into `OfflineSyncError.cipherNotFound`.
- If someone accidentally removes or modifies this method, the resolver's 404 handling would silently break.
- The project convention (see `CheckLoginRequestRequestTests.swift`) is to test `validate(_:)` methods directly.

**Priority:** Low-Medium. This is a straightforward test to add that follows an established pattern.

## Options

### Option A: Add `GetCipherRequestTests.swift` (Recommended)
- **Effort:** ~30 minutes, ~50 lines
- **Description:** Create `GetCipherRequestTests.swift` in `BitwardenShared/Core/Vault/Services/API/Cipher/Requests/` following the `CheckLoginRequestRequestTests` pattern. Test `path`, `method`, and `validate(_:)`.
- **Test scenarios:**
  - `test_method` -- verifies `.get`
  - `test_path` -- verifies `/ciphers/{id}`
  - `test_validate` -- verifies:
    - 200 response does NOT throw
    - 400 response does NOT throw
    - 500 response does NOT throw
    - 404 response throws `OfflineSyncError.cipherNotFound`
- **Pros:** Follows established project pattern. Direct coverage of the validate logic. Small effort.
- **Cons:** None significant.

### Option B: Add Validate Test Only
- **Effort:** ~15 minutes, ~25 lines
- **Description:** Create a minimal `GetCipherRequestTests.swift` with only `test_validate`. Skip `test_method` and `test_path` since these are trivial.
- **Pros:** Even less effort.
- **Cons:** Inconsistent with the comprehensive pattern used by other request test files.

### Option C: Accept As-Is
- **Rationale:** The `validate(_:)` method is trivially simple (3 lines). It is indirectly tested through the resolver tests. The risk of regression is low. The cost of NOT having this test is minimal.

## Recommendation

**Option A.** The effort is minimal (~30 minutes), it follows the established project convention, and it provides direct coverage of the HTTP-to-domain-error translation that is critical to the offline sync 404 handling path.

## Dependencies

- None. This is a standalone test file addition.
- Related to Issue #A4 (coupling of `GetCipherRequest` to `OfflineSyncError` semantics), accepted as-is in ConsolidatedOutstandingIssues.md.
