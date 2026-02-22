---
id: 106
title: "[R2-TEST-5] Corrupt cipherData — no test for resolver handling"
status: closed
created: 2026-02-21
author: claude
labels: [bug]
priority: low
closed: 2026-02-21
---

## Description

**Resolution:** Added 3 tests for corrupt data handling. AP-38 (Resolved)

**Disposition:** Resolved / Superseded

## Action Plan

*Source: `ActionPlans/Resolved/AP-38_CorruptCipherDataHandlingTest.md`*

> **Issue:** #38 from ConsolidatedOutstandingIssues.md
> **Severity:** Medium | **Complexity:** Low
> **Status:** Resolved
> **Source:** Review2/08_TestCoverage_Review.md

## Problem Statement

The `OfflineSyncResolver`'s `resolveCreate`, `resolveUpdate`, and `resolveSoftDelete` methods all decode `pendingChange.cipherData` via `JSONDecoder().decode(CipherDetailsResponseModel.self, from: cipherData)`. If the `cipherData` is malformed JSON (corrupted on disk, encoding error, schema mismatch), the `JSONDecoder` will throw a `DecodingError`. There is no explicit test verifying the resolver's behavior when `cipherData` contains malformed JSON.

The error propagation path is:
1. `resolve(pendingChange:userId:)` calls `resolveCreate`/`resolveUpdate`/`resolveSoftDelete`
2. The decode throws `DecodingError`
3. The error propagates up to `processPendingChanges` at `OfflineSyncResolver.swift:104-112`
4. The `catch` block logs the error and continues to the next pending change
5. The pending change record is NOT deleted (it remains for retry)

This behavior is correct -- a corrupt record is skipped and retried on the next sync. However, the "retried" decode will fail again with the same error, creating an infinite retry loop. This is the same class of issue as R3 (no retry backoff for permanently failing items).

## Current Test Coverage

- **No direct test for malformed cipherData.** All resolver tests use valid JSON-encoded `CipherDetailsResponseModel` data created via `JSONEncoder().encode(cipherResponseModel)`.
- **Error isolation is tested:** `test_processPendingChanges_batch_mixedFailure_successfulItemResolved` at `OfflineSyncResolverTests.swift:837-885` verifies that one item's failure does not block other items. However, the failure is caused by a mock `getCipherResult = .failure(...)`, not by corrupt data.
- **`missingCipherData` guard is tested indirectly:** The resolver has a `guard let cipherData = pendingChange.cipherData else { throw OfflineSyncError.missingCipherData }` check, but there is no test that specifically triggers it or the corrupt-data path.

## Missing Coverage

1. `resolveCreate` with malformed `cipherData` -- should log error and skip (not crash).
2. `resolveUpdate` with malformed `cipherData` -- should log error and skip.
3. `resolveSoftDelete` does NOT decode `cipherData` at all (it uses `cipherId` directly to fetch from server), so this scenario does not apply to soft deletes.
4. Batch processing with one corrupt item -- other items should still resolve successfully.

## Assessment

**Still valid:** Yes. No test exercises the `DecodingError` path from corrupt `cipherData`.

**Risk of not having the test:** Low-to-Medium.
- The `JSONDecoder().decode()` call is standard Swift and will throw `DecodingError` for any malformed input. This behavior is well-understood.
- The error is caught by the `processPendingChanges` catch block, which logs and continues. This behavior is already tested for other error types.
- The main risk is that a corrupt record creates an infinite retry loop (same as R3). Adding this test would document the behavior but not fix the underlying issue.
- Data corruption in Core Data SQLite is extremely rare in practice.

**Priority:** Low-Medium. The test is easy to add and documents an important edge case, but the behavior it verifies (error caught and logged) is already covered by other error scenario tests.

## Options

### Option A: Add Corrupt cipherData Test (Recommended)
- **Effort:** ~30 minutes, ~40 lines
- **Description:** Add a test to `OfflineSyncResolverTests.swift` that creates a pending change with invalid JSON in `cipherData` and verifies the resolver logs the error and does not delete the pending record.
- **Test scenarios:**
  - `test_processPendingChanges_create_corruptCipherData_skipsAndRetains` -- insert pending change with `cipherData = Data("not-json".utf8)`, call `processPendingChanges`, verify:
    - `addCipherWithServer` is NOT called
    - Pending change record is NOT deleted
    - No crash
  - `test_processPendingChanges_update_corruptCipherData_skipsAndRetains` -- same for `.update` type
  - `test_processPendingChanges_batch_corruptAndValid_validItemResolves` -- batch with one corrupt, one valid; valid item resolves normally
- **Pros:** Documents the behavior for corrupt data. Verifies error isolation. Easy to implement.
- **Cons:** The behavior being tested (catch-log-continue) is already implicitly covered by API failure tests.

### Option B: Add Minimal Corrupt Data Test
- **Effort:** ~15 minutes, ~20 lines
- **Description:** Add a single test for the `.create` path with corrupt data.
- **Test scenarios:**
  - `test_processPendingChanges_create_corruptCipherData_skipsAndRetains`
- **Pros:** Minimal effort. Covers the most important path.
- **Cons:** Does not cover `.update` or batch scenarios.

### Option C: Accept As-Is
- **Rationale:** The error handling behavior (catch, log, continue) is already tested via API failure tests. The `DecodingError` path is a subset of the general "any error during resolution" path. Core Data corruption is extremely rare. The infinite retry issue is tracked separately as R3.

## Recommendation

**Option A.** The effort is minimal (~30 minutes) and the test documents an important edge case (corrupt pending data). The batch test with mixed corrupt/valid items provides valuable regression coverage for the error isolation behavior. This also creates a test that can be extended when R3 (retry backoff) is implemented to verify that corrupt records are eventually marked as failed.

## Dependencies

- **R3 (#1):** Retry backoff for permanently failing items. Corrupt `cipherData` is a prime example of a permanently failing item. This test would become a natural test case for R3's failed-state handling.
- **R1 (#4):** Data format versioning. If a `dataVersion` field is added, the test could also verify behavior when the version is unrecognized.

## Resolution Details

Added 3 tests: `create_corruptCipherData_skipsAndRetains`, `update_corruptCipherData_skipsAndRetains`, `batch_corruptAndValid_validItemResolves`.

## Comments
