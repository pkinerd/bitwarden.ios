---
id: 16
title: "[R2-SS-5] Two pendingChangeCount calls — more robust than single return value"
status: closed
created: 2026-02-21
author: claude
labels: [enhancement]
priority: low
closed: 2026-02-21
---

## Description

Two `pendingChangeCount` calls in SyncService — more robust than single return value pattern.

**Disposition:** Accepted
**Action Plan:** AP-72 (Accepted)

**Related Documents:** Review2

## Action Plan

*Source: `ActionPlans/Accepted/AP-72_PendingChangeCountSimplification.md`*

> **Issue:** #72 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Triaged
> **Source:** Review2/04_SyncService_Review.md

## Problem Statement

The SyncService's pre-sync resolution block makes two separate `pendingChangeCount` calls to the `PendingCipherChangeDataStore`:

1. **Pre-resolution check** (line 343): Determines if there are any pending changes before invoking the resolver.
2. **Post-resolution check** (line 346): Determines if any pending changes remain after resolution (to decide whether to abort sync).

The review (R2-SS-5) suggests that the two `pendingChangeCount` calls could be replaced by having the resolver return a boolean indicating whether all changes were resolved, saving one Core Data query.

## Current Code

`BitwardenShared/Core/Vault/Services/SyncService.swift:340-351`:
```swift
let isVaultLocked = await vaultTimeoutService.isLocked(userId: userId)
if await configService.getFeatureFlag(.offlineSyncEnableResolution),
   !isVaultLocked {
    let pendingCount = try await pendingCipherChangeDataStore.pendingChangeCount(userId: userId)
    if pendingCount > 0 {
        try await offlineSyncResolver.processPendingChanges(userId: userId)
        let remainingCount = try await pendingCipherChangeDataStore.pendingChangeCount(userId: userId)
        if remainingCount > 0 {
            return
        }
    }
}
```

The `processPendingChanges(userId:)` method in `OfflineSyncResolver` protocol (`OfflineSyncResolver.swift:48`) currently returns `Void`.

## Assessment

**This issue is technically valid but the suggested change has tradeoffs that may not justify the effort.**

**Arguments against the change:**
1. **Robustness:** The current approach checks actual database state rather than trusting a return value from the resolver. This is more resilient to edge cases (e.g., a concurrent write adding a new pending change between resolution and the count check).
2. **TOCTOU consistency:** The post-resolution count check is the source of truth. The resolver internally catches and continues on per-change errors, so a boolean return would need to track whether ALL changes succeeded, which is effectively the same information as the count.
3. **Minimal performance impact:** The `pendingChangeCount` call is a Core Data `COUNT` fetch request, which is extremely fast (typically sub-millisecond). Saving one such query provides negligible performance benefit.
4. **Protocol change:** Changing the `OfflineSyncResolver` protocol return type from `Void` to `Bool` affects the protocol, the default implementation, the mock, and all test call sites.

**Arguments for the change:**
1. **Cleaner API:** The resolver could return a semantic boolean (`allResolved`) rather than requiring the caller to make a separate query.
2. **Reduced coupling:** The `SyncService` wouldn't need the `pendingCipherChangeDataStore` dependency for the count check (though it would still need it for the first pre-resolution count).

However, removing the post-resolution count would NOT eliminate the `pendingCipherChangeDataStore` dependency from `SyncService`, because the pre-resolution count check (line 343) still uses it. So the coupling reduction argument is moot.

## Options

### Option A: Change Resolver Return Type to Bool
- **Effort:** ~45 minutes, 4 files modified (~15 lines)
- **Description:** Change `processPendingChanges(userId:)` to return `Bool` indicating whether all changes were resolved. Update `OfflineSyncResolver` protocol, `DefaultOfflineSyncResolver`, `MockOfflineSyncResolver`, and `SyncService`.
- **Pros:** Marginally cleaner API; saves one Core Data COUNT query
- **Cons:** Less robust than checking actual state; protocol change ripples to mock and tests; `SyncService` still needs `pendingCipherChangeDataStore` for the pre-count; the resolver already swallows per-change errors internally, so the boolean would need careful implementation to accurately reflect the batch result

### Option B: Remove Pre-Resolution Count and Always Call Resolver
- **Effort:** ~15 minutes, 1 file modified (~5 lines removed)
- **Description:** Remove the pre-count check and always call `processPendingChanges`. The resolver already handles the empty case with a guard (`guard !pendingChanges.isEmpty else { return }`). Keep only the post-resolution count.
- **Pros:** Eliminates one count call; simpler code (fewer nested conditions)
- **Cons:** Always invokes the resolver (creates the actor message, performs the fetch inside the resolver); slightly less optimal for the common case (no pending changes)

### Option C: Accept As-Is (Recommended)
- **Rationale:** The two-count approach is the most robust pattern: check before (optimization to skip resolver invocation in the common case) and check after (source of truth for the abort decision). The Core Data COUNT query is sub-millisecond and not a performance concern. Changing the resolver's return type for this marginal improvement introduces protocol-level churn with no practical benefit.

## Recommendation

**Option C: Accept As-Is.** The current two-count approach is more robust than trusting a resolver return value, and the performance cost of a Core Data COUNT query is negligible. The pre-resolution count is a valuable optimization for the common case (no pending changes), and the post-resolution count is the ground truth for the sync abort decision. Changing the resolver's protocol signature for this minor improvement is not justified.

## Dependencies

- Related to Issue #73 (extracting the pre-sync resolution block into a private method) -- if both are implemented, they should be coordinated.

## Comments
