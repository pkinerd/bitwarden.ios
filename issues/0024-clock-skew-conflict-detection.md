---
id: 24
title: "[R2-RES-2] Clock skew — both versions always preserved"
status: closed
created: 2026-02-21
author: claude
labels: [enhancement]
priority: low
closed: 2026-02-21
---

## Description

Clock skew could affect conflict detection. Both versions are always preserved, and clock skew is rare on iOS — accepted as-is.

**Disposition:** Accepted
**Action Plan:** AP-R2-RES-2 (Accepted)

**Related Documents:** Review2

## Action Plan

*Source: `ActionPlans/Accepted/AP-R2-RES-2_ConflictTimestampClockSkew.md`*

> **Issue:** #44 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Triaged
> **Source:** Review2/02_OfflineSyncResolver_Review.md (Conflict Resolution Logic section)

## Problem Statement

The `resolveConflict()` method in `OfflineSyncResolver` determines which version of a cipher "wins" a conflict by comparing a client-side timestamp (`pendingChange.updatedDate`) against a server-side timestamp (`serverCipher.revisionDate`). If the device clock is significantly skewed (ahead or behind the server), the wrong version could be selected as the "winner."

For example, if a user's device clock is 2 hours ahead, the local timestamp would appear newer than the server's even if the server edit was actually more recent. Conversely, a device clock that is behind could cause local edits to always "lose" to server versions.

## Current Code

The conflict resolution logic is in `OfflineSyncResolver.swift:231-261`:

```swift
// OfflineSyncResolver.swift:237
let localTimestamp = pendingChange.updatedDate ?? pendingChange.createdDate ?? Date.distantPast
let serverTimestamp = serverCipher.revisionDate

if localTimestamp > serverTimestamp {
    // Local is newer - backup server version first, then push local.
    try await createBackupCipher(from: serverCipher, timestamp: serverTimestamp, userId: userId)
    try await cipherService.updateCipherWithServer(localCipher, encryptedFor: userId)
} else {
    // Server is newer - backup local version first, then update local storage.
    try await createBackupCipher(from: localCipher, timestamp: localTimestamp, userId: userId)
    try await cipherService.updateCipherWithLocalStorage(serverCipher)
}
```

The `localTimestamp` is sourced from `PendingCipherChangeData.updatedDate` or `createdDate` (set at `PendingCipherChangeData.swift:100-101` via `Date()` which uses the device clock). The `serverTimestamp` is `Cipher.revisionDate`, which is set by the server.

These two timestamps come from fundamentally different clock sources -- the device clock and the Bitwarden server clock. They are only comparable if the device clock is reasonably synchronized with the server.

## Assessment

**Validity:** This issue is technically valid. Client-side and server-side timestamps are not directly comparable when device clocks are skewed. However, the practical impact is extremely low due to the system's design:

1. **Both versions are always preserved.** Regardless of which version "wins," the "losing" version is backed up as a new cipher with a timestamp-suffixed name. No data is ever lost. The user can always find the backup and manually choose the correct version.

2. **Clock skew is rare on modern iOS devices.** iOS devices synchronize time via NTP automatically. Significant clock skew (minutes or hours) is extremely uncommon on well-configured devices. Minor skew (seconds) is unlikely to change the winner in realistic scenarios.

3. **The comparison is a heuristic, not a correctness guarantee.** The timestamp comparison is used to make a "best guess" about which version is more recent. The critical safety property is that both versions are preserved, not that the winner selection is perfect.

4. **No server timestamp is available for the local edit.** The server does not assign a timestamp to the offline edit (it happened offline), so the client timestamp is the only available signal.

**Blast radius:** If the wrong winner is selected due to clock skew:
- The "wrong" version becomes the primary cipher
- The "correct" version exists as a backup cipher with a timestamp-appended name
- The user can manually resolve by copying data from the backup
- No data is lost

**Likelihood:** Very low. Requires significant device clock skew (minutes+) coinciding with a conflict during offline sync resolution.

## Options

### Option A: Add Server Timestamp Normalization (Recommended If Acting)
- **Effort:** Small (2-3 hours)
- **Description:** When the resolver fetches the server cipher via `getCipher(withId:)`, capture the server's response timestamp (from the HTTP `Date` header or by recording the fetch time). Use the delta between `Date()` and the server time to normalize the local timestamp before comparison. This accounts for systematic clock offset.
- **Pros:** Corrects for systematic clock skew; uses already-available HTTP response data
- **Cons:** Only corrects for current offset, not the offset at the time of the original offline edit; adds complexity to the resolver; HTTP Date header may not be available from all server responses
- **Implementation sketch:**
  ```swift
  // After fetching server cipher, calculate offset
  let serverTime = httpResponse.dateHeader ?? Date()
  let clientTime = Date()
  let clockOffset = clientTime.timeIntervalSince(serverTime)

  // Normalize local timestamp
  let normalizedLocalTimestamp = localTimestamp.addingTimeInterval(-clockOffset)

  if normalizedLocalTimestamp > serverTimestamp { ... }
  ```

### Option B: Always Prefer Local Edits (Bias Toward User Intent)
- **Effort:** Minimal (30 minutes)
- **Description:** Change the conflict resolution to always prefer the local version when a conflict is detected, since the user explicitly made the local edit. The server version is always backed up. This eliminates the timestamp comparison entirely.
- **Pros:** Eliminates the clock skew problem entirely; aligns with the principle that the most recent user action should take priority; simpler logic
- **Cons:** If another device made a more recent edit, it would always lose to the local version; could be surprising if the user expects server edits to take priority when they are clearly newer
- **Note:** This is arguably the correct behavior for a password manager -- the user's explicit local action should not be overridden by a potentially-stale server version.

### Option C: Accept As-Is
- **Rationale:** The backup-before-overwrite pattern guarantees no data loss regardless of winner selection. The timestamp comparison is a reasonable heuristic for the common case (properly synchronized device clocks). Clock skew significant enough to affect the outcome is rare on iOS. The user can always recover from incorrect winner selection by finding the backup cipher. Adding clock normalization adds complexity for an extremely unlikely edge case, and the normalization itself introduces new edge cases (HTTP Date header parsing, offset calculation accuracy).

## Recommendation

**Option C: Accept As-Is.** The critical safety property -- that both versions are preserved via backup -- makes the winner selection a cosmetic concern rather than a data safety concern. The timestamp heuristic works correctly in the overwhelmingly common case. The effort to implement clock normalization is not justified by the extremely low probability and zero-data-loss impact of this edge case.

If this issue is revisited in the future, **Option B** (always prefer local) is worth considering as a simplification that eliminates the problem entirely while arguably providing better UX (user's explicit actions always win).

## Dependencies

- No direct dependencies on other issues.
- The backup cipher creation mechanism (`createBackupCipher` at `OfflineSyncResolver.swift:316-339`) is the key safety net that makes this issue low-severity. Any changes to backup creation would need to be reviewed in the context of this issue.

## Comments
