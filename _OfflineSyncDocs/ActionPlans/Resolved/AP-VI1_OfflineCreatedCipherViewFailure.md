# Action Plan: VI-1 — Offline-Created Cipher Fails to Load in Detail View

## Status: RESOLVED

**Resolved by:** Commits `06456bc` through `53e08ef` (PR #35, merged as `d191eb6`)
**Resolution approach:** Multi-part fix that addressed the root cause rather than Option E (catch-block fallback)

---

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | VI-1 |
| **Component** | `ViewItemProcessor` / `VaultRepository` / `CipherView+OfflineSync` |
| **Severity** | Medium |
| **Type** | Usability / Reliability |
| **Status** | **Resolved** |

## Original Description

When a user creates a new vault item while offline, the item appeared in the vault list but tapping it showed an infinite spinner — the detail view never loaded. The root cause was a chain of three factors:

1. `asyncTryMap` in `cipherDetailsPublisher` terminated the publisher stream on decryption error
2. Offline-created ciphers were stored via `Cipher.withTemporaryId()` which set `data: nil`, causing decryption failures
3. The `streamCipherDetails()` catch block only logged errors without updating `loadingState` to `.error`

## Resolution

The fix took a different and more thorough approach than the recommended Option E (error state + direct fetch fallback). Instead of working around the decryption failure, the root cause was eliminated:

### Key Changes

**1. Temp-ID assignment moved before encryption (`3f7240a`)**

The core architectural fix. Instead of assigning a temp ID to the encrypted `Cipher` after encryption (which caused the ID to be missing from the encrypted content), the temp ID is now assigned to the `CipherView` *before* encryption. This means the ID is baked into the encrypted content and survives the decrypt round-trip naturally.

- `VaultRepository.addCipher()` now calls `cipher.withId(UUID().uuidString)` before `encrypt(cipherView:)`
- The server ignores client-provided IDs for new ciphers and assigns its own

**2. `Cipher.withTemporaryId()` replaced with `CipherView.withId()` (`8ff7a09`, `3f7240a`)**

The fragile `Cipher.withTemporaryId()` method (which operated on the encrypted type and set `data: nil`) was replaced with `CipherView.withId()` (which operates on the decrypted type before encryption). This eliminates the `data: nil` problem entirely since the SDK handles all fields correctly during encryption.

**3. `handleOfflineAdd` simplified (`8ff7a09`)**

With temp-ID assignment happening before encryption, `handleOfflineAdd` no longer needs to assign IDs — it receives an already-ID'd encrypted cipher. The method was simplified to just guard that an ID exists.

**4. `resolveCreate` now cleans up temp-ID cipher records (`8ff7a09`, `12cb225`)**

After `addCipherWithServer` creates the cipher on the server (with a server-assigned ID), the old local `CipherData` record with the temporary ID is now deleted. This prevents orphaned temp-ID records from persisting in Core Data.

**5. Offline-created cipher deletion/soft-deletion handled (`12cb225`)**

When deleting or soft-deleting an offline-created cipher (one with a `.create` pending change), the handlers now clean up locally instead of queuing a `.softDelete` — since there's nothing to delete on the server.

**6. `handleOfflineUpdate` preserves `.create` change type (`12cb225`)**

When editing an offline-created cipher that hasn't synced yet, the pending change type remains `.create` instead of being overwritten to `.update`. This prevents the resolver from trying to GET the cipher by its temp ID (which the server doesn't know about).

**7. Error handling improvements (`08a2fed`, `f3e02fc`)**

The `streamCipherDetails()` catch block now sets error state directly instead of attempting a redundant re-fetch. The defensive else branch was also removed.

### Test Coverage Added

- `test_addCipher_offlineFallback_newCipherGetsTempId` — verifies temp ID assigned before encryption
- `test_withId_setsId`, `test_withId_preservesOtherProperties`, `test_withId_replacesExistingId` — tests for new `CipherView.withId()` method
- `test_deleteCipher_offlineFallback_cleansUpOfflineCreatedCipher` — verifies local cleanup for offline-created deletion
- `test_softDeleteCipher_offlineFallback_cleansUpOfflineCreatedCipher` — verifies local cleanup for offline-created soft-deletion
- `test_updateCipher_offlineFallback_preservesCreateType` — verifies `.create` type preservation
- `test_processPendingChanges_create` — updated to verify temp-ID record cleanup
- `test_processPendingChanges_create_nilId_skipsLocalDelete` — verifies nil-ID edge case

## Why This Approach Was Better Than Option E

The recommended Option E would have added a catch-block fallback in `ViewItemProcessor.streamCipherDetails()`. While that would have prevented the infinite spinner, it would have been a workaround — the cipher would still fail `decrypt()` and the user would either see stale data from a direct fetch or an error message.

The actual fix eliminates the root cause: offline-created ciphers now encrypt and decrypt identically to any other cipher because the temp ID is part of the encrypted content from the start. No special handling is needed in the detail view.

## Related Issues Affected

- **CS-2**: `Cipher.withTemporaryId()` has been deleted and replaced with `CipherView.withId()`. Only `CipherView.update(name:folderId:)` remains as a fragile copy method.
- **RES-1**: `resolveCreate` now includes temp-ID cleanup, reducing the orphan risk described in RES-1.
- **S7**: The `handleOfflineDelete` method now has a new code path for cleaning up offline-created ciphers, expanding the scope of what needs testing.
- **T7**: The `test_updateCipher_offlineFallback_preservesCreateType` test partially addresses subsequent offline edit testing.
