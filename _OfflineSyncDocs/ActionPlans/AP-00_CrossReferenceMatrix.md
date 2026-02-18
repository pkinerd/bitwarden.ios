# Cross-Reference Matrix: Inter-Issue Implications

This document maps dependencies and implications between all 31 action plans. An entry means that the resolution of one issue affects or is affected by another.

## Critical Implication Clusters

### Cluster 1: Test Infrastructure (~~S3~~, ~~S4~~, ~~T5~~, ~~T6~~, ~~S6~~, S7, ~~T7~~, ~~T8~~) **[Mostly Resolved]**

~~All test gap issues share common infrastructure. The order of implementation matters:~~

> **[UPDATE]** S3, S4, S6, T5, T7, T6, and T8 are all resolved. The remaining test gap is S7 (VaultRepository-level cipher-not-found test).
>
> - **T5** — Inline mock retained with maintenance comment. AutoMockable annotation deferred.
> - **S3 + S4** — 7 tests added to `OfflineSyncResolverTests.swift`: 3 batch tests (all-succeed, mixed-failure, all-fail) + 4 API failure tests (create, update server fetch, soft delete, backup creation).
> - **S6** — 4 password change counting tests added to `VaultRepositoryTests.swift`.
> - **T8** — 1 pre-sync resolution failure test added to `SyncServiceTests.swift`.
> - **S7** — Resolver-level 404 tests exist; VaultRepository-level `handleOfflineDelete` not-found test gap remains open.

### Cluster 2: Reliability & Safety (R3, R4, S8, R1, ~~R2~~)

These issues form a layered defense system:

1. **S8 (feature flag)** is the outermost safety layer — can disable the entire feature remotely.
2. **R3 (retry backoff)** prevents permanently stuck items from blocking sync.
3. **R4 (logging)** provides observability into what's happening.
4. **R1 (format versioning)** prevents format mismatches from creating permanently stuck items.
5. ~~**R2 (thread safety)** prevents concurrent access bugs.~~ **[Resolved]** — `DefaultOfflineSyncResolver` converted to `actor`. The `conflictFolderId` mutable state that originally motivated R2 has since been removed entirely (conflict folder eliminated).

**Implication:** If S8 (feature flag) is implemented, R3 (retry backoff) becomes less critical since the feature can be disabled entirely. However, R3 is still valuable for graceful degradation. R4 (logging) should be implemented regardless — it's trivial and provides debugging value.

**Implication:** R1 (format versioning) and R3 (retry backoff with expiry) both address the "permanently stuck item" problem. Implementing R3 with TTL-based expiry covers the format versioning case (old items expire) without needing a version field. Both together provide defense in depth.

### ~~Cluster 3: Error Classification (SEC-1, EXT-1, T6)~~ **[Resolved]**

~~These three issues all relate to `URLError+NetworkConnection`:~~

> **All three issues are resolved/superseded.** The `URLError+NetworkConnection.swift` extension and its tests have been deleted entirely. VaultRepository catch blocks now use plain `catch` — all API errors trigger offline save. SEC-1, EXT-1, and T6 no longer exist as actionable items.

### Cluster 3b: Detail View / Publisher Resilience (~~VI-1~~, ~~CS-2~~, R3, U3) ~~[VI-1 Mitigated]~~ **[VI-1 Resolved, CS-2 Resolved]**

~~VI-1 identifies a failure where offline-created ciphers cannot be loaded in the detail view due to `asyncTryMap` + `decrypt()` terminating the publisher stream on error.~~

> ~~**VI-1 is mitigated, not resolved.**~~ **VI-1 is fully resolved.** The symptom (infinite spinner) was fixed via a UI fallback (PR #31). The root cause (`Cipher.withTemporaryId()` setting `data: nil`) was **fixed** by replacing it with `CipherView.withId()` operating before encryption (commit `3f7240a`). All 5 recommended fixes implemented in Phase 2. See [AP-VI1](AP-VI1_OfflineCreatedCipherViewFailure.md).
>
> **Cluster relevance (updated):**
> - ~~**CS-2**~~ **[Resolved]** — `Cipher.withTemporaryId()` removed. `CipherView.withId(_:)` and `CipherView.update(name:)` consolidated into shared `makeCopy` helper (single SDK initializer site, 28 properties). Review comments and property count guard tests added. `folderId` parameter removed from `update` — backup ciphers retain original folder. Remaining fragility is inherent to working with external SDK types; mitigated by automated property count tests.
> - **R3** is still important independently for sync reliability. Without retry backoff, permanently failing items block all syncing.
> - **U3** remains a future enhancement independent of VI-1.

### Cluster 4: UX Improvements (U1, U2, U3, U4)

These are future enhancements that can be tracked independently:

- **U3 (pending indicator)** is the highest-impact UX improvement
- **U2 (offline-specific errors)** is low-effort and could be included in the initial release
- **U1 (org error timing)** is accept-as-is; ~~**U4 (English folder name)**~~ is **superseded** (conflict folder removed)

**Implication:** U3 (pending indicator) has a dependency on DI-1 — if the data store is not exposed to the UI layer, the indicator cannot observe pending change state. The current DI-1 recommendation (accept current exposure) enables U3.

### Cluster 5: Core Data Schema (PCDS-1, PCDS-2, R1)

These all involve the `PendingCipherChangeData` Core Data entity:

- **PCDS-1** and **PCDS-2** are accept-as-is (no schema change)
- **R1** adds a `dataVersion` field

**Implication:** If R1 is implemented, the schema change should be done in a single migration step. Bundling R1 with R3 (retry count attribute) minimizes schema churn.

---

## Full Implication Matrix

| Issue | Affects | Affected By |
|-------|---------|-------------|
| ~~**S3**~~ | ~~T5 (mock burden)~~ | ~~T5 (mock quality), S4 (can combine)~~ **[Resolved]** — 3 batch tests added |
| ~~**S4**~~ | ~~T5 (mock burden)~~ | ~~T5 (mock quality), S3 (can combine), R3 (retry behavior)~~ **[Resolved]** — 4 API failure tests added |
| ~~**SEC-1**~~ | ~~T6 (test updates)~~ | ~~EXT-1 (holistic review)~~ **[Superseded]** — Extension deleted |
| ~~**S6**~~ | — | ~~T7~~ (T7 resolved separately) **[Resolved]** — 4 password change counting tests added |
| **S7** | — | VR-2 (delete context) — **[Partially Resolved]** Resolver-level 404 tests added via RES-2 fix; VaultRepository-level `handleOfflineDelete` not-found test gap remains open |
| **S8** | R3 (less critical), U2 (gates all ops), U3 (indicator respects flag) | — |
| ~~**EXT-1**~~ | ~~T6 (test updates)~~ | ~~SEC-1 (holistic review), R3 (false-positive mitigation)~~ **[Superseded]** — Extension deleted |
| ~~**A3**~~ | ~~R2 (simpler migration)~~ | ~~R3 (timeProvider may be repurposed)~~ **[Resolved]** — Removed in commit `a52d379`. Note: if R3 (retry backoff) is implemented, `timeProvider` would need to be re-introduced to the resolver. |
| ~~**CS-1**~~ | — | — **[Resolved]** — Removed in commit `a52d379` |
| ~~**CS-2**~~ | RES-7 (attachment handling) | — **[Resolved]** Review comments added, property count guard tests added, copy methods consolidated into single `makeCopy` helper (28 properties). RES-7 attachment concern remains a known limitation. |
| **R1** | — | R3 (both address stuck items), PCDS-1/PCDS-2 (schema changes) |
| ~~**R2**~~ | — | ~~A3 (remove first for simpler migration)~~ **[A3 resolved]** — **[R2 Resolved]** Converted to `actor`; `conflictFolderId` state subsequently removed (conflict folder eliminated) |
| **R3** | S8 (complementary), R1 (complementary), SS-2 (recovery), RES-1 (expire duplicates) | ~~S4 (test retry behavior)~~ **[S4 resolved]** — R3 tests would need new dedicated tests when implemented |
| **R4** | ~~T8 (distinguish abort vs error)~~ **[T8 resolved]** — R4 logging still independently valuable for production observability | R3 (log expired items), S8 (log flag state) |
| **DI-1** | U3 (enables indicator) | — |
| ~~**T6**~~ | — | ~~SEC-1 (classification change), EXT-1 (classification change)~~ **[Resolved]** — Extension and tests deleted |
| **U1** | — | ~~EXT-1 (timeout duration)~~ **[EXT-1 Superseded]** — Extension deleted; timeout duration concern no longer applies |
| **U2** | — | S8 (feature flag gates all) |
| **U3** | — | DI-1 (requires UI access), R3 (notify on expiry), R4 (abort notification) |
| ~~**U4**~~ | — | — **[Superseded]** — Conflict folder removed; English-only name concern no longer applies |
| **VR-2** | S7 (delete context) | U2 (consistency with other ops) |
| **RES-1** | — | R3 (expire stuck creates) |
| **RES-7** | — | ~~CS-2 (update method changes)~~ **[CS-2 resolved]** — `update(name:)` now uses consolidated `makeCopy` helper; attachment=nil behavior documented |
| ~~**T5**~~ | ~~S3 (test quality), S4 (test quality)~~ | ~~CS-2 (same fragility class)~~ **[Both T5 and CS-2 Resolved]** — Maintenance comment added |
| ~~**T7**~~ | — | ~~S6~~ **[Resolved]** — See [Resolved/AP-T7](Resolved/AP-T7_SubsequentOfflineEditTest.md) |
| ~~**T8**~~ | — | ~~R4 (logging distinguishes scenarios)~~ **[Resolved]** — Pre-sync resolution failure test added |
| **PCDS-1** | — | PCDS-2 (same category) |
| **PCDS-2** | — | PCDS-1 (same category) |
| **SS-2** | — | R3 (recovery mechanism) |
| **RES-9** | — | PCDS-1 (type precision), R3 (expire stuck items) |
| ~~**VI-1**~~ | ~~CS-2 (withTemporaryId is root cause)~~, ~~S7 (no .create check in delete)~~, ~~T7~~ (now resolved) | ~~R3 (permanently unsynced items stay broken)~~, ~~CS-2 (CipherView.withId fragility)~~ **[CS-2 resolved]**, U3 (pending indicator) — **[Resolved]** Root cause fixed by `CipherView.withId()` (commit `3f7240a`); all 5 recommended fixes implemented in Phase 2. See [AP-VI1](AP-VI1_OfflineCreatedCipherViewFailure.md). |
