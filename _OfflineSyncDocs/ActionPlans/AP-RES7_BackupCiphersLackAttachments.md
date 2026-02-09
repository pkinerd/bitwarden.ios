# Action Plan: RES-7 — Backup Ciphers Don't Include Attachments

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | RES-7 |
| **Component** | `OfflineSyncResolver` / `CipherView+OfflineSync` |
| **Severity** | Informational |
| **Type** | Feature Limitation |
| **Files** | `CipherView+OfflineSync.swift`, `OfflineSyncResolver.swift` |

## Description

`CipherView.update(name:folderId:)` sets `attachments` to `nil` on backup copies. The implementation includes a comment: "Attachments are not duplicated to backup copies." This means backup ciphers in the "Offline Sync Conflicts" folder will not have the original's attachments. Users may lose access to attachment data if the conflict resolution results in the original being overwritten and the backup being their only reference.

## Context

Attachment duplication is complex because:
1. Attachments are binary blobs stored separately from the cipher JSON
2. Each attachment has its own encryption key
3. Duplicating an attachment requires downloading the binary, re-encrypting with a new key, and uploading to a new location
4. This is bandwidth and storage intensive
5. The backup is created during sync resolution, which should be fast and lightweight

The original cipher's attachments are NOT deleted during conflict resolution — they remain on whichever version is kept as the "primary" cipher. The backup is a copy of the version that was not kept, and its attachments are simply not included in the backup.

---

## Options

### Option A: Add Attachment Duplication to Backup Creation

Download, re-encrypt, and upload all attachments when creating a backup cipher.

**Approach:**
1. After creating the backup cipher via `addCipherWithServer`, iterate over the source cipher's attachments
2. For each attachment: download the binary, decrypt, re-encrypt with the backup cipher's key, upload to the backup cipher
3. Use existing attachment API methods

**Pros:**
- Complete backup — no data loss even for attachments
- User has full access to the backup's content

**Cons:**
- Significant bandwidth usage during sync resolution (attachments can be large)
- Significant implementation complexity
- Requires network for attachment operations (which may be unreliable since we're resolving offline changes)
- If attachment upload fails, the backup cipher exists without attachments (partial backup)
- Slows down the resolution process considerably
- Each attachment requires a separate API call (download + upload)

### Option B: Add a Note/Comment to Backup Ciphers About Missing Attachments

When creating a backup cipher, append a note to the cipher's `notes` field indicating that attachments were not included and where to find them.

**Approach:**
- When creating a backup: `cipher.notes = (cipher.notes ?? "") + "\n\n[Attachments were not included in this backup. See the original cipher.]"`

**Pros:**
- User is informed about the limitation
- Low implementation effort
- No bandwidth/performance impact

**Cons:**
- Modifies the cipher's content (appending to notes)
- The "original cipher" reference is ambiguous (user may not know which cipher is the original)
- Doesn't actually preserve the attachments

### Option C: Preserve Attachment References Without Duplication

Include the attachment metadata (but not the binary data) in the backup cipher, with a flag indicating they are references to the original cipher's attachments.

**Pros:**
- Attachment metadata is preserved
- No bandwidth cost

**Cons:**
- References may become invalid if the original cipher's attachments change
- Bitwarden's attachment model may not support cross-cipher references
- User cannot actually download the attachment from the backup

### Option D: Accept the Limitation (Recommended)

Accept that backup ciphers don't include attachments and document this as a known limitation.

**Pros:**
- No code change
- The limitation is clearly documented in the code comments
- Attachment data is not lost — it remains on the primary cipher
- Backup ciphers are meant to be temporary recovery references, not full duplicates
- Resolution speed is not affected

**Cons:**
- If the primary cipher is the one overwritten (not the backup), and it had attachments that differed from the backup's source, those specific attachment states are lost
- User has no attachments on the backup cipher

---

## Recommendation

**Option D** — Accept the limitation. Attachment duplication during sync resolution is disproportionately complex and bandwidth-intensive for the benefit it provides. The primary cipher's attachments are preserved in all resolution scenarios. The backup is a reference copy for text content (logins, notes, cards, identities), not a full clone.

If this becomes a user concern, **Option B** (note in backup) is a simple improvement that sets expectations.

## Estimated Impact

- **Files changed:** 0
- **Risk:** None

## Related Issues

- **CS-2**: Fragile SDK copy methods — the `update(name:folderId:)` method that sets attachments to nil is fragile against SDK changes.
- **U4 (RES-8)**: English-only conflict folder name — both relate to the properties and UX of backup/conflict artifacts.

## Updated Review Findings

The review confirms the original assessment with code-level detail. After reviewing the implementation:

1. **Code verification**: `CipherView+OfflineSync.swift:85` explicitly sets `attachments: nil` in the `update(name:folderId:)` method. The comment at line 85 reads `// Attachments are not duplicated to backup copies`. This is a deliberate design choice, not an oversight.

2. **Backup creation flow**: `OfflineSyncResolver.swift:299-328` `createBackupCipher`:
   - Line 308: `clientService.vault().ciphers().decrypt(cipher: cipher)` — decrypts the original
   - Line 317: `decryptedCipher.update(name:folderId:)` — creates backup view with `attachments: nil`
   - Line 323: `clientService.vault().ciphers().encrypt(cipherView: backupCipherView)` — encrypts backup
   - Line 324: `cipherService.addCipherWithServer(...)` — pushes backup to server

   The backup cipher is pushed as a NEW cipher. Attachment duplication would require downloading attachment files, re-uploading them to the new cipher, and managing attachment encryption keys — a complex multi-step process.

3. **Original cipher preservation**: In conflict scenarios where the backup is of the SERVER version (local wins), the original server cipher with its attachments is overwritten by the local version via `updateCipherWithServer`. The original attachments are lost from the active cipher. They exist only in the server's version history (if available) or are gone.

4. **Impact**: If a user has a cipher with attachments, edits it offline, and a conflict occurs:
   - Local-wins: server version backed up WITHOUT attachments, local version pushed (may not have attachments either since local edits don't modify attachments)
   - Server-wins: local version backed up WITHOUT attachments, server version kept (attachments preserved on active cipher)

   The local-wins scenario is the risky one: server attachments may be lost from the active cipher.

**Updated conclusion**: Original recommendation (accept limitation, document) confirmed. Attachment duplication is a significant feature requiring download/upload/re-encryption and is out of scope for the initial implementation. The backup naming clearly indicates it's a conflict copy. Users with important attachments should be aware this is a limitation. Priority: Informational, document as known limitation.
