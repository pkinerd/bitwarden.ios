# AP-60: `@MainActor` Annotation Required on Test as Workaround for `MockVaultTimeoutService` Actor Isolation

> **Issue:** #60 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Medium
> **Status:** Triaged
> **Source:** ReviewSection_TestChanges.md (Deep Dive 5)

## Problem Statement

The `VaultTimeoutService` protocol is annotated with `@MainActor` (VaultTimeoutService.swift:20), which means all conforming types — including `MockVaultTimeoutService` — inherit main-actor isolation. When test methods need to set properties on the mock (e.g., `vaultTimeoutService.isClientLocked["1"] = true`), they must also be annotated with `@MainActor` to satisfy the compiler's actor isolation requirements.

The offline sync test `test_fetchSync_preSyncResolution_skipsWhenVaultLocked` (SyncServiceTests.swift:1116) requires `@MainActor` because it mutates `vaultTimeoutService.isClientLocked` on the mock. This follows an existing pattern: `test_fetchSync_organizations_vaultLocked` (SyncServiceTests.swift:908) uses the same approach. In total, the offline sync changes added 8 tests with `@MainActor` annotations in `SyncServiceTests.swift`, all for the same reason.

## Current Code

- Protocol declaration: `BitwardenShared/Core/Vault/Services/VaultTimeoutService.swift:20-21` — `@MainActor protocol VaultTimeoutService`
- Mock: `BitwardenShared/Core/Vault/Services/TestHelpers/MockVaultTimeoutService.swift:9` — `class MockVaultTimeoutService: VaultTimeoutService`
- Mock property: `MockVaultTimeoutService.swift:29` — `var isClientLocked = [String: Bool]()`
- Example test: `SyncServiceTests.swift:1115-1125` — `@MainActor func test_fetchSync_preSyncResolution_skipsWhenVaultLocked()`
- Pre-existing pattern: `SyncServiceTests.swift:908-909` — `@MainActor func test_fetchSync_organizations_vaultLocked()`

## Assessment

**Still valid.** The issue is confirmed. The `@MainActor` annotation on the `VaultTimeoutService` protocol forces all test methods that access mock properties to be `@MainActor`-annotated. This is a pre-existing architectural pattern, not introduced by offline sync. The offline sync tests simply follow the established convention.

**Actual impact:** Low. The `@MainActor` annotations on test methods are functionally correct and do not cause test failures or flaky behavior. The tests run correctly on the main actor. The concern is one of ergonomics and potential confusion for developers who may not understand why the annotation is required.

**Hidden risks:**
- If `@MainActor` annotations proliferate across more test files, it could mask issues where tests inadvertently depend on main-actor serialization rather than explicit ordering.
- Many other test files access `isClientLocked` without `@MainActor`, suggesting the compiler is not consistently enforcing this (possibly due to `nonisolated init()` on the mock or other Swift concurrency nuances). This inconsistency is a pre-existing issue, not introduced by offline sync.

## Options

### Option A: Accept As-Is (Recommended)
- **Effort:** None
- **Description:** Keep `@MainActor` annotations on the affected test methods. This is consistent with the existing codebase pattern and is functionally correct.
- **Pros:** Zero effort, no risk, follows established convention
- **Cons:** Slightly verbose test declarations, inconsistent enforcement across test files

### Option B: Make `MockVaultTimeoutService` `nonisolated` Where Possible
- **Effort:** Medium (~2-4 hours)
- **Description:** Refactor `MockVaultTimeoutService` to make mutable properties `nonisolated(unsafe)` or use a different isolation strategy, removing the need for `@MainActor` on test methods.
- **Pros:** Removes boilerplate annotations, simplifies test code
- **Cons:** Uses `nonisolated(unsafe)` which suppresses safety checks, may introduce subtle concurrency bugs in tests, requires Swift 5.10+ features

### Option C: Refactor `VaultTimeoutService` Protocol Isolation
- **Effort:** High (~1-2 days)
- **Description:** Evaluate whether `@MainActor` on the `VaultTimeoutService` protocol is the right isolation model. Consider using `actor` isolation or removing the main-actor constraint entirely.
- **Pros:** Addresses root cause, improves architectural clarity
- **Cons:** Massive refactoring scope (affects all VaultTimeoutService consumers), high risk for an issue with negligible user impact

## Recommendation

**Option A: Accept As-Is.** The `@MainActor` annotation on test methods is a pre-existing pattern in the codebase, not a regression introduced by offline sync. The offline sync tests correctly follow this pattern. Changing the `VaultTimeoutService` isolation model would be a large cross-cutting refactor that is disproportionate to the minimal ergonomic benefit.

## Dependencies

- None. This is an independent observation about existing test patterns.
