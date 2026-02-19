# Overall Recommendations & Action Plan Summary

## Executive Summary

The offline sync feature code review identified **31 distinct issues** across the implementation. None are critical blockers — the feature is architecturally sound, secure, and well-tested. The issues range from test gaps (highest priority) through reliability improvements to UX enhancements (future considerations). **[Updated]** A subsequent error handling simplification resolved/superseded 3 issues (SEC-1, EXT-1, T6) by deleting `URLError+NetworkConnection.swift` and simplifying VaultRepository catch blocks to plain `catch`. **[Updated]** Manual testing identified VI-1: offline-created ciphers fail to load in the detail view (infinite spinner). **[Updated 2026-02-18]** Of the 31 original issues, **24 are now resolved, superseded, or accepted-as-is** (15 resolved/superseded + 9 accept-no-change). The remaining **7 items requiring attention** are: **S8** (feature flag), **R4** (logging), **R3** (retry backoff), **R1** (data format versioning), **S7** (VaultRepository-level test gap -- partially resolved), **U2** (offline errors), **U3** (future enhancement). Of these, 6 require code changes: S8, R4, R3, R1, S7 (VaultRepository-level test), and U2. The two highest-impact remaining items are **S8** (production kill switch) and **R3** (prevents permanently blocked sync).

This document summarizes the recommended approach for each issue and proposes an implementation order.

### Key Codebase Findings Informing Recommendations

After reviewing the actual source code, architecture docs (`Docs/Architecture.md`, `Docs/Testing.md`), contribution guidelines, and all related implementation files, the following findings materially affect the recommendations:

1. **Feature flags are mature and established.** The project has 9 existing server-controlled feature flags via `ConfigService.getFeatureFlag()`. SyncService already uses this pattern (line 560 for `.migrateMyVaultToMyItems`). Adding `.offlineSync` is trivial.

2. **Swift actors are a proven pattern.** 7 existing services use `actor` instead of `class` (`DefaultPolicyService`, `DefaultStateService`, `DefaultClientService`, `DefaultTokenService`, etc.). Converting `DefaultOfflineSyncResolver` to an actor follows established project conventions.

3. ~~**No project-level `MockCipherAPIService` exists.** The inline mock in the test file is the only one.~~ **[Updated]** `MockCipherAPIServiceForOfflineSync` has been extracted to its own dedicated file at `TestHelpers/MockCipherAPIServiceForOfflineSync.swift` with a maintenance comment. The project uses Sourcery `@AutoMockable` for mock generation, but `CipherAPIService` is not annotated with it (deferred -- Sourcery not available in CI).

4. **Test patterns are well-established.** `VaultRepositoryTests` uses 30+ mock dependencies with explicit setUp/tearDown. `MockPendingCipherChangeDataStore` tracks all method calls including `upsertPendingChangeCalledWith` tuples with `offlinePasswordChangeCount`. `MockClientCiphers` supports configured decrypt results.

5. **Logger.application is widely used** (22+ files) for operational logging via OSLog. The resolver already logs errors at line 132.

---

## Recommendation Summary by Issue

### Phase 1: Must-Address Before Merge (High Priority)

| Issue | Recommendation | Effort | Risk |
|-------|---------------|--------|------|
| ~~**S3** — Batch processing test~~ | ~~Add 2-3 targeted batch tests (Option B)~~ **[Resolved]** — 3 batch tests added (all-succeed, mixed-failure, all-fail) in `OfflineSyncResolverTests.swift`. See [Resolved/AP-S3](Resolved/AP-S3_BatchProcessingTest.md). | ~~200-300 lines~~ 0 | N/A |
| ~~**S4** — API failure test~~ | ~~Add representative failure tests (Option B)~~ **[Resolved]** — 4 API failure tests added (create, update server fetch, soft delete, backup creation) in `OfflineSyncResolverTests.swift`. See [Resolved/AP-S4](Resolved/AP-S4_APIFailureDuringResolutionTest.md). | ~~200-300 lines~~ 0 | N/A |

**Rationale:** ~~These test gaps cover critical reliability properties (catch-and-continue, batch processing) that should be verified before merge. Implement S3 and S4 together — the "batch with mixed failure" test covers both.~~ **[UPDATE]** S3 and S4 are fully resolved. The catch-and-continue pattern and batch processing are now verified by 7 tests covering all change types and failure modes.

### Phase 2: Should-Address Before Merge (Medium Priority)

| Issue | Recommendation | Effort | Risk |
|-------|---------------|--------|------|
| ~~**VI-1** — Offline-created cipher view failure~~ | ~~**Mitigated**~~ **[Resolved]** — Spinner fixed via UI fallback (PR #31). Root cause **fixed**: `Cipher.withTemporaryId()` replaced by `CipherView.withId()` (commit `3f7240a`). All 5 recommended fixes implemented in Phase 2. See [AP-VI1](AP-VI1_OfflineCreatedCipherViewFailure.md). | ~~50-80 lines~~ 0 | N/A |
| ~~**S6** — Password change test~~ | ~~Add dedicated tests (Option A)~~ **[Resolved]** — 4 password change counting tests added in `VaultRepositoryTests.swift`: first-edit changed, first-edit unchanged, subsequent-edit changed, subsequent-edit unchanged. See [Resolved/AP-S6](Resolved/AP-S6_PasswordChangeCountingTest.md). | ~~100-150 lines~~ 0 | N/A |
| ~~**S7** — Cipher-not-found test~~ | ~~Add single targeted test (Option A)~~ **[Partially Resolved]** — Two 404-handling tests added in `OfflineSyncResolverTests` (resolver level). VaultRepository-level test gap remains open. | ~~30-40 lines~~ 0 | N/A |
| ~~**SEC-1** — secureConnectionFailed~~ | ~~Add logging for TLS triggers~~ **[Superseded]** — `URLError+NetworkConnection` extension deleted; plain `catch` replaces URLError filtering. | ~~10-15 lines~~ 0 | N/A |
| ~~**EXT-1** — timedOut~~ | ~~Accept current behavior~~ **[Superseded]** — Extension deleted; all API errors now trigger offline save by design. | 0 lines | N/A |
| **S8** — Feature flag | Server-controlled flag (Option A) | ~20-30 lines | Low |
| ~~**A3** — Unused timeProvider~~ | ~~Remove dependency (Option A)~~ **[Resolved]** — Removed in commit `a52d379`. | ~~-10 lines~~ 0 | N/A |
| ~~**CS-1** — Stray blank line~~ | ~~Remove blank line (Option A)~~ **[Resolved]** — Removed in commit `a52d379`. | ~~1 line~~ 0 | N/A |
| **R4** — Silent sync abort | Add log line (Option A) | 1-2 lines | None |

**Rationale:** ~~VI-1's symptom (infinite spinner) is mitigated via UI fallback, but the root cause (`Cipher.withTemporaryId()` setting `data: nil`) remains. Related edge cases (editing offline-created ciphers loses `.create` type; deleting offline-created ciphers queues futile `.softDelete`; no temp-ID cleanup in `resolveCreate()`) also remain.~~ **[UPDATE]** VI-1 is fully resolved — root cause and all related edge cases fixed in Phase 2. Remaining actionable items in this phase: test gaps (S6) are low-effort, high-value. R4 logging is trivial. S8 (feature flag) is the most impactful medium-priority item for production safety. A3, CS-1, SEC-1, EXT-1, S7 (resolver-level), and VI-1 are all resolved/superseded. RES-2 (server 404 handling) and A-3 (backup-before-push ordering) are also fixed.

### Phase 3: Nice-to-Have (Low Priority)

| Issue | Recommendation | Effort | Risk |
|-------|---------------|--------|------|
| ~~**R2** — Thread safety~~ | ~~Convert to actor (Option A)~~ **[Resolved]** — `DefaultOfflineSyncResolver` converted from `class` to `actor` | ~~5 lines~~ 0 | N/A |
| **R3** — Retry backoff | TTL + retry count (Options A+B) | ~30-50 lines | Low-Medium |
| **R1** — Data format versioning | Add version field (Option A) | ~15-20 lines | Low |
| ~~**CS-2** — Fragile SDK copies~~ | ~~Add review comments (Option A)~~ **[Resolved]** — Review comments added to `CipherView+OfflineSync.swift` (Option A) AND property count guard tests added to `CipherViewOfflineSyncTests.swift` (variant of Option B). Both `CipherView` (28 properties) and `LoginView` (7 properties) are covered. Copy methods consolidated into single `makeCopy` helper. | ~~6 lines~~ 0 | N/A |
| ~~**T6** — URLError test coverage~~ | ~~Add individual tests~~ **[Resolved]** — Extension and tests deleted. | ~~35 lines~~ 0 | N/A |
| ~~**T7** — Subsequent edit test~~ | ~~Add dedicated test~~ **[Resolved]** — Covered by `test_updateCipher_offlineFallback_preservesCreateType`. See [Resolved/AP-T7](Resolved/AP-T7_SubsequentOfflineEditTest.md). | ~~50-80 lines~~ 0 | N/A |
| ~~**T8** — Hard error test~~ | ~~Add single test (Option A)~~ **[Resolved]** — Test `test_fetchSync_preSyncResolution_resolverThrows_syncFails` added in `SyncServiceTests.swift`. See [Resolved/AP-T8](Resolved/AP-T8_HardErrorInPreSyncResolution.md). | ~~30-40 lines~~ 0 | N/A |
| ~~**T5** — Inline mock fragility~~ | ~~Add `@AutoMockable` to CipherAPIService (Option A)~~ **[Resolved]** — Mock extracted from inline test code to dedicated file `MockCipherAPIServiceForOfflineSync.swift` in `TestHelpers/`, with maintenance comment documenting protocol conformance burden. AutoMockable annotation deferred (Sourcery not available in CI). See [Resolved/AP-T5](Resolved/AP-T5_InlineMockFragility.md). | ~~5 lines~~ 0 | N/A |
| **DI-1** — UI layer exposure | Accept current pattern (Option A) | 0 lines | None |

**Rationale:** ~~R2 (actor conversion) and~~ R3 (retry backoff) ~~are~~ is the most impactful improvement~~s~~ here. R3 prevents permanently blocked sync. R2 is now resolved. CS-2 is now resolved (review comments + property count guard tests). The remaining items are R3, R1, and DI-1 (accept-as-is).

### Phase 4: Accept / Future Enhancement (Informational)

| Issue | Recommendation | Effort |
|-------|---------------|--------|
| **U1** — Org error timing | Accept current behavior (Option C) | 0 |
| **U2** — Inconsistent offline ops | Add offline-specific errors (Option B) for initial release | ~20-30 lines |
| **U3** — Pending indicator | Defer; implement toast (Option B) as first enhancement | Future |
| ~~**U4** — English folder name~~ | ~~Accept English-only (Option C)~~ **[Superseded]** — Conflict folder removed | 0 |
| **VR-2** — Delete → soft delete | Accept current behavior (Option A) | 0 |
| **RES-1** — Duplicate on retry | Accept risk (Option D) | 0 |
| **RES-7** — No attachments in backup | Accept limitation (Option D) | 0 |
| **PCDS-1** — id optional type | Accept optional (Option B) | 0 |
| **PCDS-2** — dates optional type | Accept pattern (Option B) | 0 |
| **SS-2** — TOCTOU race | Accept risk (Option C) | 0 |
| **RES-9** — Implicit contract | Accept design (Option C) | 0 |

---

## Implementation Order

### Batch 1: Quick Wins (< 1 hour)
1. ~~**A3** — Remove unused `timeProvider`~~ **[Resolved]** — Removed in commit `a52d379`
2. ~~**CS-1** — Remove stray blank line~~ **[Resolved]** — Removed in commit `a52d379`
3. **R4** — Add sync abort log line (1 file, 2 lines)
4. ~~**SEC-1** — Add TLS fallback logging~~ **[Superseded]** — `URLError+NetworkConnection` extension deleted
5. ~~**VI-1** — **Mitigated** — spinner fixed via UI fallback, root cause remains~~ **[Resolved]** — All 5 recommended fixes implemented in Phase 2. See [AP-VI1](AP-VI1_OfflineCreatedCipherViewFailure.md).

### Batch 2: Test Coverage (1-2 hours)
5. ~~**T5** — Evaluate/replace inline mock (1 file)~~ **[Resolved]** — Mock extracted to dedicated `MockCipherAPIServiceForOfflineSync.swift` in `TestHelpers/` with maintenance comment
6. ~~**S3 + S4** — Batch + API failure tests (1 file, ~400-600 lines)~~ **[Resolved]** — 7 tests added to `OfflineSyncResolverTests.swift`
7. ~~**S6** — Password counting tests (1 file, ~100-150 lines)~~ **[Resolved]** — 4 tests added to `VaultRepositoryTests.swift`
8. ~~**S7** — Cipher-not-found test~~ **[Partially Resolved]** — Resolver-level 404 tests added; VaultRepository-level test gap remains
9. ~~**T8** — Hard error in pre-sync test (1-2 files, ~30-40 lines)~~ **[Resolved]** — 1 test added to `SyncServiceTests.swift`
10. ~~**T6** — Complete URLError test coverage~~ **[Resolved]** — Extension and tests deleted

### Batch 3: Reliability Improvements (2-3 hours)
11. ~~**R2** — Convert resolver to actor~~ **[Resolved]** — Converted `DefaultOfflineSyncResolver` from `class` to `actor`
12. **R3** — Add retry backoff/TTL (2-3 files, ~30-50 lines, schema change)
13. **R1** — Add data format version field (2-3 files, ~15-20 lines, schema change)

### Batch 4: Production Safety (1-2 hours)
14. **S8** — Feature flag implementation (3-4 files, ~20-30 lines)
15. **U2** — Offline-specific error messages (1 file, ~20-30 lines)

### Batch 5: UX Enhancements (Future)
16. ~~**CS-2** — Add SDK update review comments~~ **[Resolved]** — Review comments + property count guard tests implemented in `CipherView+OfflineSync.swift` and `CipherViewOfflineSyncTests.swift`
17. **U3** — Pending changes toast/indicator (future sprint)

---

## Key Decision Points

### 1. Feature Flag (S8) — Implement now or defer?
**Recommendation: Implement now.** The project already has 9 server-controlled feature flags and `SyncService` already uses `configService.getFeatureFlag(.migrateMyVaultToMyItems)` at line 560 — a direct precedent. Adding `static let offlineSync = FeatureFlag(rawValue: "offline-sync-enable-offline-changes")` to `FeatureFlag.swift` and a guard in `SyncService.fetchSync()` is a ~10-line change.

### 2. Retry Backoff (R3) — Essential or nice-to-have?
**Recommendation: Implement before wide rollout.** Without retry backoff, a single permanently failing item blocks ALL syncing for the user (due to the early-abort at `SyncService.swift:339`). This is the most impactful reliability issue. **[Updated]** The `timeProvider` has been removed (A3 resolved). If R3 is implemented, `timeProvider` can be re-added with a clear purpose for TTL-based expiry.

### 3. Actor Conversion (R2) — Worth the migration?
**Recommendation: Implement.** The project already uses actors for 7 services (DefaultPolicyService, DefaultStateService, DefaultClientService, DefaultTokenService, etc.). Converting `DefaultOfflineSyncResolver` from `class` to `actor` is a single keyword change that follows established project conventions and provides compile-time thread safety.

### 4. ~~`.secureConnectionFailed` (SEC-1) — Remove from offline triggers?~~ **[Superseded]**
~~**Recommendation: Keep but log.**~~ This decision point is superseded. The `URLError+NetworkConnection` extension has been deleted. VaultRepository catch blocks now use a denylist pattern (re-throwing `ServerError`, `ResponseValidationError` where status < 500, and `CipherAPIServiceError`; all other errors fall through to offline handlers). The fine-grained URLError classification was solving a problem that doesn't exist.

### 5. ~~`.timedOut` (EXT-1) — Remove from offline triggers?~~ **[Superseded]**
~~**Recommendation: Keep.**~~ This decision point is superseded. The `URLError+NetworkConnection` extension has been deleted. VaultRepository catch blocks use a denylist pattern where all errors except explicit server/validation/API-service errors trigger offline save.

### ~~6. Inline Mock (T5) — Keep, replace, or auto-generate?~~ **[Resolved]**
~~**Recommendation: Add `// sourcery: AutoMockable` to `CipherAPIService`.**~~ **[UPDATE]** T5 is resolved. The inline mock was extracted to its own dedicated file (`MockCipherAPIServiceForOfflineSync.swift` in `TestHelpers/`) with a maintenance comment documenting the protocol conformance burden and recommending AutoMockable annotation when feasible. The AutoMockable annotation was deferred because Sourcery is not available in CI. The mock infrastructure proved adequate for all S3/S4 batch and failure tests.

---

## Total Estimated Impact

**[Updated 2026-02-18]** The table below reflects the current state after all Phase 1, most Phase 2, and several Phase 3 items have been resolved.

| Phase | Original Estimate | Resolved | Remaining |
|-------|------------------|----------|-----------|
| Phase 1 (Must-address) | 1 file, ~400-600 lines | **All resolved** (S3, S4) | None |
| Phase 2 (Should-address) | 6-9 files, ~230-350 lines | S6, S7 (partial), SEC-1, EXT-1, A3, CS-1, VI-1 resolved/superseded | **S8** (~20-30 lines), **R4** (~2 lines), **S7** VaultRepository test (~30-40 lines) |
| Phase 3 (Nice-to-have) | 6-8 files, ~200-300 lines | R2, T6, T7, T8, T5, **CS-2** resolved | **R3** (~30-50 lines), **R1** (~15-20 lines), **DI-1** (accept) |
| Phase 4 (Accept/Future) | 0-1 files, ~20-30 lines | U4 superseded | **U2** (~20-30 lines), others accept-as-is |
| **Remaining Total** | — | — | **~4-6 files, ~90-130 lines** |

---

## Risk Assessment

**[Updated 2026-02-18]** The overall risk profile has improved significantly since the initial review:

1. **Phase 1 is fully resolved.** All must-address test gaps (S3, S4) are covered.
2. **Phase 2 is nearly complete.** VI-1 fully resolved. S6 tests added. S7 partially resolved (VaultRepository-level gap remains). SEC-1, EXT-1 superseded. A3, CS-1 resolved. Remaining: **S8** (feature flag) and **R4** (logging) -- both low-risk additive changes.
3. **Phase 3 is mostly resolved.** R2 (actor), T5, T6, T7, T8, and now **CS-2** (review comments + property count guard tests) are all resolved. Remaining: **R3** (retry backoff) and **R1** (format versioning) -- both require Core Data schema changes.
4. **Phase 4 items** are mostly accept-as-is -- no changes needed. U4 superseded.

The most significant remaining risks:
- **Without S8 (feature flag):** No remote kill switch exists. This is the highest-impact remaining item for production safety.
- **Without R3 (retry backoff):** A single permanently failing item blocks ALL syncing. This is the most impactful reliability concern.
- **Core Data schema changes** for R1 and R3 require lightweight migration, which Core Data handles automatically for new attributes, but should be tested carefully.

---

## Updated Review Findings (Post-Individual Action Plan Review)

After completing a detailed code-level review of all 31 individual action plans against the actual implementation source code, the following updates and refinements are noted. Each individual action plan has been updated with an "Updated Review Findings" section containing code-verified analysis.

### Summary of Recommendation Changes

**No major recommendation reversals.** The original recommendations were well-calibrated. The code review confirmed all recommendations with the following refinements:

#### Elevated Priority

| Issue | Original Priority | Updated Priority | Reason |
|-------|------------------|-----------------|--------|
| **R3** — Retry backoff | Low (Nice-to-have) | **Medium (Should-address)** | Code review confirmed that a single permanently failing item at `SyncService.swift:338-340` blocks ALL syncing. This is the most impactful reliability improvement. Recommend Option D (failed state) + Option A (retry count) instead of plain TTL — mark items as `.failed` after 10 retries so they don't block sync but data is preserved. |

#### Refined Recommendations

| Issue | Refinement |
|-------|-----------|
| **S8** — Feature flag | When the flag is off, the entire pre-sync pending-changes block should be skipped (both resolution AND abort check), not just the resolution. Otherwise, pending changes accumulate and permanently block sync. Two-tier approach: Tier 1 gates SyncService (simple); Tier 2 also gates VaultRepository catch blocks (requires adding `configService` dependency). |
| **R1** — Data format versioning | Priority should be deprioritized if R3 (retry backoff/TTL) is implemented, since R3 provides a more general solution for permanently stuck items. If R3 is deferred, R1 becomes important as the only graceful degradation path for format mismatches. |
| ~~**SEC-1** — secureConnectionFailed~~ | **[Superseded]** Extension deleted. The entire URLError classification approach was removed in favor of plain `catch` blocks. |
| ~~**CS-2** — Fragile SDK copies~~ | **[Resolved]** Review comments (Option A) added to `CipherView+OfflineSync.swift`. Property count guard tests using `Mirror` added to `CipherViewOfflineSyncTests.swift` for both `CipherView` (28 properties) and `LoginView` (7 properties). Original concern about Rust FFI-generated structs not reflecting via `Mirror` did not materialize -- the tests work correctly. Copy methods consolidated into single `makeCopy` helper, reducing the fragile SDK initializer call to a single site. |
| ~~**A3** vs **R3** interaction~~ | **[Resolved]** — `timeProvider` has been removed per A3 (commit `a52d379`). If R3 is implemented, `timeProvider` can be re-added with a clear purpose. |

#### Confirmed Accept-as-Is (No Changes)

The following 11 issues were confirmed as correct to accept without code changes:
- **U1** — Org cipher error timing: timeout delay is inherent to error-detection-by-failure design
- ~~**U4** — English folder name: cross-device/cross-platform consistency is the deciding factor~~ **[Superseded]** — Conflict folder removed; backup ciphers now retain original folder assignment
- **VR-2** — Delete to soft delete: safety-first design for offline conflict scenarios
- **RES-1** — Duplicate on create retry: extremely low probability, recoverable outcome
- **RES-7** — Backup lacks attachments: attachment duplication is too complex for initial release
- **RES-9** — Implicit cipherData contract: defensive guards in resolver are the correct safety net
- **PCDS-1** — id optional type: Core Data `@NSManaged` constraint, not a design flaw
- **PCDS-2** — dates optional type: Core Data constraint, nil fallback chain handles it safely
- **SS-2** — TOCTOU race: microsecond window, pending record survives, next sync resolves
- **DI-1** — DataStore UI exposure: consistent with project conventions, enables future U3 feature
- ~~**EXT-1** — timedOut classification~~ **[Superseded]** — Extension deleted; issue no longer exists

### Key Cross-Cutting Findings from Code Review

1. **Encrypt-before-queue invariant is consistently maintained.** All four VaultRepository offline handlers (`handleOfflineAdd`, `handleOfflineUpdate`, `handleOfflineDelete`, `handleOfflineSoftDelete`) store already-encrypted cipher data. No plaintext is persisted to Core Data.

2. **Per-user data isolation is enforced throughout.** The `userId` parameter flows through all data store operations, and `PendingCipherChangeData` predicates filter by userId.

3. ~~**The catch-and-continue pattern at `OfflineSyncResolver.swift:128-136` is correct but unverified.** This is the most critical untested behavior — S3 and S4 test gaps remain the highest priority.~~ **[Resolved]** — The catch-and-continue pattern is now verified by 7 tests (S3 batch tests + S4 API failure tests) covering all change types and failure modes.

4. **The early-abort pattern at `SyncService.swift:338-340` is the single most impactful reliability concern.** Without R3 (retry backoff), a permanently failing item blocks all syncing indefinitely. This makes R3 more important than originally assessed.

5. **Mock infrastructure is adequate for all proposed tests.** `MockCipherService`, `MockPendingCipherChangeDataStore`, and `MockClientCiphers` all support the configurations needed for S3, S4, S6, S7, T7, and T8 tests. ~~Only T5 (inline mock) requires attention if protocol changes are expected.~~ **[UPDATE]** T5 is resolved -- the mock was extracted to its own file (`MockCipherAPIServiceForOfflineSync.swift`) with a maintenance comment. The mock infrastructure proved adequate for all implemented tests.

### Updated Implementation Priority Order

Based on the code review, the recommended implementation order is refined:

**Batch 1: Quick Wins** (updated)
1. ~~A3 — Remove unused timeProvider~~ **[Resolved]** — Commit `a52d379`
2. ~~CS-1 — Remove stray blank line~~ **[Resolved]** — Commit `a52d379`
3. R4 — Add sync abort log line
4. ~~SEC-1 — Add TLS fallback logging~~ **[Superseded]** — Extension deleted
5. ~~**VI-1** — **Mitigated** — spinner fixed via UI fallback (PR #31), root cause remains~~ **[Resolved]** — All 5 recommended fixes implemented in Phase 2

**Batch 2: Critical Test Coverage** (updated) **[All Resolved]**
5. ~~T5 — Evaluate/replace inline mock~~ **[Resolved]** — Mock extracted to dedicated file with maintenance comment
6. ~~S3 + S4 — Batch + API failure tests~~ **[Resolved]** — 7 tests added
7. ~~S6 — Password counting tests~~ **[Resolved]** — 4 tests added
8. ~~S7 — Cipher-not-found test~~ **[Partially Resolved]** — Resolver-level 404 tests added
9. ~~T8 — Hard error in pre-sync test~~ **[Resolved]** — 1 test added
10. ~~T6 — Complete URLError test coverage~~ **[Resolved]** — Extension and tests deleted

**Batch 3: Reliability (R3 elevated)** (updated)
11. ~~R2 — Convert resolver to actor~~ **[Resolved]**
12. **R3** — Add retry count + failed state (**elevated from Nice-to-have**)
13. R1 — Add data format version (deprioritize if R3 is implemented)

**Batch 4: Production Safety** (S8 refinement noted)
14. S8 — Feature flag (skip entire pre-sync block when off, not just resolution)
15. U2 — Offline-specific error messages

**Batch 5: Future Enhancements** (updated)
16. ~~CS-2 — SDK update review comments~~ **[Resolved]** — Review comments + property count guard tests implemented
17. U3 — Pending changes indicator
