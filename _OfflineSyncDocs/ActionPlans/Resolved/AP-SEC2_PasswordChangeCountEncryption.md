# Action Plan: SEC-2 — Encryption of `offlinePasswordChangeCount`

> **Status: [RESOLVED — Will Not Implement]** — After implementing AES-256-GCM encryption of the password change count as a prototype, a comparative analysis of existing unencrypted metadata across the codebase determined that encrypting this field adds complexity without meaningful security benefit. The change has been reverted. The plaintext `Int16` storage is consistent with the existing security model and represents an accepted low-severity risk.

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | SEC-2 |
| **Component** | `PendingCipherChangeData` |
| **Severity** | ~~Low~~ **Resolved — Will Not Implement** |
| **Type** | Security |
| **File** | `BitwardenShared/Core/Vault/Models/Data/PendingCipherChangeData.swift` |

## Description

The `offlinePasswordChangeCount` field in `PendingCipherChangeData` is stored as a plaintext `Int16` in the Core Data SQLite database. An attacker with local device access (filesystem extraction, jailbreak, forensic analysis) could read this value and learn how many times a user changed a specific cipher's password while offline.

The original review (`Review2/01_PendingCipherChangeData_Review.md`) noted this as "a minor information leak but does not reveal the actual passwords" and assessed the overall security posture as **equivalent to `CipherData`**.

---

## Exploration Summary

A full prototype implementation was built across 4 commits:

1. **Analysis document** — Evaluated 6 options (SDK encryption, local AES-256-GCM, blob embedding, file-level protection, bulk metadata encryption, accept risk)
2. **AES-256-GCM implementation** — New `PendingChangeCountEncryptionService` protocol and `DefaultPendingChangeCountEncryptionService` using CryptoKit, with a per-user symmetric key derived via HKDF from a base key stored in the iOS Keychain
3. **Core Data schema migration** — Changed `offlinePasswordChangeCount: Integer 16` to `encryptedPasswordChangeCount: Binary` with lightweight migration
4. **Full integration** — Wired through `ServiceContainer`, `VaultRepository`, `OfflineSyncResolver`, `PendingCipherChangeDataStore`, with complete test coverage including the mock, round-trip encryption tests, and decryption failure handling

The implementation was functional and all tests passed. However, a broader analysis of the codebase's existing security posture revealed the change to be disproportionate.

---

## Analysis: Why Encryption Is Not Warranted

### 1. The encrypted count sits alongside plaintext metadata of equal or greater sensitivity

On the **same Core Data entity** (`PendingCipherChangeData`), these fields are stored in plaintext:

| Field | Type | What it reveals |
|-------|------|-----------------|
| `cipherId` | String | Which cipher was edited offline |
| `userId` | String | Which user owns the change |
| `changeTypeRaw` | Int16 | Whether the edit was a create, update, or soft-delete |
| `originalRevisionDate` | Date | When the cipher was last synced |
| `createdDate` | Date | When the offline edit was first queued |
| `updatedDate` | Date | When the offline edit was last modified |
| **Row count** | (implicit) | How many pending offline edits exist |

The `changeTypeRaw` field is arguably more sensitive than the password change count — it reveals the *nature* of the user's action (did they create a new credential, modify one, or delete one?), yet it is stored as a plaintext integer. Encrypting the count while leaving `changeTypeRaw` in the clear creates an inconsistent security posture without reducing overall exposure.

### 2. The broader codebase stores comparable metadata without encryption

Across the app, similar or more sensitive metadata is stored unencrypted:

**UserDefaults (AppSettingsStore):**
- Review prompt action counts (`addedNewItem`, `createdNewSend`, `copiedOrInsertedGeneratedValue`) — reveal vault modification frequency
- Vault timeout duration and action — reveal user security posture
- Last sync time — reveals usage patterns
- Access token expiration date — reveals authentication timing

**Keychain (unencrypted values, hardware-protected):**
- `lastActiveTime` — when the user last accessed the app
- `unsuccessfulUnlockAttempts` — failed biometric/PIN attempts
- `vaultTimeout` — session timeout in milliseconds

**Core Data (CipherData entity):**
- `id` and `userId` stored as plaintext, same pattern as `PendingCipherChangeData`
- Row count reveals total number of vault items

### 3. The count is ephemeral

The `offlinePasswordChangeCount` exists only while a pending change record exists — from the moment of the first offline edit until sync resolution succeeds, at which point the record is deleted (`OfflineSyncResolver.swift`). In practice, this window is typically seconds to minutes (the duration of an offline period). This is not persistent metadata that accumulates over time.

### 4. The actual sensitive data is already encrypted

The passwords themselves — both current and historical — are encrypted by the Bitwarden SDK before storage. The `cipherData` blob in `PendingCipherChangeData` contains only SDK-encrypted content. An attacker who can read the SQLite file learns "this cipher had 2 password changes while offline" but cannot access any actual password values without the user's master key derivative.

### 5. The encryption added meaningful complexity

The prototype required:
- A new `PendingChangeCountEncryptionService` protocol and implementation
- A new Keychain key entry (base key for HKDF derivation)
- HKDF key derivation with user-specific salt
- Core Data schema migration (`Integer 16` → `Binary`)
- New `ServiceContainer` registration and `Has*` protocol
- Modified signatures in `PendingCipherChangeDataStore`, `VaultRepository`, and `OfflineSyncResolver`
- A complete mock (`MockPendingChangeCountEncryptionService`) for testing
- Additional error handling paths for encryption/decryption failures
- A potential failure mode during offline operation — exactly when reliability matters most

---

## Options Considered

Six approaches were evaluated in detail:

| Option | Approach | Security | Complexity | Decision |
|--------|----------|----------|------------|----------|
| **A** | SDK encryption (vault key) | High | Medium | Not needed — vault must be unlocked, strong but heavyweight |
| **B** | Local AES-256-GCM (device key) | Medium | Medium-High | Prototyped and reverted — new key management, inconsistent pattern |
| **C** | Embed count in `cipherData` blob | Very Low | Medium | Obscurity, not encryption |
| **D** | iOS file-level protection | Medium | Low | Better as a separate initiative; breaks background sync |
| **E** | Encrypt all non-queryable metadata | High | High | Disproportionate scope |
| **F** | Accept risk and document | N/A | None | **Selected** |

### Why Option B was prototyped and rejected

Option B (local AES-256-GCM with HKDF-derived key) was fully implemented to assess real-world complexity. While the implementation worked correctly, the exercise confirmed:

- The key is device-local, not derived from the user's master password, so it does not align with the zero-knowledge model — an attacker who compromises the Keychain can decrypt the count
- It introduced a new encryption pattern not used elsewhere in the main app (the watch app uses a similar approach, but the main app does not)
- The complexity-to-security-benefit ratio was unfavorable given the low sensitivity of the data and the existing plaintext metadata surface

### Why Option F was selected

The password change count is:
1. **Low sensitivity** — reveals only "how many times," not "what to"
2. **Ephemeral** — deleted on sync resolution
3. **Consistent** — stored at the same security level as all other non-content metadata in the app
4. **Already assessed** — the original code review (`Review2/01_PendingCipherChangeData_Review.md`) rated the security posture as equivalent to `CipherData`

Encrypting this single field while the surrounding metadata remains plaintext would be **security theater** — it increases complexity and maintenance burden without meaningfully reducing the attack surface.

---

## If Circumstances Change

This decision should be revisited if:

1. **Full Core Data encryption at rest** is pursued — the right approach would be database-level encryption (e.g., SQLCipher or `NSPersistentEncryptedStore`), not per-field encryption of individual metadata
2. **The security model changes** to require encryption of all local metadata, not just vault content
3. **The count becomes persistent** (e.g., survives sync resolution) or carries more sensitive information
4. **A security audit** mandates field-level encryption regardless of the comparative analysis

---

## References

- `PendingCipherChangeData.swift:55` — Current plaintext `offlinePasswordChangeCount: Int16` storage
- `OfflineSyncResolver.swift:60` — `softConflictPasswordChangeThreshold` constant (4)
- `VaultRepository.swift:991-1042` — `handleOfflineUpdate` password change detection
- `Review2/01_PendingCipherChangeData_Review.md:56-68` — Original security assessment
- `AP-S6_PasswordChangeCountingTest.md` — Related: tests for the counting logic itself (resolved)
- `AppSettingsStore.swift` — Examples of unencrypted metadata in UserDefaults
- `KeychainRepository.swift` — Examples of unencrypted numeric metadata in Keychain
