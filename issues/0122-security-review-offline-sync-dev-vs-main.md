---
id: 122
title: "Security Review: Offline Sync Feature (dev vs main)"
status: closed
labels: [documentation]
priority: medium
created: 2026-02-26
closed: 2026-02-26
author: claude
---

## Description

Comprehensive security review of the offline sync feature comparing the `dev` branch against `main`. The feature allows users to create, update, soft-delete, and hard-delete personal vault ciphers while offline. Changes are queued as `PendingCipherChangeData` records in Core Data and resolved against server state when connectivity returns.

**Change Summary:** 35 files changed, +5,431 / -67 lines

### Overall Assessment: PASS

No critical or high-severity security issues identified.

---

### SECURE: Data Protection and Encryption

- `cipherData` stores JSON-encoded `CipherDetailsResponseModel` encrypted by SDK before Core Data storage
- Encryption chain: `clientService.vault().ciphers().encrypt(cipherView:)` -> `CipherDetailsResponseModel(cipher:)` -> `JSONEncoder().encode()` -> Core Data
- Only non-sensitive metadata stored separately (cipherId, userId, timestamps, change type, password change count)
- Password change detection: decrypted passwords compared in memory; only integer count persisted

### SECURE: Access Control and User Isolation

- All Core Data queries filter by `userId` via NSPredicates (`PendingCipherChangeData.swift:117-136`)
- Uniqueness constraint on `(userId, cipherId)` prevents cross-user collisions
- No code path accesses pending changes without userId filter

### SECURE: Organization Cipher Protection

- Organization ciphers blocked from offline operations at every entry point (`VaultRepository.swift` at lines 507, 932, 977, 1125)
- Guard clauses re-throw original network error for org ciphers

### SECURE: Error Classification

- Only genuine connectivity/timeout errors trigger offline fallback
- `ServerError`, `ResponseValidationError` (4xx), and `CipherAPIServiceError` are re-thrown immediately
- Pattern applied consistently across all four operations (add, update, softDelete, hardDelete)

### SECURE: Sync Integration

- Pending changes resolved BEFORE `replaceCiphers()` prevents overwriting offline edits
- Vault lock check skips resolution when crypto context unavailable
- Individual resolution errors logged per-change; one bad record doesn't block others

### SECURE: Conflict Resolution (`OfflineSyncResolver.swift:166-308`)

- Uses `originalRevisionDate` for conflict detection
- **Backup-before-modify** pattern ensures no data loss
- Soft conflict threshold (4+ password changes) triggers server backup even without conflict
- Deletion conflicts: server version restored locally for user review
- Server-deleted during offline edit: cipher re-created to preserve user's work
- Actor isolation on `DefaultOfflineSyncResolver` prevents internal race conditions

### SECURE: Feature Flag Controls (`FeatureFlag.swift:42-56`)

- Two independent flags: `offlineSyncEnableResolution` and `offlineSyncEnableOfflineChanges`
- Both must be enabled for offline fallback; remotely controllable for rollback

---

### LOW RISK: TOCTOU Window in resolveUpdate (`OfflineSyncResolver.swift:182-219`)

Between `getCipher(withId:)` and `updateCipherWithServer()`, server state could theoretically change. Mitigated by server-side `revisionDate` validation in PUT, extremely small window, and same pattern used by all other API interactions.

### FIXED: Backup Cipher Name Length (`OfflineSyncResolver.swift:332`)

**Status:** Resolved via truncation guard (see comments for full analysis).

Names in `createBackupCipher` are constructed as `name - timestamp`. The server
enforces `[EncryptedStringLength(1000)]` on the `Name` field (validated in
`CipherRequestModel.cs`), which checks the length of the full `EncString`
representation (`2.base64(iv)|base64(ct)|base64(mac)`). Because the cipher name
is encrypted client-side (zero-knowledge), the server cannot inspect the
plaintext — it only validates the encrypted blob length.

A fix was implemented to truncate names exceeding 400 UTF-8 bytes before
appending the 22-byte timestamp suffix. See comments below for the full
analysis of why 400 bytes is a safe threshold.

### NOT A REGRESSION: GetCipherRequest Path Interpolation (`GetCipherRequest.swift:14`)

Same `/ciphers/\(cipherId)` pattern used by all other cipher requests. CipherIDs originate from Core Data or server responses, not user input.

---

### Security Properties Summary

| Property | Status |
|---|---|
| Zero-knowledge preservation | MAINTAINED |
| User isolation | ENFORCED |
| Organization vault protection | ENFORCED |
| Error classification | CORRECT |
| Conflict resolution safety | STRONG |
| Feature flag rollback | AVAILABLE |
| Data loss prevention | STRONG |
| Thread safety | ENFORCED (actor) |

---

### Recommendation

**Approve for merge.** The backup name truncation finding has been resolved
(see comments).

Test coverage confirmed: ~1,079 lines in OfflineSyncResolverTests, ~842 lines
in VaultRepositoryTests, ~439 lines in PendingCipherChangeDataStoreTests.

## Comments

### claude — 2026-02-26

**Backup name length analysis and fix**

During the review, the backup cipher name length was flagged as low risk. Further
investigation confirmed it is a real concern that warranted a code fix.

#### The problem

`createBackupCipher` constructs backup names as `"\(name) - yyyy-MM-dd HH:mm:ss"`.
The Bitwarden server enforces `[EncryptedStringLength(1000)]` on the cipher
`Name` field (`CipherRequestModel.cs`). This is a standard .NET `StringLengthAttribute`
subclass with a custom error message — it validates the length of the encrypted
string **as received**, not the plaintext (the server cannot see plaintext due to
zero-knowledge architecture).

The `EncString` format is `2.<base64(iv)>|<base64(ciphertext)>|<base64(mac)>`.
Without truncation, a very long cipher name could produce an encrypted string
exceeding 1,000 characters, causing a 4xx rejection that would block sync
resolution for that pending change.

#### Why character count was unsafe

The initial fix used `String.count > 500` (Swift character count). This is unsafe
for multi-byte Unicode because Swift characters can be 1–4 UTF-8 bytes:

- 500 ASCII chars = 500 bytes → ~748 encrypted chars (safe)
- 500 CJK chars (3 bytes each) = 1,500 bytes → ~2,072 encrypted chars (exceeds limit)

#### The fix

Switched to **400 UTF-8 bytes** as the truncation threshold with character-boundary-safe
truncation (`OfflineSyncResolver.swift:maxBackupNameByteCount`).

#### Proof that 400 bytes is safe

EncString overhead calculation for `2.iv|ciphertext|mac`:

- Type prefix `2.` = 2 chars
- base64(16-byte IV) = 24 chars
- `|` separator = 1 char
- `|` separator = 1 char
- base64(32-byte MAC) = 44 chars
- **Fixed overhead: 72 chars**

Ciphertext for 400 + 22 = 422 byte plaintext:

- AES-CBC padded: ceil(423/16) × 16 = **432 bytes**
- base64(432 bytes): 432 / 3 × 4 = **576 chars**

**Total: 72 + 576 = 648 encrypted chars** — 35% headroom under the 1,000 limit.

#### Server validation confirmed

`EncryptedStringLengthAttribute` in the Bitwarden server
(`src/Core/Utilities/EncryptedStringLengthAttribute.cs`) extends .NET's
`StringLengthAttribute`. It validates the string length of the encrypted value
as-is (the full `2.iv|ct|mac` representation). The `Name` field is annotated
with `[EncryptedStringLength(1000)]` in `CipherRequestModel.cs`.

#### Commits

- `4c89b91` — Initial truncation at 500 characters
- `4b7a779` — Switched to 400 UTF-8 bytes with Unicode-safe truncation

Tests added:
- `test_processPendingChanges_update_conflict_longAsciiNameTruncated` — 600 ASCII chars truncated to 400
- `test_processPendingChanges_update_conflict_longUnicodeNameTruncated` — 200 CJK chars (600 bytes) truncated to 133 chars (399 bytes)
