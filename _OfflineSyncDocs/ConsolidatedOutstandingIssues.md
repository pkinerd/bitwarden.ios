# Offline Sync — Consolidated Outstanding Issues

> **Generated:** 2026-02-19 (updated 2026-02-21, issue status audit — verified all issues against implemented code, moved resolved/accepted action plans to subfolders)
> **Source:** All documents in `_OfflineSyncDocs/` including ActionPlans/, ActionPlans/Resolved/, ActionPlans/Accepted/, ActionPlans/Superseded/, and Review2/
> **Scope:** 53 documents reviewed across 13 parallel review passes + 2 gap analysis passes + action plan triage for all Review2 issues + implementation-phase fixes + code reconciliation pass + issue status audit

---

## Summary Statistics

| Category | Count | Notes |
|----------|-------|-------|
| **Open — Requires Code Changes** | 3 | R3, R1, U2-B |
| **Partially Addressed** | 1 | EXT-3/CS-2 |
| **Open — Accepted (No Code Change Planned)** | 38 | 11 (original Section 5) + 27 moved from Section 4 to `Accepted/` |
| **Deferred (Future Enhancement)** | 5 | Includes PLAN-3/AP-77 |
| **Review2 — Still Open** | 6 | 1 reliability (R2-PCDS-1) + 4 UX (AP-53, AP-54, AP-55, AP-78) |
| **Resolved / Superseded** | 62 | 58 previous + AP-34, AP-56, AP-69 (moved to `Resolved/`) + AP-68 (dead code removed) |
| **Total Unique Issues** | 114 | All issues accounted for across sections |

---

## Section 1: Open Issues Requiring Code Changes

These issues have been identified across multiple review documents and have actionable recommendations with estimated effort.

| # | Issue ID | Description | Severity | Complexity | Est. Effort | Related Documents | Notes |
|---|----------|-------------|----------|------------|-------------|-------------------|-------|
| 1 | **R3** | **No retry backoff for permanently failing resolution items.** A single permanently failing pending change blocks ALL syncing indefinitely via the early-abort pattern in `SyncService.swift:348-352`. No retry count, backoff, or expiry mechanism exists. | High | Medium | ~30-50 lines, 2-3 files, Core Data schema change | AP-R3, AP-00, OfflineSyncCodeReview.md, OfflineSyncChangelog.md, ReviewSection_SyncService.md, Review2/00_Main, Review2/02_OfflineSyncResolver | Most impactful remaining reliability issue. Recommended: Option D (`.failed` state) + Option A (retry count after 10 failures). Requires re-adding `timeProvider` dependency (removed in A3). |
| 2 | **R1** | **No data format versioning for `cipherData` JSON.** If `CipherDetailsResponseModel` changes in a future app update, old pending records fail to decode permanently, blocking sync. | Medium | Low | ~15-20 lines, 2-3 files, Core Data schema change | AP-R1, AP-00, OfflineSyncCodeReview.md, ReviewSection_PendingCipherChangeDataStore.md, Review2/02_OfflineSyncResolver | Add `dataVersion` attribute to Core Data entity (use Integer 64 per current schema conventions from `1bc17cb`). Deprioritize if R3 is implemented (R3 provides more general stuck-item solution). Bundle schema change with R3. |
| 3 | **U2-B** | **No offline-specific error messages for unsupported operations.** Archive, unarchive, restore, and collection assignment show generic network errors when attempted offline. | Medium | Low | ~20-30 lines, 1 file (VaultRepository.swift) | AP-U2, AP-00, OfflineSyncCodeReview.md, ReviewSection_VaultRepository.md, Review2/00_Main, Review2/03_VaultRepository | Add `OfflineSyncError.operationNotSupportedOffline` and catch blocks in 4 methods. Low effort, could ship in initial release. |

---

## Section 2: Partially Addressed Issues

These issues have been worked on but still have remaining gaps.

| # | Issue ID | Description | What's Done | What Remains | Severity | Complexity | Related Documents |
|---|----------|-------------|-------------|--------------|----------|------------|-------------------|
| 6 | **EXT-3 / CS-2** | **SDK `CipherView` manual copy fragility.** `makeCopy` manually copies 28 properties; new SDK properties with defaults are silently dropped. | `makeCopy` consolidation, DocC `- Important:` callouts, Mirror-based property count guard tests (28 CipherView, 7 LoginView). | Underlying fragility remains inherent to external SDK types. Developers must still manually add properties to `makeCopy` when tests fail. 5 copy methods across 2 files affected. | High | Medium | AP-CS2, ReviewSection_SupportingExtensions.md, Review2/07_CipherViewExtensions |

---

## Section 3: Deferred Issues (Future Enhancements)

| # | Issue ID | Description | Severity | Complexity | Dependencies | Related Documents |
|---|----------|-------------|----------|------------|--------------|-------------------|
| 23 | **U3** | No user-visible indicator for pending offline changes (badge, toast, banner) | Medium | High | Would require adding `HasPendingCipherChangeDataStore` to `Services` typealias (currently not exposed to UI layer) | AP-U3, AP-00, OfflineSyncCodeReview.md, Review2/00_Main |
| 24 | **U2-A** | Full offline support for archive/unarchive/restore operations (applies to all vaults — personal and org; archive requires premium; UI gated behind `.archiveVaultItems` feature flag) | Low | High | Archive UI gated behind `.archiveVaultItems` feature flag; archive requires premium | AP-U2, ReviewSection_VaultRepository.md |
| 26 | **DI-1-B** | Create separate `CoreServices` typealias for core-layer-only dependencies. **Note:** Impact reduced since `HasPendingCipherChangeDataStore` was never added to `Services` — only `HasOfflineSyncResolver` is exposed. | Low | High | Significant DI refactoring | AP-DI1 |
| 27 | **R4-C** | Return `SyncResult` enum from `fetchSync` (foundation for U3) | Low | Medium | API change affecting all callers | AP-R4 |
| 77 | **PLAN-3** | Phase 5 integration tests (end-to-end offline→reconnect→resolve) — existing `OfflineSyncResolverTests` with real `DataStore` already function as semi-integration tests | Medium | Medium | DefaultSyncService requires 19 dependencies; defer until integration test infrastructure exists | AP-77 (Deferred) |

---

## Section 4: Review2 Issues — Triaged (Action Plans Created)

These issues were identified in the second review pass. All have been triaged and have corresponding action plans in `ActionPlans/`.

> **[UPDATE 2026-02-21]** During the issue status audit, 28 items from this section were moved to `Accepted/` (their own action plan documents recommend "Accept As-Is") and 3 were moved to `Resolved/` (issue no longer applicable). Only 6 items remain open in Section 4. See subsections below.

### 4a. Code Quality / Cleanup

_All 10 issues in this section have been accepted as-is or resolved. Action plans moved to `Accepted/` or `Resolved/`:_

| # | Issue ID | Description | Disposition | Action Plan |
|---|----------|-------------|-------------|-------------|
| 30 | P2-CS1 | Redundant MARK comment — matches project conventions | Accepted | `Accepted/AP-30` |
| 31 | R2-MAIN-20 | Error classification duplication — explicit repetition preferred | Accepted | `Accepted/AP-31` |
| 33 | R2-EXT-3 | SDK fragility comments — guard tests provide centralized protection | Accepted | `Accepted/AP-33` |
| 34 | R2-EXT-4 | `@retroactive CipherWithArchive` — annotation does not exist in current code | Resolved | `Resolved/AP-34` |
| 72 | R2-SS-5 | Two `pendingChangeCount` calls — more robust than single return value | Accepted | `Accepted/AP-72` |
| 73 | R2-SS-6 | Pre-sync resolution extraction — 8 lines of actual code, well-commented | Accepted | `Accepted/AP-73` |
| 74 | R2-RES-10 | `resolveConflict` symmetry — explicit form more readable | Accepted | `Accepted/AP-74` |
| 75 | R2-RES-11 | Hardcoded threshold — unlikely to need remote tuning | Accepted | `Accepted/AP-75` |
| 76 | R2-VR-9 | Cipher roundtrip — required by SDK type constraints | Accepted | `Accepted/AP-76` |
| 84 | R2-EXT-5 | Extension inlining — current approach cleaner per review | Accepted | `Accepted/AP-84` |

### 4b. Test Coverage Gaps

_All 6 issues in this section have been resolved, accepted as-is, or deferred. See Sections 5, 3, and 6 for details._

### 4c. Reliability / Edge Cases

| # | Issue ID | Description | Severity | Complexity | Action Plan | Related Documents |
|---|----------|-------------|----------|------------|-------------|-------------------|
| 48 | **R2-PCDS-1** | No Core Data schema versioning step — current entity addition works via lightweight migration but future attribute changes require explicit versioning | Medium | Medium | AP-R2-PCDS-1 | Review2/01_PendingCipherChangeData |

_2 issues accepted as-is: #43 R2-MAIN-7 (max pending change limit — unbounded accumulation risk is very low) → `Accepted/AP-R2-MAIN-7`; #44 R2-RES-2 (clock skew — both versions always preserved) → `Accepted/AP-R2-RES-2`._

### 4d. UX Improvements

| # | Issue ID | Description | Severity | Complexity | Action Plan | Related Documents |
|---|----------|-------------|----------|------------|-------------|-------------------|
| 53 | **R2-UI-1** | Fallback `fetchCipherDetailsDirectly()` is a one-time fetch, not a stream — no live updates while viewing offline-created cipher | Low | Medium | AP-53 | Review2/06_UILayer |
| 54 | **R2-UI-2** | Generic "An error has occurred" message when both publisher stream and fallback fail — should show offline-specific message | Low | Low | AP-54 | Review2/06_UILayer |
| 55 | **VR-4** | No user feedback on successful offline save — operation completes silently | Low | Medium | AP-55 | ReviewSection_VaultRepository.md |
| 78 | **R2-MAIN-2** | No offline support for attachment operations — attachment upload/download requires server communication; distinct from org cipher exclusion (U2) | Low | High | AP-78 | Review2/00_Main |

### 4e. Upstream / Process Concerns

_All 6 issues in this section have been accepted as-is or resolved. Changes are properly applied, verified, and have no impact on offline sync functionality._

| # | Issue ID | Description | Disposition | Action Plan |
|---|----------|-------------|-------------|-------------|
| 56 | R2-UP-1 | SDK API changes — verified no interaction with offline sync | Resolved | `Resolved/AP-56` |
| 57 | R2-UP-3 | `PassthroughSubject` change — semantically correct | Accepted | `Accepted/AP-57` |
| 58 | R2-UP-4 | ~60% upstream changes — review completed with awareness | Accepted | `Accepted/AP-58` |
| 59 | R2-UP-5 | ExportVaultService typo fix — applied consistently | Accepted | `Accepted/AP-59` |
| 79 | R2-DI-6 | Incidental typo fixes — applied consistently | Accepted | `Accepted/AP-79` |
| 80 | R2-UP-6 | AuthCoordinator parameter rename — applied consistently | Accepted | `Accepted/AP-80` |

### 4f. Minor / Informational

_All 14 issues in this section have been accepted as-is or resolved. All are low-severity informational items consistent with existing project patterns._

| # | Issue ID | Description | Disposition | Action Plan |
|---|----------|-------------|-------------|-------------|
| 60 | TC-5 | `@MainActor` test annotation — pre-existing pattern | Accepted | `Accepted/AP-60` |
| 61 | TC-8 | Mock defaults convention — consistent with project pattern | Accepted | `Accepted/AP-61` |
| 62 | R2-RES-4 | Backup naming timezone — device-local is user-friendly | Accepted | `Accepted/AP-62` |
| 63 | R2-RES-8 | Sequential batch processing — correct for conflict resolution | Accepted | `Accepted/AP-63` |
| 65 | TC-4 | `isVaultLocked` caching — pre-existing pattern, very low risk | Accepted | `Accepted/AP-65` |
| 66 | R2-UI-3 | `specificPeopleUnavailable` — upstream change, properly implemented | Accepted | `Accepted/AP-66` |
| 67 | PCDS-3/4 | Fetch-then-update — safe with serial queue + uniqueness constraint | Accepted | `Accepted/AP-67` |
| 69 | R2-UP-2 | `CipherPermissionsModel` typo fix — already applied | Resolved | `Resolved/AP-69` |
| 70 | PLAN-1 | Denylist future SDK errors — data preservation bias correct | Accepted | `Accepted/AP-70` |
| 71 | PLAN-2 | Sync resolution delay — foreground sync covers common case | Accepted | `Accepted/AP-71` |
| 81 | PLAN-4 | Core Data file protection — codebase-wide decision | Accepted | `Accepted/AP-81` |
| 82 | R2-CROSS-1 | Schema migration bundling — planning note for R1/R3 | Accepted | `Accepted/AP-82` |
| 85 | R2-UI-4 | `buildViewItemState` decomposition — within acceptable limits | Accepted | `Accepted/AP-85` |

---

## Section 5: Open Issues — Accepted As-Is (No Code Change Planned)

These issues have been reviewed and a deliberate decision was made to accept the current behavior.

| # | Issue ID | Description | Severity | Rationale | Related Documents |
|---|----------|-------------|----------|-----------|-------------------|
| 11 | **U1** | Org cipher error appears after full network timeout delay (30-60s) | Low | Inherent tradeoff of detecting offline by API failure. Narrow scenario. | AP-U1, OfflineSyncCodeReview.md, ReviewSection_VaultRepository.md |
| 12 | **DI-1** | `HasOfflineSyncResolver` in `Services` typealias exposes resolver to UI layer. **Note:** `HasPendingCipherChangeDataStore` does NOT exist in `Services.swift` — the data store is passed directly via initializers to `DefaultVaultRepository` and `DefaultSyncService`, not through the `Services` typealias. Only `HasOfflineSyncResolver` (line 40) is in the typealias. The original DI-2 concern about data store exposure is therefore moot. | Low | Consistent with existing project patterns. Enables future U3. | AP-DI1, ReviewSection_DIWiring.md, Review2/05_DIWiring |
| 16 | **RES-9** | Implicit `cipherData` non-nil contract for resolution methods | Low | Defensive `missingCipherData` guards exist. Contract maintained by 4 callers. | AP-RES9, OfflineSyncCodeReview.md, ReviewSection_OfflineSyncResolver.md |
| 17 | **SS-2** | TOCTOU race condition between `remainingCount` check and `replaceCiphers` | Low | Microsecond window. Pending change record survives; next sync resolves. | AP-SS2, ReviewSection_SyncService.md, Review2/04_SyncService |
| 18 | **PCDS-1** | `PendingCipherChangeData.id` optional in Swift but required in Core Data schema | Low | Core Data `@NSManaged` limitation, not a design flaw. | AP-PCDS1, ReviewSection_PendingCipherChangeDataStore.md |
| 19 | **PCDS-2** | `createdDate`/`updatedDate` optional but always set in convenience init | Low | Nil fallback chain handles safely. | AP-PCDS2, ReviewSection_PendingCipherChangeDataStore.md |
| 20 | **VR-3** | Password change detection only compares `login?.password`, not other sensitive fields | Low | By design — soft conflict threshold targets highest-risk field. | ReviewSection_VaultRepository.md |
| 21 | **A4** | `GetCipherRequest.validate(_:)` coupled to `OfflineSyncError` semantics | Low | Acceptable coupling. | OfflineSyncCodeReview.md |
| 36 | **R2-TEST-2** | Core Data lightweight migration (adding `PendingCipherChangeData` entity) has no automated test | Medium | Entity addition is the safest lightweight migration; no other entities have migration tests; SQLite fixture effort unjustified for entity-add risk level | AP-36 (Accepted As-Is) |
| 40 | **P2-T4** | Fallback fetch in `ViewItemProcessor` doesn't re-establish subscription; no test for cipher update after fallback | Low | Negative timeout tests are inherently flaky; existing positive-path coverage sufficient; subscription gap is an intentional design simplification | AP-40 (Accepted As-Is) |
| 41 | **TC-6** | Mock defaults silently bypass abort logic: 24 of 25 `fetchSync` tests use default `pendingChangeCountResult = 0` with no assertions about offline resolution | Medium | `test_fetchSync_preSyncResolution_skipsWhenResolutionFlagDisabled` already covers the negative path; feature flag default `false` provides strong gate | AP-41 (Accepted As-Is) |

---

## Section 6: Resolved / Superseded Issues (Reference Only)

| Issue ID | Description | Resolution | Commit/Reference |
|----------|-------------|------------|-------------------|
| S3 | No batch processing test | 3 batch tests added | `4d65465` |
| S4 | No API failure during resolution test | 4 tests added | `4d65465` |
| S6 | No password change counting test | 4 tests added | `4d65465` |
| T5 | Inline mock fragility | Mock extracted to dedicated file | `4d65465` |
| T6 | Incomplete URLError test coverage | Extension and tests deleted | `e13aefe` |
| T7 | No subsequent offline edit test | Covered by `preservesCreateType` test | `12cb225` |
| T8 | No hard error in pre-sync resolution test | Test added | `4d65465` |
| R2 | `conflictFolderId` thread safety | Converted to `actor`; state removed | `9415019` |
| SEC-1 | `secureConnectionFailed` in offline triggers | URLError extension deleted | `e13aefe` |
| SEC-2 | `offlinePasswordChangeCount` unencrypted | Analyzed; Will Not Implement | Prototype reverted |
| EXT-1 | `.timedOut` classification too broad | URLError extension deleted | `e13aefe` |
| EXT-2 | Same as SEC-1 | Superseded by deletion | `e13aefe` |
| EXT-4 | Same as T6 | Superseded by deletion | `e13aefe` |
| VI-1 | Offline-created cipher infinite spinner | `CipherView.withId()` replaces `Cipher.withTemporaryId()` | `3f7240a` |
| CS-1 | Stray blank line | Removed | `a52d379` |
| CS-2 | Fragile SDK copy methods | `makeCopy` consolidation + property count guard tests | `1effe90` |
| A3 | Unused `timeProvider` dependency | Removed | `a52d379` |
| U4 | English-only conflict folder name | Conflict folder removed entirely | N/A |
| S8 | No feature flag / kill switch | Two server-controlled flags added | Implemented |
| DI-3 | Stray blank line in Services.swift | Removed | `a52d379` |
| DI-4 | Shared resolver instance thread safety | Actor conversion + state removed | Resolved |
| R2-A2 | Unused `stateService` dependency in `DefaultOfflineSyncResolver` | Already removed; dependency does not exist in current code | AP-28 (Resolved) |
| R2-DI-5 | DocC parameter block in `ServiceContainer.swift` init — alphabetical order | Already in correct alphabetical order in current code | AP-29 (Resolved) |
| R4 | Silent sync abort — no logging | Added `Logger.application.info()` log line in SyncService | AP-R4 (Resolved) |
| S7 | VaultRepository cipher-not-found test gap | Added `test_deleteCipher_offlineFallback_cipherNotFound_noOp` | AP-S7 (Resolved) |
| R2-MAIN-21 | `handleOfflineDelete`/`handleOfflineSoftDelete` duplication | Extracted `cleanUpOfflineCreatedCipherIfNeeded` helper | AP-32 (Resolved) |
| TC-7 | Narrow error type coverage in offline fallback tests | Won't-fix — `unknownError` tests already prove generic catch path; additional error types add no branch coverage | N/A |
| VI-1 | Offline-created cipher view failure (`data: nil`) | All 5 fixes implemented; `CipherView.withId()` replaces `Cipher.withTemporaryId()` | AP-VI1 (Resolved) |
| P2-T2 | `resolveCreate` partial failure (duplicate cipher scenario) | Unrealistic — local storage failure implies catastrophic issues beyond offline sync scope; won't-fix | AP-39 (Resolved) |
| P2-T3 | Orphaned pending change cleanup failure after server success | Hypothetical — same class as P2-T2; Core Data delete on serial context cannot realistically fail | AP-P2-T3 (Resolved) |
| RES-1 | Potential duplicate cipher on create retry after partial failure | Hypothetical — same class as P2-T2; requires Core Data write failure after server success, which implies catastrophic storage issues | AP-RES1 (Resolved) |
| R2-VR-5 | JSONEncoder().encode in offline helpers could theoretically fail | Hypothetical — encoding cannot fail for standard Codable types; same encoding used throughout app's cipher storage pipeline | AP-R2-VR-5 (Resolved) |
| R2-VR-6 | `getActiveAccountId()` in `handleOfflineDelete` could throw on logout | Hypothetical — sub-millisecond window; state service returns stored state, not auth state; UI lifecycle prevents logout during active operation | AP-R2-VR-6 (Resolved) |
| R2-PCDS-4 | Upsert race condition — fetch-then-insert/update not atomic | Hypothetical — prevented by serial backgroundContext, uniqueness constraint, and merge policy; same pattern used by all data stores | AP-R2-PCDS-4 (Resolved) |
| R2-PCDS-5 | Core Data corruption risk — pending changes lost | Inherent platform limitation — applies to all Core Data entities equally; not specific to offline sync | AP-R2-PCDS-5 (Resolved) |
| R2-VR-1 | Error classification catch-all may be overly broad | Design decision — only URLError and 5xx ResponseValidationError realistically reach catch-all; bias toward data preservation is correct for password manager; feature flags provide kill switch | AP-R2-VR-1 (Resolved) |
| S8.a | Orphaned pending changes when feature flag disabled | Design decision — two-flag architecture provides graceful wind-down path (disable new saves while draining existing queue); orphaned records are intentional, harmless (~1-5 KB), recoverable on re-enable, and cleaned on logout | AP-S8 (Resolved) |
| R2-VR-4 | Offline update decryption cost (decrypt previous version to compare passwords) | Accept as-is — sub-millisecond AES-GCM decryption + JSON decode per user-initiated save; user editing cadence is natural rate limiter; Core Data I/O dominates cost | AP-64 (Resolved) |
| SEC-2.a | SEC-2 revisit conditions (plaintext `offlinePasswordChangeCount`) | Accept as-is — none of four revisit conditions met (no DB encryption, no security model change, count remains ephemeral, no audit mandate); SEC-2 prototype available if conditions change | AP-83 (Resolved) |
| VR-2 | Permanent delete converted to soft delete when offline | `.hardDelete` change type added; resolver calls permanent delete API; conflict restores server version | `34b6c24` |
| VR2-B | Add `PendingCipherChangeType.permanentDelete` for offline permanent delete | `.hardDelete` added to `PendingCipherChangeType` with string-backed raw value | `34b6c24` |
| RES-7 | Backup ciphers do not include attachments | Accepted design decision — attachment duplication requires download/re-encrypt/upload per attachment, disproportionately complex for sync resolution; primary cipher attachments preserved | AP-RES7 (Resolved) |
| SS-1 | Pre-sync resolution error propagation blocks all syncing | Accepted design decision — correct fail-safe behavior; Core Data failure indicates serious system issue; blocking sync prevents data corruption | N/A (Resolved) |
| T5 / RES-6 | Manual mock uses 16 `fatalError()` stubs | Accepted design decision — compiler enforces conformance; `fatalError()` is runtime-only risk in tests; adding `AutoMockable` to `CipherAPIService` is broader project decision outside offline sync scope | AP-T5 (Resolved) |
| CD-TYPE-1 | `PendingCipherChangeType` stored as Int16 — fragile to enum case reordering; `offlinePasswordChangeCount` stored as Int16 — unnecessary constraint | Changed `changeTypeRaw` to String-backed storage and `offlinePasswordChangeCount` to Integer 64; also fixed `changeTypeRaw` optionality (`String` → `String?`) to match Core Data KVC semantics | `1bc17cb`, `d7a77c9` |
| CD-TYPE-2 | Int32 vs Int16 type mismatch in `setupPendingChange` test helper | Fixed `offlinePasswordChangeCount` parameter type in test helper | `d168860` |
| TEST-FLAKE-1 | Non-deterministic OfflineSyncResolverTests (13-15 failures) due to DataStore lifecycle — `setupPendingChange` created local DataStore that went out of scope, releasing managed object context via ARC | Promoted DataStore to class-level property in `setUp()` so context stays alive for full test duration | `710bc04` |
| R2-TEST-1 | `GetCipherRequest` 404 validation (`validate(_:)` throwing `OfflineSyncError.cipherNotFound`) had no direct unit test | Created `GetCipherRequestTests.swift` with `test_method`, `test_path`, and `test_validate` covering 200/400/500 (no throw) and 404 (throws `.cipherNotFound`) | AP-35 (Resolved) |
| R2-TEST-5 | Corrupt `cipherData` in pending change — no test for resolver handling malformed JSON | Added 3 tests: `create_corruptCipherData_skipsAndRetains`, `update_corruptCipherData_skipsAndRetains`, and `batch_corruptAndValid_validItemResolves` | AP-38 (Resolved) |
| TC-2 | Missing negative assertions in happy-path tests — 4 tests pass through offline do/catch code without asserting upsert was NOT called | Added `XCTAssertTrue(pendingCipherChangeDataStore.upsertPendingChangeCalledWith.isEmpty)` to `test_addCipher`, `test_deleteCipher`, `test_updateCipher`, `test_softDeleteCipher` | N/A (Resolved) |
| P2-TEST-T1 | No test for `missingCipherData` guard in resolver — create and update paths with nil `cipherData` untested | Added `test_processPendingChanges_create_nilCipherData_skipsAndRetains` and `test_processPendingChanges_update_nilCipherData_skipsAndRetains` to `OfflineSyncResolverTests` | N/A (Resolved) |
| P2-TEST-T3 | `resolveCreate` temp-ID cleanup not asserted — `deleteCipherWithLocalStorage` call after server create not verified | Added `XCTAssertEqual(cipherService.deleteCipherWithLocalStorageId, "cipher-1")` assertion to `test_processPendingChanges_create` | N/A (Resolved) |
| P2-TEST-T4 | `changeType` computed property fallback for nil `changeTypeRaw` not tested | Added `test_changeType_nilChangeTypeRaw_defaultsToUpdate` to `PendingCipherChangeDataStoreTests` — manually sets `changeTypeRaw = nil` via Core Data context and verifies `.update` default | N/A (Resolved) |
| P2-TEST-T5 | `changeType` computed property fallback for invalid `changeTypeRaw` not tested | Added `test_changeType_invalidChangeTypeRaw_defaultsToUpdate` to `PendingCipherChangeDataStoreTests` — sets `changeTypeRaw = "unknownType"` and verifies `.update` default | N/A (Resolved) |
| P2-TEST-T6 | `fetchPendingChanges` sort order by `createdDate` not verified | Added `test_fetchPendingChanges_sortedByCreatedDate` to `PendingCipherChangeDataStoreTests` — inserts records with delay and verifies ascending sort | N/A (Resolved) |
| P2-TEST-T7 | Nil `originalRevisionDate` conflict detection behavior untested — edge case where first offline edit predates revision date tracking | Added `test_processPendingChanges_update_nilOriginalRevisionDate_noConflict` to `OfflineSyncResolverTests` — verifies update proceeds without conflict when revision date is nil | N/A (Resolved) |
| P2-TEST-RND | No round-trip test for all four `PendingCipherChangeType` enum cases through Core Data string-backed storage | Added `test_allChangeTypes_roundTripThroughCoreData` to `PendingCipherChangeDataStoreTests` — exercises `.update`, `.create`, `.softDelete`, `.hardDelete` persistence | N/A (Resolved) |
| R2-TEST-3 | `PendingCipherChangeData.deleteByUserIdRequest` addition to batch delete not explicitly tested | Added `test_deleteDataForUser_deletesPendingCipherChanges` to `PendingCipherChangeDataStoreTests` — verifies `DataStore.deleteDataForUser(userId:)` removes pending changes for target user while preserving other users' data | AP-37 (Resolved) |
| R2-TEST-4 | Very long cipher names in backup naming pattern not tested for edge cases | Added `test_processPendingChanges_update_conflict_backupNameFormat` and `test_processPendingChanges_update_conflict_emptyNameBackup` to `OfflineSyncResolverTests` — verifies backup name format pattern and empty-name edge case | AP-42 (Resolved) |
| RES-vaultLocked | `.vaultLocked` error case defined but never thrown — dead code | Removed `.vaultLocked` case from `OfflineSyncError` enum and associated test | AP-68 (Resolved) |

---

## Reconciliation Notes (2026-02-21)

The following discrepancies were identified during a comprehensive code reconciliation pass that verified all documentation claims against the actual source code on the `claude/reconcile-docs-changes-DKIDj` branch (tree hash `7e24354`, identical to `origin/dev`).

### Corrections Applied

| # | Discrepancy | Affected Docs | Correction |
|---|-------------|---------------|------------|
| 1 | **`HasPendingCipherChangeDataStore` does not exist in `Services.swift`.** Multiple docs claimed this protocol was added to the `Services` typealias alongside `HasOfflineSyncResolver`. In reality, only `HasOfflineSyncResolver` exists at `Services.swift:40`. The `pendingCipherChangeDataStore` is injected directly via initializers to `DefaultVaultRepository` and `DefaultSyncService`, never through the `Services` typealias. | ConsolidatedOutstandingIssues.md, OfflineSyncCodeReview.md, ReviewSection_DIWiring.md, OfflineSyncPlan.md, OfflineSyncChangelog.md, Review2/05_DIWiring_Review.md, AP-DI1 | DI-1/DI-2 issue updated to reflect only `HasOfflineSyncResolver` is exposed. DI-2 concern about data store UI exposure is moot. |
| 2 | **`changeTypeRaw` is `String?`, not `Int16`.** ReviewSection_PendingCipherChangeDataStore.md stated `changeTypeRaw: Int16` and `offlinePasswordChangeCount: Int16`. The actual Core Data schema uses `changeTypeRaw: String` (optional) and `offlinePasswordChangeCount: Integer 64`. This was fixed in commits `1bc17cb`/`d7a77c9` (CD-TYPE-1) but the ReviewSection doc was not updated. | ReviewSection_PendingCipherChangeDataStore.md | Updated attribute types to match actual schema. |
| 3 | **`DefaultOfflineSyncResolver` has 4 dependencies, not 5.** ReviewSection_OfflineSyncResolver.md claimed 5 dependencies including `stateService`. The `stateService` was removed in commit `a52d379` (AP-A3). The current dependencies are: `cipherAPIService`, `cipherService`, `clientService`, `pendingCipherChangeDataStore`. | ReviewSection_OfflineSyncResolver.md | Updated dependency count and list. |
| 4 | **SyncService line numbers shifted.** The pre-sync resolution block is at lines 330-355 (not 326-347 or 334-343 as various docs claimed). The abort pattern is at lines 348-352. | ConsolidatedOutstandingIssues.md, ReviewSection_SyncService.md | Updated line references. |
| 5 | **Issue numbering gap in Section 1.** Items numbered 1, 4, 5 with no #2 or #3. | ConsolidatedOutstandingIssues.md | Renumbered to 1, 2, 3 for consistency. |
| 6 | **`addCipherWithServer` signature.** The resolver at line 344-346 calls `cipherService.addCipherWithServer(encryptionContext.cipher, encryptedFor: encryptionContext.encryptedFor)` — this is not an encryption context wrapper, it takes `(_ cipher: Cipher, encryptedFor: String)` directly. | ReviewSection_OfflineSyncResolver.md | Clarified actual API signature. |

### Verified Claims (No Correction Needed)

The following key claims were verified as accurate against the source code:
- `OfflineSyncError` has exactly 4 cases: `.missingCipherData`, `.missingCipherId`, `.vaultLocked`, `.cipherNotFound`
- `PendingCipherChangeType` has exactly 4 cases: `.update`, `.create`, `.softDelete`, `.hardDelete` (String-backed)
- Feature flags: `.offlineSyncEnableResolution` (`"offline-sync-enable-resolution"`) and `.offlineSyncEnableOfflineChanges` (`"offline-sync-enable-offline-changes"`)
- `DefaultOfflineSyncResolver` is an `actor` (not class)
- `softConflictPasswordChangeThreshold` is `4` (as `Int64`)
- `CipherView.makeCopy()` copies 28 properties
- Core Data entity has 9 attributes with `(userId, cipherId)` uniqueness constraint
- `cleanUpOfflineCreatedCipherIfNeeded` helper shared by `handleOfflineDelete` and `handleOfflineSoftDelete`
- Pre-sync resolution flow: vault lock guard → feature flag check → count check → resolve → remaining count → abort if > 0
- All 4 VaultRepository methods (add/update/delete/softDelete) follow the denylist error pattern
- `ViewItemProcessor.fetchCipherDetailsDirectly()` is the offline fallback at lines 619-632
- `GetCipherRequest.validate(_:)` throws `.cipherNotFound` on HTTP 404

### Issue Status Audit (2026-02-21)

A comprehensive audit verified all issues against the current codebase and reorganized action plans.

#### Action Plans Moved to `Resolved/` (7 total)

| Action Plan | Issue ID | Verification |
|-------------|----------|--------------|
| AP-34 | R2-EXT-4 | `@retroactive CipherWithArchive` annotation does not exist in current code — issue not applicable |
| AP-35 | R2-TEST-1 | `GetCipherRequestTests.swift` with 3 tests (`test_method`, `test_path`, `test_validate`) confirmed present |
| AP-37 | R2-TEST-3 | `test_deleteDataForUser_deletesPendingCipherChanges` at `PendingCipherChangeDataStoreTests.swift:404` confirmed present |
| AP-38 | R2-TEST-5 | 3 corrupt data tests in `OfflineSyncResolverTests.swift` confirmed present (lines 879, 896, 915) |
| AP-42 | R2-TEST-4 | `test_processPendingChanges_update_conflict_backupNameFormat` and `emptyNameBackup` in `OfflineSyncResolverTests.swift` confirmed present (lines 1009, 1057) |
| AP-56 | R2-UP-1 | SDK API changes (`.authenticator` → `.vaultAuthenticator`, `emailHashes` removal) verified — no interaction with offline sync code |
| AP-69 | R2-UP-2 | `CipherPermissionsModel` typo fix already applied consistently — documentation-only change |

#### Action Plans Moved to `Accepted/` (31 total)

| Action Plan | Issue ID | Rationale |
|-------------|----------|-----------|
| AP-30 | P2-CS1 | MARK comment matches project-wide conventions |
| AP-31 | R2-MAIN-20 | Explicit error handling repetition preferred over abstraction |
| AP-33 | R2-EXT-3 | Guard tests provide centralized automated protection |
| AP-36 | R2-TEST-2 | Entity addition is safest lightweight migration; no other entities have migration tests |
| AP-40 | P2-T4 | Stale-state-after-fallback is intentional design; negative timeout tests inherently flaky |
| AP-41 | TC-6 | Feature flag default `false` provides strong gate |
| AP-57 | R2-UP-3 | `PassthroughSubject` change is semantically correct for event stream |
| AP-58 | R2-UP-4 | Review completed with full awareness of upstream distinction |
| AP-59 | R2-UP-5 | Typo fix already applied consistently |
| AP-60 | TC-5 | `@MainActor` annotation is pre-existing project pattern |
| AP-61 | TC-8 | Mock defaults follow established `withMocks()` convention |
| AP-62 | R2-RES-4 | Device-local timezone more user-friendly for backup names |
| AP-63 | R2-RES-8 | Sequential processing is correct design for conflict resolution |
| AP-65 | TC-4 | Pre-existing caching pattern; extremely low stale-data risk |
| AP-66 | R2-UI-3 | Upstream Send feature change; properly implemented and tested |
| AP-67 | PCDS-3/4 | Safe with serial queue + uniqueness constraint + merge policy |
| ~~AP-68~~ | ~~RES-vaultLocked~~ | _Resolved — dead `.vaultLocked` case removed (see `Resolved/AP-68`)_ |
| AP-70 | PLAN-1 | Data preservation bias is correct for password manager |
| AP-71 | PLAN-2 | Foreground sync covers common reconnection case |
| AP-72 | R2-SS-5 | Two-count pattern more robust than single return value |
| AP-73 | R2-SS-6 | Block is only 8 lines of actual code, well-commented |
| AP-74 | R2-RES-10 | Explicit form more readable than abstraction |
| AP-75 | R2-RES-11 | Threshold unlikely to need remote tuning |
| AP-76 | R2-VR-9 | Roundtrip required by SDK type constraints |
| AP-79 | R2-DI-6 | Typo fixes properly applied and consistent |
| AP-80 | R2-UP-6 | Parameter rename properly applied throughout |
| AP-81 | PLAN-4 | Codebase-wide file protection decision; unchanged by feature |
| AP-82 | R2-CROSS-1 | Planning note for R1/R3 schema changes |
| AP-84 | R2-EXT-5 | Extension approach cleaner per review assessment |
| AP-85 | R2-UI-4 | Method within acceptable limits per review |
| AP-R2-MAIN-7 | R2-MAIN-7 | Unbounded accumulation risk very low (~1-5 KB per item) |
| AP-R2-RES-2 | R2-RES-2 | Both versions always preserved; clock skew rare on iOS |

#### Newly Confirmed Resolutions

| Issue ID | Finding |
|----------|---------|
| **R4** | `Logger.application.info()` at `SyncService.swift:349-351` confirmed — sync abort is now logged |
| **S7** | `test_deleteCipher_offlineFallback_cipherNotFound_noOp` at `VaultRepositoryTests.swift:928` confirmed — fully resolved (was "partially resolved") |
| **VR-2** | `.hardDelete` case exists in `PendingCipherChangeType` — permanent delete is properly supported offline |

#### Open Issues Confirmed Still Open (No Code Changes Found)

| Issue ID | Verification |
|----------|--------------|
| **R3** | No retry count, backoff, or `.failed` state in `PendingCipherChangeData` or `OfflineSyncResolver`. Zero matches for `retryCount`, `maxRetries`, `failedState` across all Swift files. |
| **R1** | No `dataVersion` attribute in `PendingCipherChangeData`. Entity has 9 attributes only. |
| **U2-B** | `OfflineSyncError` has exactly 3 cases (`missingCipherData`, `missingCipherId`, `cipherNotFound`); no `operationNotSupportedOffline`. Archive/unarchive/restore methods have no offline-specific error handling. |
| **EXT-3/CS-2** | `makeCopy()` still manually copies 28 properties. DocC `- Important:` callout and Mirror-based guard tests present. Underlying fragility inherent to external SDK types. |

#### Summary Statistics Updated

- **Open — Accepted**: 11 → 38 (27 items from Section 4 whose action plans recommend "Accept As-Is" moved to `Accepted/`)
- **Resolved / Superseded**: 36 → 62 (22 from implementation phase + 3 newly resolved: AP-34, AP-56, AP-69 + AP-68 dead code removed)
- **Review2 — Still Open**: 37 → 6 (27 accepted, 3 resolved, AP-68 resolved)
- **Total Unique Issues**: 93 → 114 (includes newly tracked implementation-phase issues)
- **Remaining code changes needed**: 3 items (R3, R1, U2-B)
- **Action plan folder reorganization**: 41 `Resolved/`, 38 `Accepted/`, 2 `Superseded/`, 10 open (including 2 meta-docs)

---

## Priority Recommendation

### Immediate (Quick Wins)
1. **U2-B** — Add offline-specific error messages (~20-30 lines)

### Should Address (Pre-Release)
2. **R3** — Retry backoff with failed state (~30-50 lines, Core Data schema change)
3. **R1** — Data format versioning (bundle with R3 schema change)

### Post-Release
4. **U3** — Pending changes indicator (toast on offline save)
5. **EXT-3** — Monitor SDK updates for property changes (ongoing)
6. **Review2 test gaps** — Section 4b fully resolved: #37 and #42 implemented with new tests; #36, #40, #41 accepted as-is; #77 deferred (existing resolver tests with real DataStore provide semi-integration coverage)
