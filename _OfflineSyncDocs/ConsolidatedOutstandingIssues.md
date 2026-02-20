# Offline Sync — Consolidated Outstanding Issues

> **Generated:** 2026-02-19 (updated 2026-02-19 — action plan cross-reference pass)
> **Source:** All documents in `_OfflineSyncDocs/` including ActionPlans/, ActionPlans/Resolved/, ActionPlans/Superseded/, and Review2/
> **Scope:** 53 documents reviewed across 13 parallel review passes + 2 gap analysis passes + action plan triage for all Review2 issues

---

## Summary Statistics

| Category | Count |
|----------|-------|
| **Open — Requires Code Changes** | 5 |
| **Open — Accepted (No Code Change Planned)** | 12 |
| **Partially Addressed** | 5 |
| **Deferred (Future Enhancement)** | 5 |
| **Review2 — Triaged (Action Plans Created)** | 35 |
| **Resolved / Superseded** | 23 |
| **Total Unique Issues** | 85 |

---

## Section 1: Open Issues Requiring Code Changes

These issues have been identified across multiple review documents and have actionable recommendations with estimated effort.

| # | Issue ID | Description | Severity | Complexity | Est. Effort | Related Documents | Notes |
|---|----------|-------------|----------|------------|-------------|-------------------|-------|
| 1 | **R3** | **No retry backoff for permanently failing resolution items.** A single permanently failing pending change blocks ALL syncing indefinitely via the early-abort pattern in `SyncService.swift:334-343`. No retry count, backoff, or expiry mechanism exists. | High | Medium | ~30-50 lines, 2-3 files, Core Data schema change | AP-R3, AP-00, OfflineSyncCodeReview.md, OfflineSyncChangelog.md, ReviewSection_SyncService.md, Review2/00_Main, Review2/02_OfflineSyncResolver | Most impactful remaining reliability issue. Recommended: Option D (`.failed` state) + Option A (retry count after 10 failures). Requires re-adding `timeProvider` dependency (removed in A3). |
| 2 | **R4** | ~~**Silent sync abort — no logging when sync aborts due to remaining pending changes.**~~ **Resolved** — added `Logger.application.info()` log line when sync aborts with remaining pending changes. | Medium | Low | 1-2 lines, 1 file (SyncService.swift) | AP-R4, AP-00, OfflineSyncCodeReview.md, ReviewSection_SyncService.md, Review2/04_SyncService | Resolved. |
| 3 | **S7** | ~~**VaultRepository-level `handleOfflineDelete` cipher-not-found test gap.**~~ **Resolved** — added `test_deleteCipher_offlineFallback_cipherNotFound_noOp` to VaultRepositoryTests. | Medium | Low | ~30-40 lines, 1 test file | AP-S7, AP-00, OfflineSyncCodeReview.md, ReviewSection_VaultRepository.md, Review2/08_TestCoverage | Resolved. |
| 4 | **R1** | **No data format versioning for `cipherData` JSON.** If `CipherDetailsResponseModel` changes in a future app update, old pending records fail to decode permanently, blocking sync. | Medium | Low | ~15-20 lines, 2-3 files, Core Data schema change | AP-R1, AP-00, OfflineSyncCodeReview.md, ReviewSection_PendingCipherChangeDataStore.md, Review2/02_OfflineSyncResolver | Add `dataVersion: Int16` to Core Data entity. Deprioritize if R3 is implemented (R3 provides more general stuck-item solution). Bundle schema change with R3. |
| 5 | **U2-B** | **No offline-specific error messages for unsupported operations.** Archive, unarchive, restore, and collection assignment show generic network errors when attempted offline. | Medium | Low | ~20-30 lines, 1 file (VaultRepository.swift) | AP-U2, AP-00, OfflineSyncCodeReview.md, ReviewSection_VaultRepository.md, Review2/00_Main, Review2/03_VaultRepository | Add `OfflineSyncError.operationNotSupportedOffline` and catch blocks in 4 methods. Low effort, could ship in initial release. |

---

## Section 2: Partially Addressed Issues

These issues have been worked on but still have remaining gaps.

| # | Issue ID | Description | What's Done | What Remains | Severity | Complexity | Related Documents |
|---|----------|-------------|-------------|--------------|----------|------------|-------------------|
| 6 | **EXT-3 / CS-2** | **SDK `CipherView` manual copy fragility.** `makeCopy` manually copies 28 properties; new SDK properties with defaults are silently dropped. | `makeCopy` consolidation, DocC `- Important:` callouts, Mirror-based property count guard tests (28 CipherView, 7 LoginView). | Underlying fragility remains inherent to external SDK types. Developers must still manually add properties to `makeCopy` when tests fail. 5 copy methods across 2 files affected. | High | Medium | AP-CS2, ReviewSection_SupportingExtensions.md, Review2/07_CipherViewExtensions |
| 7 | **TC-7** | **Narrow error type coverage in offline fallback tests.** Most tests use only `URLError(.notConnectedToInternet)`. | Denylist pattern implemented. `serverError_rethrows`, `responseValidationError4xx_rethrows`, `unknownError`, and `responseValidationError5xx` tests added. | `URLError(.timedOut)`, `URLError(.networkConnectionLost)`, and `DecodingError` not tested as offline triggers. | Medium | Low | ReviewSection_TestChanges.md |
| 8 | **VI-1** | **Offline-created cipher view failure.** Root cause was `Cipher.withTemporaryId()` setting `data: nil`. | All 5 root cause fixes implemented. `CipherView.withId()` replaces `Cipher.withTemporaryId()`. UI fallback added. | 2 tests for Fix #5 missing: (1) no assertion on temp-ID deletion via `deleteCipherWithLocalStorage`, (2) no test for `if let tempId` nil guard in `resolveCreate`. | Medium | Low | AP-VI1 |
| 9 | **T5 / RES-6** | **Manual `MockCipherAPIServiceForOfflineSync` fragility.** Mock uses 16 `fatalError()` stubs. | Mock extracted to dedicated file with maintenance comment. Compiler enforces protocol conformance. | `// sourcery: AutoMockable` annotation on `CipherAPIService` not added. Mock still requires manual updates on protocol changes. | Low | Low | AP-T5, ReviewSection_OfflineSyncResolver.md |
| 10 | **TC-2** | **Missing negative assertions in happy-path tests.** Four existing happy-path tests pass through new do/catch code but never assert offline handling was NOT triggered. | N/A — no changes made. | Add `XCTAssertFalse(pendingCipherChangeDataStore.upsertCalled)` or similar to 4 existing happy-path tests. | Medium | Low | ReviewSection_TestChanges.md |

---

## Section 3: Open Issues — Accepted As-Is (No Code Change Planned)

These issues have been reviewed and a deliberate decision was made to accept the current behavior.

| # | Issue ID | Description | Severity | Rationale | Related Documents |
|---|----------|-------------|----------|-----------|-------------------|
| 11 | **U1** | Org cipher error appears after full network timeout delay (30-60s) | Low | Inherent tradeoff of detecting offline by API failure. Narrow scenario. | AP-U1, OfflineSyncCodeReview.md, ReviewSection_VaultRepository.md |
| 12 | **DI-1 / DI-2** | `HasPendingCipherChangeDataStore` and `HasOfflineSyncResolver` in `Services` typealias expose core-layer components to UI layer | Low | Consistent with existing project patterns. Enables future U3. | AP-DI1, ReviewSection_DIWiring.md, Review2/05_DIWiring |
| 13 | **VR-2** | Permanent delete converted to soft delete when offline; cipher ends in trash | Low | Safety-first design for offline conflict scenarios. | AP-VR2, OfflineSyncCodeReview.md, ReviewSection_VaultRepository.md |
| 14 | **RES-1** | Potential duplicate cipher on create retry after partial failure | Low | Extremely low probability. Consequence is duplicate, not data loss. | AP-RES1, OfflineSyncCodeReview.md, Review2/02_OfflineSyncResolver |
| 15 | **RES-7** | Backup ciphers do not include attachments (set to nil) | Low | Attachment duplication too complex. Primary cipher attachments preserved. | AP-RES7, OfflineSyncCodeReview.md, ReviewSection_OfflineSyncResolver.md |
| 16 | **RES-9** | Implicit `cipherData` non-nil contract for resolution methods | Low | Defensive `missingCipherData` guards exist. Contract maintained by 4 callers. | AP-RES9, OfflineSyncCodeReview.md, ReviewSection_OfflineSyncResolver.md |
| 17 | **SS-2** | TOCTOU race condition between `remainingCount` check and `replaceCiphers` | Low | Microsecond window. Pending change record survives; next sync resolves. | AP-SS2, ReviewSection_SyncService.md, Review2/04_SyncService |
| 18 | **PCDS-1** | `PendingCipherChangeData.id` optional in Swift but required in Core Data schema | Low | Core Data `@NSManaged` limitation, not a design flaw. | AP-PCDS1, ReviewSection_PendingCipherChangeDataStore.md |
| 19 | **PCDS-2** | `createdDate`/`updatedDate` optional but always set in convenience init | Low | Nil fallback chain handles safely. | AP-PCDS2, ReviewSection_PendingCipherChangeDataStore.md |
| 20 | **VR-3** | Password change detection only compares `login?.password`, not other sensitive fields | Low | By design — soft conflict threshold targets highest-risk field. | ReviewSection_VaultRepository.md |
| 21 | **A4** | `GetCipherRequest.validate(_:)` coupled to `OfflineSyncError` semantics | Low | Acceptable coupling. | OfflineSyncCodeReview.md |
| 22 | **SS-1** | Pre-sync resolution error propagation blocks all syncing on Core Data failure | Low | Correct fail-safe behavior. | ReviewSection_SyncService.md |

---

## Section 4: Deferred Issues (Future Enhancements)

| # | Issue ID | Description | Severity | Complexity | Dependencies | Related Documents |
|---|----------|-------------|----------|------------|--------------|-------------------|
| 23 | **U3** | No user-visible indicator for pending offline changes (badge, toast, banner) | Medium | High | DI-1 (data store UI exposure) | AP-U3, AP-00, OfflineSyncCodeReview.md, Review2/00_Main |
| 24 | **U2-A** | Full offline support for archive/unarchive/restore operations | Low | High | Archive behind `.archiveVaultItems` feature flag | AP-U2, ReviewSection_VaultRepository.md |
| 25 | **VR2-B** | Add `PendingCipherChangeType.permanentDelete` for true offline permanent delete | Low | Medium | N/A | AP-VR2 |
| 26 | **DI-1-B** | Create separate `CoreServices` typealias for core-layer-only dependencies | Low | High | Significant DI refactoring | AP-DI1 |
| 27 | **R4-C** | Return `SyncResult` enum from `fetchSync` (foundation for U3) | Low | Medium | API change affecting all callers | AP-R4 |

---

## Section 5: Review2 Issues — Triaged (Action Plans Created)

These issues were identified in the second review pass. All have been triaged and have corresponding action plans in `ActionPlans/`.

### 5a. Code Quality / Cleanup

| # | Issue ID | Description | Severity | Complexity | Action Plan | Related Documents |
|---|----------|-------------|----------|------------|-------------|-------------------|
| 30 | **P2-CS1** | Redundant MARK comment in `CipherView+OfflineSync.swift` after removing `Cipher` extension | Low | Low | AP-30 | OfflineSyncCodeReview_Phase2.md |
| 31 | **R2-MAIN-20** | Error classification do/catch pattern repeated 4 times in VaultRepository (~15 lines each); could extract helper | Low | Low | AP-31 | Review2/00_Main, Review2/03_VaultRepository |
| 32 | **R2-MAIN-21** | ~~`handleOfflineDelete` and `handleOfflineSoftDelete` share 80% of logic; could consolidate~~ **Resolved** — extracted `cleanUpOfflineCreatedCipherIfNeeded` helper | Low | Low | AP-32 | Review2/00_Main, Review2/03_VaultRepository |
| 33 | **R2-EXT-3** | Three `/// - Important` comments about SDK fragility across files could reference a shared document | Low | Low | AP-33 | Review2/07_CipherViewExtensions |
| 34 | **R2-EXT-4** | `@retroactive CipherWithArchive` conformance change rationale unclear | Low | Low | AP-34 | Review2/07_CipherViewExtensions |
| 72 | **R2-SS-5** | SyncService simplification: two `pendingChangeCount` calls could be replaced by resolver returning boolean — saves one Core Data query | Low | Low | AP-72 | Review2/04_SyncService |
| 73 | **R2-SS-6** | SyncService simplification: extract 15-line pre-sync resolution block into private method `resolveOfflineChangesIfNeeded(userId:isVaultLocked:)` | Low | Low | AP-73 | Review2/04_SyncService |
| 74 | **R2-RES-10** | Resolver simplification: `resolveConflict` local-newer and server-newer branches have symmetric structure; could be abstracted (current explicit form more readable) | Low | Low | AP-74 | Review2/02_OfflineSyncResolver |
| 75 | **R2-RES-11** | `softConflictPasswordChangeThreshold` hardcoded to 4 as `static let` — not configurable without code change; tuning based on user feedback would require recompilation | Low | Low | AP-75 | Review2/02_OfflineSyncResolver |
| 76 | **R2-VR-9** | VaultRepository simplification: use `Cipher` directly instead of roundtripping through `CipherDetailsResponseModel` JSON (~20 lines savings per handler) — would require different serialization approach | Low | Low | AP-76 | OfflineSyncCodeReview.md |
| 84 | **R2-EXT-5** | Simplification: consider inlining `CipherView+OfflineSync` extension — `withId` and `update(name:)` are small and used in only 2 places; review recommends keeping current extension approach as cleaner | Low | Low | AP-84 | Review2/00_Main |

### 5b. Test Coverage Gaps

| # | Issue ID | Description | Severity | Complexity | Action Plan | Related Documents |
|---|----------|-------------|----------|------------|-------------|-------------------|
| 35 | **R2-TEST-1** | `GetCipherRequest` 404 validation (`validate(_:)` throwing `OfflineSyncError.cipherNotFound`) has no direct unit test | Medium | Low | AP-35 | Review2/08_TestCoverage |
| 36 | **R2-TEST-2** | Core Data lightweight migration (adding `PendingCipherChangeData` entity) has no automated test | Medium | Medium | AP-36 | Review2/08_TestCoverage |
| 37 | **R2-TEST-3** | `PendingCipherChangeData.deleteByUserIdRequest` addition to batch delete not explicitly tested | Medium | Low | AP-37 | Review2/08_TestCoverage |
| 38 | **R2-TEST-5** | Corrupt `cipherData` in pending change — no test for resolver handling malformed JSON | Medium | Low | AP-38 | Review2/08_TestCoverage |
| 39 | **P2-T2** | `resolveCreate` partial failure (server succeeds, local cleanup fails) — duplicate cipher scenario not tested | Low | Medium | AP-39 | OfflineSyncCodeReview_Phase2.md |
| 40 | **P2-T4** | Fallback fetch in `ViewItemProcessor` doesn't re-establish subscription; no test for cipher update after fallback | Low | Medium | AP-40 | OfflineSyncCodeReview_Phase2.md |
| 41 | **TC-6** | Mock defaults silently bypass abort logic: 24 of 25 `fetchSync` tests use default `pendingChangeCountResult = 0` with no assertions about offline resolution | Medium | Low | AP-41 | ReviewSection_TestChanges.md |
| 42 | **R2-TEST-4** | Very long cipher names in backup naming pattern not tested for edge cases | Low | Low | AP-42 | Review2/08_TestCoverage |
| 77 | **PLAN-3** | Phase 5 integration tests (end-to-end offline→reconnect→resolve scenarios) were planned in OfflineSyncPlan.md but status is unknown — no evidence of implementation | Medium | Medium | AP-77 | OfflineSyncPlan.md |

### 5c. Reliability / Edge Cases

| # | Issue ID | Description | Severity | Complexity | Action Plan | Related Documents |
|---|----------|-------------|----------|------------|-------------|-------------------|
| 43 | **R2-MAIN-7** | No maximum pending change age or count — unbounded accumulation possible during extended offline periods | Low | Low | AP-R2-MAIN-7 | Review2/00_Main |
| 44 | **R2-RES-2** | Conflict resolution timestamp comparison uses client-side timestamps — device clock skew could select wrong "winner" | Low | Low | AP-R2-RES-2 | Review2/02_OfflineSyncResolver |
| 45 | **R2-VR-1** | Error classification may be overly broad — catch-all block catches ANY unclassified error for offline fallback | Low | Low | AP-R2-VR-1 | Review2/03_VaultRepository |
| 46 | **R2-VR-5** | JSONEncoder().encode in offline helpers could theoretically fail — edit saved but no pending change recorded | Low | Low | AP-R2-VR-5 | Review2/03_VaultRepository |
| 47 | **R2-VR-6** | `getActiveAccountId()` in `handleOfflineDelete` could throw if user logged out between operation start and call | Low | Low | AP-R2-VR-6 | Review2/03_VaultRepository |
| 48 | **R2-PCDS-1** | No Core Data schema versioning step — current entity addition works via lightweight migration but future attribute changes require explicit versioning | Medium | Medium | AP-R2-PCDS-1 | Review2/01_PendingCipherChangeData |
| 49 | **R2-PCDS-4** | Upsert race condition — fetch-then-insert/update is not atomic; mitigated by uniqueness constraint | Low | Low | AP-R2-PCDS-4 | Review2/01_PendingCipherChangeData |
| 50 | **R2-PCDS-5** | Core Data corruption risk — if persistent store corrupts, pending changes lost (inherent to Core Data) | Low | High | AP-R2-PCDS-5 | Review2/01_PendingCipherChangeData |
| 51 | **S8.a** | When feature flag is disabled, existing pending changes remain orphaned in Core Data with no cleanup or notification | Low | Medium | AP-S8 | AP-S8 |
| 52 | **P2-T3** | Orphaned pending change cleanup failure — `deletePendingChange` fail after server success causes successful operation to appear as failure to UI | Low | Low | AP-P2-T3 | OfflineSyncCodeReview_Phase2.md |

### 5d. UX Improvements

| # | Issue ID | Description | Severity | Complexity | Action Plan | Related Documents |
|---|----------|-------------|----------|------------|-------------|-------------------|
| 53 | **R2-UI-1** | Fallback `fetchCipherDetailsDirectly()` is a one-time fetch, not a stream — no live updates while viewing offline-created cipher | Low | Medium | AP-53 | Review2/06_UILayer |
| 54 | **R2-UI-2** | Generic "An error has occurred" message when both publisher stream and fallback fail — should show offline-specific message | Low | Low | AP-54 | Review2/06_UILayer |
| 55 | **VR-4** | No user feedback on successful offline save — operation completes silently | Low | Medium | AP-55 | ReviewSection_VaultRepository.md |
| 78 | **R2-MAIN-2** | No offline support for attachment operations — attachment upload/download requires server communication; distinct from org cipher exclusion (U2) | Low | High | AP-78 | Review2/00_Main |

### 5e. Upstream / Process Concerns

| # | Issue ID | Description | Severity | Complexity | Action Plan | Related Documents |
|---|----------|-------------|----------|------------|-------------|-------------------|
| 56 | **R2-UP-1** | SDK API changes (`.authenticator` to `.vaultAuthenticator`, `emailHashes` removal) need verification against offline sync cipher operations | Medium | Low | AP-56 | Review2/09_UpstreamChanges |
| 57 | **R2-UP-3** | `MockCipherService` changed `cipherChangesSubject` from `CurrentValueSubject` to `PassthroughSubject` — alters timing semantics for existing tests | Medium | Low | AP-57 | Review2/09_UpstreamChanges |
| 58 | **R2-UP-4** | ~60% of changed files are upstream changes, complicating offline sync diff review | Low | Low | AP-58 | Review2/09_UpstreamChanges |
| 59 | **R2-UP-5** | `ExportVaultService` typo fix mixed into offline sync commits — should be separate commit | Low | Low | AP-59 | Review2/09_UpstreamChanges |
| 79 | **R2-DI-6** | ServiceContainer includes two additional incidental typo fixes unrelated to offline sync (`DefultExportVaultService` → `DefaultExportVaultService`, `Exhange` → `Exchange`) | Low | Low | AP-79 | Review2/05_DIWiring |
| 80 | **R2-UP-6** | `AuthCoordinator.swift` parameter rename (`attemptAutmaticBiometricUnlock` → `attemptAutomaticBiometricUnlock`) is a compile-affecting upstream change mixed into the offline sync diff | Low | Low | AP-80 | Review2/09_UpstreamChanges |

### 5f. Minor / Informational

| # | Issue ID | Description | Severity | Complexity | Action Plan | Related Documents |
|---|----------|-------------|----------|------------|-------------|-------------------|
| 60 | **TC-5** | `@MainActor` annotation required on test as workaround for `MockVaultTimeoutService` actor isolation | Low | Medium | AP-60 | ReviewSection_TestChanges.md |
| 61 | **TC-8** | ServiceContainer mock defaults: 131 calls across 107 test files silently receive new offline sync mocks | Low | Low | AP-61 | ReviewSection_TestChanges.md |
| 62 | **R2-RES-4** | Backup naming uses device default timezone — timestamp may not match server time | Low | Low | AP-62 | Review2/02_OfflineSyncResolver |
| 63 | **R2-RES-8** | Batch processing is sequential — many pending changes processed one-by-one (accepted simplicity tradeoff) | Low | Low | AP-63 | Review2/02_OfflineSyncResolver |
| 64 | **R2-VR-4** | Each offline update decrypts previous version to compare passwords — could be costly if offline edits are very frequent | Low | Low | AP-64 | Review2/03_VaultRepository |
| 65 | **TC-4** | `isVaultLocked` value is cached and reused across potentially long-running API calls | Low | Low | AP-65 | ReviewSection_TestChanges.md |
| 66 | **R2-UI-3** | `specificPeopleUnavailable(action:)` alert is upstream change mixed into offline sync files | Low | Low | AP-66 | Review2/06_UILayer |
| 67 | **PCDS-3/4** | `upsertPendingChange` uses fetch-then-update pattern rather than atomic upsert | Low | Medium | AP-67 | ReviewSection_PendingCipherChangeDataStore.md |
| 68 | **RES-vaultLocked** | `.vaultLocked` error case defined but never thrown in current code — dead code | Low | Low | AP-68 | ReviewSection_OfflineSyncResolver.md |
| 69 | **R2-UP-2** | `CipherPermissionsModel` typo fix ("acive" to "active") — low risk but needs verification | Low | Low | AP-69 | Review2/09_UpstreamChanges |
| 70 | **PLAN-1** | Denylist pattern may miss new error types in future SDK updates that should be rethrown | Low | Low | AP-70 | OfflineSyncPlan.md |
| 71 | **PLAN-2** | Sync resolution may be delayed up to one sync interval (~30 min) vs immediate connectivity-based trigger | Low | Medium | AP-71 | OfflineSyncPlan.md |
| 81 | **PLAN-4** | Core Data store does not configure explicit `NSFileProtectionComplete` (`DataStore.swift:50-83`) — relies on iOS default file protection (Complete Until First User Authentication), application-level encryption, and application sandbox; existing characteristic unchanged by this feature | Low | Medium | AP-81 | OfflineSyncPlan.md |
| 82 | **R2-CROSS-1** | If both R1 (data format versioning) and R3 (retry backoff) are implemented, Core Data schema changes should be bundled in a single migration step to minimize schema churn | Low | Low | AP-82 | AP-00_CrossReferenceMatrix.md |
| 83 | **SEC-2.a** | SEC-2 (plaintext `offlinePasswordChangeCount`) resolution should be revisited if: full Core Data encryption at rest is pursued, security model mandates all metadata encryption, count becomes persistent, or security audit mandates field-level encryption | Low | Low | AP-83 | AP-SEC2 |
| 85 | **R2-UI-4** | `buildViewItemState(from:)` in `ViewItemProcessor` is ~35 lines — could benefit from further decomposition; review rates as "within acceptable limits" | Low | Low | AP-85 | Review2/06_UILayer |

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

---

## Priority Recommendation

### Immediate (Ship Blockers / Quick Wins)
1. **R4** — Add sync abort log line (1-2 lines, zero risk)
2. **S7** — Add VaultRepository cipher-not-found test (~30 lines)
3. **U2-B** — Add offline-specific error messages (~20-30 lines)

### Should Address (Pre-Release)
4. **R3** — Retry backoff with failed state (~30-50 lines, Core Data schema change)
5. **R1** — Data format versioning (bundle with R3 schema change)

### Post-Release
6. **U3** — Pending changes indicator (toast on offline save)
7. **EXT-3** — Monitor SDK updates for property changes (ongoing)
8. **Review2 test gaps** — Items 35-42, 77 above (all now have action plans: AP-35 through AP-42, AP-77)
