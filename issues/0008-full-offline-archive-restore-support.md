---
id: 8
title: "[U2-A] Full offline support for archive/unarchive/restore operations"
status: open
created: 2026-02-21
author: claude
labels: [feature]
priority: low
---

## Description

Full offline support for archive/unarchive/restore operations (applies to all vaults — personal and org; archive requires premium; UI gated behind `.archiveVaultItems` feature flag).

**Severity:** Low
**Complexity:** High
**Dependencies:** Archive UI gated behind `.archiveVaultItems` feature flag; archive requires premium.

**Related Documents:** AP-U2, ReviewSection_VaultRepository.md

**Status:** Deferred — future enhancement.

## Action Plan

*Source: `ActionPlans/AP-U2_InconsistentOfflineSupport.md`*

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

**Note on scope:** Archive/unarchive/restore operations apply to **all vaults** (personal and organization), not just org ciphers. The archive UI is entirely gated behind the `.archiveVaultItems` feature flag — when the flag is disabled, no archive/unarchive buttons appear in the UI. Additionally, **archiving requires premium** (unarchiving does not). The UI surfaces in two places when the flag is enabled: the View Item toolbar menu and the vault list "More Options" context menu.

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

- **S8**: Feature flag — **[Resolved]** the two feature flags (`.offlineSyncEnableResolution` gates resolution, `.offlineSyncEnableOfflineChanges` gates offline saves) now gate the existing offline operations. If new operations are added (Option A), they should be gated by these same flags.
- **U1**: Org cipher error timing — both are UX concerns about error presentation.
- **U3**: Pending changes indicator — if more operations go offline, a pending changes indicator becomes more important.
- **VR-2**: Delete converted to soft delete — similar design decision about how operations behave differently offline.

## Updated Review Findings

The review confirms the original assessment with code-level detail. After reviewing the implementation:

1. **Supported operations verified** (reviewed 2026-02-18): VaultRepository has offline fallback handlers for:
   - `addCipher` (line 505) → `handleOfflineAdd` (line 1007) — via catch-all at line 535
   - `updateCipher` (line 959) → `handleOfflineUpdate` (line 1034) — via catch-all at line 982
   - `deleteCipher` (line 659) → `handleOfflineDelete` (line 1099) — via catch-all at line 674
   - `softDeleteCipher` (line 921) → `handleOfflineSoftDelete` (line 1145) — via catch-all at line 942

   The catch pattern now uses a broader catch-all that re-throws `ServerError`, `ResponseValidationError` (client-side), and `CipherAPIServiceError`, then falls through to the offline handler for any other errors (including network failures).

2. **Unsupported operations verified** (no offline catch block):
   - `archiveCipher` (line 546) — calls `cipherService.archiveCipherWithServer(id:_:)` with no catch
   - `unarchiveCipher` (line 950) — calls `cipherService.unarchiveCipherWithServer(id:_:)` with no catch
   - `updateCipherCollections` (line 994) — calls `cipherService.updateCipherCollectionsWithServer(_:)` with no catch
   - `shareCipher` (line 890) — calls API with no catch (correctly excluded due to org key requirements)
   - `restoreCipher` (line 856) — calls `cipherService.restoreCipherWithServer(id:_:)` with no catch

3. **Archive feature flag interaction**: `.archiveVaultItems` feature flag is still actively used throughout the codebase (VaultListProcessor, ViewItemProcessor, VaultItemMoreOptionsHelper, Fido2CredentialStoreService, ExportVaultService, AutofillCredentialService). The archive feature is still gated behind this flag, so adding offline support for archive is premature until the feature is fully stable.

4. **Option B assessment**: Adding specific error messages for unsupported operations remains the right minimum improvement. The `OfflineSyncError.operationNotSupportedOffline` case has NOT been added yet. The current `OfflineSyncError` enum contains: `.missingCipherData`, `.missingCipherId`, `.vaultLocked`, `.cipherNotFound`. To implement Option B, a new `.operationNotSupportedOffline` case would need to be added, along with a catch block in each unsupported operation matching the same pattern used by supported operations:
   ```swift
   } catch let error as ServerError {
       throw error
   } catch let error as ResponseValidationError where error.response.statusCode < 500 {
       throw error
   } catch let error as CipherAPIServiceError {
       throw error
   } catch {
       throw OfflineSyncError.operationNotSupportedOffline
   }
   ```

**Updated conclusion** (2026-02-18): Original recommendation (Option B as minimum, Option C acceptable for initial release) confirmed. Neither Option A nor Option B has been implemented yet — the unsupported operations still have no offline-specific error handling. Adding clear error messages for unsupported operations is low-effort and high-value for UX. If the initial release scope is tight, Option C (accept and document) is fine. Priority: Informational for initial release; Low for follow-up.

## Consolidated Assessment

*From: ConsolidatedOutstandingIssues.md — Section 3: Deferred Issues*

Full offline support for archive/unarchive/restore operations (applies to all vaults — personal and org; archive requires premium; UI gated behind `.archiveVaultItems` feature flag).

## Code Review References

Relevant review documents:
- `ReviewSection_VaultRepository.md`

## Comments

### claude — 2026-02-22

**Codebase validated — issue confirmed OPEN.**

1. `archiveCipher()` (line 549) — NO try/catch, NO offline fallback
2. `unarchiveCipher()` (line 961) — NO try/catch, NO offline fallback
3. `restoreCipher()` (line 864) — NO try/catch, NO offline fallback
4. No `handleOfflineArchive`, `handleOfflineRestore`, or similar methods exist

Contrast: add, update, delete, softDelete all have `handleOffline*` fallback handlers.
