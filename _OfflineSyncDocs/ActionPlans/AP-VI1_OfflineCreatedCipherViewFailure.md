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

| Test | Covers |
|------|--------|
| `test_updateCipher_offlineFallback_preservesCreateType` | Fix #3 — `.create` type preserved on subsequent edit |
| `test_deleteCipher_offlineFallback_cleansUpOfflineCreatedCipher` | Fix #4 — local cleanup on delete |
| `test_softDeleteCipher_offlineFallback_cleansUpOfflineCreatedCipher` | Fix #4 — local cleanup on soft delete |
| `test_processPendingChanges_create_deletesOldTempIdCipher` | Fix #5 — temp-ID record cleanup |
| `test_processPendingChanges_create_nilId_skipsLocalDelete` | Fix #5 — nil guard |
| `test_perform_appeared_errors_fallbackFetchThrows` | Symptom fix — fallback fetch |

## Related Issues (Updated)

- **CS-2**: ~~`Cipher.withTemporaryId()` still exists with `data: nil`~~ **Updated** — `Cipher.withTemporaryId()` removed. Fragile copy pattern now applies to `CipherView.withId(_:)` and `CipherView.update(name:)`. Same fragility concern (manual field copying), different method. **[Updated]** `folderId` parameter removed from `update` — backup ciphers now retain the original cipher's folder assignment.
- **RES-1**: ~~`resolveCreate` does NOT include temp-ID cleanup~~ **Partially Resolved** — Temp-ID cleanup added (commits `8ff7a09`, `53e08ef`). Duplicate-on-retry concern (server already has the cipher) still informational.
- ~~**S7**~~: ~~`handleOfflineDelete` does not have a `.create` check~~ **[Resolved]** — `.create` check added in commit `12cb225`. Resolver-level 404 tests added in commit `e929511`. See [AP-S7](Resolved/AP-S7_CipherNotFoundPathTest.md).
- ~~**T7**~~: ~~No `preservesCreateType` test exists~~ **[Resolved]** — Covered by `test_updateCipher_offlineFallback_preservesCreateType` (commit `12cb225`). See [AP-T7](Resolved/AP-T7_SubsequentOfflineEditTest.md).
