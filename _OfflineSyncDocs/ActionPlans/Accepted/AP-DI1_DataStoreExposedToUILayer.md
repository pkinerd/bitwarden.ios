# Action Plan: DI-1 (DI-2) — DataStore and Resolver Exposed to UI Layer via `Services` Typealias

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

The architecture docs note that data stores "may only need to be accessed by services or repositories in the core layer and wouldn't need to be exposed to the UI layer."

## Context

Both services are registered on `ServiceContainer`, which conforms to `Services`. Adding them to the `Services` typealias is required for the container conformance. However, the `Services` typealias is also used as a constraint on UI-layer dependency injection, meaning coordinators and processors can technically access these services.

This follows existing precedent in the project — other data stores are also in the `Services` typealias. It's a known architectural compromise rather than a new violation.

---

## Options

### Option A: Accept Current Pattern (Recommended)

Keep both protocols in the `Services` typealias, consistent with existing data store patterns in the project.

**Pros:**
- Consistent with existing codebase patterns
- No code change
- `ServiceContainer` conformance is straightforward
- If future UI-layer features need offline sync access (e.g., pending changes indicator), the protocol is already available

**Cons:**
- Broader exposure than architecturally ideal
- UI-layer code could accidentally depend on these services

### Option B: Create Separate Core-Only Typealias

Create a `CoreServices` typealias (or similar) for services that should only be used in the core layer. Have `ServiceContainer` conform to both `Services` and `CoreServices`.

**Approach:**
1. Define `CoreServices` typealias composing core-only `Has*` protocols
2. Move `HasPendingCipherChangeDataStore` and `HasOfflineSyncResolver` to `CoreServices`
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
- Not justified by the current 2-protocol scope

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

**Option A** — Accept the current pattern. The broader exposure is consistent with existing project conventions, and the risk of accidental UI-layer access is minimal. The benefit of Option B (clean separation) does not justify the refactoring cost for two protocols.

## Estimated Impact

- **Files changed:** 0
- **Risk:** None

## Related Issues

- **CS-1 (DI-3)**: Stray blank line — both relate to `Services.swift` changes.
- **U3**: Pending changes indicator — if a UI-layer indicator is added, `HasPendingCipherChangeDataStore` exposure in `Services` is actually needed.

## Updated Review Findings

The review confirms the original assessment. After reviewing the implementation:

1. **Code verification**: `Services.swift:40` includes `HasOfflineSyncResolver` and line 44 includes `HasPendingCipherChangeDataStore` in the `Services` typealias. The typealias is used as a constraint for UI-layer types (coordinators, processors).

2. **Existing precedent verified**: Other data stores and services in the `Services` typealias include items that are primarily core-layer concerns. The pattern of including all `Has*` protocols in a single typealias is consistent throughout the project.

3. **Future use case**: If U3 (pending changes indicator) is implemented, a UI-layer processor would need `HasPendingCipherChangeDataStore` to observe pending change counts. The current exposure actually enables this future feature without refactoring.

4. **Option B assessment**: Creating a `CoreServices` typealias would be a significant architectural refactoring affecting many files. The benefit (preventing accidental UI-layer access to 2 protocols) does not justify the cost for the current scope.

**Updated conclusion**: Original recommendation (Option A - accept current pattern) confirmed. No changes needed. The exposure is consistent with existing project conventions and enables future UI features (U3). Priority: Low, accept as-is.
