# Action Plan: VI-1 — Offline-Created Cipher Fails to Load in Detail View

## Status: MITIGATED

**Symptom mitigated by:** `ViewItemProcessor.fetchCipherDetailsDirectly()` fallback (PR #31)
**Root cause remains:** `Cipher.withTemporaryId()` still sets `data: nil`, causing decryption failures

---

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | VI-1 |
| **Component** | `ViewItemProcessor` / `VaultRepository` / `Cipher+OfflineSync` |
| **Severity** | Medium |
| **Type** | Usability / Reliability |
| **Status** | **Mitigated** |

## Original Description

When a user creates a new vault item while offline, the item appeared in the vault list but tapping it showed an infinite spinner — the detail view never loaded. The root cause was a chain of three factors:

1. `asyncTryMap` in `cipherDetailsPublisher` terminated the publisher stream on decryption error
2. Offline-created ciphers were stored via `Cipher.withTemporaryId()` which set `data: nil`, causing decryption failures
3. The `streamCipherDetails()` catch block only logged errors without updating `loadingState` to `.error`

## Current State (Mitigation)

The **symptom** (infinite spinner) has been fixed via a UI-level fallback in `ViewItemProcessor`. When the publisher-based stream fails to load cipher details, `fetchCipherDetailsDirectly()` performs a direct fetch from the cipher service as a fallback. This prevents the infinite spinner and allows users to view offline-created ciphers.

### What is fixed

- Users no longer see an infinite spinner when tapping an offline-created cipher
- The `ViewItemProcessor` gracefully falls back to a direct fetch when the publisher stream fails

### What is NOT fixed (root cause)

The root cause remains in place:

1. **`Cipher.withTemporaryId()` still sets `data: nil`** — This method in `Cipher+OfflineSync.swift` creates a copy of the `Cipher` with a new temporary ID but sets the `data` field to `nil`. When the cipher is later decrypted, the `nil` data causes a decryption failure. The publisher stream still fails; the UI fallback catches the failure.

2. **Temp-ID is assigned post-encryption** — In `handleOfflineAdd()`, the temp ID is assigned to the encrypted `Cipher` *after* encryption. This means the ID is not baked into the encrypted content. The encrypted `data` field (which is `nil` from `withTemporaryId()`) does not contain the temp ID, so a decrypt round-trip cannot produce a valid `CipherView` with the correct ID.

3. **Editing offline-created ciphers loses `.create` type** — `handleOfflineUpdate()` always sets the pending change type to `.update`, even when the cipher has an existing `.create` pending change. This means if a user edits an offline-created cipher before it syncs, the pending change becomes `.update`, and the resolver will try to GET the cipher by its temp ID (which the server doesn't know about), causing a sync failure.

4. **Deleting offline-created ciphers queues futile `.softDelete`** — `handleOfflineDelete()` and `handleOfflineSoftDelete()` do not check whether the cipher was created offline. They queue a `.softDelete` pending change, which will fail at resolution time because the server has no record of the temp-ID cipher.

5. **No temp-ID record cleanup in `resolveCreate()`** — After `addCipherWithServer` creates the cipher on the server (with a new server-assigned ID), the old local `CipherData` record with the temporary ID is not deleted. It persists until the next full sync's `replaceCiphers()` call.

## Recommended Root Cause Fix

The recommended approach to fully resolve VI-1 is:

1. **Move temp-ID assignment before encryption** — Assign the temporary ID to the `CipherView` *before* calling `encrypt(cipherView:)`. This bakes the ID into the encrypted content so the cipher survives a decrypt round-trip. The server ignores client-provided IDs for new ciphers and assigns its own.

2. **Replace `Cipher.withTemporaryId()` with a `CipherView`-level ID method** — Instead of copying the encrypted `Cipher` with `data: nil`, operate on the decrypted `CipherView` before encryption. This eliminates the `data: nil` problem entirely since the SDK handles all fields correctly during encryption.

3. **Preserve `.create` type in `handleOfflineUpdate()`** — When editing a cipher with an existing `.create` pending change, preserve the `.create` type instead of overwriting to `.update`.

4. **Clean up offline-created ciphers on delete** — In `handleOfflineDelete()`/`handleOfflineSoftDelete()`, check if the cipher has a `.create` pending change. If so, clean up locally instead of queuing a `.softDelete`.

5. **Clean up temp-ID records in `resolveCreate()`** — After `addCipherWithServer` succeeds, delete the old `CipherData` record with the temporary ID to prevent orphaned records.

## Related Issues

- **CS-2**: `Cipher.withTemporaryId()` still exists with `data: nil` — this is the root cause of VI-1's decryption failures. Both `Cipher.withTemporaryId()` and `CipherView.update(name:folderId:)` remain as fragile copy methods.
- **RES-1**: `resolveCreate` does NOT include temp-ID cleanup. The orphan risk described in RES-1 remains.
- **S7**: `handleOfflineDelete` does not have a `.create` check code path — the original test gap description applies unchanged.
- **T7**: No `preservesCreateType` test exists — the gap is fully open, with no test for `handleOfflineUpdate` with an existing pending record.
