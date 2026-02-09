# Action Plan: U2 — Inconsistent Offline Support Across Operations

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | U2 |
| **Component** | `VaultRepository` |
| **Severity** | Informational |
| **Type** | UX / Feature Gap |
| **Files** | `BitwardenShared/Core/Vault/Repositories/VaultRepository.swift` |

## Description

Add, update, delete, and soft-delete work offline. Archive, unarchive, collection assignment, and restore do not. Users performing unsupported operations offline receive generic network errors rather than offline-specific messages. This inconsistency could confuse users who expect all vault operations to work seamlessly offline.

## Context

The excluded operations (verified in `VaultRepository.swift`):
- `archiveCipher(_:)` (lines ~527-529) — moves cipher to archive
- `unarchiveCipher(_:)` (lines ~908-915) — restores from archive
- `updateCipherCollections(_:)` (lines ~939-942) — changes collection assignments
- `shareCipher(...)` — shares with an organization
- `restoreCipher(_:)` — restores from trash

`shareCipher` is correctly excluded (requires org encryption and key exchange). The others could theoretically be supported offline using the same pattern as update/delete.

**Note on archive feature flag:** The project has a `.archiveVaultItems` feature flag (`FeatureFlag.swift:9`) for the archive feature. If archive is itself behind a feature flag, adding offline support for it is premature until the archive feature is stable.

---

## Options

### Option A: Extend Offline Support to Archive/Unarchive/Restore

Add offline fallback handlers for `archiveCipher`, `unarchiveCipher`, and `restoreCipher` using the same pattern as the existing handlers.

**Approach:**
- Archive/unarchive: These modify the cipher's `deletedDate` field (archive sets it; unarchive clears it). Could be handled as update operations in the pending change system.
- Restore: Similar to unarchive — clears `deletedDate` and moves out of trash.
- Map each to a `PendingCipherChangeType` (reuse `.update` or add new types).

**Pros:**
- Consistent offline experience across all personal cipher operations
- Users can archive/unarchive/restore while offline
- Follows the same pattern as existing offline handlers

**Cons:**
- Adds more code to VaultRepository (~150-200 lines per operation)
- May need new `PendingCipherChangeType` variants
- Conflict resolution for these operations is less well-defined (what does a "conflict" mean for archive/unarchive?)
- Increases the surface area for bugs
- More operations = more potential for sync blocking

### Option B: Add Offline-Specific Error Messages for Unsupported Operations

Keep the operations unsupported offline, but replace the generic network error with a clear offline-specific message: "This action requires an internet connection. Your other changes will sync when connectivity is restored."

**Approach:**
- In `archiveCipher`, `unarchiveCipher`, `restoreCipher`, and `updateCipherCollections`: catch URLError and throw a new `OfflineSyncError.operationNotSupportedOffline` error
- The error's localized description explains the limitation clearly

**Pros:**
- Better UX — users understand why the operation failed
- No offline queue complexity
- Clear boundary of what works offline vs. not
- Minimal code change (~20-30 lines)

**Cons:**
- Still inconsistent — some operations work offline, some don't
- Users may wonder why add/update works but archive doesn't

### Option C: Accept Current Behavior (Recommended for Initial Release)

Keep the current inconsistency and track it as a future enhancement.

**Pros:**
- No code change
- Feature can ship as-is
- The excluded operations are less critical (archive/unarchive are convenience operations, not data-critical)
- Reduces initial scope and risk

**Cons:**
- Users may report the inconsistency as a bug
- Generic network error messages are unhelpful

---

## Recommendation

**Option B** as a minimum improvement for the initial release, with **Option A** tracked as a future enhancement. Adding clear error messages for unsupported operations is low-effort and significantly improves the user experience. Full offline support for these operations can be added in a future iteration once the core offline sync feature is proven in production.

## Estimated Impact

- **Option B:** Files changed: 1 (`VaultRepository.swift`), Lines added: ~20-30, Risk: Very low
- **Option A:** Files changed: 3-5, Lines added: ~300-400, Risk: Medium

## Related Issues

- **S8**: Feature flag — the feature flag should gate the existing offline operations. If new operations are added (Option A), they should be gated by the same flag.
- **U1**: Org cipher error timing — both are UX concerns about error presentation.
- **U3**: Pending changes indicator — if more operations go offline, a pending changes indicator becomes more important.
- **VR-2**: Delete converted to soft delete — similar design decision about how operations behave differently offline.

## Updated Review Findings

The review confirms the original assessment with code-level detail. After reviewing the implementation:

1. **Supported operations verified**: VaultRepository has offline fallback handlers for:
   - `addCipher` → `handleOfflineAdd` (line 520)
   - `updateCipher` → `handleOfflineUpdate` (line 931)
   - `deleteCipher` → `handleOfflineDelete` (line 645)
   - `softDeleteCipher` → `handleOfflineSoftDelete` (line 904)

2. **Unsupported operations verified** (no offline catch block):
   - `archiveCipher` — calls `cipherAPIService.archiveCipher(withID:)` with no catch for URLError
   - `unarchiveCipher` — calls `cipherAPIService.unarchiveCipher(withID:)` with no catch
   - `updateCipherCollections` — calls `cipherAPIService.updateCipherCollections()` with no catch
   - `shareCipher` — calls API with no catch (correctly excluded due to org key requirements)
   - `restoreCipher` — calls `cipherAPIService.restoreCipher(withID:)` with no catch

3. **Archive feature flag interaction**: `FeatureFlag.swift:9` defines `.archiveVaultItems`. If archive is still behind a feature flag, adding offline support for it is premature. This is correctly noted in the original action plan.

4. **Option B assessment**: Adding specific error messages for unsupported operations is the right minimum improvement. The pattern would be adding a catch block similar to:
   ```swift
   catch let error as URLError where error.isNetworkConnectionError {
       throw OfflineSyncError.operationNotSupportedOffline
   }
   ```
   This requires a new error case in `OfflineSyncError`. The implementation is ~5 lines per unsupported operation.

**Updated conclusion**: Original recommendation (Option B as minimum, Option C acceptable for initial release) confirmed. Adding clear error messages for unsupported operations is low-effort and high-value for UX. If the initial release scope is tight, Option C (accept and document) is fine. Priority: Informational for initial release; Low for follow-up.
