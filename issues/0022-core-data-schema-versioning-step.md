---
id: 22
title: "[R2-PCDS-1] No Core Data schema versioning step"
status: open
created: 2026-02-21
author: claude
labels: [enhancement]
priority: medium
---

## Description

Current entity addition works via lightweight migration but future attribute changes require explicit versioning.

**Severity:** Medium
**Complexity:** Medium
**Action Plan:** AP-R2-PCDS-1

**Related Documents:** Review2/01_PendingCipherChangeData

## Action Plan

*Source: `ActionPlans/AP-R2-PCDS-1_CoreDataSchemaVersioning.md`*

> **Issue:** #48 from ConsolidatedOutstandingIssues.md
> **Severity:** Medium | **Complexity:** Medium
> **Status:** Triaged
> **Source:** Review2/01_PendingCipherChangeData_Review.md (Core Data Schema section)

## Problem Statement

The `PendingCipherChangeData` entity was added to the existing `Bitwarden.xcdatamodel` without creating a new model version (i.e., without adding a second `.xcdatamodel` bundle inside the `.xcdatamodeld` directory). The current setup has a single model version:

```
Bitwarden.xcdatamodeld/
    Bitwarden.xcdatamodel/
        contents
```

Core Data's `NSPersistentContainer` uses automatic lightweight migration by default, which can handle adding new entities to the schema without an explicit model version. This means the current addition works -- existing users upgrading from the upstream Bitwarden app will have the `PendingCipherChangeData` entity added seamlessly.

However, this approach has limitations for future changes:
1. **Adding new attributes to `PendingCipherChangeData`** requires lightweight migration support (adding optional attributes or attributes with default values is fine, but renaming or removing attributes requires explicit mapping).
2. **Without a versioned model**, Core Data cannot track which schema version a user's persistent store is at, making it harder to write targeted migration logic in the future.
3. **The upstream Bitwarden project** has never used Core Data model versioning -- the entire `.xcdatamodeld` bundle contains only one model version. This means the offline sync feature follows the same pattern as the rest of the app.

## Current Code

**Schema definition at `Bitwarden.xcdatamodeld/Bitwarden.xcdatamodel/contents` (lines 45-61):**
```xml
<entity name="PendingCipherChangeData" representedClassName=".PendingCipherChangeData" syncable="YES">
    <attribute name="id" attributeType="String"/>
    <attribute name="cipherId" attributeType="String"/>
    <attribute name="userId" attributeType="String"/>
    <attribute name="changeTypeRaw" attributeType="Integer 16" defaultValueString="0" usesScalarValueType="YES"/>
    <attribute name="cipherData" optional="YES" attributeType="Binary"/>
    <attribute name="originalRevisionDate" optional="YES" attributeType="Date" usesScalarValueType="NO"/>
    <attribute name="createdDate" optional="YES" attributeType="Date" usesScalarValueType="NO"/>
    <attribute name="updatedDate" optional="YES" attributeType="Date" usesScalarValueType="NO"/>
    <attribute name="offlinePasswordChangeCount" attributeType="Integer 16" defaultValueString="0" usesScalarValueType="YES"/>
    <uniquenessConstraints>
        <uniquenessConstraint>
            <constraint value="userId"/>
            <constraint value="cipherId"/>
        </uniquenessConstraint>
    </uniquenessConstraints>
</entity>
```

**DataStore initialization at `DataStore.swift:64`:**
```swift
persistentContainer = NSPersistentContainer(name: "Bitwarden", managedObjectModel: Self.managedObjectModel)
```

No explicit migration options are configured. `NSPersistentContainer` defaults to:
- `NSMigratePersistentStoresAutomaticallyOption = true`
- `NSInferMappingModelAutomaticallyOption = true`

This enables automatic lightweight migration, which supports:
- Adding new entities (what the offline sync feature does)
- Adding new optional attributes
- Adding new attributes with default values
- Removing attributes
- Renaming entities/attributes (with renaming identifier)

It does NOT support:
- Changing attribute types
- Complex data transformations during migration
- Custom migration logic

## Assessment

**Validity:** This issue is valid as a forward-looking concern. The current schema addition works correctly with automatic lightweight migration. The risk is specifically about **future changes** to the `PendingCipherChangeData` entity that might require explicit model versioning.

**Key observations:**

1. **The upstream Bitwarden iOS app has never used model versioning.** The entire `Bitwarden.xcdatamodeld` bundle contains only one model version. All existing entities (`CipherData`, `FolderData`, `CollectionData`, etc.) were added to this single model without versioning. The offline sync feature follows this established pattern.

2. **Adding a new entity is one of the simplest lightweight migrations.** Core Data handles this automatically without any configuration. There is no risk of migration failure for the current change.

3. **Future attribute additions are also safe with lightweight migration** as long as new attributes are either optional or have default values. The existing `PendingCipherChangeData` attributes already follow this pattern (`cipherData`, `originalRevisionDate`, `createdDate`, `updatedDate` are all optional; `changeTypeRaw` and `offlinePasswordChangeCount` have default values).

4. **The risk materializes only if a future change requires a non-lightweight migration** (e.g., changing `changeTypeRaw` from Int16 to String, or splitting `cipherData` into multiple fields). At that point, explicit model versioning would need to be introduced for the entire `Bitwarden.xcdatamodeld`, not just the offline sync entity.

**Blast radius:** If a future schema change is incompatible with lightweight migration:
- Core Data would fail to load the persistent store on app launch
- The `loadPersistentStores` callback at `DataStore.swift:76-79` would log the error
- The app would be in a degraded state -- vault data would be inaccessible
- This is a critical failure that would affect the entire app, not just offline sync

**Likelihood:** Low in the near term. The current `PendingCipherChangeData` schema is well-designed and unlikely to need non-lightweight changes. If the schema needs to evolve, it can be done incrementally (adding optional attributes) without model versioning.

## Options

### Option A: Add Explicit Model Versioning Now (Proactive)
- **Effort:** Medium (2-4 hours)
- **Description:** Create a second model version in the `.xcdatamodeld` bundle. The original model becomes "Version 1" (pre-offline-sync schema), and the new model becomes "Version 2" (with `PendingCipherChangeData`). Set Version 2 as the current model. Core Data will perform automatic lightweight migration from V1 to V2 on first launch after the update.
- **Pros:** Establishes a versioning baseline for future changes; makes the migration path explicit and traceable; follows Core Data best practices
- **Cons:** Adds complexity (two model files to maintain); the upstream Bitwarden project does not use model versioning, so this diverges from the established pattern; the current schema change works without versioning; may cause merge conflicts if the upstream adds their own model changes
- **Implementation steps:**
  1. In Xcode, select `Bitwarden.xcdatamodeld`
  2. Editor > Add Model Version... > Name: "Bitwarden 2" based on "Bitwarden"
  3. Add `PendingCipherChangeData` entity to "Bitwarden 2"
  4. Set "Bitwarden 2" as current version in the file inspector
  5. Verify `NSPersistentContainer` loads correctly with the versioned model

### Option B: Add Model Versioning When Needed (Deferred)
- **Effort:** None now; Medium when needed
- **Description:** Accept the current single-model approach and add model versioning only when a schema change requires it. Document this decision so future developers know to add versioning before making non-additive schema changes.
- **Pros:** No work now; follows the existing upstream pattern; avoids divergence from the base project; the current schema change is safe
- **Cons:** Requires awareness from future developers; if forgotten, a non-lightweight migration could cause app crashes

### Option C: Accept As-Is
- **Rationale:** The upstream Bitwarden iOS app has 8 existing Core Data entities, all added to a single unversioned model. The project has operated this way for its entire lifetime without issues. Adding model versioning solely for the offline sync entity would diverge from the established pattern without immediate benefit. The current `PendingCipherChangeData` entity is well-designed with appropriate optional/default attributes. Future attribute additions can be handled with lightweight migration without model versioning. If a non-lightweight change is ever needed, model versioning can be added at that time.

## Recommendation

**Option B: Add Model Versioning When Needed.** This follows the established pattern of the upstream project while acknowledging the forward-looking concern. The current schema change is safe with automatic lightweight migration. Adding model versioning now would diverge from the upstream pattern without immediate benefit.

If the team anticipates significant schema evolution for `PendingCipherChangeData` in the near future (e.g., adding a data format version field per AP-R1), then **Option A** becomes more attractive as a proactive measure. Otherwise, defer until needed.

**Important note for future development:** Any change to `PendingCipherChangeData` attributes beyond adding optional attributes or attributes with default values should trigger the creation of explicit model versions. This should be documented as a development guideline.

## Dependencies

- **AP-R1_DataFormatVersioning.md** (Issue R1): If a `dataFormatVersion` field is added to `PendingCipherChangeData`, it would be an additive change (new attribute with default value) that works with lightweight migration. However, if combined with other schema changes, explicit versioning may be warranted.
- The upstream Bitwarden project's approach to Core Data schema changes will influence whether model versioning is adopted project-wide.

## Consolidated Assessment

*From: ConsolidatedOutstandingIssues.md — Section 4c: Reliability / Edge Cases*

No Core Data schema versioning step — current entity addition works via lightweight migration but future attribute changes require explicit versioning. **R1 and R3 schema changes should use a new model version.**

## Code Review References

Relevant review documents:
- `Review2/01_PendingCipherChangeData_Review.md`

## Comments
