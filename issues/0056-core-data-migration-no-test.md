---
id: 56
title: "[R2-TEST-2] Core Data lightweight migration has no automated test"
status: closed
created: 2026-02-21
author: claude
labels: [enhancement]
priority: medium
closed: 2026-02-21
---

## Description

Core Data lightweight migration (adding `PendingCipherChangeData` entity) has no automated test.

**Severity:** Medium
**Rationale:** Entity addition is the safest lightweight migration; no other entities have migration tests; SQLite fixture effort unjustified for entity-add risk level.

**Related Documents:** AP-36 (Accepted As-Is)

**Disposition:** Accepted — no code change planned.

## Action Plan

*Source: `ActionPlans/Accepted/AP-36_CoreDataLightweightMigrationTest.md`*

> **Issue:** #36 from ConsolidatedOutstandingIssues.md
> **Severity:** Medium | **Complexity:** Medium
> **Status:** Accepted As-Is
> **Source:** Review2/08_TestCoverage_Review.md

## Problem Statement

The offline sync feature adds a new `PendingCipherChangeData` entity to the Core Data model (`Bitwarden.xcdatamodeld`). When the app updates, Core Data performs a lightweight migration to add this entity to the existing SQLite store. There is no automated test verifying that this lightweight migration succeeds.

Lightweight migration for adding a new entity is one of the safest Core Data schema changes (it only adds a new table), but if the migration fails at runtime, the persistent store fails to load, potentially causing data loss or app-level errors. The `DataStore.init` at `BitwardenShared/Core/Platform/Services/Stores/DataStore.swift:76-79` logs the error via `errorReporter` but does not crash, meaning a migration failure would result in silent data access failures.

## Current Test Coverage

- **No migration tests exist.** There are no test files that load an older version of the Core Data model and verify migration to the current version.
- **Existing data store tests** use `StoreType.memory` (in-memory store at `/dev/null`), which creates a fresh schema each time and never exercises migration paths.
- **`PendingCipherChangeDataStoreTests.swift`** at `BitwardenShared/Core/Vault/Services/Stores/PendingCipherChangeDataStoreTests.swift` tests CRUD operations on the new entity but uses an in-memory store.

## Missing Coverage

1. Loading a pre-offline-sync SQLite database with the updated Core Data model succeeds via lightweight migration.
2. Existing data (ciphers, folders, etc.) survives the migration intact.
3. The new `PendingCipherChangeData` entity is accessible after migration.

## Assessment

**Still valid:** Yes. No Core Data migration tests exist anywhere in the project.

**Risk of not having the test:** Low-to-Medium.
- Adding a new entity is the simplest Core Data schema change and is fully supported by lightweight migration.
- Apple's Core Data documentation explicitly states that adding entities is supported without a mapping model.
- The risk is primarily theoretical: if the `.xcdatamodeld` were accidentally corrupted, misconfigured, or if a future schema change broke the migration chain, there would be no automated detection.
- This is a general project gap, not specific to offline sync. No other entity additions (there are 8 existing entities: `CipherData`, `CollectionData`, `FolderData`, etc.) have migration tests either.

**Priority:** Low. The theoretical risk is real but the practical probability is very low for entity addition. The effort to implement is medium due to the need to bundle a pre-migration SQLite fixture.

## Options

### Option A: Add Lightweight Migration Test with SQLite Fixture (Recommended)
- **Effort:** ~2-4 hours
- **Description:** Create a test that:
  1. Bundles a pre-migration SQLite database (created from the model version before `PendingCipherChangeData` was added) as a test resource.
  2. Copies it to a temporary directory.
  3. Initializes a `DataStore` with `StoreType.persisted` pointing to the copied file.
  4. Verifies the persistent store loads successfully.
  5. Verifies existing entity data is intact.
  6. Verifies `PendingCipherChangeData` can be inserted and fetched.
- **Test scenarios:**
  - `test_lightweightMigration_addPendingCipherChangeData_succeeds` -- store loads, entities accessible
  - `test_lightweightMigration_existingDataPreserved` -- pre-existing `CipherData` records survive
- **Pros:** Comprehensive verification. Catches future migration chain breaks. Establishes a migration test pattern for the project.
- **Cons:** Requires creating and bundling a SQLite fixture. Medium effort. Test is somewhat brittle (tied to specific model versions). Must maintain the fixture as the model evolves.

### Option B: Programmatic Model Version Test
- **Effort:** ~1-2 hours
- **Description:** Create a test that programmatically constructs an `NSManagedObjectModel` from a previous version of `Bitwarden.xcdatamodeld` (if versioned model files exist), then verifies that `NSMappingModel.inferredMappingModel(forSourceModel:destinationModel:)` succeeds between the old and new models.
- **Pros:** No SQLite fixture needed. Tests migration feasibility without an actual migration.
- **Cons:** Only verifies that lightweight migration is *possible*, not that it *works*. Requires the xcdatamodel to have version history (which it may not -- the project appears to use a single model without versioning).

### Option C: Accept As-Is
- **Rationale:** Adding a new entity is the safest lightweight migration operation. No other entities in the project have migration tests. The probability of this specific migration failing is extremely low. Manual QA testing covers this scenario during the app update flow. If the project adopts Core Data model versioning or attribute changes in the future (see Issue #48/R2-PCDS-1), migration tests would become more important at that point.

## Recommendation

**Option C (Accept As-Is) for now**, with a note to revisit if/when Issue R3 (retry backoff) or R1 (data format versioning) adds schema changes that require explicit model versioning. At that point, **Option A** should be implemented to cover the full migration chain.

The effort-to-risk ratio for entity-addition migration testing is not favorable enough to justify immediate implementation, especially since no other entities in the project have this coverage.

## Dependencies

- **R2-PCDS-1 (#48):** Core Data schema versioning concern. If explicit model versions are added, migration tests become essential.
- **R3 (#1):** Retry backoff may add schema changes. Bundle migration test effort with R3 if implemented.
- **R1 (#4):** Data format versioning may add a `dataVersion` attribute. Same bundling opportunity.
- **R2-CROSS-1 (#82):** Recommends bundling schema changes for R1 and R3 in a single migration step.

## Consolidated Assessment

*From: ConsolidatedOutstandingIssues.md — Section 5: Open Issues — Accepted As-Is*

Core Data lightweight migration (adding `PendingCipherChangeData` entity) has no automated test. Entity addition is the safest lightweight migration; no other entities have migration tests; SQLite fixture effort unjustified for entity-add risk level.

## Code Review References

Relevant review documents:
- `Review2/08_TestCoverage_Review.md`

## Comments
