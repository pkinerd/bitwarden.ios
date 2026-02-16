# Offline Sync Feature - Comprehensive Code Review

## Summary

This changeset implements a client-side offline sync feature for the Bitwarden iOS vault. When network connectivity is unavailable during cipher operations (add, update, delete, soft-delete), the app persists changes locally and queues them for resolution when connectivity is restored. A conflict resolution engine detects server-side changes made while offline and creates backup copies rather than silently discarding data.

**Scope:** 24 files changed (+3,558 lines, -11 lines) across multiple commits on `claude/plan-offline-sync-JDSOl`, with subsequent simplification commits on `claude/review-offline-sync-changes-Tiv2i`. **[Updated]** Further simplification removed `URLError+NetworkConnection.swift` (26 lines) and its tests (39 lines), simplified VaultRepository catch blocks to plain `catch`, simplified SyncService pre-sync flow, and removed `test_updateCipher_nonNetworkError_rethrows`.

**Guidelines Referenced:**
- Project architecture: `Docs/Architecture.md`, `Docs/Testing.md`
- Contribution guidelines: [bitwarden.contributing-docs](https://github.com/pkinerd/bitwarden.contributing-docs) — specifically Swift code style, iOS architecture, security principles (zero-knowledge, cryptography), and general contributing guidelines
- Project-specific: `.claude/CLAUDE.md`

**Detailed section documents (per-component deep dives):**
- [ReviewSection_PendingCipherChangeDataStore.md](ReviewSection_PendingCipherChangeDataStore.md) — Core Data entity, data store, schema changes
- [ReviewSection_OfflineSyncResolver.md](ReviewSection_OfflineSyncResolver.md) — Conflict resolution engine
- [ReviewSection_VaultRepository.md](ReviewSection_VaultRepository.md) — Offline fallback handlers in repository
- [ReviewSection_SyncService.md](ReviewSection_SyncService.md) — Pre-sync resolution and early-abort logic
- [ReviewSection_SupportingExtensions.md](ReviewSection_SupportingExtensions.md) — ~~URLError detection~~ (removed), Cipher copy helpers
- [ReviewSection_DIWiring.md](ReviewSection_DIWiring.md) — ServiceContainer, Services.swift, DataStore cleanup

### High-Level Architecture

```
User Action → VaultRepository (catch any API error) → Offline Handler → PendingCipherChangeDataStore
                                                                            ↓
Existing sync triggers (periodic, pull-to-refresh, foreground) → SyncService.fetchSync()
                                                                            ↓
                                                          OfflineSyncResolver.processPendingChanges()
                                                                            ↓
                                                          Conflict Detection → API Upload / Backup Creation
                                                                            ↓
                                                          Early-abort if unresolved → else Full Sync
```

### End-to-End Data Flow

The offline sync feature introduces two new data flows:

**Flow 1: Offline Save (user edits while disconnected)**
```
1. User edits a cipher in the UI
2. Processor calls VaultRepository.updateCipher(cipherView)
3. VaultRepository encrypts the CipherView via SDK → encrypted Cipher
4. VaultRepository attempts cipherService.updateCipherWithServer(encrypted)
5. API call fails (any error — network, server, etc.)
6. VaultRepository catches the error:
   a. Checks cipher is not org-owned (throws if it is)
   b. Saves encrypted cipher to local Core Data (cipherService.updateCipherWithLocalStorage)
   c. Encodes encrypted cipher as JSON (CipherDetailsResponseModel)
   d. Detects password changes (decrypt + compare, in-memory only)
   e. Upserts PendingCipherChangeData record (cipherId, userId, encrypted JSON, revision date)
7. Operation returns success to UI — user sees their edit applied locally
```

**Flow 2: Sync Resolution (connectivity restored)**
```
1. Existing sync trigger fires (periodic timer, app foreground, pull-to-refresh)
2. SyncService.fetchSync() called
3. Pre-sync check:
   a. Is vault locked? → Yes: skip resolution
   b. Attempt resolution: offlineSyncResolver.processPendingChanges(userId) — **[Updated]** resolver is always called; it handles the empty case internally. The pre-count check was removed.
   c. Check remaining count → If > 0: ABORT sync (protect local data)
4. For each pending change, resolver:
   a. .create: push new cipher to server, delete pending record
   b. .update: fetch server version, detect conflicts by comparing revisionDates
      - No conflict, <4 pw changes: push local to server
      - No conflict, ≥4 pw changes: push local, create backup of server version
      - Conflict, local newer: push local, backup server version
      - Conflict, server newer: keep server, backup local version
   c. .softDelete: fetch server version, backup if conflict, then soft-delete on server
5. All pending changes resolved → proceed to normal full sync (replaceCiphers, etc.)
```

---

## 1. Architecture Compliance

**Reference:** `Docs/Architecture.md`, [contributing-docs/architecture/mobile-clients/ios](https://github.com/pkinerd/bitwarden.contributing-docs/docs/architecture/mobile-clients/ios/index.md)

### 1.1 Layering

| Principle | Compliance | Notes |
|-----------|-----------|-------|
| Core layer: Services have single responsibilities | **Pass** | `OfflineSyncResolver` owns conflict resolution; `PendingCipherChangeDataStore` owns persistence |
| Core layer: Repositories synthesize data from services | **Pass** | `VaultRepository` orchestrates cipher services, pending store, and encryption |
| DI via `ServiceContainer` + `HasService` protocols | **Pass** | Two new protocols (`HasOfflineSyncResolver`, `HasPendingCipherChangeDataStore`) added to `Services` typealias |
| UI layer has no direct service access | **Pass** | Offline sync is triggered via existing sync mechanisms, no new UI-layer service dependencies |
| Protocol-based service abstractions | **Pass** | All new services have protocol + default implementation pairs |
| Data stores extend `DataStore` | **Pass** | `PendingCipherChangeDataStore` extends `DataStore` via protocol + extension |
| No new top-level Core/UI subfolders | **Pass** | All new files placed within existing `Vault` and `Platform` domains |
| Unidirectional data flow preserved | **Pass** | No new UI components; offline save is transparent to the existing Coordinator/Processor/View pattern |

### 1.2 Dependency Flow

```
VaultRepository [modified]
  └─ cipherService (CipherService) [existing]
  └─ clientService (ClientService) [existing]
  └─ pendingCipherChangeDataStore (PendingCipherChangeDataStore) [NEW]
  └─ stateService (StateService) [existing]

SyncService [modified]
  └─ offlineSyncResolver (OfflineSyncResolver) [NEW]
  └─ pendingCipherChangeDataStore (PendingCipherChangeDataStore) [NEW]
  └─ vaultTimeoutService (VaultTimeoutService) [existing]

OfflineSyncResolver (DefaultOfflineSyncResolver) [NEW]
  └─ cipherAPIService (CipherAPIService) [existing]
  └─ cipherService (CipherService) [existing]
  └─ clientService (ClientService) [existing]
  └─ folderService (FolderService) [existing]
  └─ pendingCipherChangeDataStore (PendingCipherChangeDataStore) [NEW]
  └─ stateService (StateService) [existing]
```

No circular dependencies detected. All new services flow into the existing service graph correctly.

### 1.3 Cross-Domain/Cross-Component Dependencies

**Assessment: No problematic new cross-domain dependencies introduced.**

| New Dependency | From | To | Assessment |
|----------------|------|-----|-----------|
| `PendingCipherChangeDataStore` | `VaultRepository` | `DataStore` | Same domain (Vault → Platform/Stores) — follows existing patterns (e.g., CipherData) |
| `PendingCipherChangeDataStore` | `SyncService` | `DataStore` | Same domain — follows existing SyncService-to-DataStore pattern |
| `OfflineSyncResolver` → `FolderService` | Vault/Services | Vault/Services | Same domain — creating a folder for conflict backups |
| `OfflineSyncResolver` → `CipherAPIService` | Vault/Services | Vault/Services | Same domain — fetching server cipher state |

The `OfflineSyncResolver` has the highest dependency count (6 injected services), which are all within the Vault/Platform domain and are cohesive with the resolver's responsibility. No cross-domain coupling is introduced (e.g., Auth ↔ Vault, Tools ↔ Vault).

**Removed cross-domain dependency (positive):** The simplification removed a `ConnectivityMonitor` dependency that would have imported `Network.framework` and an `AccountAPIService` dependency for health checking, both of which were cross-cutting.

### 1.4 Architectural Observations

**Observation A1 — Early-abort sync pattern:** SyncService uses an early-abort pattern: if pending offline changes exist, it attempts to resolve them first. If any remain unresolved (e.g. server unreachable), the sync is aborted entirely to prevent `replaceCiphers` from overwriting local offline edits. This is simpler and safer than the alternative of proceeding with sync and re-applying changes afterward.

**Observation A2 — `OfflineSyncResolver` has 6 dependencies:** This reflects the resolver's cross-cutting responsibility (reading ciphers, creating folders, uploading to API, managing pending state). The responsibility is cohesive, so the dependency count is acceptable.

**~~Issue A3~~ [Resolved] — `timeProvider` removed from `DefaultOfflineSyncResolver`.** The unused `timeProvider` dependency has been removed. The backup cipher name uses `DateFormatter` with the cipher's own timestamp, not a time provider. Removed in commit `a52d379`.

---

## 2. Code Style Compliance

**Reference:** [contributing-docs/contributing/code-style/swift.md](https://github.com/pkinerd/bitwarden.contributing-docs/docs/contributing/code-style/swift.md)

### 2.1 Naming Conventions

| Guideline | Compliance | Notes |
|-----------|-----------|-------|
| American English spelling | **Pass** | "organization" used consistently (was "organisation" originally, fixed in review commit) |
| Type naming (UpperCamelCase) | **Pass** | `DefaultOfflineSyncResolver`, `PendingCipherChangeData`, `PendingCipherChangeType` |
| Property/method naming (lowerCamelCase) | **Pass** | `pendingCipherChangeDataStore`, `handleOfflineUpdate`, `handleOfflineAdd` |
| Protocol naming (`Has*` for DI) | **Pass** | `HasOfflineSyncResolver`, `HasPendingCipherChangeDataStore` |
| Test naming (`test_method_scenario`) | **Pass** | `test_fetchSync_preSyncResolution_skipsWhenVaultLocked`, `test_processPendingChanges_update_noConflict` |
| Mock naming (`Mock*`) | **Pass** | `MockOfflineSyncResolver`, `MockPendingCipherChangeDataStore` |
| File naming (CamelCase of primary type) | **Pass** | `PendingCipherChangeData.swift`, `OfflineSyncResolver.swift`, `CipherView+OfflineSync.swift` |
| Verb phrases for side-effect methods | **Pass** | `handleOfflineAdd`, `resolveConflict`, `createBackupCipher` |
| "Tapped" over "Pressed" | **N/A** | No button interaction naming in this change |
| Acronym casing per API guidelines | **Pass** | `URL`, `API`, `ID`, `NFC` follow Apple conventions |

### 2.2 Code Organization

| Guideline | Compliance | Notes |
|-----------|-----------|-------|
| MARK comments for sections | **Pass** | `// MARK: Properties`, `// MARK: Initialization`, `// MARK: Private`, `// MARK: Constants` used throughout |
| MARK enforcement order (properties → initializers → methods) | **Pass** | Consistent across all new files |
| File co-location (tests with impl) | **Pass** | All test files in same directory as implementation |
| Extension-based protocol conformance | **Pass** | `DataStore` extension for `PendingCipherChangeDataStore` conformance |
| Guard clauses for early returns | **Pass** | Used consistently in `handleOfflineDelete`, `resolveCreate`, `processPendingChanges` |
| Alphabetization within MARK sections | **Pass** | Properties and methods alphabetically ordered |
| DocC documentation on all public symbols | **Pass** | All protocols, classes, methods, and properties have DocC |
| DocC skipped for protocol implementations | **Pass** | `DataStore` extension methods (implementing `PendingCipherChangeDataStore`) not redundantly documented |
| DocC skipped for mocks | **Pass** | Mock classes do not have DocC |

### 2.3 Style Issues

**~~Issue CS-1~~ [Resolved] — Stray blank line in `Services.swift` typealias.** The blank line between `& HasConfigService` and `& HasDeviceAPIService` has been removed. Fixed in commit `a52d379`.

**[Updated note]** The `URLError+NetworkConnection.swift` file (previously listed in section 2.1 file naming) has been deleted. The error handling pattern in section 2.2 (`catch let error as URLError where error.isNetworkConnectionError`) has been simplified to plain `catch` blocks.

---

## 3. Compilation Safety

### 3.1 Type Safety

| Area | Assessment | Details |
|------|-----------|---------|
| `PendingCipherChangeType` raw values | **Safe** | Backed by `Int16` with explicit raw values. `changeTypeRaw` stored in Core Data. Computed property provides typed access. |
| `CipherDetailsResponseModel` Codable | **Safe** | JSON encode/decode used for cipher data persistence. Model is well-established in codebase. |
| `Cipher(responseModel:)` init | **Safe** | Uses existing SDK init that maps from response model. |
| Error catch pattern | **Safe** | **[Updated]** Plain `catch` blocks used in all four offline fallback methods. The `URLError+NetworkConnection` extension was removed; any server API failure now triggers offline save. The encrypt step occurs outside the do-catch, so SDK errors propagate normally. |
| `CipherView.update(name:folderId:)` | **Fragile** | Manually copies all 24 properties. See Issue CS-2. |
| `Cipher.withTemporaryId(_:)` | **Fragile** | Manually copies all 26 properties. See Issue CS-2. |

**Issue CS-2 — `withTemporaryId` and `update` are fragile against SDK type changes.** Both methods manually copy all properties by calling the full initializer. If `Cipher`/`CipherView` from the BitwardenSdk package gain new properties with default values, these methods will compile but silently drop the new property's value. If new required parameters are added, compilation will break (which is the safer outcome). **Severity: Low.** **Recommendation:** Add a comment noting these methods must be reviewed when the SDK is updated.

### 3.2 Import Statements

All new files have appropriate imports. No new external framework imports. Test files correctly use `@testable import BitwardenShared`. `OfflineSyncResolverTests` correctly imports `Networking` for `EmptyResponse` and `BitwardenKitMocks` for `MockErrorReporter`.

---

## 4. New External Libraries and Dependencies

**None.** The changeset introduces zero new external libraries, packages, or framework dependencies. All imports are from existing project targets or Apple system frameworks:

| Import | Source | Status |
|--------|--------|--------|
| `Foundation` | Apple | Existing |
| `CoreData` | Apple | Existing (used by DataStore already) |
| `BitwardenSdk` | Project | Existing |
| `OSLog` | Apple | Existing (used by Logger.application already) |
| `XCTest` | Apple | Test target only |
| `BitwardenKitMocks` | Project test target | Existing |
| `Networking` | Project local package | Existing |

The removal of the `ConnectivityMonitor` (from a previous iteration) actually **eliminated** a potential new dependency on Apple's `Network.framework`.

---

## 5. Test Coverage

**Reference:** `Docs/Testing.md`, [contributing-docs/architecture/mobile-clients/ios testing section](https://github.com/pkinerd/bitwarden.contributing-docs/docs/architecture/mobile-clients/ios/index.md)

### 5.1 Coverage by Component

| Component | Test File | Test Count | Coverage Quality |
|-----------|-----------|-----------|-----------------|
| `CipherView+OfflineSync` | `CipherViewOfflineSyncTests.swift` | 7 | Good — verifies property preservation, ID/key nullification, attachment exclusion |
| `PendingCipherChangeDataStore` | `PendingCipherChangeDataStoreTests.swift` | 10 | Good — full CRUD coverage, user isolation, upsert idempotency, `originalRevisionDate` preservation |
| `OfflineSyncResolver` | `OfflineSyncResolverTests.swift` | 11 | Good — all change types, conflict resolution paths, backup naming, folder creation |
| `VaultRepository` (offline) | `VaultRepositoryTests.swift` | +8 new | Good — offline fallback for add/update/delete/softDelete + org cipher rejection. **[Updated]** `test_updateCipher_nonNetworkError_rethrows` removed (no longer applicable since all errors trigger offline save). |
| `SyncService` (offline) | `SyncServiceTests.swift` | +4 new | Good — pre-sync trigger, skip on locked vault, no pending changes, abort on remaining |

**Total new test count: 40 tests** **[Updated]** Reduced from 47: removed 5 `URLError+NetworkConnection` tests (extension deleted) and 1 `test_updateCipher_nonNetworkError_rethrows` (no longer applicable). Also removed unused `pendingChangeCountResults` sequential-return mechanism from the mock.

### 5.2 Notable Test Gaps

| ID | Component | Gap | Severity |
|----|-----------|-----|----------|
| T1 | `OfflineSyncResolver` | No batch processing test — all tests use single pending change | Medium |
| T2 | `OfflineSyncResolver` | No API failure during resolution tested — `addCipherWithServer`/`updateCipherWithServer` throwing is catch-and-continue but untested | Medium |
| T3 | `VaultRepository` | `handleOfflineUpdate` password change detection not directly tested — counting logic involves decrypt+compare | Medium |
| T4 | `VaultRepository` | `handleOfflineDelete` cipher-not-found path not tested — `fetchCipher(withId:)` returning nil leads to silent return | Low |
| T5 | `OfflineSyncResolverTests` | Inline `MockCipherAPIServiceForOfflineSync` implements full protocol with `fatalError()` stubs for 15 unused methods — fragile against protocol changes | Low |
| ~~T6~~ | ~~`URLError+NetworkConnection`~~ | ~~Only 3 of 10 positive error codes tested individually~~ **[Resolved]** Extension and tests deleted as part of error handling simplification. | ~~Low~~ N/A |
| T7 | `VaultRepository` | No test for `handleOfflineUpdate` with existing pending record (subsequent offline edit scenario) | Low |
| T8 | `SyncService` | No test for pre-sync resolution where the resolver throws a hard error (not a per-item failure) | Low |

### 5.3 Test Pattern Compliance (`Docs/Testing.md`)

| Guideline | Compliance |
|-----------|-----------|
| Every type containing logic must be tested | **Pass** — All new types have tests |
| Test file naming: `<Type>Tests.swift` | **Pass** |
| Co-located with implementation | **Pass** |
| Extends `BitwardenTestCase` | **Pass** — All test classes |
| Uses `ServiceContainer.withMocks()` where applicable | **Pass** — New mocks added to `ServiceContainer+Mocks.swift` |
| Mocks follow `Mock<Name>` naming | **Pass** |
| Alphabetical test ordering | **Pass** |
| Properties → Setup & Teardown → Tests MARK order | **Pass** |
| setUp creates all mocks, tearDown nils them | **Pass** |

---

## 6. Security Considerations

**Reference:** [contributing-docs/architecture/security/principles/01-servers-are-zero-knowledge.mdx](https://github.com/pkinerd/bitwarden.contributing-docs/docs/architecture/security/principles/01-servers-are-zero-knowledge.mdx), [contributing-docs/architecture/security/definitions.mdx](https://github.com/pkinerd/bitwarden.contributing-docs/docs/architecture/security/definitions.mdx), [contributing-docs/architecture/cryptography/crypto-guide.md](https://github.com/pkinerd/bitwarden.contributing-docs/docs/architecture/cryptography/crypto-guide.md)

### 6.1 Zero-Knowledge Architecture Preservation

| Principle | Compliance | Analysis |
|-----------|-----------|---------|
| Encrypt before persist | **Pass** | All offline handlers receive already-encrypted `Cipher` objects from `clientService.vault().ciphers().encrypt()`. The `CipherDetailsResponseModel` stored in Core Data contains only encrypted fields. |
| No plaintext secrets in storage | **Pass** | `cipherData` in `PendingCipherChangeData` stores JSON-encoded encrypted cipher snapshots. Login passwords, notes, and custom fields are encrypted by the SDK before reaching the offline handler. |
| Attackers cannot retrieve decrypted vault data | **Pass** | Pending change records store the same encrypted format as existing `CipherData`. No reduction in protection. |
| Attackers cannot retrieve user encryption keys | **Pass** | No new key storage introduced. Relies on existing encryption key management via iOS Keychain. |
| No new crypto code in Swift | **Pass** | All encryption/decryption uses existing SDK primitives (Rust). No new cryptographic code written in Swift. |
| Per-user data isolation | **Pass** | All pending change queries scoped by `userId`. Core Data uniqueness constraint is `(userId, cipherId)`. |

### 6.2 Are Temporary Offline Items Protected to the Same Level as the Offline Vault Copy?

**Yes.** The pending offline items stored in `PendingCipherChangeData.cipherData` are protected to the **identical level** as the existing offline vault copy stored in `CipherData.modelData`:

| Protection Layer | Existing `CipherData` | New `PendingCipherChangeData` | Same? |
|-----------------|----------------------|-------------------------------|-------|
| Content encryption | SDK-encrypted `CipherDetailsResponseModel` JSON | SDK-encrypted `CipherDetailsResponseModel` JSON | **Yes** |
| Core Data store location | `{AppGroupContainer}/Bitwarden.sqlite` | Same database, same SQLite file | **Yes** |
| iOS file protection | Complete Until First User Authentication (iOS default) | Same (same file) | **Yes** |
| App sandbox | App security group container | Same container | **Yes** |
| User data cleanup | Included in `deleteDataForUser` batch | Included in `deleteDataForUser` batch | **Yes** |
| Metadata exposure | `id`, `userId` stored unencrypted | `id`, `userId`, `cipherId`, `changeTypeRaw`, dates stored unencrypted | **Comparable** |

The metadata fields on `PendingCipherChangeData` (`offlinePasswordChangeCount`, `originalRevisionDate`, `changeTypeRaw`, `createdDate`, `updatedDate`) reveal activity patterns (timing and nature of offline edits) but no sensitive vault content. This is comparable to metadata already exposed by `CipherData` (which stores `id`, `userId` unencrypted alongside encrypted `modelData`).

### 6.3 Encryption Flow Verification

The encrypt-before-queue invariant is correctly maintained across all four operations:

```
addCipher:     encrypt(cipherView) → addCipherWithServer (may throw) → handleOfflineAdd(encryptedCipher)
updateCipher:  encrypt(cipherView) → updateCipherWithServer (may throw) → handleOfflineUpdate(encryptedCipher)
softDelete:    encrypt(softDeleted) → softDeleteWithServer (may throw) → handleOfflineSoftDelete(encryptedCipher)
deleteCipher:  N/A (ID only) → deleteCipherWithServer (may throw) → handleOfflineDelete(cipherId)
```

In all paths, `clientService.vault().ciphers().encrypt(cipherView:)` is called **before** the server request. The catch block receives the already-encrypted cipher, so no additional encryption is needed for offline storage.

For `deleteCipher`, the method only receives an ID (no cipher data). The `handleOfflineDelete` helper fetches the existing encrypted cipher from local storage to include in the pending record.

### 6.4 Password Change Detection

`VaultRepository.handleOfflineUpdate` (lines ~1012-1030) decrypts both the existing pending cipher and the new cipher to compare plaintext passwords in-memory. The decrypted values are ephemeral and not persisted. This is necessary for the soft conflict threshold feature (≥4 password changes triggers a backup).

### 6.5 Organization Cipher Restriction

Organization ciphers are correctly blocked from offline editing in all four operations:
- `addCipher` — checked before offline fallback
- `updateCipher` — checked before offline fallback
- `softDeleteCipher` — checked before offline fallback
- `deleteCipher` — checked inside `handleOfflineDelete` (after fetching cipher to determine org ownership)

This prevents unauthorized client-side modifications to shared organization data where permissions, collection access, and policies could change while offline.

### 6.6 Security Issues and Observations

**~~Issue SEC-1 (Medium)~~ [Superseded]** — `.secureConnectionFailed` classified as network error. This issue is superseded by the error handling simplification. The `URLError+NetworkConnection.swift` extension has been deleted. The VaultRepository catch blocks now use plain `catch` instead of filtering by `URLError.isNetworkConnectionError`. The fine-grained URLError classification was solving a problem that doesn't exist: the networking stack separates transport errors (`URLError`) from HTTP errors (`ServerError`, `ResponseValidationError`) at a different layer, and the encrypt step occurs outside the do-catch so SDK errors propagate normally. Any server API call failure now triggers offline save, which is the correct behavior since there is no realistic scenario where the server is online and reachable but a pending change is permanently invalid.

**Observation SEC-2 — Pending data survives vault lock.** `PendingCipherChangeData` is stored in Core Data alongside other vault data. The `cipherData` field contains SDK-encrypted JSON, so it's protected by the vault encryption key. The metadata fields are unencrypted, consistent with existing `CipherData`.

**Observation SEC-3 — Pending changes cleaned up on user data deletion.** `DataStore.deleteDataForUser(userId:)` includes `PendingCipherChangeData.deleteByUserIdRequest` in the batch delete, ensuring pending changes are properly removed on logout or account deletion.

---

## 7. Reliability Considerations

### 7.1 Error Handling

| Scenario | Handling | Assessment |
|---------|---------|-----------|
| Any server API failure during cipher operation | **[Updated]** Plain `catch` falls back to offline save | **Good** — The encrypt step occurs outside the do-catch, so SDK encryption errors propagate normally. Only server API call failures are caught. The networking stack separates transport errors from HTTP errors at a different layer, so fine-grained URLError filtering was unnecessary. |
| ~~Non-network error during cipher operation~~ | ~~Rethrows normally~~ | **[Superseded]** No longer applicable — all API errors trigger offline save. There is no realistic scenario where the server is reachable but a pending change is permanently invalid. |
| Single pending change resolution fails | `OfflineSyncResolver` logs error via `Logger.application`, continues to next | **Good** — One failure doesn't block others |
| Unresolved pending changes after resolution | SyncService aborts sync, returns early | **Good** — Prevents `replaceCiphers` from overwriting local offline edits |
| Resolver `processPendingChanges` throws hard error | Error propagates through `fetchSync` — entire sync fails | **Acceptable** — If the store is unreadable, sync should not proceed |
| Detail view publisher stream error (e.g., `decrypt()` failure) | ~~`asyncTryMap` terminates publisher; catch block logs error only~~ **[Fixed]** Offline-created ciphers now decrypt normally | **[Resolved]** Root cause eliminated: temp ID baked into encrypted content. See [AP-VI1](ActionPlans/Resolved/AP-VI1_OfflineCreatedCipherViewFailure.md) |

### 7.2 Data Loss Prevention

The architecture provides multiple layers of protection against data loss:

1. **Encrypt-before-queue:** Cipher data is encrypted before any network attempt, ensuring it's always available for offline storage
2. **Local persistence on failure:** The encrypted cipher is saved to local Core Data immediately on network failure
3. **Early-abort sync:** `fetchSync` will not call `replaceCiphers` while pending changes exist
4. **Conflict backup:** When conflicts are detected, both server and local versions are preserved as separate ciphers
5. **Soft conflict threshold:** Even without server conflicts, ≥4 password changes trigger a backup of the server version
6. **Organization cipher exclusion:** Prevents complex shared-item conflicts that could lead to data loss

**Potential data loss scenario (low probability):**

If `cipherService.addCipherWithServer` in `resolveCreate` succeeds on the server but the subsequent local storage update fails, the pending record is NOT deleted. On retry, the resolver creates a duplicate cipher on the server. The user sees a duplicate but loses no data. See `ReviewSection_OfflineSyncResolver.md` Issue RES-1.

### 7.3 Reliability Issues

**Issue R1 (Low) — Pending change data format versioning:** Pending changes store `CipherDetailsResponseModel` as JSON. If the model evolves in a future app update, old pending changes might fail to decode. Severity is low since pending changes are short-lived (resolved on next successful sync).

**Issue R2 (Low) — `conflictFolderId` thread safety:** `DefaultOfflineSyncResolver.conflictFolderId` is a mutable `var` on a class with no `actor` isolation. Currently safe due to sequential calling pattern, but fragile if ever called concurrently.

**Issue R3 (Low) — No retry backoff for failed resolution items:** Failed items are retried on every subsequent sync with no backoff. If a cipher consistently fails to resolve (e.g., server returns 404), the resolver will attempt it every sync indefinitely. Consider adding a retry count or expiry mechanism.

**Issue R4 (Low) — Silent sync abort:** When sync is aborted due to remaining pending changes, there's no logging. Consider adding `Logger.application.info()` to aid debugging.

---

## 8. Usability Considerations

### 8.1 User Experience During Offline Operations

| Scenario | Behavior | Assessment |
|---------|---------|-----------|
| Save cipher while offline | Saves silently, queues for sync | **Good** — Transparent to user |
| Save org cipher while offline | Throws `organizationCipherOfflineEditNotSupported` | **Needs attention** — Error appears after network timeout delay |
| Next sync after connectivity restored | Resolves pending changes, then syncs | **Good** — No manual action needed |
| Conflict detected (server changed) | Backup created in "Offline Sync Conflicts" folder | **Good** — No data loss |
| Multiple password changes offline | Extra backup when ≥4 changes | **Good** — Soft conflict protects against accumulated drift |
| Archive/unarchive cipher while offline | Fails with generic network error | **Gap** — Inconsistent with add/update/delete offline support |
| Update cipher collections while offline | Fails with generic network error | **Gap** — Inconsistent |
| Restore cipher from trash while offline | Fails with generic network error | **Gap** — Inconsistent |
| Viewing offline-created item | ~~Infinite spinner, item never loads~~ **[Fixed]** Item loads normally | **[Resolved]** Root cause eliminated: temp ID assigned before encryption ensures cipher decrypts correctly. See [AP-VI1](ActionPlans/Resolved/AP-VI1_OfflineCreatedCipherViewFailure.md) |
| Viewing pending changes status | No UI indicator | **Gap** — User has no awareness of unsynced changes |
| Conflict folder discovery | "Offline Sync Conflicts" folder appears in vault | **Acceptable** — Clear name, but English-only |

### 8.2 Usability Observations

**Observation U1 — Org cipher error timing.** The organization check happens after the network request fails, so the user must wait for the network timeout before seeing the error. Proactive checking would require knowing connectivity state before the API call.

**Observation U2 — Inconsistent offline support across operations.** Add, update, delete, and soft-delete work offline. Archive, unarchive, collection assignment, and restore do not. Users performing unsupported operations offline get generic errors rather than offline-specific messages.

**Observation U3 — No user-visible pending changes indicator.** Users have no way to see pending offline changes. If resolution continues to fail, the user is unaware their changes haven't been uploaded.

**Observation U4 — Conflict folder name in English only.** "Offline Sync Conflicts" is hardcoded in English, not localized. Non-English users see an English folder name. Localization is complex since the encrypted folder name syncs across devices with potentially different locales.

**~~Issue VI-1~~ [Resolved] — Offline-created cipher view failure.** ~~When a user creates a new cipher while offline, the item appeared in the vault list but failed to load in the detail view (infinite spinner).~~ **Fixed in PR #35.** The root cause was eliminated by moving temp-ID assignment before encryption — offline-created ciphers now encrypt/decrypt identically to any other cipher. See [AP-VI1](ActionPlans/Resolved/AP-VI1_OfflineCreatedCipherViewFailure.md).

---

## 9. Simplification Opportunities

### 9.1 Ways to Reduce Code Change Extent Without Reducing Functionality

| Opportunity | Estimated Savings | Trade-off |
|-------------|-------------------|-----------|
| ~~Remove `timeProvider` from `DefaultOfflineSyncResolver`~~ | ~~5 lines~~ | **[Done]** — Removed in commit `a52d379` |
| Merge `handleOfflineDelete` and `handleOfflineSoftDelete` | ~30 lines | Slight increase in complexity of one method; both queue `.softDelete` changes |
| Use `Cipher` directly instead of roundtripping through `CipherDetailsResponseModel` JSON | ~20 lines per handler | Would require a different serialization approach for `cipherData`; the current JSON approach matches existing `CipherData` patterns |
| Remove `CipherView.update(name:folderId:)` and inline the `CipherView(...)` init call in the resolver | ~20 lines | Reduces abstraction but couples resolver to SDK init signature |
| Use existing project-level mock for `CipherAPIService` (if one exists) instead of inline `MockCipherAPIServiceForOfflineSync` | ~40 lines | Depends on whether a project mock exists with `fatalError` stubs for unused methods |

**Assessment:** The code is already reasonably compact. The `timeProvider` removal has been applied. The remaining opportunities offer modest savings with tradeoffs.

### 9.2 Simplifications Already Applied

The implementation has already been simplified significantly from the original plan:

1. **ConnectivityMonitor removed** — Saved ~500 lines and eliminated `Network.framework` dependency
2. **Health check removed** — Saved ~50 lines and eliminated `AccountAPIService` dependency
3. **Post-sync re-application replaced with early-abort** — Simplified sync logic significantly
4. **`AddEditItemProcessor` not modified** — Errors propagate through existing UI error handling
5. **No changes to `CipherService` or `FolderService`** — Existing protocol methods sufficient

---

## 10. Core Data Model

### 10.1 `PendingCipherChangeData` Entity

```
PendingCipherChangeData
├── id: String (required)
├── cipherId: String (required)
├── userId: String (required)
├── changeTypeRaw: Integer 16 (required, default 0)
├── cipherData: Binary (optional)
├── originalRevisionDate: Date (optional)
├── createdDate: Date (optional)
├── updatedDate: Date (optional)
├── offlinePasswordChangeCount: Integer 16 (required, default 0)
└── Uniqueness: (userId, cipherId)
```

The uniqueness constraint ensures at most one pending change per cipher per user. Subsequent offline edits update the existing record.

### 10.2 Core Data Model Versioning

The entity is added to the existing `Bitwarden.xcdatamodel` without creating a new model version. Core Data's lightweight migration handles new entity additions automatically. Future modifications to this entity (renamed/removed attributes) would require explicit model versioning.

### 10.3 User Data Cleanup

`DataStore.deleteDataForUser(userId:)` correctly includes `PendingCipherChangeData.deleteByUserIdRequest(userId:)` in the batch delete.

---

## 11. New and Modified File Inventory

### New Files (9 source + 3 docs)

**[Updated]** `URLError+NetworkConnection.swift` (26 lines) and `URLError+NetworkConnectionTests.swift` (39 lines) were deleted as part of the error handling simplification. The `isNetworkConnectionError` computed property is no longer needed since all API failures now trigger offline save.

| File | Type | Lines | Purpose |
|------|------|-------|---------|
| `CipherView+OfflineSync.swift` | Extension | 95 | Cipher copy helpers for offline/backup |
| `CipherViewOfflineSyncTests.swift` | Tests | 128 | Tests for above |
| `PendingCipherChangeData.swift` | Model | 192 | Core Data entity + predicates |
| `PendingCipherChangeDataStore.swift` | Store | 155 | Data access layer protocol + impl |
| `PendingCipherChangeDataStoreTests.swift` | Tests | 286 | Full CRUD tests |
| `MockPendingCipherChangeDataStore.swift` | Mock | 77 | Test helper |
| `OfflineSyncResolver.swift` | Service | 360 | Conflict resolution engine |
| `OfflineSyncResolverTests.swift` | Tests | 517 | Conflict scenarios |
| `MockOfflineSyncResolver.swift` | Mock | 11 | Test helper |

### Modified Files (10)

| File | Changes | Detailed Review |
|------|---------|-----------------|
| `ServiceContainer.swift` | +29 lines: Register 2 new services, add init params and DocC, wire in `defaultServices()` | [ReviewSection_DIWiring.md](ReviewSection_DIWiring.md) |
| `Services.swift` | +17 lines: Add `HasOfflineSyncResolver`, `HasPendingCipherChangeDataStore` protocols, compose into `Services` typealias | [ReviewSection_DIWiring.md](ReviewSection_DIWiring.md) |
| `DataStore.swift` | +1 line: Add `PendingCipherChangeData` to `deleteDataForUser` batch delete | [ReviewSection_DIWiring.md](ReviewSection_DIWiring.md) |
| `Bitwarden.xcdatamodel/contents` | +17 lines: Add `PendingCipherChangeData` entity with 9 attributes and uniqueness constraint | [ReviewSection_PendingCipherChangeDataStore.md](ReviewSection_PendingCipherChangeDataStore.md) |
| `VaultRepository.swift` | +225 lines: Add `pendingCipherChangeDataStore` dependency; offline fallback handlers; org cipher guards | [ReviewSection_VaultRepository.md](ReviewSection_VaultRepository.md) |
| `VaultRepositoryTests.swift` | +115 lines: 8 new tests for offline fallback and org cipher rejection. **[Updated]** `test_updateCipher_nonNetworkError_rethrows` removed (no longer applicable since all errors trigger offline save). | [ReviewSection_VaultRepository.md](ReviewSection_VaultRepository.md) |
| `SyncService.swift` | +30 lines: Add `offlineSyncResolver`, `pendingCipherChangeDataStore`; pre-sync resolution with early-abort | [ReviewSection_SyncService.md](ReviewSection_SyncService.md) |
| `SyncServiceTests.swift` | +69 lines: 4 new tests for pre-sync resolution conditions | [ReviewSection_SyncService.md](ReviewSection_SyncService.md) |
| `ServiceContainer+Mocks.swift` | +6 lines: Add mock defaults for 2 new services | [ReviewSection_DIWiring.md](ReviewSection_DIWiring.md) |
| `AppProcessor.swift` | ~~+1 line: Whitespace only (blank line added)~~ **[Reverted]** — Blank line removed in commit `a52d379`. Net zero change. | N/A |

### Deleted Files

| File | Reason |
|------|--------|
| `ConnectivityMonitor.swift` | Removed (previous iteration) — existing sync triggers suffice |
| `ConnectivityMonitorTests.swift` | Tests for removed service |
| `MockConnectivityMonitor.swift` | Mock for removed service |
| `URLError+NetworkConnection.swift` | **[Removed in simplification]** — `isNetworkConnectionError` property no longer needed; plain `catch` replaces URLError filtering |
| `URLError+NetworkConnectionTests.swift` | **[Removed in simplification]** — Tests for deleted extension |

### Documentation Files (3)

| File | Purpose |
|------|---------|
| `_OfflineSyncDocs/OfflineSyncPlan.md` | Implementation plan |
| `_OfflineSyncDocs/OfflineSyncReviewActionPlan.md` | Review action plan with issue tracking |
| `_OfflineSyncDocs/OfflineSyncCodeReview.md` | This review document |

---

## 12. Implementation Plan Deviations

### 12.1 `AddEditItemProcessor` Not Modified

The plan (Section 9) lists `AddEditItemProcessor.swift` as a modified file. In the implementation, **no changes were made**. `OfflineSyncError.organizationCipherOfflineEditNotSupported` propagates through existing generic error handling. This is a reasonable deviation.

### 12.2 `CipherService` and `FolderService` Not Directly Modified

The plan lists both as modified files. In the implementation, they were not modified — the resolver uses existing methods on their protocols.

### 12.3 No Feature Flag

The feature has no feature flag or kill switch. If issues are discovered in production, the only mitigation is a code change and app update.

### 12.4 Simplifications Applied

1. **ConnectivityMonitor removed** — ~500 lines and `Network.framework` dependency eliminated
2. **Health check removed** — ~50 lines and `AccountAPIService` dependency eliminated
3. **Early-abort replaces re-application** — Simpler, safer sync protection

---

## 13. Critical Issues (Must Address)

**None identified.** No blocking issues that would prevent merge from a correctness, security, or architecture standpoint.

---

## 14. All Issues Summary (Prioritized)

### High Priority

| ID | Component | Issue | Detailed Section |
|----|-----------|-------|-----------------|
| S3 | `OfflineSyncResolverTests` | No batch processing test (multiple pending changes, mixed success/failure) | [RES-3](ReviewSection_OfflineSyncResolver.md) |
| S4 | `OfflineSyncResolverTests` | No API failure during resolution test | [RES-4](ReviewSection_OfflineSyncResolver.md) |

### Medium Priority

| ID | Component | Issue | Detailed Section |
|----|-----------|-------|-----------------|
| ~~SEC-1~~ | ~~`URLError+NetworkConnection`~~ | ~~`.secureConnectionFailed` may mask TLS security issues~~ **[Superseded]** Extension deleted; plain `catch` replaces URLError filtering. | ~~[EXT-2](ReviewSection_SupportingExtensions.md)~~ |
| ~~VI-1~~ | ~~`ViewItemProcessor` / `VaultRepository`~~ | ~~Offline-created cipher fails to load in detail view (infinite spinner)~~ **[Resolved]** Root cause eliminated by moving temp-ID assignment before encryption (PR #35). | [AP-VI1](ActionPlans/Resolved/AP-VI1_OfflineCreatedCipherViewFailure.md) |
| S6 | `VaultRepositoryTests` | `handleOfflineUpdate` password change counting not directly tested | [VR](ReviewSection_VaultRepository.md) |
| S7 | `VaultRepositoryTests` | `handleOfflineDelete` cipher-not-found path not tested | [VR-5](ReviewSection_VaultRepository.md) |
| S8 | Feature | Consider adding a feature flag for production safety | Section 12.3 |
| ~~EXT-1~~ | ~~`URLError+NetworkConnection`~~ | ~~`.timedOut` may trigger offline save for temporarily slow servers~~ **[Superseded]** Extension deleted; all API errors now trigger offline save by design. | ~~[EXT-1](ReviewSection_SupportingExtensions.md)~~ |

### Low Priority

| ID | Component | Issue | Detailed Section |
|----|-----------|-------|-----------------|
| ~~A3~~ | ~~`OfflineSyncResolver`~~ | ~~`timeProvider` dependency injected but never used~~ **[Resolved]** Removed in commit `a52d379`. | ~~Section 1.4~~ |
| ~~CS-1~~ | ~~`Services.swift`~~ | ~~Stray blank line in typealias~~ **[Resolved]** Removed in commit `a52d379`. | ~~Section 2.3~~ |
| CS-2 | `CipherView+OfflineSync` | `withTemporaryId`/`update` fragile against SDK type changes | Section 3.1 |
| R1 | `PendingCipherChangeData` | No data format versioning for `cipherData` JSON | Section 7.3 |
| R2 | `OfflineSyncResolver` | `conflictFolderId` thread safety (class with mutable var, no actor isolation) | [RES-2](ReviewSection_OfflineSyncResolver.md) |
| R3 | `OfflineSyncResolver` | No retry backoff for permanently failing resolution items | Section 7.3 |
| R4 | `SyncService` | Silent sync abort (no logging) | [SS-3](ReviewSection_SyncService.md) |
| DI-1 | `Services.swift` | `HasPendingCipherChangeDataStore` exposes data store to UI layer (broader than needed) | [DI-1](ReviewSection_DIWiring.md) |
| ~~T6~~ | ~~`URLError+NetworkConnectionTests`~~ | ~~Only 3 of 10 positive error codes tested~~ **[Resolved]** Extension and tests deleted. | ~~[EXT-4](ReviewSection_SupportingExtensions.md)~~ |

### Informational / Future Considerations

| ID | Component | Observation | Detailed Section |
|----|-----------|-------------|-----------------|
| U1 | UX | Org cipher error appears after network timeout delay | Section 8.2 |
| U2 | UX | Archive/unarchive/collections/restore not offline-aware (inconsistent) | Section 8.2 |
| U3 | UX | No user-visible indicator for pending offline changes | Section 8.2 |
| U4 | UX | Conflict folder name is English-only | Section 8.2 |
| VR-2 | `VaultRepository` | `deleteCipher` (permanent) converted to soft delete offline | [VR-2](ReviewSection_VaultRepository.md) |
| RES-1 | `OfflineSyncResolver` | Potential duplicate cipher on create retry after partial failure | [RES-1](ReviewSection_OfflineSyncResolver.md) |
| RES-7 | `OfflineSyncResolver` | Backup ciphers don't include attachments | [RES-7](ReviewSection_OfflineSyncResolver.md) |

---

## 15. Good Practices Observed

- **Encrypt-before-queue invariant** correctly maintained across all offline paths — sensitive data never stored unencrypted
- **Same protection level** as existing vault cache — pending offline items use identical encryption and storage
- **Protocol-based abstractions** with comprehensive mocks for every new service
- **Conflict resolution preserves both versions** — no silent data loss in any scenario
- **Organization cipher restriction** consistently enforced across all four operations
- **Core Data entity has proper uniqueness constraints** — `(userId, cipherId)` prevents duplicates
- **Early-abort sync pattern** prevents `replaceCiphers` from overwriting unsynced local data
- **DocC documentation** is complete on all public APIs per project guidelines
- **All test files follow `BitwardenTestCase` patterns** with proper setUp/tearDown lifecycle
- **Pending changes cleaned up on user data deletion** via `DataStore.deleteDataForUser`
- **`originalRevisionDate` preserved across upserts** — ensures conflict detection baseline is never accidentally overwritten
- **`conflictFolderId` caching** avoids redundant folder lookups/creation within a sync batch
- **No new external dependencies** — zero new libraries, packages, or framework imports
- **No problematic cross-domain dependencies** — all new relationships are within Vault/Platform domains
- **Simplification from original design** — ConnectivityMonitor, health check, and post-sync re-application all removed for cleaner architecture
- **`softConflictPasswordChangeThreshold` extracted as named constant** — avoids magic number

---

## 16. Post-Review Code Changes: VI-1 Fix — Comprehensive Technical Walkthrough

**[Added 2026-02-16]** After the initial code review, the VI-1 usability bug (offline-created ciphers showing an infinite spinner in the detail view) was fixed through PR #35 (11 commits, merged as `d191eb6`). This section provides a detailed technical walkthrough of every code change, organized by functional grouping. Each subsection explains the rationale, shows the code, describes test coverage, and links to related review issues and action plans.

The fix took a fundamentally different approach than the recommended Option E (catch-block fallback in the detail view publisher). Instead of adding defensive error handling, it eliminated the root cause by restructuring the temp-ID assignment to occur *before* encryption rather than *after*.

### 16.0 Summary of Changes

| File | Lines Changed | Description |
|------|--------------|-------------|
| `CipherView+OfflineSync.swift` | +28/-28 | `Cipher.withTemporaryId()` → `CipherView.withId()` |
| `CipherViewOfflineSyncTests.swift` | +77/-77 | Tests rewritten for `CipherView.withId()` |
| `VaultRepository.swift` | +62/-25 | Temp-ID before encryption; `.create` preservation; offline-created cleanup |
| `VaultRepositoryTests.swift` | +113/-2 | 5 new tests for new behaviors |
| `OfflineSyncResolver.swift` | +14/-0 | Temp-ID record cleanup in `resolveCreate` |
| `OfflineSyncResolverTests.swift` | +37/-2 | 2 new tests for temp-ID cleanup |

**Total:** 6 files changed, +331/-134 lines

### 16.1 Root Cause Analysis

**The bug:** When a user created a new cipher while offline, the item appeared in the vault list but failed to load in the detail view — an infinite spinner appeared and the item could never be viewed.

**Root cause — `data: nil` on encrypted cipher:**

The original `addCipher()` flow assigned a temp ID *after* encryption:

```
CipherView (id: nil)
    → encrypt()
    → Cipher (id: nil, data: <encrypted blob>)
    → withTemporaryId("temp-uuid")
    → Cipher (id: "temp-uuid", data: nil)      ← BUG: data field lost
    → updateCipherWithLocalStorage()
    → CipherData stored in Core Data
```

`Cipher.withTemporaryId()` created a new `Cipher` instance by calling the full initializer with all properties copied — except it explicitly set `data: nil`. The `data` field on `Cipher` contains the raw encrypted content needed for decryption. When the detail view's `streamCipherDetails` publisher tried to decrypt this cipher via `asyncTryMap { try await decrypt($0) }`, the `decrypt()` call failed because `data` was nil.

The publisher's `asyncTryMap` operator terminated on the first error, leaving the detail view in a permanent loading state (infinite spinner). See [AP-VI1](ActionPlans/Resolved/AP-VI1_OfflineCreatedCipherViewFailure.md) for the full investigation and option analysis.

**The fix — assign ID before encryption:**

```
CipherView (id: nil)
    → withId("temp-uuid")
    → CipherView (id: "temp-uuid")
    → encrypt()
    → Cipher (id: "temp-uuid", data: <encrypted blob with ID baked in>)
    → updateCipherWithLocalStorage()
    → CipherData stored in Core Data
```

By assigning the ID on the *decrypted* `CipherView` before encryption, the ID becomes part of the encrypted content. The resulting `Cipher` has both `id` and `data` populated — it encrypts/decrypts identically to any server-created cipher.

### 16.2 Change Group 1: `CipherView.withId()` — Replacing `Cipher.withTemporaryId()`

**Files:** `CipherView+OfflineSync.swift`, `CipherViewOfflineSyncTests.swift`
**Related issues:** [CS-2](ActionPlans/AP-CS2_FragileSDKCopyMethods.md), [EXT-3](ReviewSection_SupportingExtensions.md)

#### What Changed

The `Cipher.withTemporaryId(_:)` method was deleted and replaced with `CipherView.withId(_:)`. The key differences:

| Aspect | Old: `Cipher.withTemporaryId()` | New: `CipherView.withId()` |
|--------|-------------------------------|---------------------------|
| Operates on | `Cipher` (encrypted type, post-encryption) | `CipherView` (decrypted type, pre-encryption) |
| `data` field | Set to `nil` (the bug) | N/A — `CipherView` has no `data` field |
| ID in encrypted content | Not included (assigned after encrypt) | Included (assigned before encrypt) |
| `attachmentDecryptionFailures` | Not copied (field doesn't exist on `Cipher`) | Copied (field exists on `CipherView`) |

#### Implementation

The MARK section was renamed from `Cipher + OfflineSync` to `CipherView + OfflineSync`, and both `withId()` and `update()` now live in a single `CipherView` extension:

```swift
// MARK: - CipherView + OfflineSync

extension CipherView {
    /// Returns a copy of the cipher view with the specified ID.
    ///
    /// Used to assign a temporary client-generated ID to a new cipher view before
    /// encryption for offline support. The ID is baked into the encrypted content
    /// so it survives the decrypt round-trip without special handling.
    func withId(_ id: String) -> CipherView {
        CipherView(
            id: id,
            organizationId: organizationId,
            folderId: folderId,
            // ... all ~26 properties copied through ...
            attachmentDecryptionFailures: attachmentDecryptionFailures,  // NEW: not on Cipher
            // ... remaining properties ...
            archivedDate: archivedDate
            // NOTE: no `data: nil` — CipherView doesn't have a `data` field
        )
    }
}
```

The method copies all `CipherView` properties through the full initializer, replacing only `id`. Unlike the old `Cipher.withTemporaryId()`, there is no `data: nil` assignment because `CipherView` (the decrypted type) doesn't have a `data` field. This eliminates the entire class of bugs where post-encryption property manipulation corrupts the cipher.

**Fragility note (CS-2):** This method still manually copies ~26 properties. If the BitwardenSdk adds new properties with default values to `CipherView`, the method will compile but silently drop the new property. This is the same fragility concern as the `update(name:folderId:)` method, but the scope is now reduced to one SDK type (`CipherView`) instead of two (`Cipher` + `CipherView`). See [AP-CS2](ActionPlans/AP-CS2_FragileSDKCopyMethods.md).

#### Test Coverage

The tests were rewritten to test `CipherView.withId()` instead of `Cipher.withTemporaryId()`:

| Test | What It Verifies |
|------|-----------------|
| `test_withId_setsId` | `CipherView.fixture(id: nil).withId("temp-id-123")` produces a cipher view with `id == "temp-id-123"` |
| `test_withId_preservesOtherProperties` | Key properties preserved: `name`, `notes`, `folderId`, `organizationId`, `login.username`, `login.password`, `login.totp` |
| `test_withId_replacesExistingId` | `CipherView.fixture(id: "old-id").withId("new-id")` replaces the existing ID |

```swift
func test_withId_setsId() {
    let original = CipherView.fixture(id: nil, name: "No ID Cipher")
    let result = original.withId("temp-id-123")
    XCTAssertEqual(result.id, "temp-id-123")
}

func test_withId_replacesExistingId() {
    let original = CipherView.fixture(id: "old-id", name: "Cipher")
    let result = original.withId("new-id")
    XCTAssertEqual(result.id, "new-id")
}
```

The `test_withId_replacesExistingId` test is new — the old `withTemporaryId` tests didn't verify the replace-existing-ID scenario.

### 16.3 Change Group 2: Temp-ID Assignment Before Encryption in `addCipher()`

**Files:** `VaultRepository.swift` (`addCipher()`, `handleOfflineAdd()`)
**Related issues:** [AP-VI1](ActionPlans/Resolved/AP-VI1_OfflineCreatedCipherViewFailure.md)

#### What Changed in `addCipher()`

The temp-ID assignment was moved from `handleOfflineAdd()` (post-encryption) to `addCipher()` (pre-encryption). This is the core architectural fix:

```swift
// VaultRepository.swift — addCipher()

// Assign a temporary client-side ID for new ciphers so it's baked into the
// encrypted content. This ensures offline-created ciphers can be decrypted
// and loaded in the detail view like any other cipher. The server ignores
// this ID for new ciphers and assigns its own.
let cipherToEncrypt = cipher.id == nil ? cipher.withId(UUID().uuidString) : cipher

let cipherEncryptionContext = try await clientService.vault().ciphers()
    .encrypt(cipherView: cipherToEncrypt)
do {
    try await cipherService.addCipherWithServer(
        cipherEncryptionContext.cipher,
        // ...
    )
} catch {
    // ... offline fallback receives cipher with ID already set
    try await handleOfflineAdd(encryptedCipher: cipherEncryptionContext.cipher, userId: userId)
}
```

Key points:
- The conditional `cipher.id == nil ? cipher.withId(...) : cipher` handles only new ciphers (which have no ID yet)
- `UUID().uuidString` generates a standard UUID as the temp ID — the server ignores this for create operations and assigns its own ID
- The `encrypt(cipherView:)` call now receives a `CipherView` with a non-nil ID, so the ID is included in the encrypted content
- If the server call succeeds, the server assigns its own ID — the temp ID is only used locally until sync resolves
- If the server call fails (offline), `handleOfflineAdd` receives an encrypted cipher with a valid ID and intact `data`

#### What Changed in `handleOfflineAdd()`

The method was simplified — it no longer needs to assign a temp ID because `addCipher()` already did that:

**Before (old code):**
```swift
private func handleOfflineAdd(encryptedCipher: Cipher, userId: String) async throws {
    // Assign a temporary client-side ID if the cipher doesn't have one yet.
    let cipher: Cipher
    if encryptedCipher.id != nil {
        cipher = encryptedCipher
    } else {
        cipher = encryptedCipher.withTemporaryId(UUID().uuidString)
    }
    try await cipherService.updateCipherWithLocalStorage(cipher)
    let cipherResponseModel = try CipherDetailsResponseModel(cipher: cipher)
    // ... guard let cipherId = cipher.id at the bottom ...
```

**After (new code):**
```swift
private func handleOfflineAdd(encryptedCipher: Cipher, userId: String) async throws {
    guard let cipherId = encryptedCipher.id else {
        throw CipherAPIServiceError.updateMissingId
    }
    try await cipherService.updateCipherWithLocalStorage(encryptedCipher)
    let cipherResponseModel = try CipherDetailsResponseModel(cipher: encryptedCipher)
    // ... uses encryptedCipher directly throughout ...
```

Changes:
1. The conditional temp-ID assignment block (6 lines) is deleted — `encryptedCipher` is used directly
2. The `guard let cipherId` moves to the top as a precondition check
3. All references to the local `cipher` variable are replaced with `encryptedCipher`

This simplification is safe because `addCipher()` guarantees the cipher has an ID before reaching `handleOfflineAdd()`. The guard clause is defensive — if a caller passes a cipher without an ID, it throws `CipherAPIServiceError.updateMissingId` rather than proceeding with nil ID.

#### Test Coverage

```swift
/// `addCipher()` assigns a temporary ID before encryption when the cipher has no ID,
/// so the ID is baked into the encrypted content and survives the decrypt round-trip.
func test_addCipher_offlineFallback_newCipherGetsTempId() async throws {
    cipherService.addCipherWithServerResult = .failure(URLError(.notConnectedToInternet))

    let cipher = CipherView.fixture(id: nil, name: "New Cipher")
    try await subject.addCipher(cipher)

    // The cipher passed to encrypt should have a non-nil ID
    let encryptedCipher = try XCTUnwrap(clientCiphers.encryptedCiphers.first)
    XCTAssertNotNil(encryptedCipher.id, "New ciphers should get a temp ID before encryption")
    XCTAssertEqual(encryptedCipher.name, "New Cipher")

    // The locally stored cipher should have the same temp ID.
    let storedCipher = try XCTUnwrap(cipherService.updateCipherWithLocalStorageCiphers.first)
    XCTAssertEqual(storedCipher.id, encryptedCipher.id)
}
```

This test verifies the complete fix chain:
1. A cipher with `id: nil` enters `addCipher()`
2. The cipher passed to `encrypt()` has a non-nil ID (temp UUID was assigned)
3. The locally stored cipher has the same temp ID as the encrypted cipher
4. The `name` property is preserved through the `withId()` transformation

---

### 16.4 Change Group 3: `.create` Type Preservation in `handleOfflineUpdate()`

**Files:** `VaultRepository.swift` (`handleOfflineUpdate()`)
**Related issues:** [AP-T7](ActionPlans/AP-T7_SubsequentOfflineEditTest.md)

#### Problem

When a user creates a cipher offline (pending change type `.create`) and then edits it again before sync, the `handleOfflineUpdate()` method was called for the edit. Previously, this unconditionally set `changeType: .update` on the pending record:

```swift
// Old behavior — always sets .update
try await pendingCipherChangeDataStore.upsertPendingChange(
    changeType: .update,   // ← WRONG: overwrites .create
    // ...
)
```

This caused the resolver to call `resolveUpdate()` instead of `resolveCreate()`. The resolver would try to `GET /ciphers/{tempId}` from the server — which returns 404 because the temp ID doesn't exist on the server. The cipher would fail to sync.

#### Fix

The `handleOfflineUpdate()` method now checks the existing pending change type and preserves `.create` if present:

```swift
// VaultRepository.swift — handleOfflineUpdate()

// Preserve .create type if this cipher was originally created offline and hasn't been
// synced to the server yet. From the server's perspective it's still a new cipher that
// needs to be POSTed, not an existing cipher to PUT.
let changeType: PendingCipherChangeType = existing?.changeType == .create ? .create : .update

try await pendingCipherChangeDataStore.upsertPendingChange(
    cipherId: cipherId,
    userId: userId,
    changeType: changeType,       // ← preserves .create when appropriate
    cipherData: cipherData,
    originalRevisionDate: originalRevisionDate,
    offlinePasswordChangeCount: passwordChangeCount
)
```

The logic:
- If an existing pending change has `changeType == .create`: keep `.create` — from the server's perspective, this cipher doesn't exist yet and needs `POST /ciphers`
- If no existing pending change, or existing type is `.update`/`.softDelete`: use `.update` — the cipher exists on the server and needs `PUT /ciphers/{id}`

#### Test Coverage

```swift
/// `updateCipher()` preserves the `.create` pending change type when editing
/// an offline-created cipher that hasn't been synced to the server yet.
func test_updateCipher_offlineFallback_preservesCreateType() async throws {
    cipherService.updateCipherWithServerResult = .failure(URLError(.notConnectedToInternet))

    // Simulate an existing .create pending change for this cipher.
    let dataStore = DataStore(errorReporter: MockErrorReporter(), storeType: .memory)
    let existingChange = PendingCipherChangeData(
        context: dataStore.persistentContainer.viewContext,
        cipherId: "123", userId: "1",
        changeType: .create, cipherData: nil, originalRevisionDate: nil
    )
    pendingCipherChangeDataStore.fetchPendingChangeResult = existingChange

    let cipher = CipherView.fixture(id: "123")
    try await subject.updateCipher(cipher)

    // Should preserve .create type, not overwrite to .update.
    let pending = pendingCipherChangeDataStore.upsertPendingChangeCalledWith.first
    XCTAssertEqual(pending?.changeType, .create)
}
```

**Note:** This test partially addresses [AP-T7](ActionPlans/AP-T7_SubsequentOfflineEditTest.md) (subsequent offline edit). However, T7's recommended test for the `.update` → `.update` path with `originalRevisionDate` preservation and `offlinePasswordChangeCount` accumulation remains untested.

---

### 16.5 Change Group 4: Offline-Created Cipher Deletion Cleanup

**Files:** `VaultRepository.swift` (`handleOfflineDelete()`, `handleOfflineSoftDelete()`)
**Related issues:** [AP-S7](ActionPlans/AP-S7_CipherNotFoundPathTest.md)

#### Problem

When a user creates a cipher offline, then deletes (or soft-deletes) it before sync, the original code would:
1. Try `deleteCipherWithServer(id:)` — fails (offline)
2. Enter the offline fallback handler
3. Queue a `.softDelete` pending change for a temp-ID cipher that doesn't exist on the server

On the next sync, the resolver would try to `resolveDelete()` by fetching the server version — which returns 404. The pending change would permanently fail.

#### Fix

Both `handleOfflineDelete()` and `handleOfflineSoftDelete()` now check if the cipher was created offline (pending type `.create`) and clean up locally instead of queuing a server operation:

```swift
// VaultRepository.swift — handleOfflineDelete() (identical pattern in handleOfflineSoftDelete)

// If this cipher was created offline and hasn't been synced to the server,
// just clean up locally — there's nothing to delete on the server.
if let existing = try await pendingCipherChangeDataStore.fetchPendingChange(
    cipherId: cipherId,
    userId: userId
), existing.changeType == .create {
    try await cipherService.deleteCipherWithLocalStorage(id: cipherId)
    if let recordId = existing.id {
        try await pendingCipherChangeDataStore.deletePendingChange(id: recordId)
    }
    return
}

// (existing code for server-synced ciphers follows...)
```

The cleanup logic:
1. **`fetchPendingChange`** — checks if this cipher has an existing pending change
2. **`.changeType == .create`** — confirms it was created offline (not yet on server)
3. **`deleteCipherWithLocalStorage(id:)`** — removes the `CipherData` record from Core Data
4. **`deletePendingChange(id:)`** — removes the pending change record
5. **`return`** — exits without queuing any server-side operation

Both methods share identical cleanup code. The `existing.id` nil check (`if let recordId = existing.id`) is defensive — pending change records should always have IDs assigned by Core Data.

**Impact on S7 test gap:** The new `.create` check adds a code path *before* the original `guard let cipher = fetchCipher(withId:)` guard clause that S7 tests. The S7 test gap still exists — the guard clause (cipher not found locally) remains untested. See [AP-S7](ActionPlans/AP-S7_CipherNotFoundPathTest.md) for updated test setup.

#### Test Coverage

**Delete cleanup test:**

```swift
func test_deleteCipher_offlineFallback_cleansUpOfflineCreatedCipher() async throws {
    cipherService.deleteCipherWithServerResult = .failure(URLError(.notConnectedToInternet))

    // Simulate an existing .create pending change
    let existingChange = PendingCipherChangeData(
        context: dataStore.persistentContainer.viewContext,
        id: "pending-1", cipherId: "123", userId: "1",
        changeType: .create, cipherData: nil, originalRevisionDate: nil
    )
    pendingCipherChangeDataStore.fetchPendingChangeResult = existingChange

    try await subject.deleteCipher("123")

    XCTAssertEqual(cipherService.deleteCipherWithLocalStorageId, "123")
    XCTAssertEqual(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith, ["pending-1"])
    XCTAssertTrue(pendingCipherChangeDataStore.upsertPendingChangeCalledWith.isEmpty)
}
```

**Soft-delete cleanup test:**

```swift
func test_softDeleteCipher_offlineFallback_cleansUpOfflineCreatedCipher() async throws {
    cipherService.softDeleteWithServerResult = .failure(URLError(.notConnectedToInternet))

    // Same pattern as delete test
    pendingCipherChangeDataStore.fetchPendingChangeResult = existingChange

    try await subject.softDeleteCipher(cipherView)

    // Should delete, not update
    XCTAssertEqual(cipherService.deleteCipherWithLocalStorageId, "123")
    XCTAssertTrue(cipherService.updateCipherWithLocalStorageCiphers.isEmpty)
    // Should delete pending record, not upsert
    XCTAssertEqual(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith, ["pending-1"])
    XCTAssertTrue(pendingCipherChangeDataStore.upsertPendingChangeCalledWith.isEmpty)
}
```

Both tests verify: local cipher deleted, pending record deleted, NO new pending change queued, and for soft-delete specifically: `updateCipherWithLocalStorage` NOT called.

---

### 16.6 Change Group 5: Temp-ID Record Cleanup in `resolveCreate()`

**Files:** `OfflineSyncResolver.swift` (`resolveCreate()`), `OfflineSyncResolverTests.swift`
**Related issues:** [AP-RES1](ActionPlans/AP-RES1_DuplicateCipherOnCreateRetry.md)

#### Problem

When `resolveCreate()` pushes an offline-created cipher to the server via `addCipherWithServer()`, the server assigns a new server-generated ID. The `addCipherWithServer()` implementation creates a new `CipherData` record in Core Data with the server ID. However, the old `CipherData` record with the temporary client-side ID was left behind — an orphan that would persist until the next full sync's `replaceCiphers()` call.

#### Fix

After `addCipherWithServer()` succeeds, the resolver now explicitly deletes the old temp-ID record:

```swift
// OfflineSyncResolver.swift — resolveCreate()

let responseModel = try JSONDecoder().decode(CipherDetailsResponseModel.self, from: cipherData)
let cipher = Cipher(responseModel: responseModel)
let tempId = cipher.id                                              // ← capture temp ID

try await cipherService.addCipherWithServer(cipher, encryptedFor: userId)

// Remove the old cipher record that used the temporary client-side ID.
// `addCipherWithServer` upserts a new record with the server-assigned ID,
// so the temp-ID record is now orphaned.
if let tempId {                                                      // ← cleanup block
    try await cipherService.deleteCipherWithLocalStorage(id: tempId)
}

if let recordId = pendingChange.id {
    try await pendingCipherChangeDataStore.deletePendingChange(id: recordId)
}
```

The sequence after the fix:
1. Decode pending cipher data → `Cipher` with temp ID
2. Capture `tempId = cipher.id` before the server call
3. `addCipherWithServer()` — uploads to server, server assigns real ID, creates new `CipherData` with server ID
4. **NEW:** `deleteCipherWithLocalStorage(id: tempId)` — removes old `CipherData` with temp ID
5. `deletePendingChange(id:)` — removes the pending change record

**Impact on RES-1:** The temp-ID cleanup step adds a new potential failure point. If `addCipherWithServer` succeeds but `deleteCipherWithLocalStorage(id: tempId)` fails, the orphan temp-ID record remains but the server cipher was already created. The duplicate-on-retry risk in [AP-RES1](ActionPlans/AP-RES1_DuplicateCipherOnCreateRetry.md) is unchanged. The recommendation (accept risk) remains valid.

#### Test Coverage

**Standard create test (updated):**

```swift
func test_processPendingChanges_create() async throws {
    // ... existing setup ...
    try await subject.processPendingChanges(userId: "1")

    XCTAssertEqual(cipherService.addCipherWithServerCiphers.count, 1)
    // The old cipher record with the temp ID should be deleted
    XCTAssertEqual(cipherService.deleteCipherWithLocalStorageId, "cipher-1")
    XCTAssertEqual(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.count, 1)
}
```

**Nil-ID edge case test (new):**

```swift
/// Cipher with no ID does not attempt local delete (no temp ID to clean up).
func test_processPendingChanges_create_nilId_skipsLocalDelete() async throws {
    let cipherResponseModel = CipherDetailsResponseModel.fixture(id: nil)
    // ... setup with nil-ID cipher ...
    try await subject.processPendingChanges(userId: "1")

    XCTAssertEqual(cipherService.addCipherWithServerCiphers.count, 1)
    XCTAssertNil(cipherService.deleteCipherWithLocalStorageId)  // No temp ID to clean up
    XCTAssertEqual(pendingCipherChangeDataStore.deletePendingChangeByIdCalledWith.count, 1)
}
```

---

### 16.7 Additional Minor Changes

**VaultRepositoryTests UserId assertion fix:** A pre-existing test assertion was corrected from `"13512467-9cfe-43b0-969f-07534084764b"` to `"1"` to match the `Account.fixture()` default user ID.

**CoreData import:** `VaultRepositoryTests.swift` gained `import CoreData` because the new tests create `PendingCipherChangeData` instances directly using Core Data's `NSManagedObject` initializer.

---

### 16.8 End-to-End Scenarios: How the Changes Work Together

#### Scenario A: Create Cipher While Offline → Edit → Sync

```
1. User creates cipher "MyLogin" while offline
   → addCipher(): CipherView(id: nil) → withId("temp-abc") → encrypt()
     → Cipher(id: "temp-abc", data: ✓)
   → handleOfflineAdd(): stores locally, queues PendingCipherChangeData(type: .create)
   → User sees "MyLogin" in vault list ✓ and can view it in detail view ✓

2. User edits "MyLogin" while still offline (changes password)
   → updateCipher(): encrypt() → Cipher(id: "temp-abc", data: ✓)
   → handleOfflineUpdate(): existing?.changeType == .create → changeType = .create (preserved!)
   → PendingCipherChangeData updated (cipherData updated, type stays .create)

3. Connectivity restored, sync triggers
   → offlineSyncResolver.processPendingChanges()
   → resolveCreate(): decode → Cipher(id: "temp-abc")
   → addCipherWithServer(cipher) → server creates with ID "server-xyz"
   → deleteCipherWithLocalStorage(id: "temp-abc") → removes orphan
   → deletePendingChange(id:) → cleans up pending record
   → Full sync proceeds normally
```

#### Scenario B: Create Cipher While Offline → Delete Before Sync

```
1. User creates cipher "Mistake" while offline
   → Stored locally with temp-ID, pending .create

2. User deletes "Mistake" while still offline
   → deleteCipherWithServer() fails → offline fallback
   → handleOfflineDelete(): fetchPendingChange returns .create type
   → deleteCipherWithLocalStorage("temp-abc") → cipher removed
   → deletePendingChange(id:) → pending record removed
   → Return (no .softDelete queued — nothing to delete on server)

3. Connectivity restored
   → No pending changes → normal full sync proceeds
```

#### Scenario C: Create Cipher While Offline → Sync Resolves ID

```
1. Cipher stored as CipherData(id: "temp-abc", modelData: <encrypted>)

2. Sync resolves the pending create
   → addCipherWithServer() → server responds with ID "server-xyz"
   → Creates CipherData(id: "server-xyz", modelData: <server-encrypted>)
   → deleteCipherWithLocalStorage("temp-abc") → orphan cleanup
   → Only CipherData(id: "server-xyz") remains in Core Data
```

---

### 16.9 Action Plan Status Changes

| Issue | Previous Status | New Status | Details |
|-------|----------------|------------|---------|
| **[VI-1](ActionPlans/Resolved/AP-VI1_OfflineCreatedCipherViewFailure.md)** | Open (Medium) | **Resolved** — moved to `Resolved/` | Root cause eliminated: temp ID before encryption ensures normal decrypt |
| **[CS-2](ActionPlans/AP-CS2_FragileSDKCopyMethods.md)** | Open (Low) | Updated — scope reduced | `Cipher.withTemporaryId` deleted; only `CipherView.withId` and `.update` remain |
| **[RES-1](ActionPlans/AP-RES1_DuplicateCipherOnCreateRetry.md)** | Open (Informational) | Updated | `resolveCreate` includes temp-ID cleanup; adds failure point but risk unchanged |
| **[S7](ActionPlans/AP-S7_CipherNotFoundPathTest.md)** | Open (Medium) | Updated — expanded code path | New `.create` check precedes guard clause; original test gap remains |
| **[T7](ActionPlans/AP-T7_SubsequentOfflineEditTest.md)** | Open (Low) | Partially addressed | `preservesCreateType` covers `.create` → `.create`; `.update` → `.update` untested |

---

### 16.10 Commit History

The fix was developed iteratively across 11 commits, with the final approach emerging through investigation and refinement:

| Commit | Description | Significance |
|--------|-------------|-------------|
| `06456bc` | Add investigation tests for offline spinner bug | Diagnostic tests to reproduce and understand VI-1 |
| `ce48a28` | Fix @MainActor annotation on createSubject helper | Test infrastructure fix for investigation |
| `de2b978` | Fix nil-ID test to not use waitFor for expected-untransitioned state | Test technique improvement |
| `8ff7a09` | Fix offline cipher spinner bug and temp-ID cleanup | Initial fix: `resolveCreate` temp-ID cleanup, offline-created deletion |
| `08a2fed` | Set error state directly instead of redundant re-fetch | Simplified error handling in `streamCipherDetails` |
| `bd7e443` | Preserve cipher ID through decrypt for offline-created ciphers | Intermediate approach (later superseded by `3f7240a`) |
| `f3e02fc` | Remove defensive else branch from streamCipherDetails | Cleanup: removed unnecessary fallback |
| `3f7240a` | **Assign temp ID before encryption for offline-created ciphers** | **Core fix**: `CipherView.withId()` replaces `Cipher.withTemporaryId()` |
| `eda008b` | Fix fixture argument order in CipherViewOfflineSyncTests | Test cleanup after type change |
| `12cb225` | Prevent server fetch of temp-ID ciphers during offline sync | `.create` preservation + offline-created cleanup |
| `53e08ef` | Add test coverage for resolveCreate temp-ID cleanup | Nil-ID edge case test |
| `d191eb6` | Merge pull request #35 | Final merge into dev |

---

## 17. Conclusion

The offline sync implementation is architecturally sound, follows project conventions, maintains the zero-knowledge security model, and provides robust data loss prevention. The code is well-documented, well-tested (40+ new tests across the original implementation and subsequent fixes), and introduces no new external dependencies or problematic cross-domain coupling.

The most significant design choice — the early-abort sync pattern — is the correct tradeoff: it prioritizes data safety (never overwriting unsynced local edits) over freshness (users with unresolvable pending changes won't receive server updates until those are cleared). This is consistent with Bitwarden's security-first philosophy.

The VI-1 fix (Section 16) demonstrates good engineering practice: rather than adding defensive workarounds, the root cause was identified and eliminated through an architectural adjustment. The temp-ID-before-encryption approach ensures offline-created ciphers are structurally identical to server-created ciphers, removing an entire class of edge-case bugs.

**Primary areas for improvement:**
1. Additional test coverage for batch processing and error paths in the resolver (S3, S4)
2. ~~Evaluation of whether `.secureConnectionFailed` should trigger offline mode (SEC-1)~~ **[Superseded]** — resolved by error handling simplification
3. Consider a feature flag for production safety (S8)
4. ~~Offline-created cipher fails to load in detail view (VI-1)~~ **[Resolved]** — Root cause eliminated by moving temp-ID assignment before encryption (PR #35)

None of these are blocking issues. The implementation is ready for merge consideration with the understanding that the identified test gaps should be tracked.

**Resolution history:**
- SEC-1 superseded by error handling simplification (URLError extension deleted)
- VI-1 resolved by architectural fix (temp-ID before encryption, PR #35)
- 6 action plans now in Resolved: A3, CS-1, SEC-1, EXT-1, T6, VI-1
