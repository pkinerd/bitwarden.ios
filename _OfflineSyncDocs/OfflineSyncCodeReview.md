# Offline Sync Feature - Comprehensive Code Review

## Summary

This changeset implements a client-side offline sync feature for the Bitwarden iOS vault. When network connectivity is unavailable during cipher operations (add, update, delete, soft-delete), the app persists changes locally and queues them for resolution when connectivity is restored. A conflict resolution engine detects server-side changes made while offline and creates backup copies rather than silently discarding data.

**Scope:** 23 source files (10 new, 13 modified) across 142 commits on the `dev` branch from fork point to HEAD. The implementation spans ~3,500 lines of new code and ~600 lines of modifications. The changes include a Phase 1 (core implementation) and Phase 2 (bug fixes, hardening, and consolidation — 13 commits, 7 files, +131/-56 lines).

**Guidelines Referenced (cloned locally to `/home/user/bitwarden.contributing-docs/`):**
- **Swift code style:** `docs/contributing/code-style/swift.md` — MARK section ordering, DocC requirements, naming conventions, alphabetization, 120-char line limit, SwiftLint/SwiftFormat compliance
- **iOS architecture:** `docs/architecture/mobile-clients/ios/index.md` — Core/UI split, Services/Repositories/Coordinators/Processors, `ServiceContainer` DI, `HasService` protocols, unidirectional data flow
- **Testing guidelines:** `docs/architecture/mobile-clients/ios/index.md` (testing section) + project `Docs/Testing.md` — every type with logic must be tested, test file co-location, `BitwardenTestCase`, setUp/tearDown lifecycle, `Mock<Name>` conventions
- **Security principles:** `docs/architecture/security/` — P01 (zero-knowledge/servers never see plaintext), P02 (locked vault is secure), vault data requirements (VD: at-rest encryption, in-use minimization, in-transit protection), encryption key requirements (EK), no new crypto in Swift (use SDK)
- **Cryptography guide:** `docs/architecture/cryptography/crypto-guide.md` — content-encryption-keys, key wrapping, no rolling custom crypto
- **General contributing:** `docs/contributing/index.md` — PR guidelines, contributor agreement
- **Project-specific:** `.claude/CLAUDE.md`

**Detailed section documents (per-component deep dives):**
- [ReviewSection_PendingCipherChangeDataStore.md](ReviewSection_PendingCipherChangeDataStore.md) — Core Data entity, data store, schema changes
- [ReviewSection_OfflineSyncResolver.md](ReviewSection_OfflineSyncResolver.md) — Conflict resolution engine
- [ReviewSection_VaultRepository.md](ReviewSection_VaultRepository.md) — Offline fallback handlers in repository
- [ReviewSection_SyncService.md](ReviewSection_SyncService.md) — Pre-sync resolution and early-abort logic
- [ReviewSection_SupportingExtensions.md](ReviewSection_SupportingExtensions.md) — ~~URLError detection~~ (removed), Cipher copy helpers
- [ReviewSection_DIWiring.md](ReviewSection_DIWiring.md) — ServiceContainer, Services.swift, DataStore cleanup
- [ReviewSection_TestChanges.md](ReviewSection_TestChanges.md) — Test infrastructure improvements and coverage analysis

**Companion review:** [OfflineSyncCodeReview_Phase2.md](OfflineSyncCodeReview_Phase2.md) — Detailed analysis of the Phase 2 bug fixes and improvements (30+ commits covering temp-ID before encryption, error type filtering, `.create` type preservation, offline-created deletion cleanup, temp-ID record cleanup, ViewItemProcessor fallback, and SyncService pre-check optimization)

### High-Level Architecture

```
User Action → VaultRepository (denylist catch — rethrow client errors, catch all others)
                  ↓
              Offline Handler → PendingCipherChangeDataStore
                  ↓ (on success path, clean up orphaned pending changes)
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

*Example: updateCipher path. addCipher, deleteCipher, and softDeleteCipher follow analogous patterns with operation-specific variations noted below.*

```
1. User edits a cipher in the UI
2. Processor calls VaultRepository.updateCipher(cipherView)
3. VaultRepository encrypts the CipherView via SDK → EncryptionContext (contains encrypted Cipher + userId)
4. VaultRepository attempts cipherService.updateCipherWithServer(encrypted)
   - On success: cleans up any orphaned pending change from a prior offline save,
     then returns normally
5. API call fails — denylist catch pattern applies:
   - ServerError → rethrown (API-level errors)
   - ResponseValidationError with status < 500 → rethrown (client 4xx errors)
   - CipherAPIServiceError → rethrown (client-side validation bugs)
   - All other errors → fall through to offline save (step 6)
6. VaultRepository catches the error (handleOfflineUpdate):
   a. Checks cipher is not org-owned (throws if it is)
   b. Saves encrypted cipher to local Core Data (cipherService.updateCipherWithLocalStorage)
   c. Encodes encrypted cipher as JSON (CipherDetailsResponseModel)
   d. Detects password changes (decrypt + compare, in-memory only)
   e. Preserves .create type if cipher was originally created offline (Phase 2 fix)
   f. Upserts PendingCipherChangeData record (cipherId, userId, encrypted JSON, revision date)
7. Operation returns success to UI — user sees their edit applied locally
```

*Operation-specific variations:*
- **addCipher:** Before encryption, assigns a temporary client-side ID via `CipherView.withId(UUID().uuidString)` so it's baked into the encrypted content. Uses `handleOfflineAdd` which queues a `.create` pending change.
- **deleteCipher:** No encryption step (ID only). `handleOfflineDelete` fetches the existing encrypted cipher from local storage, checks org ownership, and queues a `.hardDelete`. **[Updated]** Changed from `.softDelete` to `.hardDelete` to honor the user's permanent delete intent — the resolver calls the permanent delete API when no conflict exists, or restores the server version on conflict. **[Phase 2]** If the cipher was created offline (existing pending change has `.create` type), cleans up locally instead of queuing a server operation.
- **softDeleteCipher:** Encrypts the soft-deleted cipher. `handleOfflineSoftDelete` queues a `.softDelete`. **[Phase 2]** Same offline-created cipher cleanup as deleteCipher.

**Flow 2: Sync Resolution (connectivity restored)**
```
1. Existing sync trigger fires (periodic timer, app foreground, pull-to-refresh)
2. SyncService.fetchSync() called
3. Pre-sync check:
   a. Is vault locked? → Yes: skip resolution
   b. Pre-count check: pendingChangeCount → If 0: skip resolution (optimization)
   c. Attempt resolution: offlineSyncResolver.processPendingChanges(userId) — resolver is
      only called when pending changes exist (pre-count check).
   d. Post-resolution count check → If > 0: ABORT sync (protect local data)
4. For each pending change, resolver:
   a. .create: push new cipher to server, delete old temp-ID cipher record from local
      Core Data (server assigns a new ID), delete pending record
   b. .update: fetch server version via cipherAPIService.getCipher(withId:)
      - Server returns 404 (cipherNotFound): re-create cipher on server to preserve
        offline edits, delete pending record
      - No conflict, <4 pw changes: push local to server
      - No conflict, ≥4 pw changes: push local, create backup of server version
      - Conflict (revisionDates differ), local newer: push local, backup server version
      - Conflict, server newer: keep server, backup local version
   c. .softDelete / .hardDelete: fetch server version
      - Server returns 404 (cipherNotFound): clean up local record, delete pending record
      - No conflict: .softDelete → soft-delete on server; .hardDelete → permanent delete on server
      - Conflict: restore server version locally, drop pending delete (user can review)
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
  └─ ~~folderService (FolderService) [existing]~~ [REMOVED — conflict folder eliminated]
  └─ pendingCipherChangeDataStore (PendingCipherChangeDataStore) [NEW]
  └─ stateService (StateService) [existing, UNUSED — userId passed as parameter instead]
```

No circular dependencies detected. All new services flow into the existing service graph correctly.

### 1.3 Cross-Domain/Cross-Component Dependencies

**Assessment: No problematic new cross-domain dependencies introduced.**

| New Dependency | From | To | Assessment |
|----------------|------|-----|-----------|
| `PendingCipherChangeDataStore` | `VaultRepository` | `DataStore` | Same domain (Vault → Platform/Stores) — follows existing patterns (e.g., CipherData) |
| `PendingCipherChangeDataStore` | `SyncService` | `DataStore` | Same domain — follows existing SyncService-to-DataStore pattern |
| ~~`OfflineSyncResolver` → `FolderService`~~ | ~~Vault/Services~~ | ~~Vault/Services~~ | ~~Same domain — creating a folder for conflict backups~~ **[Removed]** — Conflict folder eliminated |
| `OfflineSyncResolver` → `CipherAPIService` | Vault/Services | Vault/Services | Same domain — fetching server cipher state |

The `OfflineSyncResolver` has 5 injected services (reduced from 6 after `folderService` removal), though `stateService` is currently unused — `userId` is passed as a parameter to `processPendingChanges(userId:)` instead. The remaining 4 active dependencies are all within the Vault/Platform domain and are cohesive with the resolver's responsibility. No cross-domain coupling is introduced (e.g., Auth ↔ Vault, Tools ↔ Vault).

**Removed cross-domain dependency (positive):** The simplification removed a `ConnectivityMonitor` dependency that would have imported `Network.framework` and an `AccountAPIService` dependency for health checking, both of which were cross-cutting.

### 1.4 Architectural Observations

**Observation A1 — Early-abort sync pattern:** SyncService uses an early-abort pattern: if pending offline changes exist, it attempts to resolve them first. If any remain unresolved (e.g. server unreachable), the sync is aborted entirely to prevent `replaceCiphers` from overwriting local offline edits. This is simpler and safer than the alternative of proceeding with sync and re-applying changes afterward.

**Observation A2 — `OfflineSyncResolver` has 5 injected but 4 active dependencies:** **[Updated]** Reduced from 6 after removing `folderService`. `stateService` is injected (`OfflineSyncResolver.swift:78,95`) but **never called** — `userId` is passed as a parameter from `SyncService` instead. The 4 active dependencies (`cipherAPIService`, `cipherService`, `clientService`, `pendingCipherChangeDataStore`) reflect the resolver's cross-cutting responsibility (reading ciphers, uploading to API, managing pending state). The responsibility is cohesive, so the dependency count is acceptable. **Recommendation:** Remove `stateService` from `DefaultOfflineSyncResolver`'s initializer and stored properties — it adds unnecessary coupling and violates the principle of injecting only what is used. This is a ~5-line cleanup with no behavioral change.

**~~Issue A3~~ [Resolved] — `timeProvider` removed.** See [AP-A3](ActionPlans/Resolved/AP-A3_UnusedTimeProvider.md).

**Observation A4 — `GetCipherRequest` modified for 404 handling:** `GetCipherRequest.validate(_:)` (`BitwardenShared/Core/Vault/Services/API/Cipher/Requests/GetCipherRequest.swift:28`) was added to throw `OfflineSyncError.cipherNotFound` when the server returns HTTP 404. This allows the resolver's `resolveUpdate` and `resolveSoftDelete` methods to catch the not-found case and handle it gracefully (re-create for updates, clean up locally for soft-deletes). This couples a general-purpose API request type to offline sync error semantics — the request now imports and throws `OfflineSyncError` directly.

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

### 2.3 Contributing Guidelines Compliance Matrix

The following table verifies compliance against each relevant guideline from the cloned `bitwarden.contributing-docs` repository (`docs/contributing/code-style/swift.md`):

| Guideline | Compliance | Evidence |
|-----------|-----------|---------|
| **120-char line limit** | **Pass** | SwiftLint enforced; no violations observed in new files |
| **4-space indent** | **Pass** | Consistent across all new files |
| **Trailing whitespace trimmed** | **Pass** | SwiftLint enforced |
| **MARK comments with dividers** | **Pass** | All new files use `// MARK: - SectionName` pattern with dividers |
| **MARK section ordering (Properties → Init → Methods)** | **Pass** | `OfflineSyncResolver.swift`: Properties → Initialization → OfflineSyncResolver → Private. `PendingCipherChangeDataStore.swift`: Protocol methods → Extension implementation. `CipherView+OfflineSync.swift`: Public methods → Private section. |
| **DocC on all public symbols** | **Pass** | Every public protocol, class, method, property, and enum case has DocC. Parameter lists and return values documented. |
| **DocC skipped for protocol implementations** | **Pass** | `DataStore` extension methods implementing `PendingCipherChangeDataStore` are not redundantly documented |
| **DocC skipped for mocks** | **Pass** | `MockOfflineSyncResolver`, `MockPendingCipherChangeDataStore`, `MockCipherAPIServiceForOfflineSync` have no DocC |
| **Alphabetization within MARK sections** | **Pass** | Properties and methods alphabetically ordered within each section |
| **UpperCamelCase for types** | **Pass** | `DefaultOfflineSyncResolver`, `PendingCipherChangeData`, `PendingCipherChangeType`, `OfflineSyncError` |
| **lowerCamelCase for properties/methods** | **Pass** | `pendingCipherChangeDataStore`, `handleOfflineUpdate`, `processPendingChanges`, `createBackupCipher` |
| **Verb phrases for side-effect methods** | **Pass** | `handleOfflineAdd`, `resolveConflict`, `createBackupCipher`, `processPendingChanges` |
| **Noun phrases for non-side-effect methods** | **Pass** | `cardItemState()`, `loginItemState()`, `sshKeyItemState()` (existing pattern) |
| **`Has*` naming for DI protocols** | **Pass** | `HasOfflineSyncResolver`, `HasPendingCipherChangeDataStore` |
| **`Mock*` naming for test doubles** | **Pass** | `MockOfflineSyncResolver`, `MockPendingCipherChangeDataStore`, `MockCipherAPIServiceForOfflineSync` |
| **CamelCase file names** | **Pass** | `PendingCipherChangeData.swift`, `OfflineSyncResolver.swift`, `CipherView+OfflineSync.swift` |
| **Test naming `test_method_scenario`** | **Pass** | `test_processPendingChanges_update_noConflict`, `test_fetchSync_preSyncResolution_skipsWhenVaultLocked` |
| **Test file co-location** | **Pass** | All test files in same directory as implementation |
| **`BitwardenTestCase` superclass** | **Pass** | All test classes extend `BitwardenTestCase` |
| **setUp/tearDown lifecycle** | **Pass** | All test classes create mocks in setUp, nil them in tearDown |
| **No new external frameworks** | **Pass** | Zero new library dependencies; only Apple/project frameworks used |
| **No new crypto in Swift** | **Pass** | All encryption/decryption uses existing SDK (Rust) primitives; no Swift-level cryptographic code |
| **ServiceContainer DI pattern** | **Pass** | Two new services registered in `ServiceContainer` with `HasService` protocols |
| **Core/UI layer separation** | **Pass** | All new code in Core layer (`Core/Vault`); no new UI components |
| **Protocol-based abstractions** | **Pass** | `OfflineSyncResolver` protocol + `DefaultOfflineSyncResolver`; `PendingCipherChangeDataStore` protocol + `DataStore` extension |

### 2.4 Style Issues

**~~Issue CS-1~~ [Resolved] — Stray blank line removed.** See [AP-CS1](ActionPlans/Resolved/AP-CS1_StrayBlankLine.md).

**[Updated note]** The `URLError+NetworkConnection.swift` file has been deleted. See [AP-URLError_NetworkConnectionReview.md](ActionPlans/Superseded/AP-URLError_NetworkConnectionReview.md). Error handling now uses a denylist pattern: rethrow `ServerError`, `CipherAPIServiceError`, `ResponseValidationError` < 500; all other errors trigger offline save (PRs #26–#28).

---

## 3. Compilation Safety

### 3.1 Type Safety

| Area | Assessment | Details |
|------|-----------|---------|
| `PendingCipherChangeType` raw values | **Safe** | Backed by `Int16` with explicit raw values. `changeTypeRaw` stored in Core Data. Computed property provides typed access. |
| `CipherDetailsResponseModel` Codable | **Safe** | JSON encode/decode used for cipher data persistence. Model is well-established in codebase. |
| `Cipher(responseModel:)` init | **Safe** | Uses existing SDK init that maps from response model. |
| Error catch pattern | **Safe** | **[Updated]** Plain `catch` blocks used in all four offline fallback methods. The `URLError+NetworkConnection` extension was removed; any server API failure now triggers offline save. The encrypt step occurs outside the do-catch, so SDK errors propagate normally. |
| `CipherView.update(name:)` / `CipherView.withId(_:)` | **Mitigated** | Both delegate to a single `makeCopy(id:key:name:attachments:attachmentDecryptionFailures:)` private helper that manually copies all 28 `CipherView` properties. See Issue CS-2. **[Updated]** `Cipher.withTemporaryId(_:)` removed in Phase 2; replaced by `CipherView.withId(_:)` operating before encryption. `folderId` parameter removed; backup retains original folder. Property count guard tests (`test_cipherView_propertyCount_matchesExpected`, `test_loginView_propertyCount_matchesExpected`) now provide compile-time-like safety by failing when the SDK adds properties. |

**Issue CS-2 — `makeCopy` is fragile against SDK type changes. ~~[Mitigated]~~** **[Updated]** `Cipher.withTemporaryId()` has been removed. Both `CipherView.withId(_:)` and `CipherView.update(name:)` now delegate to a single `makeCopy` helper in `CipherView+OfflineSync.swift` that manually copies all 28 `CipherView` properties. If `CipherView` gains new properties with default values, `makeCopy` will compile but silently drop the new property's value. **Mitigation added:** Two property count guard tests (`test_cipherView_propertyCount_matchesExpected` asserting 28 properties, `test_loginView_propertyCount_matchesExpected` asserting 7 properties) will fail when the SDK type changes, alerting developers to update all manual copy methods. **Severity: Low (mitigated).** The single-point-of-update pattern (`makeCopy`) plus the guard tests substantially reduce the risk of silent property loss.

### 3.2 Import Statements

All new files have appropriate imports. No new external framework imports. Test files correctly use `@testable import BitwardenShared`. **[Updated]** `OfflineSyncResolverTests` imports: `BitwardenKitMocks` (for `MockErrorReporter`), `BitwardenSdk` (for SDK types), `Networking` (for types used by `MockCipherAPIServiceForOfflineSync`), `TestHelpers` (for `BitwardenTestError`), `XCTest`, `@testable import BitwardenShared`, and `@testable import BitwardenSharedMocks`. The `Networking` import supports the separate `MockCipherAPIServiceForOfflineSync` file (not the test file directly) which uses `EmptyResponse` in its protocol stubs.

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
| `BitwardenSharedMocks` | Project test target | Existing |
| `Networking` | Project local package | Existing |
| `TestHelpers` | Project test target | Existing |

The removal of the `ConnectivityMonitor` (from a previous iteration) actually **eliminated** a potential new dependency on Apple's `Network.framework`.

---

## 5. Test Coverage

**Reference:** `Docs/Testing.md`, [contributing-docs/architecture/mobile-clients/ios testing section](https://github.com/pkinerd/bitwarden.contributing-docs/docs/architecture/mobile-clients/ios/index.md)

### 5.1 Coverage by Component

| Component | Test File | Test Count | Coverage Quality |
|-----------|-----------|-----------|-----------------|
| `CipherView+OfflineSync` | `CipherViewOfflineSyncTests.swift` | 10 | **[Updated]** Excellent — 3 `withId` tests (set/preserve/replace), 5 `update` tests (name, id, key, attachments, passwordHistory), 2 property count guard tests (`CipherView` at 28, `LoginView` at 7) that fail when the SDK type changes |
| `PendingCipherChangeDataStore` | `PendingCipherChangeDataStoreTests.swift` | 9 | **[Updated]** Good — full CRUD coverage, user isolation, upsert idempotency, `originalRevisionDate` preservation, `pendingChangeCount` |
| `OfflineSyncResolver` | `OfflineSyncResolverTests.swift` | 21 | **[Updated]** Excellent — all change types, conflict resolution paths (local newer, server newer, soft conflict), 3 password history preservation tests, 2 cipher-not-found (404) tests, 1 error description test, 4 API failure/retention tests, 3 batch processing tests (all succeed, mixed failure, all fail) |
| `VaultRepository` (offline) | `VaultRepositoryTests.swift` | +32 new | **[Updated]** Excellent — offline fallback for add/update/delete/softDelete (4 basic tests), org cipher rejection (4 tests), denylist error handling (unknownError + responseValidationError5xx + serverError_rethrows + responseValidationError4xx_rethrows per operation = 16 tests), temp-ID assignment for new ciphers (1 test), `.create` type preservation (1 test), offline-created cipher deletion cleanup (2 tests), password change count tracking (4 tests: increment, zero, subsequent increment, subsequent preserve) |
| `SyncService` (offline) | `SyncServiceTests.swift` | +5 new | **[Updated]** Good — pre-sync trigger, skip on locked vault, no pending changes, abort on remaining, resolver throws hard error (sync fails) |

**Total new test count: 77 tests** **[Updated from 69]** Breakdown: `CipherViewOfflineSyncTests` = 10, `PendingCipherChangeDataStoreTests` = 9, `OfflineSyncResolverTests` = 21, `VaultRepositoryTests` offline = 32 (24 offline fallback + 8 error rethrow), `SyncServiceTests` pre-sync = 5. Prior expansion details: `CipherViewOfflineSyncTests` grew from 7 to 10 (added 3 `withId` tests and 2 property count guard tests). `PendingCipherChangeDataStoreTests` corrected to 9 (was overcounted at 10). `OfflineSyncResolverTests` grew from 11 to 21 (added password history, 404, API failure, and batch processing tests). `VaultRepositoryTests` offline tests grew from 8 to 32 (added denylist error handling including serverError_rethrows and responseValidationError4xx_rethrows, password change counting, `.create` type preservation, and offline-created cipher cleanup). `SyncServiceTests` grew from 4 to 5 (added resolver-throws test). The `pendingChangeCountResults` sequential-return mechanism remains in the mock (used by 3 SyncService tests for sequential count checks).

### 5.2 Notable Test Gaps

| ID | Component | Gap | Severity |
|----|-----------|-----|----------|
| ~~T1~~ | ~~`OfflineSyncResolver`~~ | ~~No batch processing test~~ **[Resolved]** 3 batch tests added: `_batch_allSucceed`, `_batch_mixedFailure_successfulItemResolved`, `_batch_allFail`. | ~~Medium~~ |
| ~~T2~~ | ~~`OfflineSyncResolver`~~ | ~~No API failure during resolution tested~~ **[Resolved]** 4 API failure tests added: `_create_apiFailure_pendingRecordRetained`, `_update_serverFetchFailure_pendingRecordRetained`, `_softDelete_apiFailure_pendingRecordRetained`, `_update_backupFailure_pendingRecordRetained`. | ~~Medium~~ |
| ~~T3~~ | ~~`VaultRepository`~~ | ~~`handleOfflineUpdate` password change detection not directly tested~~ **[Resolved]** 4 tests: `_passwordChanged_incrementsCount`, `_passwordUnchanged_zeroCount`, `_subsequentEdit_passwordChanged_incrementsCount`, `_subsequentEdit_passwordUnchanged_preservesCount`. | ~~Medium~~ |
| T4 | `VaultRepository` | `handleOfflineDelete` cipher-not-found path not tested — `fetchCipher(withId:)` returning nil leads to silent return | Low | **[Partially Resolved]** Resolver-level 404 tests added (RES-2 fix, commit `e929511`). VaultRepository-level `handleOfflineDelete` not-found test gap remains. See [AP-S7](ActionPlans/Resolved/AP-S7_CipherNotFoundPathTest.md). |
| ~~T5~~ | ~~`OfflineSyncResolverTests`~~ | ~~Inline mock fragile against protocol changes~~ **[Resolved]** Mock extracted to own file (`TestHelpers/MockCipherAPIServiceForOfflineSync.swift`). Accepted as-is per Option C: compiler enforces protocol conformance, `fatalError()` stubs catch unexpected calls. Consider adding `// sourcery: AutoMockable` to `CipherAPIService` for further improvement. See [AP-T5](ActionPlans/Resolved/AP-T5_InlineMockFragility.md). | ~~Low~~ |
| ~~T6~~ | ~~`URLError+NetworkConnection`~~ | ~~Only 3 of 10 positive error codes tested~~ **[Resolved]** See [AP-T6](ActionPlans/Resolved/AP-T6_IncompleteURLErrorTestCoverage.md). | ~~Low~~ N/A |
| ~~T7~~ | ~~`VaultRepository`~~ | ~~No test for `handleOfflineUpdate` with existing pending record (subsequent offline edit scenario)~~ | ~~Low~~ | **[Resolved]** Covered by `test_updateCipher_offlineFallback_preservesCreateType` (commit `12cb225`). See [AP-T7](ActionPlans/Resolved/AP-T7_SubsequentOfflineEditTest.md). |
| ~~T8~~ | ~~`SyncService`~~ | ~~No test for pre-sync resolution where the resolver throws a hard error~~ **[Resolved]** `test_fetchSync_preSyncResolution_resolverThrows_syncFails` verifies error propagation, no API requests, and no cipher replacement. | ~~Low~~ |

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

**Yes.** The pending offline items stored in `PendingCipherChangeData.cipherData` are protected to the **identical level** as the existing offline vault copy stored in `CipherData.modelData`. This has been verified against the Bitwarden security requirements:

| Protection Layer | Existing `CipherData` | New `PendingCipherChangeData` | Same? | Security Requirement |
|-----------------|----------------------|-------------------------------|-------|---------------------|
| Content encryption | SDK-encrypted `CipherDetailsResponseModel` JSON | SDK-encrypted `CipherDetailsResponseModel` JSON | **Yes** | VD-1.1: "Client MUST encrypt vault data stored on disk" |
| Encryption key | UserKey (256-bit, per EK-1) | Same UserKey (via SDK encrypt pipeline) | **Yes** | VD-1.2: "Client MUST use UserKey to encrypt vault data" |
| Core Data store location | `{AppGroupContainer}/Bitwarden.sqlite` | Same database, same SQLite file | **Yes** | — |
| iOS file protection | Complete Until First User Authentication (iOS default) | Same (same file) | **Yes** | VD-1.4: "Client MUST NOT store artifacts enabling decryption without additional user info" |
| App sandbox | App security group container | Same container | **Yes** | — |
| User data cleanup | Included in `deleteDataForUser` batch | Included in `deleteDataForUser` batch | **Yes** | — |
| Metadata exposure | `id`, `userId` stored unencrypted | `id`, `userId`, `cipherId`, `changeTypeRaw`, dates stored unencrypted | **Comparable** | — |
| No plaintext storage | Encrypted by SDK before reaching Core Data | Encrypted by SDK before reaching catch block | **Yes** | P01: "No possibility for attacker to access unencrypted data" |
| No new key storage | Uses existing iOS Keychain key management | No new key storage introduced | **Yes** | EK-2: "UserKey MUST be protected at rest" |

The metadata fields on `PendingCipherChangeData` (`offlinePasswordChangeCount`, `originalRevisionDate`, `changeTypeRaw`, `createdDate`, `updatedDate`) reveal activity patterns (timing and nature of offline edits) but no sensitive vault content. This is comparable to metadata already exposed by `CipherData` (which stores `id`, `userId` unencrypted alongside encrypted `modelData`).

**Password change detection note:** `handleOfflineUpdate` in `VaultRepository.swift:1057-1073` briefly decrypts the existing and new ciphers in-memory to compare passwords. The decrypted values are ephemeral local variables that go out of scope immediately after comparison. Per VD-2.2, "Client MAY decrypt all vault data during unlock" — this comparison occurs while the vault is unlocked (the user just made an edit). No plaintext is persisted. This is consistent with VD-2.3: "Client SHOULD ensure unprotected data not in memory when no longer in use."

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

`VaultRepository.handleOfflineUpdate` decrypts both the existing pending cipher and the new cipher to compare plaintext passwords in-memory (the password comparison logic is in the `handleOfflineUpdate` method, within the `// Detect password change by comparing with the previous version` block). The decrypted values are ephemeral and not persisted. This is necessary for the soft conflict threshold feature (≥4 password changes triggers a backup).

### 6.5 Organization Cipher Restriction

Organization ciphers are correctly blocked from offline editing in all four operations:
- `addCipher` — `isOrgCipher` flag computed before the API call; `guard !isOrgCipher` in catch block re-throws the original error before reaching `handleOfflineAdd`
- `updateCipher` — same pattern; `guard !isOrgCipher` in catch block re-throws before reaching `handleOfflineUpdate`
- `softDeleteCipher` — same pattern; `guard !isOrgCipher` in catch block re-throws before reaching `handleOfflineSoftDelete`
- `deleteCipher` — checked inside `handleOfflineDelete` (after fetching cipher to determine org ownership via `cipher.organizationId == nil`)

This prevents unauthorized client-side modifications to shared organization data where permissions, collection access, and policies could change while offline.

### 6.6 Security Issues and Observations

**~~Issue SEC-1~~ [Superseded]** — URLError extension deleted; all API errors trigger offline save. See [AP-SEC1](ActionPlans/Resolved/AP-SEC1_SecureConnectionFailedClassification.md).

**~~Observation SEC-2~~ [Resolved — Will Not Implement] — Pending metadata stored unencrypted.** `PendingCipherChangeData` is stored in Core Data alongside other vault data. The `cipherData` field contains SDK-encrypted JSON, so it's protected by the vault encryption key. The metadata fields (including `offlinePasswordChangeCount`) are unencrypted, consistent with existing `CipherData`. Encrypting the password change count was prototyped (AES-256-GCM) and reverted — the surrounding plaintext metadata (`changeTypeRaw`, timestamps, row count) and comparable unencrypted metadata elsewhere in the app (review prompt counts, vault timeout, last active time) mean encrypting this single field adds complexity without meaningfully reducing the attack surface. See [AP-SEC2](ActionPlans/Resolved/AP-SEC2_PasswordChangeCountEncryption.md).

**Observation SEC-3 — Pending changes cleaned up on user data deletion.** `DataStore.deleteDataForUser(userId:)` includes `PendingCipherChangeData.deleteByUserIdRequest` in the batch delete, ensuring pending changes are properly removed on logout or account deletion.

---

## 7. Reliability Considerations

### 7.1 Error Handling

| Scenario | Handling | Assessment |
|---------|---------|-----------|
| Any server API failure during cipher operation | **[Updated]** Denylist catch pattern: rethrow `ServerError`, `CipherAPIServiceError`, `ResponseValidationError` with status < 500; all other errors fall through to offline save | **Good** — The encrypt step occurs outside the do-catch, so SDK encryption errors propagate normally. Client errors (4xx) and programming errors are rethrown; server errors (5xx) and connectivity failures trigger offline save. |
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
| Save org cipher while offline | Re-throws the original network error (org ciphers are excluded from offline fallback) | **Needs attention** — Error appears after network timeout delay |
| Next sync after connectivity restored | Resolves pending changes, then syncs | **Good** — No manual action needed |
| Conflict detected (server changed) | Backup created (retains original folder) | **Good** — No data loss |
| Multiple password changes offline | Extra backup when ≥4 changes | **Good** — Soft conflict protects against accumulated drift |
| Archive/unarchive cipher while offline | Fails with generic network error | **Gap** — Inconsistent with add/update/delete offline support |
| Update cipher collections while offline | Fails with generic network error | **Gap** — Inconsistent |
| Restore cipher from trash while offline | Fails with generic network error | **Gap** — Inconsistent |
| Viewing offline-created item | ~~Infinite spinner, item never loads~~ **[Resolved]** Item loads normally | **[Resolved]** Root cause (`Cipher.withTemporaryId()` producing `data: nil`) **fixed** by `CipherView.withId()` (commit `3f7240a`). Symptom (spinner) mitigated by fallback fetch (PR #31). See Phase 2 §2.1, [AP-VI1](ActionPlans/AP-VI1_OfflineCreatedCipherViewFailure.md). |
| Viewing pending changes status | No UI indicator | **Gap** — User has no awareness of unsynced changes |
| ~~Conflict folder discovery~~ | ~~"Offline Sync Conflicts" folder appears in vault~~ | **[Removed]** — Conflict folder eliminated; backups retain original folder |

### 8.2 Usability Observations

**Observation U1 — Org cipher error timing.** The organization check happens after the network request fails, so the user must wait for the network timeout before seeing the error. Proactive checking would require knowing connectivity state before the API call.

**Observation U2 — Inconsistent offline support across operations.** Add, update, delete, and soft-delete work offline. Archive, unarchive, collection assignment, and restore do not. Users performing unsupported operations offline get generic errors rather than offline-specific messages.

**Observation U3 — No user-visible pending changes indicator.** Users have no way to see pending offline changes. If resolution continues to fail, the user is unaware their changes haven't been uploaded.

~~**Observation U4 — Conflict folder name in English only.**~~ ~~"Offline Sync Conflicts" is hardcoded in English, not localized. Non-English users see an English folder name. Localization is complex since the encrypted folder name syncs across devices with potentially different locales.~~ **[Superseded]** — The dedicated conflict folder has been removed. Backup ciphers now retain their original folder assignment.

**Issue VI-1 ~~[Mitigated]~~ [Resolved] — Offline-created cipher view failure.** When a user creates a new cipher while offline, the item appeared in the vault list but failed to load in the detail view (infinite spinner). **Mitigated in PR #31** (fallback fetch in `ViewItemProcessor`). **Root cause fixed in Phase 2:** `Cipher.withTemporaryId()` (which produced `data: nil`) replaced by `CipherView.withId()` operating before encryption (commit `3f7240a`). Offline-created ciphers now encrypt correctly, so the publisher stream no longer fails. The UI fallback remains as defense-in-depth. See Phase 2 §2.1, [AP-VI1](ActionPlans/AP-VI1_OfflineCreatedCipherViewFailure.md).

---

## 9. Simplification Opportunities

### 9.1 Ways to Reduce Code Change Extent Without Reducing Functionality

| Opportunity | Estimated Savings | Trade-off |
|-------------|-------------------|-----------|
| ~~Remove `timeProvider` from `DefaultOfflineSyncResolver`~~ | ~~5 lines~~ | **[Done]** — Removed in commit `a52d379` |
| Merge `handleOfflineDelete` and `handleOfflineSoftDelete` | ~40 lines | Slight increase in complexity of one method; both now contain duplicated offline-created cipher cleanup logic (checking for `.create` type, deleting locally, removing the pending record). **Note:** These methods now queue different change types (`.hardDelete` vs `.softDelete`). |
| Use `Cipher` directly instead of roundtripping through `CipherDetailsResponseModel` JSON | ~20 lines per handler | Would require a different serialization approach for `cipherData`; the current JSON approach matches existing `CipherData` patterns |
| ~~Remove `CipherView.update(name:)` and inline the `CipherView(...)` init call in the resolver~~ | ~~~20 lines~~ | **[Partially addressed]** — `update(name:)` and `withId(_:)` now delegate to a shared `makeCopy` helper, so the full `CipherView` initializer is called in exactly one place. The thin wrappers are only ~5 lines each and improve readability. |
| Use existing project-level mock for `CipherAPIService` (if one exists) instead of inline `MockCipherAPIServiceForOfflineSync` | ~40 lines | Depends on whether a project mock exists with `fatalError` stubs for unused methods. The inline mock currently has 16 `fatalError()` stubs for unused protocol methods. |

**Assessment:** The code is already reasonably compact. The `timeProvider` removal has been applied and the `CipherView` copy methods have been consolidated into a shared `makeCopy` helper. The remaining opportunities offer modest savings with tradeoffs. The most impactful remaining simplification is merging `handleOfflineDelete` and `handleOfflineSoftDelete`, which now share duplicated offline-created cipher cleanup logic from the Phase 2 additions.

### 9.3 Unused Dependency Cleanup

**`stateService` in `DefaultOfflineSyncResolver`** (`OfflineSyncResolver.swift:78,95`): This dependency is injected but never used — `userId` is passed as a parameter to `processPendingChanges(userId:)` from `SyncService`. Removing it would:
- Eliminate 4 lines of code (property, init parameter, init assignment, ServiceContainer wiring)
- Reduce the resolver's dependency count from 5 to 4
- Better align with the principle of injecting only used dependencies
- **No behavioral change** — the resolver never calls `stateService`

### 9.2 Simplifications Already Applied

The implementation has already been simplified significantly from the original plan:

1. **ConnectivityMonitor removed** — Saved ~500 lines and eliminated `Network.framework` dependency
2. **Health check removed** — Saved ~50 lines and eliminated `AccountAPIService` dependency
3. **Post-sync re-application replaced with early-abort** — Simplified sync logic significantly
4. **`AddEditItemProcessor` not modified** — Errors propagate through existing UI error handling
5. **No changes to `CipherService` or `FolderService`** — Existing protocol methods sufficient. **[Updated]** `FolderService` dependency subsequently removed from the resolver entirely.

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

### New Files (10 source + 4 docs)

**[Updated]** `URLError+NetworkConnection.swift` (26 lines) and `URLError+NetworkConnectionTests.swift` (39 lines) were deleted as part of the error handling simplification. The `isNetworkConnectionError` computed property is no longer needed since all API failures now trigger offline save.

**[Updated 2026-02-18]** Line counts and test counts updated to reflect all changes through Phase 2 and resolved action plans (S3, S4, S6, T5, T8).

| File | Type | Lines | Purpose |
|------|------|-------|---------|
| `CipherView+OfflineSync.swift` | Extension | 104 | Cipher copy helpers for offline/backup (`withId`, `update`) |
| `CipherViewOfflineSyncTests.swift` | Tests | 171 (10 tests) | Tests for above, including property count verification |
| `PendingCipherChangeData.swift` | Model | 192 | Core Data entity + predicates |
| `PendingCipherChangeDataStore.swift` | Store | 155 | Data access layer protocol + impl |
| `PendingCipherChangeDataStoreTests.swift` | Tests | 286 (9 tests) | Full CRUD tests |
| `MockPendingCipherChangeDataStore.swift` | Mock | 78 | Test helper |
| `OfflineSyncResolver.swift` | Service | 349 | Conflict resolution engine (actor) |
| `OfflineSyncResolverTests.swift` | Tests | 933 (21 tests) | Conflict scenarios, batch processing, API failure paths |
| `MockOfflineSyncResolver.swift` | Mock | 13 | Test helper |
| `MockCipherAPIServiceForOfflineSync.swift` | Mock | 68 | Test helper for resolver tests (extracted from inline in OfflineSyncResolverTests) |

### Modified Files (13)

| File | Changes | Detailed Review |
|------|---------|-----------------|
| `ServiceContainer.swift` | +29 lines: Register 2 new services, add init params and DocC, wire in `defaultServices()` | [ReviewSection_DIWiring.md](ReviewSection_DIWiring.md) |
| `Services.swift` | +17 lines: Add `HasOfflineSyncResolver`, `HasPendingCipherChangeDataStore` protocols, compose into `Services` typealias | [ReviewSection_DIWiring.md](ReviewSection_DIWiring.md) |
| `DataStore.swift` | +1 line: Add `PendingCipherChangeData` to `deleteDataForUser` batch delete | [ReviewSection_DIWiring.md](ReviewSection_DIWiring.md) |
| `Bitwarden.xcdatamodel/contents` | +17 lines: Add `PendingCipherChangeData` entity with 9 attributes and uniqueness constraint | [ReviewSection_PendingCipherChangeDataStore.md](ReviewSection_PendingCipherChangeDataStore.md) |
| `VaultRepository.swift` | +225 lines: Add `pendingCipherChangeDataStore` dependency; offline fallback handlers (`handleOfflineAdd`, `handleOfflineUpdate`, `handleOfflineDelete`, `handleOfflineSoftDelete`); org cipher guards; denylist catch pattern; orphaned pending change cleanup; temp-ID assignment before encryption; `.create` type preservation; offline-created cipher deletion cleanup | [ReviewSection_VaultRepository.md](ReviewSection_VaultRepository.md) |
| `VaultRepositoryTests.swift` | +32 offline tests: offline fallback for add/update/delete/softDelete (4), org cipher rejection (4), denylist error handling (serverError_rethrows + responseValidationError4xx_rethrows + unknownError + responseValidationError5xx per operation = 16), temp-ID assignment (1), `.create` type preservation (1), offline-created cleanup (2), password change counting (4) | [ReviewSection_VaultRepository.md](ReviewSection_VaultRepository.md) |
| `SyncService.swift` | +30 lines: Add `offlineSyncResolver`, `pendingCipherChangeDataStore`; pre-sync resolution with early-abort; pre-count check optimization | [ReviewSection_SyncService.md](ReviewSection_SyncService.md) |
| `SyncServiceTests.swift` | +5 offline tests: pre-sync resolution conditions including resolver hard error (T8) | [ReviewSection_SyncService.md](ReviewSection_SyncService.md) |
| `ServiceContainer+Mocks.swift` | +6 lines: Add mock defaults for 2 new services | [ReviewSection_DIWiring.md](ReviewSection_DIWiring.md) |
| `GetCipherRequest.swift` | +5 lines: Add `validate(_:)` method that throws `OfflineSyncError.cipherNotFound` on HTTP 404 | [ReviewSection_OfflineSyncResolver.md](ReviewSection_OfflineSyncResolver.md) |
| `ViewItemProcessor.swift` | +30 lines: Add `fetchCipherDetailsDirectly()` fallback and extract `buildViewItemState(from:)` helper | [OfflineSyncCodeReview_Phase2.md §3](OfflineSyncCodeReview_Phase2.md) |
| `ViewItemProcessorTests.swift` | +4 tests: Fallback fetch success, nil cipher, throw, and stream error tests | [OfflineSyncCodeReview_Phase2.md §5](OfflineSyncCodeReview_Phase2.md) |
| `CipherView+Update.swift` | +13 lines: Added `- Important:` DocC annotations documenting manual property counts (28 for `CipherView`, 7 for `LoginView`) on `updatedView(with:)`, `update(archivedDate:...)`, and `LoginView.update(totp:)` to alert developers when SDK types change | [ReviewSection_SupportingExtensions.md](ReviewSection_SupportingExtensions.md) |

### Deleted Files

| File | Reason |
|------|--------|
| `ConnectivityMonitor.swift` | Removed (previous iteration) — existing sync triggers suffice |
| `ConnectivityMonitorTests.swift` | Tests for removed service |
| `MockConnectivityMonitor.swift` | Mock for removed service |
| `URLError+NetworkConnection.swift` | **[Removed in simplification]** — `isNetworkConnectionError` property no longer needed; denylist catch pattern replaces URLError filtering (PRs #26–#28) |
| `URLError+NetworkConnectionTests.swift` | **[Removed in simplification]** — Tests for deleted extension |

### Documentation Files

**[Updated 2026-02-18]** `OfflineSyncReviewActionPlan.md` no longer exists (issue tracking is managed via individual Action Plans in `ActionPlans/`). The documentation suite has grown to 55 files as the feature evolved through review cycles.

| File | Purpose |
|------|---------|
| `_OfflineSyncDocs/OfflineSyncPlan.md` | Implementation plan |
| `_OfflineSyncDocs/OfflineSyncCodeReview.md` | This review document (comprehensive, standalone) |
| `_OfflineSyncDocs/OfflineSyncCodeReview_Phase2.md` | Phase 2 detailed review (VI-1 root cause fix, `.create` preservation, etc.) |
| `_OfflineSyncDocs/OfflineSyncChangelog.md` | Change history across all phases |
| `_OfflineSyncDocs/ReviewSection_*.md` (7 files) | Per-component detailed reviews |
| `_OfflineSyncDocs/OverallRecommendations.md` | Cross-cutting recommendations |
| `_OfflineSyncDocs/CrossReferenceMatrix.md` | Issue cross-reference matrix |
| `_OfflineSyncDocs/ActionPlans/*.md` (17 active) | Individual action plans for identified issues |
| `_OfflineSyncDocs/ActionPlans/Resolved/*.md` (15 files) | Completed action plans |
| `_OfflineSyncDocs/ActionPlans/Superseded/*.md` (2 files) | Superseded action plans |

---

## 12. Implementation Plan Deviations

### 12.1 `AddEditItemProcessor` Not Modified

The plan (Section 9) lists `AddEditItemProcessor.swift` as a modified file. In the implementation, **no changes were made**. Organization cipher errors (the original network error is rethrown rather than using a custom `OfflineSyncError` case) propagate through existing generic error handling. This is a reasonable deviation. **[Updated]** The `.organizationCipherOfflineEditNotSupported` case was removed; org cipher protection now rethrows the original caught error.

### 12.2 `CipherService` and `FolderService` Not Directly Modified

The plan lists both as modified files. In the implementation, they were not modified — the resolver uses existing methods on their protocols.

### ~~12.3 No Feature Flag~~ [Resolved]

~~The feature has no feature flag or kill switch. If issues are discovered in production, the only mitigation is a code change and app update.~~ **[Resolved]** Two server-controlled feature flags (`.offlineSyncEnableResolution`, `.offlineSyncEnableOfflineChanges`) now gate all offline sync entry points. Both default to `false` (server-controlled rollout). See [AP-S8](ActionPlans/AP-S8_FeatureFlag.md).

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

**[Updated 2026-02-18]** All high-priority issues have been resolved.

| ID | Component | Issue | Detailed Section |
|----|-----------|-------|-----------------|
| ~~S3~~ | ~~`OfflineSyncResolverTests`~~ | ~~No batch processing test~~ — **[Resolved]** 3 batch tests added: `test_processPendingChanges_batch_allSucceed`, `test_processPendingChanges_batch_mixedFailure_successfulItemResolved`, `test_processPendingChanges_batch_allFail` | [AP-S3](ActionPlans/Resolved/AP-S3_BatchProcessingTest.md) |
| ~~S4~~ | ~~`OfflineSyncResolverTests`~~ | ~~No API failure during resolution test~~ — **[Resolved]** 4 API failure tests added: `test_processPendingChanges_create_apiFailure_pendingRecordRetained`, `test_processPendingChanges_update_serverFetchFailure_pendingRecordRetained`, `test_processPendingChanges_softDelete_apiFailure_pendingRecordRetained`, `test_processPendingChanges_update_backupFailure_pendingRecordRetained` | [AP-S4](ActionPlans/Resolved/AP-S4_APIFailureDuringResolutionTest.md) |

### Medium Priority

| ID | Component | Issue | Detailed Section |
|----|-----------|-------|-----------------|
| ~~VI-1~~ | ~~`ViewItemProcessor` / `VaultRepository`~~ | ~~Offline-created cipher fails to load in detail view (infinite spinner)~~ — **[Resolved]** Symptom fixed by `fetchCipherDetailsDirectly()` fallback (PR #31). Root cause (`data: nil` in `Cipher.withTemporaryId()`) **fixed** by `CipherView.withId()` (commit `3f7240a`). All 5 recommended fixes implemented in Phase 2. | [AP-VI1](ActionPlans/AP-VI1_OfflineCreatedCipherViewFailure.md) |
| ~~S6~~ | ~~`VaultRepositoryTests`~~ | ~~`handleOfflineUpdate` password change counting not directly tested~~ — **[Resolved]** 4 password change detection tests added: `test_updateCipher_offlineFallback_passwordChanged_incrementsCount`, `test_updateCipher_offlineFallback_passwordUnchanged_zeroCount`, `test_updateCipher_offlineFallback_subsequentEdit_passwordChanged_incrementsCount`, `test_updateCipher_offlineFallback_subsequentEdit_passwordUnchanged_preservesCount` | [AP-S6](ActionPlans/Resolved/AP-S6_PasswordChangeCountingTest.md) |
| ~~S8~~ | ~~Feature~~ | ~~Consider adding a feature flag for production safety~~ — **[Resolved]** Two server-controlled flags added. See Section 12.3. | Section 12.3 |

### Low Priority

**[Updated 2026-02-18]** T5, T8 resolved. CS-2 description updated to reflect `withTemporaryId` removal.

| ID | Component | Issue | Detailed Section |
|----|-----------|-------|-----------------|
| ~~CS-2~~ | ~~`CipherView+OfflineSync`~~ | ~~`withId`/`update` fragile against SDK type changes~~ — **[Resolved]** Both `withId(_:)` and `update(name:)` now delegate to a single `makeCopy()` helper. Property count guard tests (`test_cipherView_propertyCount_matchesExpected` at 28 properties, `test_loginView_propertyCount_matchesExpected` at 7 properties) fail when the SDK type changes, ensuring the copy method is updated. | [AP-CS2](ActionPlans/AP-CS2_FragileSDKCopyMethods.md) |
| R1 | `PendingCipherChangeData` | No data format versioning for `cipherData` JSON | Section 7.3 |
| ~~R2~~ | ~~`OfflineSyncResolver`~~ | ~~`conflictFolderId` thread safety (class with mutable var, no actor isolation)~~ **[Resolved]** — Converted to `actor` | [AP-R2](ActionPlans/AP-R2_ConflictFolderIdThreadSafety.md) |
| R3 | `OfflineSyncResolver` | No retry backoff for permanently failing resolution items | Section 7.3 |
| R4 | `SyncService` | Silent sync abort (no logging) — confirmed still absent at `SyncService.swift:340` | [SS-3](ReviewSection_SyncService.md) |
| ~~T5~~ | ~~`OfflineSyncResolverTests`~~ | ~~Inline `MockCipherAPIServiceForOfflineSync` fragile against protocol changes~~ — **[Resolved]** Mock extracted from inline to dedicated file (`TestHelpers/MockCipherAPIServiceForOfflineSync.swift`). Compiler enforces protocol conformance, `fatalError()` stubs catch unexpected calls. | [AP-T5](ActionPlans/Resolved/AP-T5_InlineMockFragility.md) |
| ~~T8~~ | ~~`SyncServiceTests`~~ | ~~No test for hard error in pre-sync resolution~~ — **[Resolved]** `test_fetchSync_preSyncResolution_resolverThrows_syncFails` added | [AP-T8](ActionPlans/Resolved/AP-T8_HardErrorInPreSyncResolution.md) |
| DI-1 | `Services.swift` | `HasPendingCipherChangeDataStore` exposes data store to UI layer (broader than needed) | [DI-1](ReviewSection_DIWiring.md) |
| A2 | `OfflineSyncResolver` | `stateService` injected but never used — should be removed (~4 lines cleanup) | Section 1.4, 9.3 |
| A4 | `GetCipherRequest` | `validate(_:)` couples general-purpose API request to `OfflineSyncError` — acceptable but noted | Section 1.4 |

### Informational / Future Considerations

| ID | Component | Observation | Detailed Section |
|----|-----------|-------------|-----------------|
| U1 | UX | Org cipher error appears after network timeout delay | Section 8.2 |
| U2 | UX | Archive/unarchive/collections/restore not offline-aware (inconsistent) | Section 8.2 |
| U3 | UX | No user-visible indicator for pending offline changes | Section 8.2 |
| ~~U4~~ | ~~UX~~ | ~~Conflict folder name is English-only~~ — **[Superseded]** Conflict folder removed | ~~Section 8.2~~ |
| ~~VR-2~~ | `VaultRepository` | ~~`deleteCipher` (permanent) converted to soft delete offline~~ **[Resolved]** Now uses `.hardDelete` pending change; permanent delete honored on sync when no conflict | [VR-2](ReviewSection_VaultRepository.md) |
| RES-1 | `OfflineSyncResolver` | Potential duplicate cipher on create retry after partial failure | [RES-1](ReviewSection_OfflineSyncResolver.md) |
| RES-7 | `OfflineSyncResolver` | Backup ciphers don't include attachments | [RES-7](ReviewSection_OfflineSyncResolver.md) |

---

## 15. Good Practices Observed

**[Updated 2026-02-18]** Added new practices from resolved action plans and Phase 2.

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
- ~~**`conflictFolderId` caching** avoids redundant folder lookups/creation within a sync batch~~ **[Removed]** — Conflict folder eliminated
- **No new external dependencies** — zero new libraries, packages, or framework imports
- **No problematic cross-domain dependencies** — all new relationships are within Vault/Platform domains
- **Simplification from original design** — ConnectivityMonitor, health check, and post-sync re-application all removed for cleaner architecture
- **`softConflictPasswordChangeThreshold` extracted as named constant** — avoids magic number
- **Comprehensive batch and failure test coverage** (S3/S4 resolved) — 3 batch tests (all-success, mixed-failure, all-fail) and 4 API failure tests verify the catch-and-continue reliability property in the resolver
- **Password change detection fully tested** (S6 resolved) — 4 tests cover first-edit and subsequent-edit paths for both changed and unchanged passwords
- **`DefaultOfflineSyncResolver` is an `actor`** (R2 resolved) — eliminates thread safety concerns for mutable state
- **Property count verification tests** in `CipherViewOfflineSyncTests` — `test_cipherView_propertyCount_matchesExpected` and `test_loginView_propertyCount_matchesExpected` provide compile-time guards against SDK type changes affecting the fragile copy methods (CS-2 mitigation)

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
| `AddEditItemProcessorTests.swift` | Network error alert tests, `ServerError` alert test | User sees proper error alert when offline fallback fails; `ServerError` propagates to UI |
| `VaultRepositoryTests.swift` | `serverError_rethrows` and `responseValidationError4xx_rethrows` tests (4 operations × 2 = 8 tests) | `ServerError` and 4xx `ResponseValidationError` propagate rather than triggering offline save |

These tests partially address Deep Dive 7 (narrow error coverage) from the original review.

### 16.3 ~~Conflict Folder Encryption Fix (PR #29)~~ **[Superseded]**

~~**Commit `266bffa`**~~

~~**Bug:** `getOrCreateConflictFolder()` in `OfflineSyncResolver` was passing the plaintext string `"Offline Sync Conflicts"` directly to `folderService.addFolderWithServer(name:)`. The `addFolderWithServer` method expects an *encrypted* folder name. The server stored the plaintext, and when the SDK later tried to decrypt the folder name during a folder fetch, it panicked (Rust panic) because plaintext is not valid ciphertext.~~

**[Updated]** This fix is no longer applicable — the conflict folder feature, `getOrCreateConflictFolder()` method, and `FolderService` dependency have been removed entirely. Backup ciphers now retain the original cipher's folder assignment.

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

Fixed the userId assertion in the soft-delete pending change cleanup test — was `"1"` but should have been `"13512467-9cfe-43b0-969f-07534084764b"` to match `fixtureAccountLogin()`. This assertion now lives in `test_softDeleteCipher()` in `VaultRepositoryTests.swift` (the original standalone test `test_softDeleteCipher_pendingChangeCleanup` was merged into the main `test_softDeleteCipher` test).

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
| **[CS-2](ActionPlans/AP-CS2_FragileSDKCopyMethods.md)** | ~~Open (Low)~~ **[Resolved]** | Both `withId(_:)` and `update(name:)` now delegate to a single `makeCopy()` helper with SDK update review comment and property count (28). Only one method needs updating when `CipherView` changes. Option A implemented. |
| ~~**[RES-1](ActionPlans/AP-RES1_DuplicateCipherOnCreateRetry.md)**~~ | ~~Open (Informational)~~ **Partially Resolved** | Temp-ID cipher record cleanup added to `resolveCreate()` (commits `8ff7a09`, `53e08ef`). Duplicate-on-retry concern (server already has the cipher) still informational. |
| ~~**[S7](ActionPlans/Resolved/AP-S7_CipherNotFoundPathTest.md)**~~ | ~~Open (Medium)~~ **[Partially Resolved]** | Resolver-level 404 tests added (RES-2 fix, commit `e929511`). VaultRepository-level `handleOfflineDelete` not-found test gap remains. |
| ~~**[T7](ActionPlans/Resolved/AP-T7_SubsequentOfflineEditTest.md)**~~ | ~~Open (Low)~~ **[Resolved]** | Covered by `test_updateCipher_offlineFallback_preservesCreateType` (commit `12cb225`). |

---

## 17. Conclusion

### 17.1 Overall Assessment

The offline sync implementation is architecturally sound, follows project conventions, maintains the zero-knowledge security model, and provides robust data loss prevention. The code has been verified against the cloned [bitwarden.contributing-docs](https://github.com/pkinerd/bitwarden.contributing-docs) guidelines (Section 2.3) and the project's own `Docs/Architecture.md` and `Docs/Testing.md`.

**Key compliance findings:**
- **Architecture:** All 8 architectural principles verified as passing (Section 1.1). No problematic cross-domain dependencies (Section 1.3). All new code placed within existing `Vault` and `Platform` domains.
- **Code style:** All 26 Swift code style guidelines verified as passing (Section 2.3). Full DocC coverage on public APIs, correct MARK ordering, proper naming conventions.
- **Security:** Zero-knowledge architecture preserved (Section 6.1). Offline items protected to identical level as existing vault cache (Section 6.2, verified against 10 protection layers). No new cryptographic code in Swift — all encryption uses existing SDK (Rust) primitives per the contributing docs' crypto guidelines.
- **Testing:** 77 new tests across 5 test files (Section 5.1). All test pattern guidelines followed (Section 5.3). Test co-location, `BitwardenTestCase` superclass, setUp/tearDown lifecycle all verified.
- **Dependencies:** Zero new external libraries or framework imports (Section 4). No new cross-domain coupling introduced.
- **Data safety:** Encrypt-before-queue invariant maintained across all 4 operations. Early-abort sync prevents `replaceCiphers` from overwriting local edits. Conflict resolution preserves both versions via backup ciphers. 6 layers of data loss prevention (Section 7.2).

The code is well-documented, well-tested (77 new tests across the original implementation and subsequent fixes), and introduces no new external dependencies or problematic cross-domain coupling.

### 17.2 Design Decisions

The most significant design choice — the early-abort sync pattern — is the correct tradeoff: it prioritizes data safety (never overwriting unsynced local edits) over freshness (users with unresolvable pending changes won't receive server updates until those are cleared). This is consistent with Bitwarden's security-first philosophy.

The denylist error handling pattern (rethrow `ServerError`, `CipherAPIServiceError`, `ResponseValidationError` < 500; all others trigger offline save) is more resilient than the original URLError allowlist. Unknown error types automatically trigger offline save, defaulting to the safest behavior.

### 17.3 All Issues Resolved or Tracked

The VI-1 root cause and all related edge cases have been **fully resolved in Phase 2**: `CipherView.withId()` replaces `Cipher.withTemporaryId()` (commit `3f7240a`), `.create` type preservation (commit `12cb225`), offline-created deletion cleanup (commit `12cb225`), temp-ID record cleanup (commits `8ff7a09`, `53e08ef`). See [Phase 2 Code Review](OfflineSyncCodeReview_Phase2.md).

**Remaining open items (by priority):**

| Priority | ID | Description |
|----------|-----|-------------|
| ~~Medium~~ | ~~S8~~ | ~~Feature flag for production safety~~ — **[Resolved]** |
| Low | A2 | Remove unused `stateService` from `OfflineSyncResolver` (~4 lines) |
| Low | R3 | Add retry backoff for permanently failing resolution items |
| Low | R4 | Add logging on sync abort (`SyncService.swift:340`) |
| Low | R1 | Data format versioning for `cipherData` JSON |
| Low | S7 | VaultRepository-level `handleOfflineDelete` cipher-not-found test |
| Low | A4 | `GetCipherRequest.validate` couples to `OfflineSyncError` |
| Low | DI-1 | `HasPendingCipherChangeDataStore` broader than needed |
| Info | U1 | Org cipher error appears after network timeout delay |
| Info | U2 | Archive/unarchive/collections/restore not offline-aware |
| Info | U3 | No user-visible indicator for pending offline changes |

~~Of these, S8 (feature flag) is the highest-impact item.~~ **[S8 Resolved]** Two server-controlled flags now gate all offline sync entry points. The remaining items are low-priority or informational and do not block merge.

### 17.4 Recommendation

The implementation is ready for merge consideration. The code is comprehensive, well-tested, architecturally compliant, and security-sound. No critical or high-priority issues remain open.

**Resolution history (18 issues resolved/superseded):**
- SEC-1, EXT-1 superseded by error handling simplification (URLError extension deleted)
- A3, CS-1, T6 resolved by code cleanup and deletion
- T7 resolved by `test_updateCipher_offlineFallback_preservesCreateType` (Phase 2)
- S7 partially resolved — resolver-level 404 tests added
- VI-1 **resolved** — UI fallback (PR #31) fixed spinner; root cause (`data: nil`) fixed by `CipherView.withId()` (commit `3f7240a`)
- RES-1 partially resolved — temp-ID cleanup added to `resolveCreate()` (commits `8ff7a09`, `53e08ef`)
- CS-2 **resolved** — `makeCopy()` helper with SDK update review comment and property count (28). Property count guard tests added.
- S3 **resolved** — 3 batch processing tests added to `OfflineSyncResolverTests.swift`
- S4 **resolved** — 4 API failure during resolution tests added to `OfflineSyncResolverTests.swift`
- S6 **resolved** — 4 password change counting tests added to `VaultRepositoryTests.swift`
- T5 **resolved** — mock extracted to dedicated file `MockCipherAPIServiceForOfflineSync.swift`
- T8 **resolved** — `test_fetchSync_preSyncResolution_resolverThrows_syncFails` added to `SyncServiceTests.swift`
- R-2 **resolved** — `DefaultOfflineSyncResolver` converted from `class` to `actor`
- U-4 **superseded** — conflict folder removed entirely; English-only name concern no longer applicable
- All 5 "remaining gaps" from §16.7 addressed in Phase 2
- Action plans in Resolved folder: A3, CS1, CS2, EXT1, R2, S3, S4, S6, S7, SEC1, T5, T6, T7, T8, VI1
- Action plans in Superseded folder: U4, URLError_NetworkConnectionReview

**Review verified against:** Contributing guidelines from [bitwarden.contributing-docs](https://github.com/pkinerd/bitwarden.contributing-docs) (cloned locally), project `Docs/Architecture.md`, project `Docs/Testing.md`, and `.claude/CLAUDE.md` — all iOS-relevant guidelines checked. See Section 2.3 for compliance matrix.
