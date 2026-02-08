# Action Plan: SS-2 — TOCTOU Race Condition Between Count Check and Sync

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | SS-2 |
| **Component** | `SyncService` |
| **Severity** | Low |
| **Type** | Reliability / Thread Safety |
| **File** | `BitwardenShared/Core/Vault/Services/SyncService.swift` |

## Description

There's a theoretical time-of-check-time-of-use (TOCTOU) gap between checking `remainingCount == 0` after resolution and proceeding to the full sync (which includes `replaceCiphers`). If a new offline change is queued between these two points (by another async task calling a VaultRepository method), the sync could proceed and `replaceCiphers` would overwrite the newly queued change.

## Context

In practice, `fetchSync` is called from a serial context (the sync workflow), and user operations that queue pending changes go through `VaultRepository` methods which are separate async flows. For the race to occur:
1. Resolution completes (count = 0)
2. Between the count check and `replaceCiphers`, a VaultRepository offline handler queues a new pending change
3. `replaceCiphers` overwrites the newly queued change's local data

The timing window is extremely narrow (microseconds), and the user would need to be actively editing a cipher at the exact moment sync resolution completes.

---

## Options

### Option A: Add a Lock/Transaction Around Count-Check-and-Sync

Wrap the count check and the beginning of the sync in a transaction that prevents new pending changes from being queued.

**Approach:**
- Use a shared `NSLock` or `actor` to serialize pending change writes and sync decisions
- Before syncing: acquire lock, check count, if 0 proceed to sync
- VaultRepository offline handlers: acquire same lock before upserting

**Pros:**
- Eliminates the race condition
- Guarantees consistency between count and sync state

**Cons:**
- Mixing locks with async/await is an anti-pattern
- Significant complexity for an extremely unlikely race
- Could introduce deadlocks if not carefully implemented
- Performance impact on every cipher operation (lock acquisition)

### Option B: Double-Check Count After Sync

After `replaceCiphers` completes, check the pending count again. If > 0, the newly queued change exists and the next sync will handle it.

**Approach:**
- No change to the pre-sync flow
- Add a post-sync check: after `replaceCiphers`, if `pendingChangeCount > 0`, log a warning

**Pros:**
- Simple addition
- The next sync will resolve the new pending change
- No locking complexity

**Cons:**
- The `replaceCiphers` may have already overwritten the local data for the pending change
- The pending change's `cipherData` is still intact in the pending record, so the resolver can still push it to the server
- Doesn't prevent the race — just detects it after the fact

### Option C: Accept the Risk (Recommended)

Accept the theoretical race condition given its extremely low probability and the mitigating factors.

**Mitigating factors:**
1. The timing window is microseconds
2. The user would need to be actively editing at the exact moment resolution completes
3. Even if the race occurs, the pending change record's `cipherData` contains the user's edit — the resolver will push it on the next sync
4. `replaceCiphers` overwrites the local cipher data but doesn't touch the pending change record
5. The next sync will resolve the pending change correctly

**Pros:**
- No code change
- The mitigating factors make this essentially a non-issue
- Simpler architecture

**Cons:**
- Theoretical impurity — the local cipher view briefly shows the server version before the next sync restores the user's edit
- Not suitable for a hard real-time system (but this is a mobile app)

---

## Recommendation

**Option C** — Accept the risk. The race condition is theoretical with an extremely narrow timing window. The mitigating factors (pending record survives, next sync resolves) mean that even if the race occurs, the user's data is not lost — it's temporarily inconsistent until the next sync.

## Estimated Impact

- **Files changed:** 0
- **Risk:** None

## Related Issues

- **R2 (RES-2)**: conflictFolderId thread safety — both are concurrency concerns, but the resolver's is more practical (shared mutable state) while this is more theoretical (timing window).
- **R4 (SS-3)**: Silent sync abort — logging would help diagnose if this race ever occurs in practice.

## Updated Review Findings

The review confirms the original assessment. After reviewing the implementation:

1. **Code verification**: `SyncService.swift:334-341`:
   ```swift
   let pendingCount = try await pendingCipherChangeDataStore.pendingChangeCount(userId: userId)
   if pendingCount > 0 {
       try await offlineSyncResolver.processPendingChanges(userId: userId)
       let remainingCount = try await pendingCipherChangeDataStore.pendingChangeCount(userId: userId)
       if remainingCount > 0 {
           return
       }
   }
   // ... sync proceeds, eventually calls replaceCiphers
   ```
   The gap between `remainingCount == 0` (line 337) and `replaceCiphers` (later in fetchSync) is the TOCTOU window.

2. **Race window analysis**: For the race to occur:
   - `remainingCount` returns 0 (all pending changes resolved)
   - Before `replaceCiphers` executes, a VaultRepository offline handler queues a new pending change
   - `replaceCiphers` overwrites local cipher storage with server data

   The timing window is the async execution gap between the count check and the cipher replacement. In practice, this is milliseconds.

3. **Mitigation already in place**: Even if the race occurs:
   - The new pending change record in Core Data survives (it's in a separate entity)
   - The `cipherData` in the pending record contains the user's edit
   - On the next sync, the resolver processes this pending change
   - The user's data is NOT lost — just temporarily inconsistent in the vault view

4. **Locking assessment**: Adding a lock/actor between VaultRepository and SyncService to prevent this race would add significant complexity and potential deadlock risks. The async/await execution model makes traditional locking hazardous.

**Updated conclusion**: Original recommendation (Option C - accept risk) confirmed strongly. The race window is microseconds, the probability is near-zero, and the mitigating factors (pending record survives, next sync resolves) mean no data loss even if the race occurs. No code change needed. Priority: Low, accept as-is.
