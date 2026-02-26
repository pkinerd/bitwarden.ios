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

### LOW RISK: Backup Cipher Name Length (`OfflineSyncResolver.swift:332`)

Names constructed as `name - timestamp` with no truncation. Very long names could exceed server limits, resulting in logged 4xx error. Consider adding truncation guard as minor robustness improvement.

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

**Approve for merge** with optional consideration of name truncation in backup cipher creation.

Test coverage confirmed: ~1,079 lines in OfflineSyncResolverTests, ~842 lines in VaultRepositoryTests, ~439 lines in PendingCipherChangeDataStoreTests.

## Comments
