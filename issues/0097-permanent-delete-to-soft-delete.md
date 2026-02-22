---
id: 97
title: "[VR-2] Permanent delete converted to soft delete when offline"
status: closed
created: 2026-02-21
author: claude
labels: [bug]
priority: low
closed: 2026-02-21
---

## Description

**Resolution:** `.hardDelete` change type added. Commit: `34b6c24`

**Disposition:** Resolved / Superseded

## Action Plan

*Source: `ActionPlans/Resolved/AP-VR2_DeleteConvertedToSoftDelete.md`*

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

~~**Option A** — Accept current behavior.~~ **[Superseded]** Option B has been implemented. See resolution below.

## Resolution (2026-02-20)

**Option B implemented** in commit `34b6c24`. The implementation differs slightly from the original Option B proposal:

1. **New `PendingCipherChangeType.hardDelete` (raw value 3):** Added to distinguish permanent delete intent from soft delete.
2. **`handleOfflineDelete` now stores `.hardDelete`** instead of `.softDelete`.
3. **`resolveSoftDelete` refactored into `resolveDelete(permanent:)`:** A unified method handles both `.softDelete` (calls `softDeleteCipher` API) and `.hardDelete` (calls `deleteCipher` API) in the no-conflict path.
4. **Conflict behavior changed:** Instead of creating a backup and completing the delete (original Option B proposal), the resolver **restores the server version locally** and drops the pending delete. This is safer because:
   - Backups may lack attachments (RES-7)
   - Users might not notice backup copies
   - The user explicitly sees the updated cipher reappear and can re-decide

**Files changed:** 6 (PendingCipherChangeData, VaultRepository, OfflineSyncResolver, OfflineSyncResolverTests, VaultRepositoryTests, MockCipherAPIServiceForOfflineSync)

**Status:** Resolved

## Estimated Impact

- **Files changed:** 6
- **Risk:** Low — conflict path is more conservative (restore vs. delete)

## Related Issues

- **RES-1**: Duplicate on create retry — both are scenarios where the offline behavior differs from the user's exact intent.
- **U2**: Inconsistent offline support — if archive/restore are added, the delete behavior should be consistent with the broader offline strategy.
- **S7 (VR-5)**: Cipher-not-found test — the not-found path in `handleOfflineDelete` is related to the delete flow.
- **RES-7**: Backup ciphers lack attachments — this was a contributing factor in choosing the "restore server version" conflict strategy over "backup + delete".

## Resolution Details

`.hardDelete` change type added; resolver calls permanent delete API; conflict restores server version. Commit: `34b6c24`.

## Comments
