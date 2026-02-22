---
id: 11
title: "[PLAN-3] Phase 5 integration tests (end-to-end offline→reconnect→resolve)"
status: open
created: 2026-02-21
author: claude
labels: [enhancement]
priority: medium
---

## Description

Phase 5 integration tests (end-to-end offline→reconnect→resolve). Existing `OfflineSyncResolverTests` with real `DataStore` already function as semi-integration tests.

**Severity:** Medium
**Complexity:** Medium
**Dependencies:** DefaultSyncService requires 19 dependencies; defer until integration test infrastructure exists.

**Related Documents:** AP-77 (Deferred)

**Status:** Deferred — future enhancement.

## Action Plan

*Source: `ActionPlans/AP-77_Phase5IntegrationTestsStatus.md`*

> **Issue:** #77 from ConsolidatedOutstandingIssues.md
> **Severity:** Medium | **Complexity:** Medium
> **Status:** Deferred
> **Source:** OfflineSyncPlan.md

## Problem Statement

The `OfflineSyncPlan.md` document outlines an implementation plan with 5 phases. Phase 5 (Section 11, item 16) states:

> **Phase 5: Testing**
> 14. Unit tests for all new services
> 15. Unit tests for modified flows
> 16. Integration tests for end-to-end offline -> reconnect -> resolve scenarios

Items 14 and 15 have been implemented -- comprehensive unit tests exist for all new services (`OfflineSyncResolverTests`, `PendingCipherChangeDataStoreTests`, `CipherViewOfflineSyncTests`) and modified flows (`VaultRepositoryTests` additions, `SyncServiceTests` additions, `ViewItemProcessorTests` additions).

Item 16 -- integration tests for end-to-end scenarios -- has no evidence of implementation. No test file in the codebase combines the full offline-save -> sync-trigger -> resolver-executes -> cipher-synced flow across multiple real (non-mocked) components.

## Current Test Coverage

### Unit Tests (Comprehensive)

All offline sync components have thorough unit tests with mocked dependencies:

| Component | Test File | Tests |
|-----------|-----------|-------|
| `OfflineSyncResolver` | `OfflineSyncResolverTests.swift` | 20+ tests (create, update, softDelete, conflict, 404, batch, error isolation) |
| `PendingCipherChangeDataStore` | `PendingCipherChangeDataStoreTests.swift` | 10+ tests (fetch, upsert, delete, count, multi-user isolation) |
| `CipherView+OfflineSync` | `CipherViewOfflineSyncTests.swift` | 6+ tests (withId, update, property count guard) |
| `VaultRepository` (offline paths) | `VaultRepositoryTests.swift` | 32 tests (all CRUD operations, error filtering, offline fallback) |
| `SyncService` (pre-sync resolution) | `SyncServiceTests.swift` | 7 tests (trigger, skip, abort, error, feature flag) |
| `ViewItemProcessor` (fallback) | `ViewItemProcessorTests.swift` | 4 tests (fallback success, failure, throws, error logging) |

### Integration Tests (None Found)

A search for integration tests, end-to-end tests, or tests that combine multiple real (non-mocked) offline sync components yielded no results:

- No test file combines `VaultRepository` (real) -> `SyncService` (real) -> `OfflineSyncResolver` (real) -> `PendingCipherChangeDataStore` (real).
- No test simulates the full "save offline, trigger sync, resolve, verify server state" flow.
- No UI-level integration test exists for the offline -> reconnect journey.

### Closest Existing Tests

The closest to integration tests are the `OfflineSyncResolverTests`, which use a real `DataStore` (in-memory) for creating `PendingCipherChangeData` fixtures but mock `CipherService` and `CipherAPIService`. This is a "semi-integration" approach for the resolver but does not span the full flow.

## Missing Coverage

1. **End-to-end save-offline flow:** `VaultRepository.addCipher` throws network error -> cipher saved locally -> pending change queued -> verify pending change exists in data store.
2. **End-to-end resolution flow:** Pending change exists -> `SyncService.fetchSync` called -> resolver processes change -> cipher created on server -> pending change deleted -> sync completes normally.
3. **End-to-end conflict resolution:** Cipher saved offline -> server cipher edited concurrently -> sync triggered -> conflict detected -> backup created -> winner determined -> pending change resolved.
4. **End-to-end feature flag interaction:** Feature flag disabled -> offline save not queued -> sync proceeds without resolution.

## Assessment

**Still valid:** Yes. No integration tests exist for the end-to-end offline sync flow. Phase 5, item 16 from the plan has not been implemented.

**Risk of not having integration tests:** Medium.
- The unit test coverage is comprehensive. Each component is thoroughly tested with mocked dependencies.
- The "seams" between components (VaultRepository -> PendingCipherChangeDataStore, SyncService -> OfflineSyncResolver -> CipherService) are covered by tests on both sides of each seam.
- Integration tests would primarily catch issues in component wiring (DI configuration, dependency interaction) that are not covered by unit tests.
- The ServiceContainer wiring is tested implicitly by the fact that the app compiles and the DI registrations are type-checked at compile time.
- Manual QA testing likely covers the end-to-end flow.

**Priority:** Medium. Integration tests are valuable for confidence but the comprehensive unit test suite provides strong coverage. The main gap is verifying the DI wiring and the full flow interaction.

## Options

### Option A: Add Targeted Integration Tests (Recommended)
- **Effort:** ~4-8 hours, 100-200 lines
- **Description:** Create an `OfflineSyncIntegrationTests.swift` file that uses real implementations for the core offline sync components (with mocked network layer) to test the full flow.
- **Test scenarios:**
  - `test_endToEnd_addCipherOffline_syncResolves` -- configure mock HTTP client to fail for addCipher, succeed for sync; call `addCipher`, verify pending change created; call `fetchSync`, verify cipher created on server and pending change deleted
  - `test_endToEnd_updateCipherOffline_conflict_backupCreated` -- save cipher, simulate offline edit with pending change, configure server with different revision date, trigger sync, verify backup created and winner determined
  - `test_endToEnd_featureFlagOff_noOfflineSave` -- disable feature flag, trigger network failure, verify cipher operation fails (no offline fallback)
- **Component wiring:**
  - Real: `DefaultVaultRepository`, `DefaultSyncService`, `DefaultOfflineSyncResolver`, `DefaultPendingCipherChangeDataStore`, `DataStore` (in-memory)
  - Mocked: `HTTPClient` (to control network success/failure), `ClientService` (SDK encryption), `StateService`
- **Pros:** Verifies the full flow. Catches wiring issues. High confidence. Closes the Phase 5 plan item.
- **Cons:** Significant effort. Complex mock setup. Potentially brittle. May require test infrastructure changes.

### Option B: Add Smoke Integration Test
- **Effort:** ~2-3 hours, 50-80 lines
- **Description:** A single integration test that verifies the happy path: save offline -> sync -> resolved. Use real implementations where feasible, mock at the network boundary.
- **Test scenarios:**
  - `test_endToEnd_offlineSave_thenSync_resolves` -- single happy-path test
- **Pros:** Verifies the critical path with moderate effort.
- **Cons:** Does not cover conflict, error, or feature flag scenarios.

### Option C: Accept As-Is -- Unit Tests Sufficient
- **Rationale:** The unit test suite is comprehensive with 70+ tests across all offline sync components. Each component boundary is tested from both sides. The DI wiring is type-checked at compile time. Manual QA testing covers the end-to-end flow. Integration tests would provide incremental confidence but at significant effort.

## Recommendation

**Option B (Smoke Integration Test)** as a pragmatic middle ground. A single happy-path integration test provides the highest value per effort: it verifies the DI wiring, the component interaction sequence, and the data flow from offline save through sync resolution. This closes the Phase 5 plan item without the full effort of comprehensive integration tests.

If the team has capacity, **Option A** provides more thorough coverage but at 4-8 hours of effort. The decision depends on the team's confidence level from the existing unit tests and manual QA coverage.

## Dependencies

- **Test infrastructure:** May need a test helper that creates a `ServiceContainer` with real offline sync components and mocked network services.
- **MockHTTPClient:** Needs to support sequenced responses (fail for cipher operations, succeed for sync).
- **ClientService mocking:** SDK encryption/decryption needs to work (or be mocked to pass through) for the full flow.
- All other test coverage gap issues (35-42) are independent and do not block this.

## Consolidated Assessment

*From: ConsolidatedOutstandingIssues.md — Section 3: Deferred Issues*

Phase 5 integration tests (end-to-end offline→reconnect→resolve). Existing `OfflineSyncResolverTests` with real `DataStore` already function as semi-integration tests. DefaultSyncService requires 19 dependencies; defer until integration test infrastructure exists.

## Comments
