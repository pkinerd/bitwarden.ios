---
id: 18
title: "[R2-RES-10] resolveConflict symmetry — explicit form more readable"
status: closed
created: 2026-02-21
author: claude
labels: [enhancement]
priority: low
closed: 2026-02-21
---

## Description

`resolveConflict` symmetry suggestion. Explicit form is more readable than abstraction — accepted as-is.

**Disposition:** Accepted
**Action Plan:** AP-74 (Accepted)

**Related Documents:** Review2

## Action Plan

*Source: `ActionPlans/Accepted/AP-74_ResolveConflictSymmetry.md`*

> **Issue:** #74 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Triaged
> **Source:** Review2/02_OfflineSyncResolver_Review.md

## Problem Statement

The review (R2-RES-10) observes that the `resolveConflict` method's two branches (local-newer and server-newer) have a symmetric structure: both create a backup of the "loser" and then either push the local version to the server or update local storage with the server version. The suggestion is that this symmetric pattern could potentially be abstracted.

## Current Code

`BitwardenShared/Core/Vault/Services/OfflineSyncResolver.swift:231-261`:
```swift
private func resolveConflict(
    localCipher: Cipher,
    serverCipher: Cipher,
    pendingChange: PendingCipherChangeData,
    userId: String
) async throws {
    let localTimestamp = pendingChange.updatedDate ?? pendingChange.createdDate ?? Date.distantPast
    let serverTimestamp = serverCipher.revisionDate

    if localTimestamp > serverTimestamp {
        // Local is newer - backup server version first, then push local.
        try await createBackupCipher(
            from: serverCipher,
            timestamp: serverTimestamp,
            userId: userId
        )
        try await cipherService.updateCipherWithServer(localCipher, encryptedFor: userId)
    } else {
        // Server is newer - backup local version first, then update local storage.
        try await createBackupCipher(
            from: localCipher,
            timestamp: localTimestamp,
            userId: userId
        )
        try await cipherService.updateCipherWithLocalStorage(serverCipher)
    }
}
```

The two branches are indeed symmetric:
- **Local-newer:** backup(server), push(local) to server
- **Server-newer:** backup(local), update local with (server)

## Assessment

**This issue is valid in observation but the review itself recommends keeping the current explicit form.** The review document (R2-RES-10) states: "current explicit form more readable." This is included in the issue description itself.

The current code is 30 lines (including the signature and comments). An abstracted version would need to determine the "winner" and "loser" ciphers and their corresponding timestamps, then decide whether to push to server or update local storage. The abstraction would look something like:

```swift
let (winner, loser, loserTimestamp, pushToServer) = localTimestamp > serverTimestamp
    ? (localCipher, serverCipher, serverTimestamp, true)
    : (serverCipher, localCipher, localTimestamp, false)

try await createBackupCipher(from: loser, timestamp: loserTimestamp, userId: userId)
if pushToServer {
    try await cipherService.updateCipherWithServer(winner, encryptedFor: userId)
} else {
    try await cipherService.updateCipherWithLocalStorage(winner)
}
```

This reduces line count by ~5 lines but introduces:
1. A confusing tuple destructuring with 4 elements
2. A boolean flag (`pushToServer`) that determines the action -- code smell
3. Less clarity about what happens in each case (the comments "Local is newer" and "Server is newer" are more immediately meaningful)

The current form is explicit, has clear comments, and each branch tells a complete story.

## Options

### Option A: Abstract the Symmetric Pattern
- **Effort:** ~20 minutes, ~10 lines modified
- **Description:** Determine winner/loser and use a single code path as shown above.
- **Pros:** Slight DRY improvement (~5 fewer lines); makes the symmetry explicit
- **Cons:** Less readable; tuple destructuring or local variables add cognitive load; boolean flag for server vs local is a code smell; comments lose their contextual placement

### Option B: Accept As-Is (Recommended)
- **Rationale:** The review itself recommends keeping the current explicit form. The two branches are only 7 lines each. The explicit if/else with descriptive comments makes the conflict resolution logic immediately clear. The abstracted version would save ~5 lines at the cost of readability. This is a case where explicit code is better than DRY code.

## Recommendation

**Option B: Accept As-Is.** The review's own conclusion is correct: "current explicit form more readable." The two branches tell a clear story about what happens in each conflict scenario. The slight duplication (each branch calls `createBackupCipher` then a different update method) is not worth abstracting because the resulting code would be harder to understand and maintain.

## Dependencies

None.

## Comments
