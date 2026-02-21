# AP-61: ServiceContainer Mock Defaults — 131 Calls Silently Receive New Offline Sync Mocks

> **Issue:** #61 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Triaged
> **Source:** ReviewSection_TestChanges.md (Deep Dive 8)

## Problem Statement

The `ServiceContainer.withMocks()` factory method gained two new parameters with default values:
- `offlineSyncResolver: OfflineSyncResolver = MockOfflineSyncResolver()` (line 48)
- `pendingCipherChangeDataStore: PendingCipherChangeDataStore = MockPendingCipherChangeDataStore()` (not directly a parameter — wired via `DataStore` — but the mock defaults are set up)

There are 131 call sites across 107 test files that invoke `ServiceContainer.withMocks()`. All now silently receive these new mocks without any explicit opt-in. Zero of these 131 call sites customize the new parameters.

The mock defaults are:
- `MockOfflineSyncResolver`: `processPendingChangesCalledWith` tracks calls but does nothing
- `MockPendingCipherChangeDataStore`: `pendingChangeCountResult = 0`, `upsertPendingChangeResult = .success(())`

## Current Code

- Factory method: `BitwardenShared/Core/Platform/Services/TestHelpers/ServiceContainer+Mocks.swift:14-151`
- New parameter at line 48: `offlineSyncResolver: OfflineSyncResolver = MockOfflineSyncResolver()`
- Wiring into `ServiceContainer` at line 125: `offlineSyncResolver: offlineSyncResolver`

## Assessment

**Still valid.** The observation is accurate: 131 call sites now receive mock offline sync services. However, this is the standard Swift pattern for adding new dependencies with backward-compatible defaults. The existing `ServiceContainer.withMocks()` factory already has 60+ parameters, all with defaults. The offline sync additions are consistent with this pattern.

**Actual impact:** Minimal. The mock defaults (`pendingChangeCountResult = 0`) mean the offline sync code paths are effectively no-ops in all existing tests. Since `pendingChangeCount` returns 0, the pre-sync resolution block in `fetchSync()` skips immediately. This is the correct behavior — existing tests should not be affected by the new feature.

**Primary risk:** Discoverability. Future test authors may not know these dependencies exist unless they inspect the factory signature. If a developer needs to test offline sync behavior in a new context, they must discover and override the relevant mock parameters.

**Hidden risks:**
- If `MockPendingCipherChangeDataStore.pendingChangeCountResult` were changed from `0` to a positive number, all 24 existing `fetchSync` tests in `SyncServiceTests` would break because `fetchSync` would return early via the abort path. This fragility is documented in Issue #41 (TC-6) and is a separate concern.

## Options

### Option A: Accept As-Is (Recommended)
- **Effort:** None
- **Description:** Keep the current default-parameter pattern. This is consistent with how all other services are added to `ServiceContainer.withMocks()`.
- **Pros:** Zero effort, follows established pattern, backward compatible
- **Cons:** No improvement to discoverability

### Option B: Add Comment Documenting New Dependencies
- **Effort:** Low (~15 minutes)
- **Description:** Add a brief comment in `ServiceContainer+Mocks.swift` near the new parameters noting their role in offline sync and directing developers to `SyncServiceTests` and `VaultRepositoryTests` for examples of customization.
- **Pros:** Improves discoverability for new developers
- **Cons:** Comments can become stale; the factory already has 60+ parameters

### Option C: Create Dedicated Factory for Offline Sync Tests
- **Effort:** Medium (~1-2 hours)
- **Description:** Create a `ServiceContainer.withOfflineSyncMocks()` variant that configures offline sync dependencies explicitly, leaving the base factory unchanged.
- **Pros:** Makes offline sync test setup explicit and discoverable
- **Cons:** Diverges from established pattern, adds maintenance burden, over-engineering for 2 parameters

## Recommendation

**Option A: Accept As-Is.** The default-parameter pattern for `ServiceContainer.withMocks()` is the established convention in this codebase. Every new service follows the same approach. The offline sync additions are a natural extension of this pattern. The discoverability concern is inherent to a factory with 60+ parameters and is not specific to offline sync.

## Dependencies

- Related to Issue #41 (TC-6): Mock defaults silently bypass abort logic in `fetchSync` tests.
