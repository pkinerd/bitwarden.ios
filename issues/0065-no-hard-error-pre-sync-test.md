---
id: 65
title: "[T8] No hard error in pre-sync resolution test"
status: closed
created: 2026-02-21
author: claude
labels: [bug]
priority: low
closed: 2026-02-21
---

## Description

**Resolution:** Test added. Commit: `4d65465`

**Disposition:** Resolved / Superseded

## Action Plan

*Source: `ActionPlans/Resolved/AP-T8_HardErrorInPreSyncResolution.md`*

> **Status: [RESOLVED]** — Option A has been implemented in `SyncServiceTests.swift` as `test_fetchSync_preSyncResolution_resolverThrows_syncFails`. The test configures `processPendingChangesResult = .failure(BitwardenTestError.example)`, verifies the error is thrown from `fetchSync()`, confirms the resolver was called, and asserts that no API sync request was made and no ciphers were replaced.

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | T8 / SS-1 |
| **Component** | `SyncServiceTests` |
| **Severity** | ~~Low~~ **Resolved** |
| **Type** | Test Gap |
| **File** | `BitwardenShared/Core/Vault/Services/SyncServiceTests.swift` |

## Description

No test verifies what happens when `offlineSyncResolver.processPendingChanges()` throws a hard error (not a per-item failure that's caught internally, but a propagating error like a Core Data failure). The `try await` in `fetchSync` would propagate this error, causing the entire sync to fail. This behavior should be verified by a test.

## Context

The `processPendingChanges` method internally catches per-item errors. It would only throw if:
1. `pendingCipherChangeDataStore.fetchPendingChanges()` fails (Core Data error)
2. An unexpected/unhandled error occurs in the resolution loop setup

In either case, the error propagating through `fetchSync` is the correct behavior — if we can't read pending changes, sync should not proceed (to protect unsynced data). But this behavior is untested.

---

## Options

### Option A: Add a Single Test for Resolver Hard Error (Recommended)

Add a test that configures the mock resolver to throw an error, and verify that `fetchSync` propagates the error (sync does not complete).

**Approach:**
```
test_fetchSync_preSyncResolution_resolverThrows_syncFails:
1. Configure mock pendingCipherChangeDataStore.pendingChangeCount to return > 0
2. Configure mock offlineSyncResolver.processPendingChanges to throw an error
3. Call syncService.fetchSync()
4. Assert: error is thrown
5. Assert: no API sync request was made
```

**Pros:**
- Directly tests error propagation from resolver
- Verifies sync does not proceed on resolver failure
- Simple test (~30-40 lines)

**Cons:**
- Requires the mock resolver to support throwing (may need a `processPendingChangesError` property on `MockOfflineSyncResolver`)

### Option B: Add Tests for Multiple Hard Error Scenarios

Test both the resolver throwing and the data store count method throwing.

**Pros:**
- More comprehensive
- Tests both failure points

**Cons:**
- Additional test for a low-severity issue
- The count method throwing is even more unlikely than the resolver throwing

---

## Recommendation

**Option A** — Add a single test for resolver hard error. This verifies the critical safety property that sync does not proceed when the resolver cannot function.

## Estimated Impact

- **Files changed:** 1-2 (`SyncServiceTests.swift`, possibly `MockOfflineSyncResolver.swift`)
- **Lines added:** ~30-40
- **Risk:** Very low — test-only changes

## Related Issues

- **R4 (SS-3)**: Silent sync abort — the hard error case should be distinguishable from the "remaining pending changes" abort in logs.
- **S4 (RES-4)**: API failure during resolution — the hard error is a different failure mode from per-item API failures.

## Updated Review Findings

The review confirms the original assessment. After reviewing the implementation:

1. **Code verification**: `SyncService.swift:336` calls `try await offlineSyncResolver.processPendingChanges(userId: userId)`. If this throws, the error propagates through `fetchSync()` since there's no catch block around this call. The entire sync operation fails.

2. **When processPendingChanges throws**: Looking at `OfflineSyncResolver.swift:121-137`, the method can throw from:
   - Line 122: `pendingCipherChangeDataStore.fetchPendingChanges()` — Core Data error
   - Any unexpected error not caught by the per-item catch (unlikely given the broad `catch error` at line 131)

   In practice, only Core Data failures would propagate. Per-item API/logic errors are caught by the do/catch inside the loop.

3. **Mock verification**: `MockOfflineSyncResolver.swift` has:
   ```swift
   var processPendingChangesResult: Result<Void, Error> = .success(())
   ```
   This already supports `.failure(someError)` configuration. The mock infrastructure is ready for this test.

4. **Test assertion**: The test should verify:
   - Error is thrown from `fetchSync()`
   - No API sync request was made (the sync data fetch never happened)
   - The error is the same error thrown by the resolver

**Updated conclusion**: Original recommendation (Option A - single test for resolver hard error) confirmed. The mock infrastructure already supports this. This is a straightforward ~30-40 line test. Priority: Low.

## Resolution Details

Test added: `test_fetchSync_preSyncResolution_resolverThrows_syncFails`. Commit: `4d65465`.

## Comments
