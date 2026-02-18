# Analysis: Encrypting `offlinePasswordChangeCount` in Pending Changes

**Date**: 2026-02-18
**Issue**: Lack of encryption of the password change count in offline storage of pending changes
**Source**: `_OfflineSyncDocs/Review2/00_Main_Review.md` — Security Assessment, `01_PendingCipherChangeData_Review.md`

---

## 1. Problem Statement

The `offlinePasswordChangeCount` field in `PendingCipherChangeData` is stored as a plaintext `Int16` in the Core Data SQLite database. An attacker with local device access (filesystem extraction, jailbreak, forensic analysis) can read this value and learn how many times a user changed a specific cipher's password while offline.

**Current storage** (`PendingCipherChangeData.swift:55`):
```swift
@NSManaged var offlinePasswordChangeCount: Int16
```

**Core Data schema** (`Bitwarden.xcdatamodel/contents`):
```xml
<attribute name="offlinePasswordChangeCount" attributeType="Integer 16"
           defaultValueString="0" usesScalarValueType="YES"/>
```

---

## 2. Threat Model Assessment

### What the count reveals

- The number of times a password was changed across offline editing sessions for a specific cipher
- Combined with `cipherId` (also plaintext), it identifies *which* cipher had multiple password changes

### What the count does NOT reveal

- The actual passwords (old or new) — these are SDK-encrypted within `cipherData`
- The specific password values at each change — only a running total is stored
- Any other credential content — usernames, URIs, notes remain SDK-encrypted

### Existing plaintext metadata in the same entity

| Field | Type | Already Plaintext |
|-------|------|-------------------|
| `cipherId` | String | Yes |
| `userId` | String | Yes |
| `changeTypeRaw` | Int16 | Yes (reveals create/update/delete) |
| `originalRevisionDate` | Date | Yes |
| `createdDate` | Date | Yes |
| `updatedDate` | Date | Yes |
| **`offlinePasswordChangeCount`** | **Int16** | **Yes — the field in question** |

### Comparison with existing `CipherData` entity

The main `CipherData` entity (`CipherData.swift`) stores `id` and `userId` as plaintext with the encrypted model in `modelData`. The `PendingCipherChangeData` entity follows this same pattern. The password change count is the only field that provides *behavioral* information (how the user interacted with the cipher) beyond simple identification metadata.

### Severity assessment

**Low severity.** The information leaked is:
- A small integer (typically 0–4 before sync resolution occurs)
- Only present while changes are pending (deleted after sync)
- Only actionable if combined with access to the encrypted cipher data (which requires the encryption key)
- Consistent with the existing security posture of other plaintext metadata

However, for a password manager, the principle of minimal information disclosure applies — even low-severity leaks deserve consideration.

---

## 3. How the Count Is Used

### Write path (`VaultRepository.swift:1055-1088`)

When a user edits a cipher offline, `handleOfflineUpdate()`:
1. Fetches the existing pending change record (if any)
2. Loads the current `offlinePasswordChangeCount`
3. Decrypts the previous cipher version to compare passwords
4. Increments the count if the password changed
5. Upserts the pending change with the new count

**Key constraint**: Both reading and writing the count occur in the context of an active vault (unlocked, SDK crypto context available) because the user just edited a cipher.

### Read path (`OfflineSyncResolver.swift:207-208`)

During sync resolution, `resolveUpdate()`:
1. Reads `pendingChange.offlinePasswordChangeCount` directly (no decryption)
2. Compares against `softConflictPasswordChangeThreshold` (4)
3. If threshold reached, creates a server backup before pushing local changes

**Key constraint**: The vault must be unlocked during sync resolution (`SyncService.swift:333-334` checks `isVaultLocked`). The SDK crypto context is available.

### Lifecycle

The count exists only while a pending change record exists — from the moment of the first offline edit until sync resolution succeeds. After resolution, the record is deleted (`OfflineSyncResolver.swift:231-233`).

---

## 4. Implementation Options

### Option A: SDK Encryption via `EncString`

**Approach**: Encrypt the count using the Bitwarden SDK's crypto client before storing in Core Data. Store as encrypted `Data` (or `String` in EncString format) instead of `Int16`.

**Implementation sketch**:
```swift
// Write path (VaultRepository.handleOfflineUpdate):
let countData = Data(String(passwordChangeCount).utf8)
let encryptedCount = try await clientService.vault().ciphers().encryptBuffer(countData)

// Read path (OfflineSyncResolver.resolveUpdate):
let decryptedData = try await clientService.vault().ciphers().decryptBuffer(pendingChange.encryptedPasswordChangeCount)
let count = Int16(String(data: decryptedData, encoding: .utf8) ?? "0") ?? 0
```

**Changes required**:
- `PendingCipherChangeData.swift`: Change `offlinePasswordChangeCount: Int16` to `encryptedPasswordChangeCount: Data?`
- Core Data schema: Change attribute from `Integer 16` to `Binary` (requires model versioning)
- `PendingCipherChangeDataStore.swift`: Update `upsertPendingChange()` signature
- `VaultRepository.swift`: Encrypt count before passing to data store
- `OfflineSyncResolver.swift`: Decrypt count before threshold comparison
- All test files: Update for new encrypted format

**Pros**:
- Uses the project's established SDK encryption — consistent with zero-knowledge architecture
- Encrypted with the user's vault key — no new key management
- Strongest security guarantee: only decryptable with the user's master key derivative

**Cons**:
- **Vault must be unlocked to read/write the count** — this is already true for both code paths (cipher editing requires unlock, sync resolution checks for unlock), so this is not a practical limitation
- **Requires SDK crypto context for a simple integer comparison** — adds async decryption overhead to the sync resolution hot path
- **SDK buffer encryption API availability** — the SDK's `CryptoClient` may not expose a simple encrypt/decrypt buffer API directly; the existing `encrypt(cipher:)` / `decrypt(cipher:)` operates on `Cipher` objects, not arbitrary data. Would need to verify SDK capabilities or use `encryptString` if available
- **Increases complexity** of the threshold check from a simple integer comparison to an async decrypt-then-compare operation
- **Core Data model versioning** required for schema change

---

### Option B: Local Symmetric Encryption (CryptoKit AES-256-GCM)

**Approach**: Generate a per-device symmetric key stored in the iOS Keychain. Encrypt the count before Core Data storage and decrypt on read. Similar to the pattern used in `BitwardenWatchApp/Services/CryptoService.swift`.

**Implementation sketch**:
```swift
// New service: PendingChangeEncryptionService
protocol PendingChangeEncryptionService {
    func encrypt(_ value: Int16) throws -> Data
    func decrypt(_ data: Data) throws -> Int16
}

// Implementation using CryptoKit
struct DefaultPendingChangeEncryptionService: PendingChangeEncryptionService {
    private let key: SymmetricKey  // Retrieved from Keychain

    func encrypt(_ value: Int16) throws -> Data {
        let plaintext = withUnsafeBytes(of: value) { Data($0) }
        let sealed = try AES.GCM.seal(plaintext, using: key)
        return sealed.combined!
    }

    func decrypt(_ data: Data) throws -> Int16 {
        let box = try AES.GCM.SealedBox(combined: data)
        let plaintext = try AES.GCM.open(box, using: key)
        return plaintext.withUnsafeBytes { $0.load(as: Int16.self) }
    }
}
```

**Changes required**:
- New `PendingChangeEncryptionService` protocol and implementation
- New Keychain key entry for the local encryption key
- `PendingCipherChangeData.swift`: Change `offlinePasswordChangeCount: Int16` to `encryptedPasswordChangeCount: Data?`
- Core Data schema change (`Integer 16` → `Binary`)
- `ServiceContainer.swift`: Wire up new service
- `VaultRepository.swift`: Inject and use encryption service
- `OfflineSyncResolver.swift`: Inject and use encryption service for decryption
- All related test files

**Pros**:
- **Independent of vault lock state** — the local key is always accessible (stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`)
- **No SDK dependency** — simple, self-contained encryption
- **Synchronous API** — no async overhead for encrypt/decrypt
- **Established pattern** — the watch app already uses this exact approach

**Cons**:
- **Introduces a new key** that must be managed (created, stored, cleared on logout/wipe)
- **Not zero-knowledge** — the encryption key is device-local, not derived from the user's master password. An attacker who compromises the device keychain can decrypt the count
- **New service + DI wiring** — adds a new service to `ServiceContainer`, new `Has*` protocol, mock for testing
- **Doesn't match the main app's security model** — the watch app pattern is acceptable for a companion app but may not meet the main app's security bar
- **Core Data model versioning** required

---

### Option C: Embed Count in the `cipherData` Blob

**Approach**: Instead of storing `offlinePasswordChangeCount` as a separate Core Data attribute, embed it inside a wrapper struct that envelopes the existing `cipherData` content.

**Implementation sketch**:
```swift
/// Wraps the encrypted cipher snapshot with offline-sync metadata that
/// should be stored alongside it rather than as separate Core Data attributes.
struct PendingChangeEnvelope: Codable {
    let cipherDetailsResponseModel: CipherDetailsResponseModel
    let offlinePasswordChangeCount: Int16
}
```

**Changes required**:
- New `PendingChangeEnvelope` struct
- Remove `offlinePasswordChangeCount` attribute from Core Data schema
- `VaultRepository.swift`: Encode count into envelope before storing in `cipherData`
- `OfflineSyncResolver.swift`: Decode envelope to extract both cipher data and count
- `PendingCipherChangeDataStore.swift`: Remove `offlinePasswordChangeCount` parameter from `upsertPendingChange()`
- Core Data schema change (remove attribute)

**Pros**:
- **No new encryption infrastructure** — piggybacks on existing `cipherData` storage
- **Reduces Core Data attribute surface** — fewer plaintext fields
- **Simpler schema** — one fewer attribute to manage

**Cons**:
- **Does not actually encrypt the count** — the `CipherDetailsResponseModel` JSON contains encrypted *values* (EncString fields) but the JSON structure itself is plaintext in the blob. The count would be visible alongside plaintext field names and IDs within the JSON. The only protection is that the count is no longer in a named, easily-queryable Core Data column
- **Obscurity, not encryption** — moves the data from a labeled column to an unlabeled position in a binary blob. A determined attacker can still find it
- **Tight coupling** — the cipher data payload now carries sync metadata, mixing concerns
- **Decode complexity** — every read of `cipherData` must now also parse the count wrapper

**Assessment**: This option provides marginal security improvement (data is harder to find but not encrypted) and introduces coupling. Not recommended as a standalone solution.

---

### Option D: iOS Data Protection (File-Level Encryption)

**Approach**: Ensure the Core Data SQLite file uses iOS's strongest file protection class (`NSFileProtectionComplete`), which encrypts the file at rest when the device is locked.

**Implementation sketch**:
```swift
// In DataStore initialization, set file protection on the SQLite file
let storeURL = container.persistentStoreDescriptions.first?.url
try FileManager.default.setAttributes(
    [.protectionKey: FileProtectionType.complete],
    ofItemAtPath: storeURL!.path
)
```

**Changes required**:
- Verify current file protection level on the Core Data store
- Potentially upgrade to `NSFileProtectionComplete` if not already set
- Handle the constraint that `NSFileProtectionComplete` makes the database inaccessible when the device is locked (affects background sync, extensions)

**Pros**:
- **Protects ALL data at rest** — not just the count, but every field in every entity
- **No code changes to models or business logic**
- **OS-level encryption** — hardware-backed on modern devices
- **Protects against offline forensic extraction** when device is locked

**Cons**:
- **Does not protect against runtime access** — if an attacker has code execution while the device is unlocked, the database is readable
- **May break background sync** — `NSFileProtectionComplete` makes files inaccessible in the background when the device is locked, which is when sync might run
- **App extension compatibility** — AutoFill and Action extensions may need database access when the main app is not foregrounded
- **Already partially in place** — the app group container may already have `NSFileProtectionCompleteUntilFirstUserAuthentication` by default
- **Broad scope** — changes affect the entire database, not just the pending change entity, increasing the risk of regressions

**Assessment**: Worth investigating as a defense-in-depth measure independently of this specific issue, but does not address the field-level concern raised in the review. The background sync and extension constraints likely make `NSFileProtectionComplete` impractical for this database.

---

### Option E: Encrypt All Non-Queryable Metadata Together

**Approach**: Bundle `offlinePasswordChangeCount` along with other non-queryable metadata (`changeTypeRaw`, `originalRevisionDate`, `createdDate`, `updatedDate`) into an encrypted metadata blob. Keep only `cipherId` and `userId` as plaintext (needed for Core Data queries/predicates).

**Implementation sketch**:
```swift
struct PendingChangeMetadata: Codable {
    let changeTypeRaw: Int16
    let originalRevisionDate: Date?
    let createdDate: Date
    let updatedDate: Date
    let offlinePasswordChangeCount: Int16
}

// Encrypt using SDK or local key before storage
// Store as single `encryptedMetadata: Data?` in Core Data
```

**Changes required**:
- New `PendingChangeMetadata` struct
- Core Data schema: Replace 5 attributes with 1 `encryptedMetadata: Binary`
- Choose encryption method (SDK or local key — same trade-offs as Options A/B)
- Update all read/write paths to encrypt/decrypt the metadata bundle
- Significant refactoring of data store, repository, and resolver

**Pros**:
- **Encrypts multiple metadata fields** — addresses not just the count but also `changeTypeRaw` (which reveals the operation type) and timestamps
- **Minimal queryable surface** — only `cipherId` and `userId` remain plaintext
- **Comprehensive** — if metadata encryption is worth doing, this is the thorough approach

**Cons**:
- **Largest implementation scope** — significant refactoring of multiple files
- **Loses Core Data query capabilities** — cannot sort by `createdDate` or filter by `changeTypeRaw` at the database level
- **All the cons of the chosen encryption method** (A or B) apply
- **Overkill** — the additional metadata (timestamps, change type) has even less security sensitivity than the count

---

### Option F: Accept the Risk (Document and Defer)

**Approach**: Formally document the information leak as an accepted risk, noting that it is consistent with the existing security model and represents minimal incremental exposure.

**Changes required**:
- Update the review document to classify this as "Accepted — Low Risk"
- Add an inline code comment explaining the security trade-off
- Optionally file a backlog issue for future consideration

**Pros**:
- **Zero implementation cost**
- **No regression risk**
- **Consistent with existing patterns** — `CipherData`, `PasswordHistoryData`, and all other Core Data entities store non-sensitive metadata in plaintext
- **The count is ephemeral** — exists only during the offline editing window, deleted on sync

**Cons**:
- **Leaves the information leak in place** — however minor
- **May not satisfy security review requirements** if field-level encryption is mandated

---

## 5. Comparative Summary

| Dimension | A: SDK Encrypt | B: Local AES | C: Embed in Blob | D: File Protection | E: Encrypt All Metadata | F: Accept Risk |
|-----------|---------------|-------------|-------------------|--------------------|-----------------------|---------------|
| Security strength | High (master-key derived) | Medium (device-local key) | Very Low (obscurity) | Medium (device-locked) | High (depends on method) | None |
| Vault lock dependency | Yes (already satisfied) | No | No | N/A | Depends on method | N/A |
| Implementation scope | Medium | Medium-High | Medium | Low | High | None |
| New infrastructure | None (uses SDK) | New service + key | New wrapper struct | FileManager config | New service + struct | Documentation only |
| Schema migration | Yes | Yes | Yes | No | Yes | No |
| Regression risk | Low | Medium | Medium | High (extensions) | Medium-High | None |
| Consistency with architecture | High | Low (new pattern) | Low (mixed concerns) | N/A | Medium | High |
| Addresses the concern | Fully | Fully | Minimally | Partially | Fully | No |

---

## 6. Recommendation

### If the risk must be mitigated: **Option A (SDK Encryption)**

Option A is the most architecturally consistent choice. It uses the same encryption infrastructure that protects all other vault data, requires no new key management, and aligns with the zero-knowledge model. The main implementation concern — that the vault must be unlocked to read/write the count — is already satisfied by both code paths (cipher editing and sync resolution both require an active crypto context).

**Before choosing Option A**, verify that the `BitwardenSdk` exposes an API for encrypting/decrypting arbitrary byte buffers (not just `Cipher` objects). If it does not, this option requires either:
- An SDK enhancement to expose buffer-level encryption
- Using the `encryptString` API on a string representation of the count

### If the risk is acceptable: **Option F (Accept and Document)**

The password change count is a small integer with a short lifecycle that reveals minimal behavioral information. It is consistent with the existing security model where non-sensitive metadata is stored in plaintext alongside SDK-encrypted content. The `PasswordHistoryData` entity in the same database stores *actual plaintext passwords* (`PasswordHistoryData.swift:15`), which represents a significantly larger information exposure. Addressing the count while `PasswordHistoryData` remains plaintext would be inconsistent prioritization.

### Not recommended

- **Option B**: Introduces a new encryption pattern inconsistent with the main app's security model
- **Option C**: Security-through-obscurity; doesn't actually solve the problem
- **Option D**: Overly broad with high regression risk; better addressed as a separate initiative
- **Option E**: Disproportionate scope for the risk level

---

## 7. Implementation Considerations (If Proceeding with Option A)

### Core Data Schema Migration

Adding a schema version is required. The project uses `NSPersistentContainer` which supports lightweight migration by default. The migration would:
1. Add a new `encryptedPasswordChangeCount: Binary (optional)` attribute
2. Remove the `offlinePasswordChangeCount: Integer 16` attribute
3. Existing pending change records (if any during upgrade) would lose their count, resetting to 0 — acceptable since the count is ephemeral

### Files to Modify

| File | Change |
|------|--------|
| `PendingCipherChangeData.swift:55` | Replace `offlinePasswordChangeCount: Int16` with `encryptedPasswordChangeCount: Data?` |
| `Bitwarden.xcdatamodel/contents` | Schema attribute change + model version |
| `PendingCipherChangeDataStore.swift` | Update `upsertPendingChange()` signature and implementation |
| `VaultRepository.swift:1055-1088` | Encrypt count before passing to data store |
| `OfflineSyncResolver.swift:207-208` | Decrypt count before threshold comparison |
| `MockPendingCipherChangeDataStore.swift` | Update mock for new signature |
| `PendingCipherChangeDataStoreTests.swift` | Update tests for encrypted count |
| `OfflineSyncResolverTests.swift` | Update tests — mock encryption/decryption |
| `VaultRepositoryTests.swift` | Update tests for encrypted count flow |

### Testing Strategy

- Unit test: Verify count encrypts to non-deterministic ciphertext (AES-GCM produces different output each time)
- Unit test: Verify round-trip encrypt → store → fetch → decrypt returns original count
- Unit test: Verify threshold comparison works correctly after decryption
- Unit test: Verify count of 0 (default for new records) is handled correctly
- Integration test: End-to-end offline edit → sync resolution with encrypted count

---

## 8. References

- `PendingCipherChangeData.swift:55` — Current plaintext storage
- `OfflineSyncResolver.swift:60, 207-208` — Threshold constant and comparison
- `VaultRepository.swift:1055-1088` — Count detection and persistence
- `CipherData.swift` — Existing plaintext metadata pattern for comparison
- `PasswordHistoryData.swift:15` — Existing plaintext password storage (higher severity)
- `CryptoService.swift` (WatchApp) — Local AES-256-GCM pattern reference
- `KeychainRepository.swift` — Keychain key storage patterns
- `00_Main_Review.md` — Security Assessment section identifying the concern
- `01_PendingCipherChangeData_Review.md` — Detailed entity review
