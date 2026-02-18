# Detailed Review: PendingCipherChangeDataStore & PendingCipherChangeData

## Files Covered

| File | Type | Lines |
|------|------|-------|
| `BitwardenShared/Core/Vault/Models/Data/PendingCipherChangeData.swift` | Core Data Entity + Predicates | 192 |
| `BitwardenShared/Core/Vault/Services/Stores/PendingCipherChangeDataStore.swift` | Data Store Protocol + Implementation | 155 |
| `BitwardenShared/Core/Vault/Services/Stores/PendingCipherChangeDataStoreTests.swift` | Tests | 286 |
| `BitwardenShared/Core/Vault/Services/Stores/TestHelpers/MockPendingCipherChangeDataStore.swift` | Mock | 78 |
| `BitwardenShared/Core/Platform/Services/Stores/Bitwarden.xcdatamodeld/Bitwarden.xcdatamodel/contents` | Core Data Schema (modified) | +17 lines |

---

## End-to-End Walkthrough

### 1. Core Data Entity (`PendingCipherChangeData.swift`)

This file defines the Core Data managed object for queuing offline cipher changes. It serves as the foundational persistence layer for all offline operations.

**Class Structure:**

```
PendingCipherChangeData : NSManagedObject
├── @NSManaged properties: id, cipherId, userId, changeTypeRaw, cipherData,
│                          originalRevisionDate, createdDate, updatedDate,
│                          offlinePasswordChangeCount
├── Computed property: changeType (PendingCipherChangeType enum wrapper)
├── convenience init(context:id:cipherId:userId:changeType:cipherData:
│                    originalRevisionDate:offlinePasswordChangeCount:)
└── static predicate/request helpers (7 methods)
```

**Change Type Enum (`PendingCipherChangeType`):**

- `.update` (rawValue: 0) — Update to an existing cipher
- `.create` (rawValue: 1) — Newly created cipher (offline)
- `.softDelete` (rawValue: 2) — Soft delete of an existing cipher

**Notable Design Decisions:**

1. **`cipherData` is stored as `Data?` (binary)** — This contains JSON-encoded `CipherDetailsResponseModel` in the same encrypted format as `CipherData.modelData`. The approach preserves the encrypt-before-queue invariant: all sensitive fields within the JSON are encrypted by the SDK before storage.

2. **`originalRevisionDate` is captured once** — On the first offline edit, this records the cipher's `revisionDate` at that point. Subsequent offline edits to the same cipher preserve this value (the upsert logic in the data store does not overwrite it). This is the baseline used for conflict detection during sync resolution.

3. **`offlinePasswordChangeCount` tracks password mutations** — A counter that increments each time the user changes the password field across offline edits. When this reaches the soft conflict threshold (4), a backup is created even without a server-side conflict. This is a safety net for scenarios where a user changes a password many times offline.

4. **Predicate methods use `#keyPath` references** — `PendingCipherChangeData.swift:115` uses `#keyPath(PendingCipherChangeData.userId)` for type-safe predicate construction, avoiding string literal errors.

5. **Uniqueness constraint on `(userId, cipherId)`** — Defined in the `.xcdatamodel` schema, this ensures at most one pending change per cipher per user. This is the correct constraint: if a user makes multiple offline edits to the same cipher, the subsequent edits update the existing record rather than creating duplicates.

### 2. Core Data Schema (`Bitwarden.xcdatamodel/contents`)

The schema adds the `PendingCipherChangeData` entity with 9 attributes and a uniqueness constraint:

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

**Model Versioning Note:** The entity is added to the existing model version without creating a new versioned model file (no `.xcdatamodeld` version step). Core Data's lightweight migration automatically handles new entity additions, so this is safe for app upgrades. However, any future modification to this entity's attributes (e.g., renaming or removing a field) would require explicit model versioning to avoid migration failures.

### 3. Data Store Protocol & Implementation (`PendingCipherChangeDataStore.swift`)

**Protocol:** Defines 7 methods for CRUD operations on pending changes:

| Method | Purpose |
|--------|---------|
| `fetchPendingChanges(userId:)` | Fetch all pending changes for a user |
| `fetchPendingChange(cipherId:userId:)` | Fetch a single pending change by cipher/user |
| `upsertPendingChange(...)` | Insert or update a pending change (6 params) |
| `deletePendingChange(id:)` | Delete by record ID |
| `deletePendingChange(cipherId:userId:)` | Delete by cipher/user pair |
| `deleteAllPendingChanges(userId:)` | Delete all for a user |
| `pendingChangeCount(userId:)` | Count pending changes for a user |

**Implementation via `DataStore` extension:** The implementation extends `DataStore` (the existing Core Data wrapper) rather than creating a separate class. This follows the established pattern in the codebase (see `DataStore+CipherData`, `DataStore+FolderData`, etc.).

**Key Implementation Details:**

1. **Upsert semantics (`upsertPendingChange`):** Performs a fetch-then-insert-or-update within `performAndSave`. On update, it explicitly preserves `originalRevisionDate` (line 109: `// Do NOT overwrite originalRevisionDate`). This is critical for conflict detection correctness.

2. **Sort order:** `fetchPendingChanges` sorts by `createdDate` ascending, ensuring FIFO processing during sync resolution.

3. **Thread safety:** All operations execute on `backgroundContext.perform {}` or `backgroundContext.performAndSave {}`, which confines them to the background context's serial queue. This is consistent with the existing Core Data access patterns in the codebase.

4. **Batch delete for cleanup:** `deleteAllPendingChanges` uses `executeBatchDelete` (the existing `DataStore` helper), which operates at the SQL level for efficiency.

### 4. Mock (`MockPendingCipherChangeDataStore.swift`)

A comprehensive mock capturing all method calls and supporting configurable results:

- `fetchPendingChangesResult` / `fetchPendingChangesCalledWith` — Track fetch-all calls
- `fetchPendingChangeResult` / `fetchPendingChangeCalledWith` — Track fetch-by-cipher calls
- `upsertPendingChangeCalledWith` — Captures full parameter tuple for assertion
- `pendingChangeCountResult: Int` / `pendingChangeCountResults: [Int]` — Supports both a single default count and a sequential-return mechanism. When `pendingChangeCountResults` is non-empty, the mock returns (and removes) the first element; otherwise it falls back to `pendingChangeCountResult`.
- `upsertPendingChangeResult: Result<Void, Error>` — Supports configurable error injection

### 5. User Data Cleanup (`DataStore.swift:105`)

The single-line change adds `PendingCipherChangeData.deleteByUserIdRequest(userId: userId)` to the `deleteDataForUser` batch delete array. This ensures pending changes are properly cleaned up on logout or account deletion, preventing orphaned data.

---

## Compliance Assessment

### Architecture Compliance

| Guideline | Status | Details |
|-----------|--------|---------|
| Data stores extend `DataStore` | **Pass** | Implementation via `DataStore` extension follows existing pattern |
| Protocol-based abstractions | **Pass** | `PendingCipherChangeDataStore` protocol with `DataStore` conformance |
| Core Data entity in `.xcdatamodel` | **Pass** | Properly added to existing schema |
| Mock follows `Mock<Name>` pattern | **Pass** | `MockPendingCipherChangeDataStore` |
| User data isolation | **Pass** | All queries scoped by `userId` |
| User data cleanup | **Pass** | Integrated into `deleteDataForUser` batch |

### Code Style Compliance

| Guideline | Status | Details |
|-----------|--------|---------|
| MARK comments | **Pass** | `// MARK: Properties`, `// MARK: Initialization`, `// MARK: Computed Properties` used |
| DocC documentation | **Pass** | All public APIs documented, including parameter descriptions |
| Naming conventions | **Pass** | UpperCamelCase for types, lowerCamelCase for properties/methods |
| American English | **Pass** | "organization" spelling used consistently |
| Alphabetization | **Pass** | Properties and methods within MARK sections are ordered appropriately |

### Security Compliance

| Principle | Status | Details |
|-----------|--------|---------|
| Encrypt before persist | **Pass** | `cipherData` receives already-encrypted JSON from the SDK |
| No plaintext secrets | **Pass** | Only encrypted cipher data stored; metadata fields are non-sensitive |
| Per-user isolation | **Pass** | `(userId, cipherId)` uniqueness constraint; all queries include `userId` |
| Core Data protection level | **Matches existing** | Uses same `DataStore` with same file protection as existing vault data |

### Test Coverage

| Test | Coverage |
|------|----------|
| `test_fetchPendingChanges_empty` | Empty state |
| `test_fetchPendingChanges_returnsUserChanges` | User isolation, multi-user scenario |
| `test_fetchPendingChange_byId` | Single fetch, not-found case |
| `test_upsertPendingChange_insert` | New record creation, all field verification |
| `test_upsertPendingChange_update` | Upsert idempotency, `originalRevisionDate` preservation |
| `test_deletePendingChange_byId` | Delete by record ID |
| `test_deletePendingChange_byCipherId` | Delete by cipher/user pair, verify only target deleted |
| `test_deleteAllPendingChanges` | Bulk delete with user isolation |
| `test_pendingChangeCount` | Count verification, multi-user |

**Coverage Assessment:** Good. All CRUD paths tested including multi-user isolation. The `originalRevisionDate` preservation invariant is explicitly tested.

---

## Issues and Observations

### Issue PCDS-1: `PendingCipherChangeData.id` is `String?` but Required in Schema

The Core Data schema defines `id` as a required `attributeType="String"`, but the Swift class declares it as `@NSManaged var id: String?` (optional). While this works at runtime (Core Data enforces the non-optional constraint at the persistence layer), the Swift type doesn't communicate the required-ness to callers. Throughout the resolver code, `pendingChange.id` must be safely unwrapped with `if let recordId = pendingChange.id`.

**Severity:** Low. Functional but slightly increases nil-checking verbosity.

### Issue PCDS-2: `createdDate` and `updatedDate` Set in `convenience init` but Marked Optional in Schema

The `createdDate` and `updatedDate` attributes are optional in the schema but are always set in the `convenience init` via `Date()`. If a `PendingCipherChangeData` were ever created via `init(context:)` directly (bypassing the convenience init), these fields would be nil. The `OfflineSyncResolver.resolveConflict` method uses `pendingChange.updatedDate ?? pendingChange.createdDate ?? Date.distantPast`, which gracefully handles nil but with a potentially surprising fallback.

**Severity:** Low. The convenience init is the only creation path in practice.

### Issue PCDS-3: No Data Migration Strategy for `cipherData` Format

The `cipherData` field stores `CipherDetailsResponseModel` as JSON. If this model changes in a future version (added/removed/renamed fields), old pending records could fail to decode. The `JSONDecoder` will throw on missing required fields.

**Severity:** Low. Pending changes are short-lived (resolved on next successful sync). The risk is low unless a user upgrades the app while having unresolved pending changes during an extended offline period.

### Observation PCDS-4: `upsertPendingChange` Performs Fetch-Then-Update (Not Atomic Upsert)

The upsert implementation fetches the existing record and then either updates or inserts within a single `performAndSave` block. This is a two-step operation within a single Core Data context operation, which is safe given the serial queue execution model. A true upsert (using `NSMergePolicy`) would be more efficient but would require different conflict handling logic.

**Severity:** Informational. Current approach is correct and consistent with other `DataStore` patterns.
