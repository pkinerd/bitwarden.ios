# Action Plan: VI-1 — Offline-Created Cipher Fails to Load in Detail View

## Status: RESOLVED

> **Symptom fixed by:** `ViewItemProcessor.fetchCipherDetailsDirectly()` fallback (PR #31)
> **Root cause fixed by:** `CipherView.withId()` replacing `Cipher.withTemporaryId()` (commit `3f7240a`)
> **All 5 recommended fixes implemented in Phase 2** — see resolution details below.

---

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | VI-1 |
| **Component** | `ViewItemProcessor` / `VaultRepository` / `Cipher+OfflineSync` |
| **Severity** | ~~Medium~~ Resolved |
| **Type** | Usability / Reliability |
| **Status** | **Resolved** |

## Original Description

When a user created a new vault item while offline, the item appeared in the vault list but tapping it showed an infinite spinner — the detail view never loaded. The root cause was a chain of three factors:

1. `asyncTryMap` in `cipherDetailsPublisher` terminated the publisher stream on decryption error
2. Offline-created ciphers were stored via `Cipher.withTemporaryId()` which set `data: nil`, causing decryption failures
3. The `streamCipherDetails()` catch block only logged errors without updating `loadingState` to `.error`

## Resolution

### Symptom Fix (PR #31)

The **symptom** (infinite spinner) was fixed via a UI-level fallback in `ViewItemProcessor`. When the publisher-based stream fails to load cipher details, `fetchCipherDetailsDirectly()` performs a direct fetch from the cipher service as a fallback. This remains as defense-in-depth.

### Root Cause Fixes (Phase 2)

All 5 recommended root cause fixes have been implemented:

| # | Fix | Commit | Status |
|---|-----|--------|--------|
| 1 | **Move temp-ID assignment before encryption** — Temp ID now assigned to `CipherView` before `encrypt(cipherView:)`, baking the ID into encrypted content | `3f7240a` | **DONE** |
| 2 | **Replace `Cipher.withTemporaryId()` with `CipherView.withId()`** — Operates on decrypted `CipherView` before encryption; eliminates `data: nil` problem entirely | `3f7240a` | **DONE** |
| 3 | **Preserve `.create` type in `handleOfflineUpdate()`** — Editing a cipher with existing `.create` pending change preserves `.create` type | `12cb225` | **DONE** |
| 4 | **Clean up offline-created ciphers on delete** — `handleOfflineDelete()`/`handleOfflineSoftDelete()` check for `.create` pending change and clean up locally instead of queuing futile `.softDelete` | `12cb225` | **DONE** |
| 5 | **Clean up temp-ID records in `resolveCreate()`** — After `addCipherWithServer` succeeds, old `CipherData` record with temp ID is deleted | `8ff7a09`, `53e08ef` | **DONE** |

### Test Coverage

| Test | Covers | Status (verified 2026-02-18) |
|------|--------|------|
| `test_updateCipher_offlineFallback_preservesCreateType` | Fix #3 — `.create` type preserved on subsequent edit | Present (`VaultRepositoryTests.swift:1730`) |
| `test_deleteCipher_offlineFallback_cleansUpOfflineCreatedCipher` | Fix #4 — local cleanup on delete | Present (`VaultRepositoryTests.swift:854`) |
| `test_softDeleteCipher_offlineFallback_cleansUpOfflineCreatedCipher` | Fix #4 — local cleanup on soft delete | Present (`VaultRepositoryTests.swift:2166`) |
| `test_perform_appeared_errors_fallbackFetchThrows` | Symptom fix — fallback fetch | Present (`ViewItemProcessorTests.swift:310`) |

> **Note** (2026-02-20): Two tests originally listed for Fix #5 (`deletesOldTempIdCipher` and `nilId_skipsLocalDelete`) were evaluated and intentionally not added. The temp-ID cleanup at `OfflineSyncResolver.swift:159-161` is already exercised by `test_processPendingChanges_create` (`OfflineSyncResolverTests.swift:69`). A dedicated assertion on `deleteCipherWithLocalStorage` would test an implementation detail already covered by that path. The `if let tempId` nil guard tests a state that cannot occur in practice — `handleOfflineAdd` guards `encryptedCipher.id != nil` before storing, so any `.create` pending change always has a non-nil cipher ID. Adding a test for an impossible state would be misleading cruft.

## Code Verification (2026-02-18)

All 5 fixes verified present in the codebase:

1. **Fix #1 & #2**: `VaultRepository.swift:513` — `cipher.withId(UUID().uuidString)` assigns temp ID to `CipherView` before encryption. `CipherView.withId(_:)` defined in `CipherView+OfflineSync.swift:16`. No `Cipher.withTemporaryId()` exists anywhere in the codebase.
2. **Fix #3**: `VaultRepository.swift:1077-1080` — `handleOfflineUpdate` preserves `.create` type: `let changeType: PendingCipherChangeType = existing?.changeType == .create ? .create : .update`
3. **Fix #4**: `VaultRepository.swift:1104-1113` (`handleOfflineDelete`) and `VaultRepository.swift:1150-1159` (`handleOfflineSoftDelete`) — both check for `.create` pending change and clean up locally.
4. **Fix #5**: `OfflineSyncResolver.swift:158-167` — `resolveCreate` deletes temp-ID record after `addCipherWithServer` succeeds.
5. **Symptom fix**: `ViewItemProcessor.swift:611,619` — `fetchCipherDetailsDirectly()` fallback present.

## Related Issues (Updated)

- **CS-2**: ~~`Cipher.withTemporaryId()` still exists with `data: nil`~~ **Updated** — `Cipher.withTemporaryId()` removed. Fragile copy pattern now applies to `CipherView.withId(_:)` and `CipherView.update(name:)`. Same fragility concern (manual field copying), different method. **[Updated]** `folderId` parameter removed from `update` — backup ciphers now retain the original cipher's folder assignment. (Verified 2026-02-18: `CipherView+OfflineSync.swift` has `makeCopy` at line 66 that manually copies all 28 `CipherView` properties — fragility concern remains but is well-documented.)
- **RES-1**: ~~`resolveCreate` does NOT include temp-ID cleanup~~ **Partially Resolved** — Temp-ID cleanup added (commits `8ff7a09`, `53e08ef`). Duplicate-on-retry concern (server already has the cipher) still informational.
- ~~**S7**~~: ~~`handleOfflineDelete` does not have a `.create` check~~ **[Resolved]** — `.create` check added in commit `12cb225`. Resolver-level 404 tests added in commit `e929511`. See [AP-S7](Resolved/AP-S7_CipherNotFoundPathTest.md).
- ~~**T7**~~: ~~No `preservesCreateType` test exists~~ **[Resolved]** — Covered by `test_updateCipher_offlineFallback_preservesCreateType` (commit `12cb225`). See [AP-T7](Resolved/AP-T7_SubsequentOfflineEditTest.md).
