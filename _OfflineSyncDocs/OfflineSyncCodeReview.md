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

**~~Issue A3~~ [Resolved] — `timeProvider` removed.** See [AP-A3](ActionPlans/Resolved/AP-A3_UnusedTimeProvider.md).

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

**~~Issue CS-1~~ [Resolved] — Stray blank line removed.** See [AP-CS1](ActionPlans/Resolved/AP-CS1_StrayBlankLine.md).

**[Updated note]** The `URLError+NetworkConnection.swift` file has been deleted. See [AP-URLError_NetworkConnectionReview.md](ActionPlans/Superseded/AP-URLError_NetworkConnectionReview.md). Error handling simplified to plain `catch` blocks.

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
| T4 | `VaultRepository` | `handleOfflineDelete` cipher-not-found path not tested — `fetchCipher(withId:)` returning nil leads to silent return | Low | **[Partially Resolved]** Resolver-level 404 tests added (RES-2 fix, commit `e929511`). VaultRepository-level `handleOfflineDelete` not-found test gap remains. See [AP-S7](ActionPlans/Resolved/AP-S7_CipherNotFoundPathTest.md). |
| T5 | `OfflineSyncResolverTests` | Inline `MockCipherAPIServiceForOfflineSync` implements full protocol with `fatalError()` stubs for 15 unused methods — fragile against protocol changes | Low |
| ~~T6~~ | ~~`URLError+NetworkConnection`~~ | ~~Only 3 of 10 positive error codes tested~~ **[Resolved]** See [AP-T6](ActionPlans/Resolved/AP-T6_IncompleteURLErrorTestCoverage.md). | ~~Low~~ N/A |
| ~~T7~~ | ~~`VaultRepository`~~ | ~~No test for `handleOfflineUpdate` with existing pending record (subsequent offline edit scenario)~~ | ~~Low~~ | **[Resolved]** Covered by `test_updateCipher_offlineFallback_preservesCreateType` (commit `12cb225`). See [AP-T7](ActionPlans/Resolved/AP-T7_SubsequentOfflineEditTest.md). |
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

**~~Issue SEC-1~~ [Superseded]** — URLError extension deleted; all API errors trigger offline save. See [AP-SEC1](ActionPlans/Resolved/AP-SEC1_SecureConnectionFailedClassification.md).

**Observation SEC-2 — Pending data survives vault lock.** `PendingCipherChangeData` is stored in Core Data alongside other vault data. The `cipherData` field contains SDK-encrypted JSON, so it's protected by the vault encryption key. The metadata fields are unencrypted, consistent with existing `CipherData`.

**Observation SEC-3 — Pending changes cleaned up on user data deletion.** `DataStore.deleteDataForUser(userId:)` includes `PendingCipherChangeData.deleteByUserIdRequest` in the batch delete, ensuring pending changes are properly removed on logout or account deletion.

---

## 7. Reliability Considerations

### 7.1 Error Handling

| Scenario | Handling | Assessment |
|---------|---------|-----------|
| Any server API failure during cipher operation | **[Updated]** Plain `catch` falls back to offline save | **Good** — The encrypt step occurs outside the do-catch, so SDK encryption errors propagate normally. Only server API call failures are caught. The networking stack separates transport errors from HTTP errors at a different layer, so fine-grained URLError filtering was unnecessary. |
| ~~Non-network error during cipher operation~~ | ~~Rethrows normally~~ | **[Superseded]** Error handling evolved to denylist pattern (PRs #26, #28). See Phase 2 review §2.2. |
| Single pending change resolution fails | `OfflineSyncResolver` logs error via `Logger.application`, continues to next | **Good** — One failure doesn't block others |
| Unresolved pending changes after resolution | SyncService aborts sync, returns early | **Good** — Prevents `replaceCiphers` from overwriting local offline edits |
| Resolver `processPendingChanges` throws hard error | Error propagates through `fetchSync` — entire sync fails | **Acceptable** — If the store is unreadable, sync should not proceed |
| Detail view publisher stream error (e.g., `decrypt()` failure) | ~~`asyncTryMap` terminates publisher; catch block logs error only~~ **[Fixed]** `ViewItemProcessor` catches publisher errors and calls `fetchCipherDetailsDirectly()` fallback | **[Resolved]** Root cause (`Cipher.withTemporaryId()` producing `data: nil`) **fixed** — replaced by `CipherView.withId()` operating before encryption (commit `3f7240a`). Symptom (infinite spinner) mitigated by fallback fetch (PR #31). See Phase 2 §2.1, [AP-VI1](ActionPlans/AP-VI1_OfflineCreatedCipherViewFailure.md). |

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

~~**Issue R2 (Low) — `conflictFolderId` thread safety:** `DefaultOfflineSyncResolver.conflictFolderId` is a mutable `var` on a class with no `actor` isolation. Currently safe due to sequential calling pattern, but fragile if ever called concurrently.~~ **[Resolved]** `DefaultOfflineSyncResolver` converted from `class` to `actor`. See [AP-R2](ActionPlans/AP-R2_ConflictFolderIdThreadSafety.md).

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
| Viewing offline-created item | ~~Infinite spinner, item never loads~~ **[Resolved]** Item loads normally | **[Resolved]** Root cause (`Cipher.withTemporaryId()` producing `data: nil`) **fixed** by `CipherView.withId()` (commit `3f7240a`). Symptom (spinner) mitigated by fallback fetch (PR #31). See Phase 2 §2.1, [AP-VI1](ActionPlans/AP-VI1_OfflineCreatedCipherViewFailure.md). |
| Viewing pending changes status | No UI indicator | **Gap** — User has no awareness of unsynced changes |
| Conflict folder discovery | "Offline Sync Conflicts" folder appears in vault | **Acceptable** — Clear name, but English-only |

### 8.2 Usability Observations

**Observation U1 — Org cipher error timing.** The organization check happens after the network request fails, so the user must wait for the network timeout before seeing the error. Proactive checking would require knowing connectivity state before the API call.

**Observation U2 — Inconsistent offline support across operations.** Add, update, delete, and soft-delete work offline. Archive, unarchive, collection assignment, and restore do not. Users performing unsupported operations offline get generic errors rather than offline-specific messages.

**Observation U3 — No user-visible pending changes indicator.** Users have no way to see pending offline changes. If resolution continues to fail, the user is unaware their changes haven't been uploaded.

**Observation U4 — Conflict folder name in English only.** "Offline Sync Conflicts" is hardcoded in English, not localized. Non-English users see an English folder name. Localization is complex since the encrypted folder name syncs across devices with potentially different locales.

**Issue VI-1 ~~[Mitigated]~~ [Resolved] — Offline-created cipher view failure.** When a user creates a new cipher while offline, the item appeared in the vault list but failed to load in the detail view (infinite spinner). **Mitigated in PR #31** (fallback fetch in `ViewItemProcessor`). **Root cause fixed in Phase 2:** `Cipher.withTemporaryId()` (which produced `data: nil`) replaced by `CipherView.withId()` operating before encryption (commit `3f7240a`). Offline-created ciphers now encrypt correctly, so the publisher stream no longer fails. The UI fallback remains as defense-in-depth. See Phase 2 §2.1, [AP-VI1](ActionPlans/AP-VI1_OfflineCreatedCipherViewFailure.md).

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
| ~~VI-1~~ | ~~`ViewItemProcessor` / `VaultRepository`~~ | ~~Offline-created cipher fails to load in detail view (infinite spinner)~~ — **[Resolved]** Symptom fixed by `fetchCipherDetailsDirectly()` fallback (PR #31). Root cause (`data: nil` in `Cipher.withTemporaryId()`) **fixed** by `CipherView.withId()` (commit `3f7240a`). All 5 recommended fixes implemented in Phase 2. | [AP-VI1](ActionPlans/AP-VI1_OfflineCreatedCipherViewFailure.md) |
| S6 | `VaultRepositoryTests` | `handleOfflineUpdate` password change counting not directly tested | [VR](ReviewSection_VaultRepository.md) |
| S8 | Feature | Consider adding a feature flag for production safety | Section 12.3 |

### Low Priority

| ID | Component | Issue | Detailed Section |
|----|-----------|-------|-----------------|
| CS-2 | `CipherView+OfflineSync` | `withTemporaryId`/`update` fragile against SDK type changes | Section 3.1 |
| R1 | `PendingCipherChangeData` | No data format versioning for `cipherData` JSON | Section 7.3 |
| ~~R2~~ | ~~`OfflineSyncResolver`~~ | ~~`conflictFolderId` thread safety (class with mutable var, no actor isolation)~~ **[Resolved]** — Converted to `actor` | [AP-R2](ActionPlans/AP-R2_ConflictFolderIdThreadSafety.md) |
| R3 | `OfflineSyncResolver` | No retry backoff for permanently failing resolution items | Section 7.3 |
| R4 | `SyncService` | Silent sync abort (no logging) | [SS-3](ReviewSection_SyncService.md) |
| DI-1 | `Services.swift` | `HasPendingCipherChangeDataStore` exposes data store to UI layer (broader than needed) | [DI-1](ReviewSection_DIWiring.md) |

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

## 16. Post-Review Code Changes on `dev`

**[Updated 2026-02-16]** After the initial code review, several post-review fixes were merged to `dev` through PRs #26–#33. This section documents all code changes on the `dev` branch, organized by functional grouping.

### 16.1 Error Handling Evolution (PRs #26, #28)

The error handling in the offline fallback catch blocks evolved through three stages:

**Stage 1 (Original):** URLError allowlist
```swift
catch let error as URLError where error.isNetworkConnectionError {
    // handle offline
}
```

**Stage 2 (Simplification commit `e13aefe`):** Bare catch
```swift
catch {
    // handle offline — all errors trigger save
}
```

**Stage 3 (PRs #26, #28):** Denylist pattern (current state on dev)
```swift
} catch let error as ServerError {
    throw error
} catch let error as ResponseValidationError where error.response.statusCode < 500 {
    throw error
} catch let error as CipherAPIServiceError {
    throw error
} catch {
    // All other errors trigger offline save
}
```

**PR #26 (Commit `207065c`):** Fixed 5xx HTTP errors not triggering offline save. When CDN/proxy layers (e.g., Cloudflare) returned HTTP 502, they threw `ResponseValidationError`, which wasn't caught by the bare `catch` approach (it was, but then PR #26 added the `< 500` discriminator to rethrow 4xx while catching 5xx).

**PR #28 (Commit `7ff2fd8`):** Added `CipherAPIServiceError` to the rethrow list. Client-side validation errors (e.g., `updateMissingId`) are programming errors that should propagate to the caller, not silently trigger offline save.

**Impact:** The denylist pattern is more resilient than the original allowlist. Unknown error types automatically trigger offline save rather than propagating as unhandled errors. The only errors rethrown are:
- `ServerError` — API-level errors the caller should handle
- `ResponseValidationError` with status < 500 — client errors (4xx) that indicate a problem with the request, not connectivity
- `CipherAPIServiceError` — client-side validation errors indicating bugs

### 16.2 Test Coverage Improvements (PR #27)

**Commits `481ddc4`, `578a366`**

PR #27 closed several test coverage gaps identified in the original review:

| Test File | Tests Added | What They Verify |
|-----------|------------|-----------------|
| `CipherServiceTests.swift` | URLError propagation tests | `URLError` flows through `CipherService` → `APIService` → `HTTPService` chain correctly |
| `AddEditItemProcessorTests.swift` | Network error alert tests | User sees proper error alert when offline fallback fails |
| Both files | Non-network error rethrow tests | `CipherAPIServiceError` and `ServerError` propagate rather than triggering offline save |

These tests partially address Deep Dive 7 (narrow error coverage) from the original review.

### 16.3 Conflict Folder Encryption Fix (PR #29)

**Commit `266bffa`**

**Bug:** `getOrCreateConflictFolder()` in `OfflineSyncResolver` was passing the plaintext string `"Offline Sync Conflicts"` directly to `folderService.addFolderWithServer(name:)`. The `addFolderWithServer` method expects an *encrypted* folder name. The server stored the plaintext, and when the SDK later tried to decrypt the folder name during a folder fetch, it panicked (Rust panic) because plaintext is not valid ciphertext.

**Fix:** Encrypt the folder name via `clientService.vault().folders().encrypt()` before sending:

```swift
// Before (CRASH — plaintext folder name)
let newFolder = try await folderService.addFolderWithServer(name: folderName)

// After (FIXED — encrypted)
let folderView = FolderView(id: nil, name: folderName, revisionDate: Date.now)
let encryptedFolder = try await clientService.vault().folders().encrypt(folder: folderView)
let newFolder = try await folderService.addFolderWithServer(name: encryptedFolder.name)
```

This follows the same encryption pattern used in `SettingsRepository.addFolder()`.

### 16.4 VI-1 Mitigation — Direct Fetch Fallback (PR #31)

**Commits `86b9104`, `01070eb`**

**The bug (VI-1):** When a user created a new cipher while offline, the item appeared in the vault list but showed an infinite spinner in the detail view. The cipher could never be viewed until sync resolved the pending change.

**Root cause:** `Cipher.withTemporaryId()` sets `data: nil` on the copy. The `data` field contains the raw encrypted content needed for decryption. When `ViewItemProcessor.streamCipherDetails()` calls `asyncTryMap { try await decrypt($0) }`, the `decrypt()` call fails because `data` is nil. The publisher's `asyncTryMap` terminates on the first error, leaving the detail view in a permanent loading state.

**Approach taken on dev:** UI-level fallback rather than root cause fix. Two changes in `ViewItemProcessor`:

1. **Extracted `buildViewItemState(from:)` helper** from the existing `buildState(for:)` method, making the state-building logic reusable.

2. **Added `fetchCipherDetailsDirectly()` fallback** in the `streamCipherDetails()` catch block:

```swift
/// Attempts to fetch and display cipher details directly from the data store
/// as a fallback when the cipher details publisher stream fails.
private func fetchCipherDetailsDirectly() async {
    do {
        guard let cipher = try await services.vaultRepository.fetchCipher(withId: itemId),
              let newState = try await buildViewItemState(from: cipher)
        else {
            state.loadingState = .error(errorMessage: Localizations.anErrorHasOccurred)
            return
        }
        state = newState
    } catch {
        services.errorReporter.log(error: error)
        state.loadingState = .error(errorMessage: Localizations.anErrorHasOccurred)
    }
}
```

When the publisher stream fails (e.g., decrypt error from `data: nil`), the fallback:
1. Catches the error and logs it
2. Calls `fetchCipher(withId:)` which uses `try?` for resilient decryption
3. If successful: displays the item normally via `buildViewItemState`
4. If failed: shows an error message (not an infinite spinner)

~~**What this does NOT fix (root cause remains):**~~
~~- `Cipher.withTemporaryId()` still sets `data: nil` — the VI-1 root cause~~
~~- The publisher stream still fails on first try for offline-created ciphers~~
~~- The fallback adds latency (two fetch attempts instead of one)~~
~~- Related edge cases remain (see 16.7)~~

**[UPDATE — All Fixed in Phase 2]:** Root cause `Cipher.withTemporaryId()` replaced by `CipherView.withId()` (commit `3f7240a`). Publisher stream no longer fails for offline-created ciphers since encryption data is intact. All edge cases from §16.7 resolved. The UI fallback remains as defense-in-depth.

### 16.5 Orphaned Pending Change Cleanup

**Commit `dd3bc38`**

**Problem:** After a successful online save (e.g., `addCipherWithServer` succeeds), leftover `PendingCipherChangeData` records from prior offline attempts remained in Core Data. On the next sync, `processPendingChanges()` would find these orphans and attempt resolution, potentially creating false conflicts and unnecessary backup copies.

**Fix:** After each successful server operation, clean up any orphaned pending change record:

```swift
// In addCipher() — after successful server add
try await cipherService.addCipherWithServer(...)
if let cipherId = cipherEncryptionContext.cipher.id {
    try await pendingCipherChangeDataStore.deletePendingChange(
        cipherId: cipherId,
        userId: cipherEncryptionContext.encryptedFor
    )
}
```

This pattern was added to all four operations: `addCipher`, `updateCipher`, `deleteCipher`, `softDeleteCipher`.

**SyncService optimization:** A count check was added so the common case (no pending changes) skips `processPendingChanges()` entirely.

### 16.6 Test Assertion Fix (PR #33)

**Commit `a10fe15`**

Fixed `test_softDeleteCipher_pendingChangeCleanup` — userId assertion was `"1"` but should have been `"13512467-9cfe-43b0-969f-07534084764b"` to match `fixtureAccountLogin()`.

### 16.7 Remaining Gaps from Original Review ~~(Not Fixed on `dev`)~~ **[All Fixed in Phase 2]**

The following issues from the original review and VI-1 investigation ~~are **not addressed on `dev`**~~ have been **resolved in Phase 2** (see [Phase 2 Code Review](OfflineSyncCodeReview_Phase2.md)):

| Issue | Description | Impact | Status |
|-------|-------------|--------|--------|
| ~~**VI-1 root cause**~~ | ~~`Cipher.withTemporaryId()` sets `data: nil`, causing decryption failures~~ | ~~Mitigated by UI fallback, but root cause remains~~ | **[FIXED]** Commit `3f7240a` — replaced `Cipher.withTemporaryId()` with `CipherView.withId()` operating before encryption. See Phase 2 §2.1. |
| ~~**`.create` type not preserved**~~ | ~~`handleOfflineUpdate()` always overwrites pending change type to `.update`~~ | ~~Editing offline-created cipher before sync fails~~ | **[FIXED]** Commit `12cb225` — `handleOfflineUpdate` now preserves `.create` type. See Phase 2 §2.4. |
| ~~**Offline-created deletion not cleaned up**~~ | ~~`handleOfflineDelete()`/`handleOfflineSoftDelete()` queue `.softDelete` for temp-ID ciphers~~ | ~~Deleting offline-created cipher before sync fails~~ | **[FIXED]** Commit `12cb225` — offline-created ciphers are now deleted locally without queuing a server operation. See Phase 2 §2.5. |
| ~~**Temp-ID record not cleaned up in `resolveCreate()`**~~ | ~~After `addCipherWithServer()` succeeds, old temp-ID record is orphaned~~ | ~~Minor: stale data until next full sync~~ | **[FIXED]** Commits `8ff7a09`, `53e08ef` — `resolveCreate()` now deletes the temp-ID cipher record after successful server creation. See Phase 2 §2.6. |
| ~~**No test for subsequent offline edit** (T7)~~ | ~~`handleOfflineUpdate` with existing pending record is untested~~ | ~~Test gap~~ | **[RESOLVED]** Covered by `test_updateCipher_offlineFallback_preservesCreateType` (commit `12cb225`). See [AP-T7](ActionPlans/Resolved/AP-T7_SubsequentOfflineEditTest.md). |

~~**Recommended root cause fix:** Replace `Cipher.withTemporaryId()` with `CipherView.withId()` that operates *before* encryption (on the decrypted type). This eliminates the `data: nil` problem because `CipherView` doesn't have a `data` field. The ID would be baked into the encrypted content, making offline-created ciphers structurally identical to server-created ciphers. This would also address the `.create` type preservation and offline-created deletion cleanup as prerequisites.~~ **[DONE]** All recommended fixes implemented in Phase 2: `CipherView.withId()` (commit `3f7240a`), `.create` type preservation (commit `12cb225`), offline-created deletion cleanup (commit `12cb225`), temp-ID record cleanup (commits `8ff7a09`, `53e08ef`).

### 16.8 Action Plan Status Updates

| Issue | Status | Details |
|-------|--------|---------|
| **[VI-1](ActionPlans/AP-VI1_OfflineCreatedCipherViewFailure.md)** | ~~Mitigated~~ **Resolved** | Spinner fixed via UI fallback (PR #31). Root cause (`data: nil` from `Cipher.withTemporaryId()`) **fixed** in Phase 2: `CipherView.withId()` replaces `Cipher.withTemporaryId()` (commit `3f7240a`). |
| **[CS-2](ActionPlans/AP-CS2_FragileSDKCopyMethods.md)** | Open (Low) | **Updated** — `Cipher.withTemporaryId()` removed, but fragile copy pattern now applies to `CipherView.withId(_:)` and `CipherView.update(name:folderId:)`. Same underlying concern. |
| ~~**[RES-1](ActionPlans/AP-RES1_DuplicateCipherOnCreateRetry.md)**~~ | ~~Open (Informational)~~ **Partially Resolved** | Temp-ID cipher record cleanup added to `resolveCreate()` (commits `8ff7a09`, `53e08ef`). Duplicate-on-retry concern (server already has the cipher) still informational. |
| ~~**[S7](ActionPlans/Resolved/AP-S7_CipherNotFoundPathTest.md)**~~ | ~~Open (Medium)~~ **[Partially Resolved]** | Resolver-level 404 tests added (RES-2 fix, commit `e929511`). VaultRepository-level `handleOfflineDelete` not-found test gap remains. |
| ~~**[T7](ActionPlans/Resolved/AP-T7_SubsequentOfflineEditTest.md)**~~ | ~~Open (Low)~~ **[Resolved]** | Covered by `test_updateCipher_offlineFallback_preservesCreateType` (commit `12cb225`). |

---

## 17. Conclusion

The offline sync implementation is architecturally sound, follows project conventions, maintains the zero-knowledge security model, and provides robust data loss prevention. The code is well-documented, well-tested (40+ new tests across the original implementation and subsequent fixes), and introduces no new external dependencies or problematic cross-domain coupling.

The most significant design choice — the early-abort sync pattern — is the correct tradeoff: it prioritizes data safety (never overwriting unsynced local edits) over freshness (users with unresolvable pending changes won't receive server updates until those are cleared). This is consistent with Bitwarden's security-first philosophy.

The post-review fixes on `dev` (Section 16) improved error handling resilience (denylist pattern), fixed a critical encryption bug (conflict folder), and mitigated the VI-1 spinner bug via a UI fallback. ~~However, the VI-1 root cause (`Cipher.withTemporaryId()` setting `data: nil`) remains, along with related edge cases for editing and deleting offline-created ciphers before sync.~~ **[UPDATE]** The VI-1 root cause and all related edge cases have been **fully resolved in Phase 2**: `CipherView.withId()` replaces `Cipher.withTemporaryId()` (commit `3f7240a`), `.create` type preservation (commit `12cb225`), offline-created deletion cleanup (commit `12cb225`), temp-ID record cleanup (commits `8ff7a09`, `53e08ef`). See [Phase 2 Code Review](OfflineSyncCodeReview_Phase2.md).

**Primary areas for improvement:**
1. Additional test coverage for batch processing and error paths in the resolver (S3, S4)
2. ~~Evaluation of whether `.secureConnectionFailed` should trigger offline mode (SEC-1)~~ **[Superseded]** — resolved by error handling simplification
3. Consider a feature flag for production safety (S8)
4. ~~VI-1 root cause fix — replace `Cipher.withTemporaryId()` with `CipherView.withId()` operating before encryption, plus `.create` type preservation and offline-created deletion cleanup~~ **[DONE]** — All implemented in Phase 2: `CipherView.withId()` (commit `3f7240a`), `.create` type preservation (commit `12cb225`), offline-created deletion cleanup (commit `12cb225`), temp-ID record cleanup (commits `8ff7a09`, `53e08ef`)

None of these are blocking issues. The implementation is ready for merge consideration with the understanding that the identified test gaps and the VI-1 root cause should be tracked.

**Resolution history:**
- SEC-1, EXT-1 superseded by error handling simplification (URLError extension deleted)
- A3, CS-1, T6 resolved by code cleanup and deletion
- T7 resolved by `test_updateCipher_offlineFallback_preservesCreateType` (Phase 2)
- S7 partially resolved — resolver-level 404 tests added
- VI-1 **resolved** — UI fallback (PR #31) fixed spinner; root cause (`data: nil`) fixed by `CipherView.withId()` (commit `3f7240a`)
- RES-1 partially resolved — temp-ID cleanup added to `resolveCreate()` (commits `8ff7a09`, `53e08ef`)
- All 5 "remaining gaps" from §16.7 addressed in Phase 2
- 7 action plans in Resolved: A3, CS-1, SEC-1, EXT-1, T6, S7, T7
