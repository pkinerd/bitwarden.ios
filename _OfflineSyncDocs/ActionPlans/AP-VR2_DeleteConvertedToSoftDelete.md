# Action Plan: VR-2 — Permanent Delete Converted to Soft Delete Offline

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | VR-2 |
| **Component** | `VaultRepository` |
| **Severity** | Informational |
| **Type** | Design Decision |
| **File** | `BitwardenShared/Core/Vault/Repositories/VaultRepository.swift` |

## Description

`deleteCipher` is intended as a permanent delete, but `handleOfflineDelete` performs a local soft delete (`deleteCipherWithLocalStorage` moves to trash). The `OfflineSyncResolver` also performs a soft delete on the server when resolving the pending change. This means a user who permanently deletes a cipher while offline ends up with the cipher in trash (both locally and server-side) rather than permanently deleted. The user would need to empty trash after reconnecting.

## Context

This design decision was made for safety: permanent deletes are irreversible, and in offline scenarios where conflicts can occur, a soft delete gives the resolver flexibility to create backups if needed. If the server version was modified while the user was offline, the resolver can back up the server version before deleting.

The tradeoff is that the user's intent (permanent delete) is not fully honored until they manually empty trash.

---

## Options

### Option A: Accept Current Behavior (Recommended)

Keep the soft-delete-in-offline behavior as a safety measure.

**Pros:**
- Safer — preserves the ability to recover if there's a conflict
- Consistent with the offline sync philosophy of "preserve data over honoring exact intent"
- Trash can be emptied after reconnecting
- No code change

**Cons:**
- User's intent (permanent delete) is not fully honored
- User may not realize the cipher is in trash
- Extra step required to complete the permanent delete

### Option B: Add a Post-Resolution Permanent Delete

After the resolver completes resolution and the pending change is deleted, perform a permanent delete (if the original operation was permanent delete).

**Approach:**
1. Add a new `PendingCipherChangeType.permanentDelete` to distinguish from `.softDelete`
2. In `handleOfflineDelete`, use `.permanentDelete` instead of `.softDelete`
3. In the resolver, after resolving a `.permanentDelete`: backup if needed, then permanently delete from server and local storage

**Pros:**
- Honors the user's original intent
- Clear distinction between soft and permanent delete in the pending change system

**Cons:**
- Adds a new change type and resolution path
- Permanent delete after backup means the backup survives but the original is gone
- More complex resolver logic
- The safety benefit of soft delete is partially lost

### Option C: Document the Behavior for Users

Add user-facing documentation or an in-app note explaining that permanent deletes while offline will move the item to trash.

**Pros:**
- Sets user expectations
- No code change to the logic
- Low effort

**Cons:**
- Documentation doesn't prevent the surprising behavior
- Users may not read documentation

---

## Recommendation

**Option A** — Accept current behavior. The soft-delete approach is the safer design for offline scenarios. Data preservation (in trash) is preferable to irreversible permanent deletion in a context where conflicts are possible. If user feedback indicates this is a significant issue, Option B can be implemented later.

## Estimated Impact

- **Files changed:** 0
- **Risk:** None

## Related Issues

- **RES-1**: Duplicate on create retry — both are scenarios where the offline behavior differs from the user's exact intent.
- **U2**: Inconsistent offline support — if archive/restore are added, the delete behavior should be consistent with the broader offline strategy.
- **S7 (VR-5)**: Cipher-not-found test — the not-found path in `handleOfflineDelete` is related to the delete flow.

## Updated Review Findings

The review confirms the original assessment. After reviewing the implementation:

1. **Code verification** (reviewed 2026-02-18): `VaultRepository.swift:1099-1137` shows `handleOfflineDelete`:
   - Lines 1102-1113: First checks if the cipher was created offline (`.create` pending change). If so, cleans up locally and returns — no server action needed.
   - Line 1124: `try await cipherService.deleteCipherWithLocalStorage(id: cipherId)` — this performs a LOCAL soft delete (moves to trash)
   - Lines 1129-1136: Queues pending change as `.softDelete` type

   Then in `OfflineSyncResolver.swift:270-313` `resolveSoftDelete`:
   - Lines 280-288: Handles 404 (cipher already deleted on server) — cleans up locally
   - Lines 293-300: If conflict detected, backs up the server version before deleting
   - Line 308: `try await cipherService.softDeleteCipherWithServer(id: cipherId, localCipher)` — performs SERVER soft delete

   So: user intends permanent delete → local soft delete → server soft delete. The cipher ends up in trash on both local and server.

2. **Design rationale validated**: The soft delete approach is correct because:
   - The resolver may detect a conflict (server version was modified while offline)
   - If there's a conflict, the resolver backs up the server version before deleting (lines 293-300)
   - A permanent delete would destroy the server version with no recovery path
   - Soft delete preserves the ability to create a backup of the conflicting server version

3. **User impact**: The user must empty trash to complete the permanent delete. This is a minor inconvenience compared to the risk of irreversible data loss in a conflict scenario.

4. **PendingCipherChangeType consideration**: Currently there is no `.permanentDelete` type (`PendingCipherChangeData.swift:8-17` defines only `.update`, `.create`, `.softDelete`). If permanent delete support were added (Option B), it would require adding a new enum case and a new resolution path. This complexity is not justified for the initial release.

**Updated conclusion** (2026-02-18): Original recommendation (Option A - accept current behavior) confirmed. The soft-delete-in-offline approach is the correct safety-first design. Data preservation in trash is strongly preferred over irreversible deletion in offline conflict scenarios. The `handleOfflineDelete` method has also been enhanced since the original review with a `.create` pending change check (lines 1102-1113) that cleans up offline-created ciphers locally rather than queuing them for server deletion. Priority: Informational, no change needed.
