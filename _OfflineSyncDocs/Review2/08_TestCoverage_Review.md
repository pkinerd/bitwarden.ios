# Review: Test Coverage Analysis

## Overview

This document assesses the overall test coverage of the offline sync feature, including both new test files and modifications to existing tests.

## New Test Files

| Test File | Lines | Testing |
|-----------|-------|---------|
| `CipherViewOfflineSyncTests.swift` | 171 | CipherView+OfflineSync extension methods |
| `OfflineSyncResolverTests.swift` | 933 | Conflict resolution logic |
| `PendingCipherChangeDataStoreTests.swift` | 286 | Core Data persistence operations |

## Modified Test Files

| Test File | Lines Added | Testing |
|-----------|-------------|---------|
| `VaultRepositoryTests.swift` | +671 | Offline fallback in add/update/delete/softDelete |
| `SyncServiceTests.swift` | +90 | Pre-sync resolution flow |
| `ViewItemProcessorTests.swift` | +87 | Publisher fallback for offline-created ciphers |
| `AlertVaultTests.swift` | +29 | specificPeopleUnavailable alert (upstream) |
| `CipherServiceTests.swift` | +32 | Various cipher operations |

## New Test Helpers / Mocks

| Mock File | Lines | Purpose |
|-----------|-------|---------|
| `MockPendingCipherChangeDataStore.swift` | 78 | Mock for data store in tests |
| `MockOfflineSyncResolver.swift` | 13 | Mock for resolver in SyncService tests |
| `MockCipherAPIServiceForOfflineSync.swift` | 68 | Mock for getCipher API in resolver tests |

## Coverage by Component

### PendingCipherChangeDataStore — Comprehensive

| Scenario | Covered |
|----------|---------|
| Fetch all pending changes for user | Yes |
| Fetch specific change by cipher ID | Yes |
| Upsert — insert new record | Yes |
| Upsert — update existing record | Yes |
| Preserve originalRevisionDate on update | Yes |
| Delete by record ID | Yes |
| Delete by cipher+user | Yes |
| Delete all for user | Yes |
| Count pending changes | Yes |
| Multi-user isolation | Yes |

### OfflineSyncResolver — Comprehensive

| Scenario | Covered |
|----------|---------|
| resolveCreate — success | Yes |
| resolveCreate — temp ID cleanup | Yes |
| resolveUpdate — no conflict | Yes |
| resolveUpdate — conflict, local newer | Yes |
| resolveUpdate — conflict, server newer | Yes |
| resolveUpdate — soft conflict (4+ password changes) | Yes |
| resolveUpdate — cipher not found (404) | Yes |
| resolveSoftDelete — no conflict | Yes |
| resolveSoftDelete — conflict | Yes |
| resolveSoftDelete — already deleted (404) | Yes |
| Batch processing — multiple changes | Yes |
| Error handling — per-change isolation | Yes |
| Password change counting — threshold | Yes |

### VaultRepository Offline Helpers — Comprehensive

| Scenario | Covered |
|----------|---------|
| addCipher — online success | Yes |
| addCipher — offline fallback | Yes |
| addCipher — server error not caught for offline | Yes |
| updateCipher — online success | Yes |
| updateCipher — offline fallback | Yes |
| updateCipher — org cipher rejection | Yes |
| deleteCipher — online success | Yes |
| deleteCipher — offline fallback (soft-delete) | Yes |
| deleteCipher — offline-created cipher (local cleanup) | Yes |
| softDeleteCipher — online success | Yes |
| softDeleteCipher — offline fallback | Yes |
| softDeleteCipher — offline-created cipher (local cleanup) | Yes |
| Pending change cleanup on success | Yes |
| Password change counting | Yes |
| Temp ID assignment for new ciphers | Yes |

### SyncService Integration — Good

| Scenario | Covered |
|----------|---------|
| Sync with pending changes — resolution succeeds | Yes |
| Sync with remaining changes — abort | Yes |
| Sync with locked vault — skip resolution | Yes |
| Sync with no pending changes — normal flow | Yes |

### ViewItemProcessor Fallback — Good

| Scenario | Covered |
|----------|---------|
| Publisher error — fallback fetch succeeds | Yes |
| Publisher error — fallback fetch returns nil | Yes |
| Publisher error — fallback fetch throws | Yes |
| Error logging on both paths | Yes |

### CipherView+OfflineSync — Good

| Scenario | Covered |
|----------|---------|
| withId preserves all properties | Yes |
| withId assigns new ID | Yes |
| update(name:) sets new name | Yes |
| update(name:) nils ID and key | Yes |
| update(name:) preserves other properties | Yes |
| SDK property count guard | Yes |

## Compliance with Testing.md Guidelines

### Test Naming

- **Compliant**: Test names follow the `test_<function>_<behavior>` pattern (e.g., `test_addCipher_offlineFallback_savesLocally`)
- **Compliant**: Tests are grouped by function being tested, with success paths before failure paths

### Test Organization

- **Compliant**: Test files are co-located with implementation files
- **Compliant**: Tests inherit from `BitwardenTestCase`
- **Compliant**: Proper `setUp()` and `tearDown()` with nil cleanup

### Mock Usage

- **Compliant**: All tests use mocks for dependencies
- **Compliant**: `ServiceContainer.withMocks()` used where appropriate
- **Compliant**: Custom mocks follow the project's mock conventions (tracking `calledWith` arrays, configurable `result` properties)

### Test Strategies

Per Testing.md, the required test types for each component:

| Component | Unit Tests | ViewInspector | Snapshots |
|-----------|-----------|---------------|-----------|
| OfflineSyncResolver (Service) | **Yes** | N/A | N/A |
| PendingCipherChangeDataStore (Store) | **Yes** | N/A | N/A |
| VaultRepository (Repository) | **Yes** | N/A | N/A |
| SyncService (Service) | **Yes** | N/A | N/A |
| ViewItemProcessor (Processor) | **Yes** | N/A | N/A |
| PendingCipherChangeData (Model) | **Yes** (via store tests) | N/A | N/A |
| CipherView+OfflineSync (Extension) | **Yes** | N/A | N/A |

**Assessment**: All component types have the required test types per Testing.md.

## Missing Test Coverage

The following scenarios have limited or no explicit test coverage:

1. **GetCipherRequest 404 validation** — The `validate(_ response:)` method that throws `OfflineSyncError.cipherNotFound` on 404 is tested indirectly through the resolver tests (which mock the API service), but there's no direct unit test for the request's validation logic.

2. **Core Data lightweight migration** — No test verifies that adding the `PendingCipherChangeData` entity to an existing Core Data store works correctly via lightweight migration. This is typically tested manually or through integration tests.

3. **DataStore.swift cleanup** — The addition of `PendingCipherChangeData.deleteByUserIdRequest` to the batch delete is not explicitly tested. It's covered by the existing `DataStore` test infrastructure that tests user data cleanup.

4. **Edge case: Very long cipher names in backup naming** — The backup naming (`"<name> - <timestamp>"`) could create very long names. No test verifies behavior with extreme name lengths.

5. **Edge case: Corrupt cipherData in pending change** — While error handling exists, there's no explicit test for attempting to resolve a pending change with malformed JSON in `cipherData`.

## Compliance with Contributing Docs Style Guide

### Test File Naming (contributing docs)

- **Compliant**: `<TypeToTest>Tests.swift` naming convention used
- **Compliant**: Test files in same folder as implementation

### Mock Generation (contributing docs)

- The mocks for offline sync are hand-written rather than auto-generated with Sourcery. This is consistent with other mocks in the project that have custom behavior (e.g., `MockCipherService` which also has custom tracking properties).
- The `MockPendingCipherChangeDataStore` provides configurable results and call tracking, which is the expected pattern.

## Summary

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Overall coverage | **Good** | All core paths tested |
| Test organization | **Good** | Follows Testing.md guidelines |
| Mock usage | **Good** | Proper isolation with mocks |
| Edge cases | **Adequate** | Some edge cases untested (corruption, migration) |
| Naming conventions | **Good** | Follows project patterns |
| Test file location | **Good** | Co-located with implementation |
