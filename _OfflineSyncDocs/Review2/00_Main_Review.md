# Offline Sync Feature — Comprehensive Code Review (Review 2)

**Date**: 2026-02-18
**Scope**: All code changes from fork point (`0283b1f9`) to current `dev` branch (`7c0edbf2`)
**Baseline**: Upstream Bitwarden iOS at commit `0283b1f9`
**Reference**: [Architecture.md](../../Docs/Architecture.md), [Testing.md](../../Docs/Testing.md), [Swift Code Style](https://contributing.bitwarden.com/contributing/code-style/swift)

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Feature Overview](#feature-overview)
3. [End-to-End Change Walkthrough](#end-to-end-change-walkthrough)
4. [Architecture Compliance Summary](#architecture-compliance-summary)
5. [Security Assessment](#security-assessment)
6. [Data Safety Assessment](#data-safety-assessment)
7. [Code Style Compliance](#code-style-compliance)
8. [Reliability & Error Handling](#reliability--error-handling)
9. [Cross-Component Dependencies](#cross-component-dependencies)
10. [External Dependencies](#external-dependencies)
11. [Test Coverage Summary](#test-coverage-summary)
12. [Simplification Opportunities](#simplification-opportunities)
13. [Open Concerns & Action Items](#open-concerns--action-items)
14. [File-by-File Coverage Matrix](#file-by-file-coverage-matrix)
15. [Detailed Section Documents](#detailed-section-documents)

---

## Executive Summary

The offline sync feature adds the ability for the Bitwarden iOS app to queue vault cipher operations (create, update, delete, soft-delete) locally when the server is unreachable, and resolve these pending changes against server state when connectivity returns. The implementation:

- Introduces **6 new production files** and **5 new test/mock files** specific to offline sync
- Modifies **7 existing production files** for offline sync integration
- Adds **~3,800 lines** of offline-sync-specific code (including ~2,150 lines of tests)
- Introduces **no new external dependencies**
- Follows the project's established architectural patterns consistently
- Provides **comprehensive test coverage** for all major code paths
- Encrypts pending offline data to the **same level as the vault's offline copy**

The remainder of the diff (~100+ files) consists of upstream Bitwarden iOS development changes (SDK updates, typo fixes, feature work) that are orthogonal to the offline sync feature.

---

## Feature Overview

### What It Does

When a user creates, edits, deletes, or soft-deletes a vault cipher and the server is unreachable:

1. **The operation is saved locally** — The cipher is persisted to Core Data so the user sees their change immediately.
2. **A pending change record is created** — Metadata about the offline operation is stored in a new `PendingCipherChangeData` Core Data entity.
3. **On next sync, changes are resolved** — Before the full vault sync runs, the `OfflineSyncResolver` processes all pending changes, pushing them to the server or handling conflicts.
4. **Conflicts are resolved with backups** — If the server version changed while offline, both versions are preserved (the "losing" version becomes a backup cipher with a timestamp-suffixed name).

### What It Doesn't Do

- **No offline support for organization ciphers** — Shared/org items require server-side policy enforcement that can't be replicated offline.
- **No offline support for attachment operations** — Attachment upload/download requires server communication.
- **No user-visible pending changes indicator** — The user has no UI feedback that changes are pending sync.
- ~~**No feature flag**~~ **[Resolved]** — Two server-controlled feature flags (`.offlineSyncEnableResolution`, `.offlineSyncEnableOfflineChanges`) gate all offline sync entry points. Both default to `false` for server-controlled rollout.

---

## End-to-End Change Walkthrough

This section walks through the complete offline sync flow, referencing specific files and line numbers.

### 1. User Creates a Cipher Offline

**Entry point**: `VaultRepository.addCipher(_:)` (`VaultRepository.swift:503`)

1. The cipher has no ID (`cipher.id == nil`). A temporary UUID is assigned via `cipher.withId(UUID().uuidString)` using the `CipherView+OfflineSync.swift` extension. This temp ID is baked into the encrypted content.
2. The cipher is encrypted via `clientService.vault().ciphers().encrypt()`.
3. `cipherService.addCipherWithServer()` is called — this fails with a network error.
4. The error is caught by the catch-all block (after filtering out `ServerError`, 4xx `ResponseValidationError`, and `CipherAPIServiceError`).
5. `handleOfflineAdd()` is called (`VaultRepository.swift:1002`):
   - Saves the encrypted cipher to local Core Data via `cipherService.updateCipherWithLocalStorage()`
   - Encodes the cipher as `CipherDetailsResponseModel` JSON
   - Creates a pending change record with `.create` type via `pendingCipherChangeDataStore.upsertPendingChange()`
6. The user sees the cipher in their vault list immediately.

### 2. User Views the Offline-Created Cipher

**Entry point**: `ViewItemProcessor.streamCipherDetails()` (`ViewItemProcessor.swift:586`)

1. The `cipherDetailsPublisher` stream may fail for offline-created ciphers (the publisher's `asyncTryMap` can fail during decryption).
2. On failure, `fetchCipherDetailsDirectly()` is called as a fallback (`ViewItemProcessor.swift:604`).
3. This directly fetches and decrypts the cipher via `vaultRepository.fetchCipher(withId:)`.
4. The view state is populated via `buildViewItemState(from:)`.

### 3. User Edits the Cipher Again (Still Offline)

**Entry point**: `VaultRepository.updateCipher(_:)` (`VaultRepository.swift:957`)

1. The cipher is encrypted and `updateCipherWithServer()` fails again.
2. `handleOfflineUpdate()` is called (`VaultRepository.swift:1038`):
   - Saves locally
   - Checks for existing pending change — finds the `.create` record from step 1
   - Detects if the password changed by decrypting and comparing
   - Preserves the `.create` change type (important: the server hasn't seen this cipher yet)
   - Upserts the pending change with updated `cipherData`

### 4. Connectivity Returns — Sync Triggers

**Entry point**: `SyncService._syncAccountData()` (`SyncService.swift:326`)

1. Before the full sync, the vault lock status is checked.
2. `pendingCipherChangeDataStore.pendingChangeCount()` is called — returns 1 (or more).
3. `offlineSyncResolver.processPendingChanges()` is called (`OfflineSyncResolver.swift:106`).
4. The resolver iterates over pending changes:

### 5. Resolver Processes the Pending Create

**Entry point**: `OfflineSyncResolver.resolveCreate()` (`OfflineSyncResolver.swift:151`)

1. Decodes the stored cipher from `pendingChange.cipherData`.
2. Calls `cipherService.addCipherWithServer()` — succeeds this time.
3. The server assigns a new ID. The old temp-ID record is cleaned up via `cipherService.deleteCipherWithLocalStorage(id: tempId)`.
4. The pending change record is deleted.
5. The full sync proceeds normally (since `remainingCount == 0`).

### 6. Conflict Resolution (Alternative Path)

If the user had edited an existing cipher offline and the server version changed:

**Entry point**: `OfflineSyncResolver.resolveUpdate()` (`OfflineSyncResolver.swift:175`)

1. Fetches the server version via `cipherAPIService.getCipher(withId:)`.
2. Compares `originalRevisionDate` with server's `revisionDate` — they differ → conflict.
3. Calls `resolveConflict()` (`OfflineSyncResolver.swift:237`):
   - Compares timestamps to determine "winner"
   - Creates a backup of the "loser" via `createBackupCipher()` (`OfflineSyncResolver.swift:325`)
   - Pushes the "winner" to server or local storage

### 7. Data Cleanup

The pending change data is cleaned up in several ways:
- On successful online operation: `VaultRepository` cleans up orphaned pending changes
- On successful resolution: `OfflineSyncResolver` deletes resolved records
- On user logout/delete: `DataStore.swift` includes pending changes in batch delete
- On account data clear: `PendingCipherChangeData.deleteByUserIdRequest` is called

---

## Architecture Compliance Summary

| Principle | Status | Details |
|-----------|--------|---------|
| Core/UI layer separation | **Compliant** | All business logic in Core layer; UI only handles display fallback |
| Unidirectional data flow | **Compliant** | Processor pattern maintained in ViewItemProcessor |
| Protocol-based abstractions | **Compliant** | All new types use protocols (`OfflineSyncResolver`, `PendingCipherChangeDataStore`) |
| Dependency injection via ServiceContainer | **Compliant** | New deps added through Has protocols and initializers |
| Data store pattern (Core Data extension) | **Compliant** | `DataStore` extended with `PendingCipherChangeDataStore` conformance |
| Service single responsibility | **Compliant** | Resolver handles resolution; data store handles persistence; repository handles fallback |
| Repository as outermost core layer | **Compliant** | `VaultRepository` orchestrates the offline fallback decision |
| CODEOWNERS domain structure | **Compliant** | All new files within `Vault/` domain |
| Test co-location | **Compliant** | Tests alongside implementation |
| DocC documentation | **Compliant** | All public APIs documented |

See detailed section reviews for per-component analysis:
- [01: PendingCipherChangeData & DataStore](01_PendingCipherChangeData_Review.md)
- [02: OfflineSyncResolver](02_OfflineSyncResolver_Review.md)
- [03: VaultRepository](03_VaultRepository_Review.md)
- [04: SyncService](04_SyncService_Review.md)
- [05: DI Wiring](05_DIWiring_Review.md)
- [06: UI Layer](06_UILayer_Review.md)
- [07: CipherView Extensions](07_CipherViewExtensions_Review.md)

---

## Security Assessment

### Zero-Knowledge Architecture

| Check | Status |
|-------|--------|
| Pending change data encrypted at same level as vault | **Pass** — `cipherData` stores SDK-encrypted JSON |
| No encryption keys stored in pending change records | **Pass** — Only metadata stored as plaintext |
| SDK used for all encrypt/decrypt operations | **Pass** — No custom crypto |
| Organization cipher policy enforcement | **Pass** — Org ciphers excluded from offline edit |
| Data cleanup on logout/delete | **Pass** — Batch delete includes pending changes |
| No new attack surface for key extraction | **Pass** — No key material handling |

### Plaintext Metadata in Pending Changes

The following metadata is stored unencrypted (same as existing `CipherData` entity):
- `cipherId` (UUID)
- `userId` (UUID)
- `changeTypeRaw` (enum integer)
- `originalRevisionDate`, `createdDate`, `updatedDate` (timestamps)
- `offlinePasswordChangeCount` (counter)

This is consistent with the security model of the existing cipher storage.

### Potential Attack Vectors

1. **Local device compromise**: If a device is compromised, the attacker could see that offline edits were made and what type (create/update/delete). However, this is the same level of information available from the existing `CipherData` entity.
2. **Password change counting**: The `offlinePasswordChangeCount` reveals how many times a password was changed offline but not the actual passwords. This is a minor information leak. **[Explored and Resolved — Will Not Implement]** Encrypting this count was prototyped (AES-256-GCM with HKDF-derived key) and reverted after analysis showed the surrounding plaintext metadata (`changeTypeRaw`, timestamps, row count) and comparable unencrypted counts elsewhere in the app provide equivalent information to an attacker. See [AP-SEC2](../ActionPlans/Resolved/AP-SEC2_PasswordChangeCountEncryption.md).

**Overall Security Rating: Good** — The offline sync feature maintains the same security guarantees as the existing offline vault copy.

---

## Data Safety Assessment

This is the most critical assessment for a password manager. The offline sync feature's primary obligation is to **never lose user data**.

### Safety Properties

| Property | Status | Mechanism |
|----------|--------|-----------|
| User edits saved locally on failure | **Guaranteed** | `handleOffline*` methods save before recording pending change |
| Pending changes survive app restart | **Guaranteed** | Core Data persistence |
| Pending changes survive device reboot | **Guaranteed** | Core Data persistence |
| Sync doesn't overwrite unresolved changes | **Guaranteed** | Abort pattern in `SyncService._syncAccountData()` |
| Conflicts preserve both versions | **Guaranteed** | `createBackupCipher()` before any overwrite |
| Server-deleted cipher preserves offline edits | **Guaranteed** | `resolveUpdate` re-creates on 404 |
| Offline-created cipher visible to user | **Guaranteed** | Temp ID + ViewItemProcessor fallback |

### Risk Scenarios

| Scenario | Risk Level | Mitigation |
|----------|-----------|------------|
| Core Data corruption | **Low** | Inherent to Core Data; same risk as existing vault |
| App crash during resolution | **Low** | Pending change persists; retry on next sync |
| Duplicate cipher on create retry | **Low** | User can delete duplicate; original preserved |
| Very old pending changes after long offline period | **Low** | No expiration; changes resolve whenever connectivity returns |

**Overall Data Safety Rating: Good** — The design consistently prioritizes data preservation over correctness, which is the right trade-off for a password manager.

---

## Code Style Compliance

### Swift Style Guide (contributing.bitwarden.com)

| Rule | Status |
|------|--------|
| MARK comments before class definitions and sections | **Compliant** |
| DocC documentation on all public symbols | **Compliant** |
| Alphabetical ordering within sections | **Compliant** |
| Protocol implementation docs in protocol (not impl) | **Compliant** |
| CamelCase file naming | **Compliant** |
| 4-space indentation | **Compliant** |
| SwiftLint annotations where needed | **Compliant** (e.g., `function_parameter_count`, `type_body_length`) |

### Project Testing Guidelines (Testing.md)

| Rule | Status |
|------|--------|
| Test files co-located with implementation | **Compliant** |
| `BitwardenTestCase` inheritance | **Compliant** |
| setUp/tearDown with nil cleanup | **Compliant** |
| Test naming: `test_<function>_<behavior>` | **Compliant** |
| Tests grouped by function, then logically ordered | **Compliant** |
| Mocks for all dependencies | **Compliant** |

---

## Reliability & Error Handling

### Error Handling Patterns

| Pattern | Assessment |
|---------|-----------|
| Per-change error isolation in resolver | **Good** — One failure doesn't block others |
| Error classification in VaultRepository | **Good** — Conservative offline-fallback bias |
| Vault lock check before resolution | **Good** — Prevents crypto context errors |
| Error logging via `Logger.application` | **Good** — Errors traceable |
| Error reporting via `errorReporter` | **Good** — Used in ViewItemProcessor |

### Reliability Concerns

| Concern | Severity | Details |
|---------|----------|---------|
| No retry backoff for failed resolutions | **Medium** | Pending changes retried every sync without backoff |
| Silent sync abort on remaining changes | **Medium** | User has no visibility into why vault isn't updating |
| No data format versioning | **Low** | Old pending changes may fail to decode after app update |
| No maximum pending change age/count | **Low** | Unbounded accumulation possible during extended offline |
| ~~No feature flag to disable offline mode~~ | ~~**Low**~~ **[Resolved]** | Two server-controlled flags (`.offlineSyncEnableResolution`, `.offlineSyncEnableOfflineChanges`) gate all entry points; both default to `false` |

---

## Cross-Component Dependencies

### New Dependencies Introduced

```
VaultRepository ──→ PendingCipherChangeDataStore (new)
SyncService ──→ OfflineSyncResolver (new)
SyncService ──→ PendingCipherChangeDataStore (new)
OfflineSyncResolver ──→ CipherAPIService (existing)
OfflineSyncResolver ──→ CipherService (existing)
OfflineSyncResolver ──→ ClientService (existing)
OfflineSyncResolver ──→ PendingCipherChangeDataStore (new)
OfflineSyncResolver ──→ StateService (existing, potentially unused)
GetCipherRequest ──→ OfflineSyncError (new coupling)
```

### Assessment

- **All new dependencies are within the Vault domain** or cross to Platform services, which is the existing pattern.
- **No problematic cross-domain coupling** — the offline sync changes don't create dependencies between Auth/Autofill/Tools/Platform domains.
- **Minor concern**: `GetCipherRequest` (an API request model) now throws `OfflineSyncError.cipherNotFound` on 404. This couples a network-layer type to an offline-sync-specific error. A more general error (e.g., `CipherAPIServiceError.notFound`) would be better decoupled. However, the `GetCipherRequest` is currently only used by the offline sync resolver.
- **Minor concern**: `HasPendingCipherChangeDataStore` in the `Services` typealias exposes the data store to the UI layer unnecessarily (see [05: DI Wiring](05_DIWiring_Review.md)).

---

## External Dependencies

**No new external libraries or dependencies are introduced.** The feature uses:
- **Core Data** (Apple framework, already used)
- **BitwardenSdk** (already a project dependency)
- **OSLog** (Apple framework, already used)
- **Foundation** (Apple framework)

The `Package.resolved` changes in the diff are from upstream SDK version updates, not offline sync additions.

---

## Test Coverage Summary

| Component | Test File | Lines | Coverage |
|-----------|-----------|-------|----------|
| PendingCipherChangeDataStore | `PendingCipherChangeDataStoreTests.swift` | 286 | Comprehensive |
| OfflineSyncResolver | `OfflineSyncResolverTests.swift` | 933 | Comprehensive |
| VaultRepository (offline) | `VaultRepositoryTests.swift` | +671 | Comprehensive |
| SyncService (offline) | `SyncServiceTests.swift` | +90 | Good |
| ViewItemProcessor (fallback) | `ViewItemProcessorTests.swift` | +87 | Good |
| CipherView+OfflineSync | `CipherViewOfflineSyncTests.swift` | 171 | Comprehensive |
| **Total new test code** | | **~2,238** | |

See [08: Test Coverage Analysis](08_TestCoverage_Review.md) for detailed coverage matrix.

---

## Simplification Opportunities

### Reducing Code Size

1. **Extract error classification helper**: The four-way `do/catch` pattern in VaultRepository is repeated 4 times (~15 lines each). A generic helper could reduce ~40 lines. However, each catch block has slightly different parameters, making extraction somewhat awkward.

2. **Consolidate `handleOfflineDelete` and `handleOfflineSoftDelete`**: These methods share 80% of their logic. A shared helper with a parameter for the local operation type could save ~30 lines.

3. **Remove unused `stateService` from `OfflineSyncResolver`**: The resolver injects `StateService` but doesn't use it in any resolution method. Removing it would simplify the initializer.

4. **Remove `HasPendingCipherChangeDataStore` from `Services` typealias**: The data store is only used in the core layer. Removing it from the UI-exposed typealias would be more architecturally correct and would simplify the `ServiceContainer.withMocks()` helper.

### Architectural Simplifications

5. **Use a general `CipherAPIServiceError.notFound` instead of `OfflineSyncError.cipherNotFound`**: This would decouple `GetCipherRequest` from the offline sync error type.

6. **Consider inlining the `CipherView+OfflineSync` extension**: The `withId` and `update(name:)` methods are small and used in only 2 places. They could be inlined into the calling code, though the current extension approach is cleaner.

None of these simplifications are critical. The current codebase is well-structured and readable.

---

## Open Concerns & Action Items

These are organized by priority:

### Medium Priority

| ID | Concern | Details |
|----|---------|---------|
| R3 | No retry backoff | Failed resolutions retry every sync without exponential backoff |
| R4 | Silent sync abort | User has no visibility when sync is paused due to pending changes |
| ~~S8~~ | ~~No feature flag~~ | ~~Cannot disable offline mode if issues found in production~~ — **[Resolved]** Two server-controlled flags added |
| RES1 | Duplicate on create retry | If create succeeds but cleanup fails, retry creates duplicate |
| DI1 | DataStore in Services typealias | `PendingCipherChangeDataStore` exposed to UI layer unnecessarily |

### Low Priority

| ID | Concern | Details |
|----|---------|---------|
| R1 | No data format versioning | Old pending changes may fail after app update |
| U1 | Org cipher error timing | User sees generic network error, not offline-specific message |
| U2 | Inconsistent offline support | Only personal ciphers supported; no Send, no org items |
| U3 | No pending changes indicator | User can't see that changes are queued |
| VR2 | Delete → soft-delete conversion | Hard delete stored as soft-delete pending change |
| RES7 | Backup ciphers lack attachments | Backup copies don't include original attachments |
| RES9 | Implicit cipher data contract | `CipherDetailsResponseModel(cipher:)` could silently drop SDK fields |
| SS2 | TOCTOU in sync service | Count check and processing aren't atomic |
| PCDS1 | id optional but required | Swift property optional, schema required |
| PCDS2 | Dates optional but always set | `createdDate`/`updatedDate` optional but always initialized |

### Resolved/Superseded

Many issues from prior reviews have been resolved. See `_OfflineSyncDocs/ActionPlans/Resolved/` for details.

---

## File-by-File Coverage Matrix

This matrix confirms that every changed file is covered by this review.

### New Files (Offline Sync Specific)

| File | Review Section |
|------|---------------|
| `Core/Vault/Extensions/CipherView+OfflineSync.swift` | [07](07_CipherViewExtensions_Review.md) |
| `Core/Vault/Extensions/CipherViewOfflineSyncTests.swift` | [07](07_CipherViewExtensions_Review.md), [08](08_TestCoverage_Review.md) |
| `Core/Vault/Models/Data/PendingCipherChangeData.swift` | [01](01_PendingCipherChangeData_Review.md) |
| `Core/Vault/Services/OfflineSyncResolver.swift` | [02](02_OfflineSyncResolver_Review.md) |
| `Core/Vault/Services/OfflineSyncResolverTests.swift` | [02](02_OfflineSyncResolver_Review.md), [08](08_TestCoverage_Review.md) |
| `Core/Vault/Services/Stores/PendingCipherChangeDataStore.swift` | [01](01_PendingCipherChangeData_Review.md) |
| `Core/Vault/Services/Stores/PendingCipherChangeDataStoreTests.swift` | [01](01_PendingCipherChangeData_Review.md), [08](08_TestCoverage_Review.md) |
| `Core/Vault/Services/Stores/TestHelpers/MockPendingCipherChangeDataStore.swift` | [01](01_PendingCipherChangeData_Review.md) |
| `Core/Vault/Services/TestHelpers/MockCipherAPIServiceForOfflineSync.swift` | [02](02_OfflineSyncResolver_Review.md) |
| `Core/Vault/Services/TestHelpers/MockOfflineSyncResolver.swift` | [02](02_OfflineSyncResolver_Review.md) |
| `Core/Vault/Services/API/Cipher/Requests/GetCipherRequest.swift` | [02](02_OfflineSyncResolver_Review.md) |

### Modified Files (Offline Sync Integration)

| File | Review Section |
|------|---------------|
| `Core/Vault/Repositories/VaultRepository.swift` | [03](03_VaultRepository_Review.md) |
| `Core/Vault/Repositories/VaultRepositoryTests.swift` | [03](03_VaultRepository_Review.md), [08](08_TestCoverage_Review.md) |
| `Core/Vault/Services/SyncService.swift` | [04](04_SyncService_Review.md) |
| `Core/Vault/Services/SyncServiceTests.swift` | [04](04_SyncService_Review.md), [08](08_TestCoverage_Review.md) |
| `Core/Platform/Services/ServiceContainer.swift` | [05](05_DIWiring_Review.md) |
| `Core/Platform/Services/Services.swift` | [05](05_DIWiring_Review.md) |
| `Core/Platform/Services/TestHelpers/ServiceContainer+Mocks.swift` | [05](05_DIWiring_Review.md) |
| `Core/Platform/Services/Stores/DataStore.swift` | [01](01_PendingCipherChangeData_Review.md) |
| `Core/Platform/Services/Stores/Bitwarden.xcdatamodeld/...` | [01](01_PendingCipherChangeData_Review.md) |
| `UI/Vault/VaultItem/ViewItem/ViewItemProcessor.swift` | [06](06_UILayer_Review.md) |
| `UI/Vault/VaultItem/ViewItem/ViewItemProcessorTests.swift` | [06](06_UILayer_Review.md), [08](08_TestCoverage_Review.md) |
| `UI/Vault/VaultItem/ViewItem/ViewLoginItem/Extensions/CipherView+Update.swift` | [07](07_CipherViewExtensions_Review.md) |
| `UI/Vault/VaultItem/ViewItem/ViewLoginItem/Extensions/LoginViewUpdateTests.swift` | [07](07_CipherViewExtensions_Review.md) |
| `Core/Vault/Extensions/CipherWithArchive.swift` | [07](07_CipherViewExtensions_Review.md) |
| `UI/Vault/Extensions/Alert+Vault.swift` | [06](06_UILayer_Review.md) |
| `UI/Vault/Extensions/AlertVaultTests.swift` | [06](06_UILayer_Review.md), [08](08_TestCoverage_Review.md) |
| `Core/Vault/Services/TestHelpers/MockCipherService.swift` | [08](08_TestCoverage_Review.md), [09](09_UpstreamChanges_Review.md) |
| `Core/Vault/Services/CipherServiceTests.swift` | [08](08_TestCoverage_Review.md), [09](09_UpstreamChanges_Review.md) |
| `Core/Vault/Services/TestHelpers/BitwardenSdk+VaultMocking.swift` | [09](09_UpstreamChanges_Review.md) |

### Upstream / Incidental Changes (~126 files)

All upstream and incidental changes are cataloged in [09: Upstream Changes](09_UpstreamChanges_Review.md). These include:
- ~20 typo/spelling fixes across various files
- ~10 SDK API changes (`.authenticator` → `.vaultAuthenticator`, `emailHashes` removal)
- ~55 feature changes & test updates (Send feature, Auth domain, Vault UI, Autofill, Authenticator app, BitwardenKit)
- ~8 CI/build configuration updates
- ~6 localization updates
- ~2 other data files
- ~25 previous review documentation files

---

## Detailed Section Documents

| Document | Content |
|----------|---------|
| [01: PendingCipherChangeData & DataStore](01_PendingCipherChangeData_Review.md) | Core Data model, data store protocol, persistence |
| [02: OfflineSyncResolver](02_OfflineSyncResolver_Review.md) | Conflict resolution engine |
| [03: VaultRepository](03_VaultRepository_Review.md) | Offline fallback in CRUD operations |
| [04: SyncService](04_SyncService_Review.md) | Pre-sync resolution integration |
| [05: DI Wiring](05_DIWiring_Review.md) | ServiceContainer, Services typealias |
| [06: UI Layer](06_UILayer_Review.md) | ViewItemProcessor fallback, alerts |
| [07: CipherView Extensions](07_CipherViewExtensions_Review.md) | SDK type extensions |
| [08: Test Coverage](08_TestCoverage_Review.md) | Comprehensive test analysis |
| [09: Upstream Changes](09_UpstreamChanges_Review.md) | Non-offline-sync changes |
