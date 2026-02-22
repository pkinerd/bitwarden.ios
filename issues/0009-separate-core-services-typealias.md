---
id: 9
title: "[DI-1-B] Create separate CoreServices typealias for core-layer-only dependencies"
status: open
created: 2026-02-21
author: claude
labels: [refactor]
priority: low
---

## Description

Create separate `CoreServices` typealias for core-layer-only dependencies.

**Note:** Impact reduced since `HasPendingCipherChangeDataStore` was never added to `Services` — only `HasOfflineSyncResolver` is exposed.

**Severity:** Low
**Complexity:** High
**Dependencies:** Significant DI refactoring.

**Related Documents:** AP-DI1

**Status:** Deferred — future enhancement.

## Action Plan

*Source: `ActionPlans/Accepted/AP-DI1_DataStoreExposedToUILayer.md`*

> **Reconciliation Note (2026-02-21):** The DI-2 concern (`HasPendingCipherChangeDataStore` exposed to UI layer via `Services` typealias) is **moot**. Code verification confirms that `HasPendingCipherChangeDataStore` was **never added** to the `Services` typealias in `Services.swift`. Only `HasOfflineSyncResolver` is present (line 40). The `pendingCipherChangeDataStore` is passed directly via initializer injection to `DefaultOfflineSyncResolver` and `DefaultVaultRepository`, which is architecturally cleaner than typealias exposure. Therefore, only DI-1 (`HasOfflineSyncResolver` exposed to UI layer) remains as a valid concern, and it was accepted as consistent with existing project conventions. The original analysis below is preserved for historical reference, with inline corrections marked **[CORRECTION]**.

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | DI-1 / DI-2 |
| **Component** | `Services.swift` |
| **Severity** | Low |
| **Type** | Architecture |
| **File** | `BitwardenShared/Core/Platform/Services/Services.swift` |

## Description

`HasPendingCipherChangeDataStore` and `HasOfflineSyncResolver` are added to the top-level `Services` typealias, which defines dependencies accessible to the UI layer (coordinators, processors). Both are currently used only in the core layer (`VaultRepository` and `SyncService`), making the `Services` typealias exposure broader than necessary.

**[CORRECTION (2026-02-21)]:** Only `HasOfflineSyncResolver` is in the `Services` typealias (`Services.swift:40`). `HasPendingCipherChangeDataStore` does NOT exist in the `Services` typealias and never did. The `pendingCipherChangeDataStore` is injected directly via initializer parameters to `DefaultOfflineSyncResolver` and `DefaultVaultRepository`. The DI-2 concern is therefore moot -- the data store is NOT exposed to the UI layer.

The architecture docs note that data stores "may only need to be accessed by services or repositories in the core layer and wouldn't need to be exposed to the UI layer."

## Context

Both services are registered on `ServiceContainer`, which conforms to `Services`. Adding them to the `Services` typealias is required for the container conformance. However, the `Services` typealias is also used as a constraint on UI-layer dependency injection, meaning coordinators and processors can technically access these services.

This follows existing precedent in the project — other data stores are also in the `Services` typealias. It's a known architectural compromise rather than a new violation.

**[CORRECTION (2026-02-21)]:** This context is only accurate for `HasOfflineSyncResolver`. `HasPendingCipherChangeDataStore` is not registered in the `Services` typealias and is instead injected directly via initializers, avoiding the UI-layer exposure concern entirely.

---

## Options

### Option A: Accept Current Pattern (Recommended)

Keep both protocols in the `Services` typealias, consistent with existing data store patterns in the project.

**[CORRECTION (2026-02-21)]:** This option's premise is partially incorrect. Only `HasOfflineSyncResolver` is in the `Services` typealias. `HasPendingCipherChangeDataStore` uses direct initializer injection and is not exposed to the UI layer. The "both protocols" framing is inaccurate -- only one protocol (`HasOfflineSyncResolver`) is relevant to this option.

**Pros:**
- Consistent with existing codebase patterns
- No code change
- `ServiceContainer` conformance is straightforward
- If future UI-layer features need offline sync access (e.g., pending changes indicator), the protocol is already available **[CORRECTION: This pro applies only to `HasOfflineSyncResolver`. `HasPendingCipherChangeDataStore` would need to be explicitly added to `Services` for UI-layer access.]**

**Cons:**
- Broader exposure than architecturally ideal
- UI-layer code could accidentally depend on these services

### Option B: Create Separate Core-Only Typealias

Create a `CoreServices` typealias (or similar) for services that should only be used in the core layer. Have `ServiceContainer` conform to both `Services` and `CoreServices`.

**Approach:**
1. Define `CoreServices` typealias composing core-only `Has*` protocols
2. Move `HasOfflineSyncResolver` (and `HasPendingCipherChangeDataStore` if it were added) to `CoreServices` **[CORRECTION: `HasPendingCipherChangeDataStore` is not in `Services`, so only `HasOfflineSyncResolver` would need moving]**
3. Have `ServiceContainer` conform to both
4. Core-layer types constrain on `CoreServices`; UI-layer types constrain on `Services`

**Pros:**
- Clean separation of core and UI dependencies
- Prevents UI-layer access to core-only services
- More architecturally correct

**Cons:**
- Significant refactoring — affects the entire DI pattern
- Introduces a new typealias that all existing core services would need to be evaluated for
- Risk of confusion about which typealias to use
- Not justified by the current 2-protocol scope **[CORRECTION: Only 1 protocol (`HasOfflineSyncResolver`) is actually in `Services`]**

### Option C: Remove from `Services`, Use Direct Init Injection Only

Remove the `Has*` protocols from `Services` and inject the services directly via initializer parameters without going through the `Services` typealias.

**Pros:**
- Services are not exposed to the UI layer
- Explicit injection at each use site

**Cons:**
- `ServiceContainer` still needs to store the instances as properties
- `ServiceContainer` conformance to `Services` would fail if the protocol is in `Services`
- Would require a different wiring approach
- Inconsistent with how all other services are wired

---

## Recommendation

**Option A** — Accept the current pattern. The broader exposure is consistent with existing project conventions, and the risk of accidental UI-layer access is minimal. The benefit of Option B (clean separation) does not justify the refactoring cost for two protocols. **[CORRECTION (2026-02-21): Only one protocol (`HasOfflineSyncResolver`) is in the `Services` typealias. `HasPendingCipherChangeDataStore` is not exposed via `Services` -- it uses direct initializer injection. The refactoring cost consideration applies to a single protocol only.]**

## Estimated Impact

- **Files changed:** 0
- **Risk:** None

## Related Issues

- **CS-1 (DI-3)**: Stray blank line — both relate to `Services.swift` changes.
- **U3**: Pending changes indicator — if a UI-layer indicator is added, `HasPendingCipherChangeDataStore` exposure in `Services` is actually needed. **[CORRECTION (2026-02-21): Since `HasPendingCipherChangeDataStore` is NOT currently in the `Services` typealias, implementing U3 would REQUIRE adding it -- it cannot leverage existing exposure because no such exposure exists.]**

## Updated Review Findings

The review confirms the original assessment. After reviewing the implementation:

1. **Code verification**: `Services.swift:40` includes `HasOfflineSyncResolver` ~~and line 44 includes `HasPendingCipherChangeDataStore`~~ in the `Services` typealias. The typealias is used as a constraint for UI-layer types (coordinators, processors). **[CORRECTION (2026-02-21): `HasPendingCipherChangeDataStore` does NOT appear in `Services.swift` at all. It is not in the `Services` typealias. The data store is injected directly via initializer parameters to `DefaultOfflineSyncResolver` and `DefaultVaultRepository`.]**

2. **Existing precedent verified**: Other data stores and services in the `Services` typealias include items that are primarily core-layer concerns. The pattern of including all `Has*` protocols in a single typealias is consistent throughout the project. **[CORRECTION (2026-02-21): This precedent observation is valid for `HasOfflineSyncResolver`, but `HasPendingCipherChangeDataStore` does not follow this pattern -- it uses direct initializer injection instead.]**

3. **Future use case**: If U3 (pending changes indicator) is implemented, a UI-layer processor would need `HasPendingCipherChangeDataStore` to observe pending change counts. ~~The current exposure actually enables this future feature without refactoring.~~ **[CORRECTION (2026-02-21): Since `HasPendingCipherChangeDataStore` is NOT in the `Services` typealias, implementing U3 would REQUIRE adding it to `Services` or creating a new observable mechanism. The current architecture does NOT enable this future feature without refactoring.]**

4. **Option B assessment**: Creating a `CoreServices` typealias would be a significant architectural refactoring affecting many files. The benefit (preventing accidental UI-layer access to ~~2 protocols~~ 1 protocol) does not justify the cost for the current scope. **[CORRECTION (2026-02-21): Only `HasOfflineSyncResolver` is in `Services`. `HasPendingCipherChangeDataStore` already uses direct injection.]**

**Updated conclusion (2026-02-21)**: Original recommendation (Option A - accept current pattern) confirmed for `HasOfflineSyncResolver`. No changes needed. The exposure of `HasOfflineSyncResolver` is consistent with existing project conventions. However, the DI-2 concern (`HasPendingCipherChangeDataStore` in `Services`) is moot -- it was never added to the `Services` typealias and uses direct initializer injection instead. Future UI features (U3) would require explicitly adding `HasPendingCipherChangeDataStore` to `Services` or creating a new observable mechanism. Priority: Low, accept as-is.

## Consolidated Assessment

*From: ConsolidatedOutstandingIssues.md — Section 3: Deferred Issues*

Create separate `CoreServices` typealias for core-layer-only dependencies. Impact reduced since `HasPendingCipherChangeDataStore` was never added to `Services` — only `HasOfflineSyncResolver` is exposed. Significant DI refactoring required.

## Code Review References

Relevant review documents:
- `ReviewSection_DIWiring.md`

## Comments
