# Cross-Reference Matrix: Inter-Issue Implications

This document maps dependencies and implications between all 30 action plans. An entry means that the resolution of one issue affects or is affected by another.

## Critical Implication Clusters

### Cluster 1: Test Infrastructure (S3, S4, T5, T6, S6, S7, T7, T8)

All test gap issues share common infrastructure. The order of implementation matters:

1. **T5 (inline mock)** should be addressed first — if the inline mock is replaced with a project-level mock, all subsequent test additions benefit.
2. **S3 + S4** (batch + API failure tests) should be implemented together — the "batch with mixed failure" scenario covers both.
3. **S6 + T7** (password counting + subsequent edit) should be implemented together — subsequent edits are the primary path for password counting.
4. **S7** (cipher-not-found) and **T8** (hard error) are independent and can be implemented in any order.
5. **T6** (URLError coverage) is independent of the above.

**Implication:** If T5 is resolved by using a project-level mock, S3/S4 tests benefit from a cleaner mock setup. If T5 is deferred, S3/S4 add more weight to the inline mock, increasing its maintenance burden.

### Cluster 2: Reliability & Safety (R3, R4, S8, R1, R2)

These issues form a layered defense system:

1. **S8 (feature flag)** is the outermost safety layer — can disable the entire feature remotely.
2. **R3 (retry backoff)** prevents permanently stuck items from blocking sync.
3. **R4 (logging)** provides observability into what's happening.
4. **R1 (format versioning)** prevents format mismatches from creating permanently stuck items.
5. **R2 (thread safety)** prevents concurrent access bugs.

**Implication:** If S8 (feature flag) is implemented, R3 (retry backoff) becomes less critical since the feature can be disabled entirely. However, R3 is still valuable for graceful degradation. R4 (logging) should be implemented regardless — it's trivial and provides debugging value.

**Implication:** R1 (format versioning) and R3 (retry backoff with expiry) both address the "permanently stuck item" problem. Implementing R3 with TTL-based expiry covers the format versioning case (old items expire) without needing a version field. Both together provide defense in depth.

### Cluster 3: Error Classification (SEC-1, EXT-1, T6)

These three issues all relate to `URLError+NetworkConnection`:

- **SEC-1** considers removing `.secureConnectionFailed`
- **EXT-1** considers removing `.timedOut`
- **T6** provides test coverage for the full set

**Implication:** Any change to SEC-1 or EXT-1 must be reflected in T6 tests. If SEC-1 removes `.secureConnectionFailed`, T6 should add a test verifying it returns `false`. Implement T6 after SEC-1 and EXT-1 decisions are finalized.

### Cluster 4: UX Improvements (U1, U2, U3, U4)

These are future enhancements that can be tracked independently:

- **U3 (pending indicator)** is the highest-impact UX improvement
- **U2 (offline-specific errors)** is low-effort and could be included in the initial release
- **U1 (org error timing)** and **U4 (English folder name)** are accept-as-is

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
| **S3** | T5 (mock burden) | T5 (mock quality), S4 (can combine) |
| **S4** | T5 (mock burden) | T5 (mock quality), S3 (can combine), R3 (retry behavior) |
| **SEC-1** | T6 (test updates) | EXT-1 (holistic review) |
| **S6** | — | T7 (combine subsequent edit) |
| **S7** | — | VR-2 (delete context) |
| **S8** | R3 (less critical), U2 (gates all ops), U3 (indicator respects flag) | — |
| **EXT-1** | T6 (test updates) | SEC-1 (holistic review), R3 (false-positive mitigation) |
| **A3** | R2 (simpler migration) | R3 (timeProvider may be repurposed) |
| **CS-1** | — | — |
| **CS-2** | RES-7 (attachment handling) | — |
| **R1** | — | R3 (both address stuck items), PCDS-1/PCDS-2 (schema changes) |
| **R2** | — | A3 (remove first for simpler migration) |
| **R3** | S8 (complementary), R1 (complementary), A3 (timeProvider reuse), SS-2 (recovery), RES-1 (expire duplicates) | S4 (test retry behavior) |
| **R4** | T8 (distinguish abort vs error) | R3 (log expired items), S8 (log flag state) |
| **DI-1** | U3 (enables indicator) | — |
| **T6** | — | SEC-1 (classification change), EXT-1 (classification change) |
| **U1** | — | EXT-1 (timeout duration) |
| **U2** | — | S8 (feature flag gates all) |
| **U3** | — | DI-1 (requires UI access), R3 (notify on expiry), R4 (abort notification) |
| **U4** | — | — |
| **VR-2** | S7 (delete context) | U2 (consistency with other ops) |
| **RES-1** | — | R3 (expire stuck creates) |
| **RES-7** | — | CS-2 (update method changes) |
| **T5** | S3 (test quality), S4 (test quality) | CS-2 (same fragility class) |
| **T7** | — | S6 (combine password tests) |
| **T8** | — | R4 (logging distinguishes scenarios) |
| **PCDS-1** | — | PCDS-2 (same category) |
| **PCDS-2** | — | PCDS-1 (same category) |
| **SS-2** | — | R3 (recovery mechanism) |
| **RES-9** | — | PCDS-1 (type precision), R3 (expire stuck items) |
