# Review: PendingCipherChangeData & PendingCipherChangeDataStore

## Files Reviewed

| File | Status | Lines Changed |
|------|--------|--------------|
| `BitwardenShared/Core/Vault/Models/Data/PendingCipherChangeData.swift` | **New** | +192 |
| `BitwardenShared/Core/Vault/Services/Stores/PendingCipherChangeDataStore.swift` | **New** | +155 |
| `BitwardenShared/Core/Vault/Services/Stores/PendingCipherChangeDataStoreTests.swift` | **New** | +286 |
| `BitwardenShared/Core/Vault/Services/Stores/TestHelpers/MockPendingCipherChangeDataStore.swift` | **New** | +78 |
| `BitwardenShared/Core/Platform/Services/Stores/Bitwarden.xcdatamodeld/Bitwarden.xcdatamodel/contents` | Modified | +17 |
| `BitwardenShared/Core/Platform/Services/Stores/DataStore.swift` | Modified | +1 |

## Overview

These files implement the Core Data persistence layer for offline cipher changes. `PendingCipherChangeData` is the Core Data managed object that stores pending offline edits, and `PendingCipherChangeDataStore` is the protocol/extension that provides CRUD operations on that entity.

## Architecture Compliance

### Layering (Architecture.md)

- **Compliant**: The data store follows the established pattern of extending `DataStore` with protocol conformance (see `CipherDataStore`, `FolderDataStore`, etc.). This is consistent with `Architecture.md` which states data stores should be responsible for persisting data to Core Data.
- **Compliant**: The `PendingCipherChangeDataStore` protocol defines the interface, and `DataStore` provides the default implementation — matching the project's existing pattern.
- **Compliant**: Test helper mock (`MockPendingCipherChangeDataStore`) follows the project convention of hand-written mocks in `TestHelpers/` directories.

### Core Data Schema

- **Compliant**: The `PendingCipherChangeData` entity is added to the existing `Bitwarden.xcdatamodel` alongside `CipherData`, `FolderData`, etc.
- **Concern — No schema versioning**: The Core Data model file is modified directly without adding a versioned `.xcdatamodel` (i.e., a new model version in the `.xcdatamodeld` bundle). This means existing users upgrading from the upstream version will get a Core Data schema that doesn't match their persistent store. Core Data's lightweight migration can handle adding new entities automatically, but this relies on the project's `NSPersistentContainer` being configured with appropriate migration options. The existing `DataStore` uses `NSPersistentContainer` which by default enables lightweight migration, so this should work — but the lack of explicit versioning is a deviation from best practice.
- **Uniqueness constraint**: The entity uses `(userId, cipherId)` as its uniqueness constraint, which is correct — there should be at most one pending change per cipher per user.

### Data Model Design

The entity has these attributes:

| Attribute | Type | Notes |
|-----------|------|-------|
| `id` | String | Record ID (UUID) |
| `cipherId` | String | Cipher ID |
| `userId` | String | User ID |
| `changeTypeRaw` | Int16 | Enum backing: 0=update, 1=create, 2=softDelete |
| `cipherData` | Binary (optional) | JSON-encoded encrypted cipher snapshot |
| `originalRevisionDate` | Date (optional) | Baseline for conflict detection |
| `createdDate` | Date (optional) | When queued |
| `updatedDate` | Date (optional) | Last updated |
| `offlinePasswordChangeCount` | Int16 | Password change counter |

**Observations**:

1. **`id` is marked as required in schema but `@NSManaged var id: String?`** — The Core Data schema says `attributeType="String"` (required) but the Swift property is declared as `String?`. This works because Core Data allows optional Swift properties even for required attributes, but it creates a mismatch in intent. The `id` is always set via the convenience initializer (defaults to `UUID().uuidString`), so in practice it's never nil for properly-created objects. However, the optional typing means callers must unwrap it, leading to `if let recordId = pendingChange.id` guards throughout the codebase.

2. **`createdDate` and `updatedDate` are optional in schema** — These are set in the convenience initializer to `Date()` but the schema marks them as optional. This is fine for Core Data but means they could theoretically be nil if an object is created through a different code path. The code handles this defensively (e.g., `pendingChange.updatedDate ?? pendingChange.createdDate ?? Date.distantPast`).

3. **`offlinePasswordChangeCount` uses `Int16`** — Adequate range (max 32,767) for a password change counter. The threshold is 4, so Int16 is more than sufficient.

## Security Assessment

### Encryption of Stored Data

- **Compliant with zero-knowledge architecture**: The `cipherData` field stores the same JSON-encoded `CipherDetailsResponseModel` format used by the existing `CipherData` entity. All sensitive fields (name, login credentials, notes, etc.) are encrypted by the Bitwarden SDK before storage. The `PendingCipherChangeData` stores only the already-encrypted blob.
- **Metadata stored in plaintext**: The following fields are stored as plaintext metadata:
  - `cipherId` — The cipher's UUID. This is also stored plaintext in the existing `CipherData` entity, so this is consistent.
  - `userId` — Also stored plaintext in existing entities.
  - `changeTypeRaw` — Reveals the type of operation (create/update/delete). This is minor metadata.
  - `originalRevisionDate`, `createdDate`, `updatedDate` — Timestamps revealing when offline edits occurred. This is comparable to the `revisionDate` stored in `CipherData`.
  - `offlinePasswordChangeCount` — Reveals the number of password changes. This is a minor information leak but does not reveal the actual passwords. **[Explored — Will Not Implement encryption]** See [AP-SEC2](../ActionPlans/Resolved/AP-SEC2_PasswordChangeCountEncryption.md).

**Assessment**: The security posture of `PendingCipherChangeData` is **equivalent to `CipherData`** — sensitive content is encrypted by the SDK, and only non-sensitive metadata is stored as separate attributes. The pending change data is protected to the same level as the offline vault copy. The `offlinePasswordChangeCount` plaintext storage was formally evaluated for encryption and determined to be consistent with the existing security model (see AP-SEC2).

### Data Cleanup on Logout/Account Delete

- **Compliant**: `DataStore.swift` is modified to include `PendingCipherChangeData.deleteByUserIdRequest(userId:)` in the batch delete operations that run when user data is cleared. This ensures pending changes are cleaned up alongside other user data on logout or account deletion.

## Code Style Compliance

### Swift Code Style (contributing docs)

- **Compliant**: MARK comments used appropriately (`// MARK: Properties`, `// MARK: Computed Properties`, `// MARK: Initialization`, `// MARK: - Predicates`)
- **Compliant**: DocC documentation on all public APIs
- **Compliant**: Alphabetical ordering within sections
- **Compliant**: File naming follows CamelCase convention
- **Compliant**: Test file co-located with implementation

### Protocol Design

- The `PendingCipherChangeDataStore` protocol is well-designed with a minimal, focused API surface. It provides:
  - Fetch operations (all for user, single by cipher+user)
  - Upsert (insert or update)
  - Delete operations (by record ID, by cipher+user, all for user)
  - Count query
- **Compliant** with the "single discrete responsibility" principle for services.

## Reliability Concerns

1. **Upsert race condition**: The `upsertPendingChange` method performs a fetch-then-insert/update within `performAndSave`. Since `performAndSave` wraps the operation in the background context's `perform` block, this should be thread-safe within a single `DataStore` instance. However, if multiple `DataStore` instances exist (unlikely given the DI setup), there could be a race. The uniqueness constraint on `(userId, cipherId)` would catch duplicate inserts at the Core Data level, preventing data corruption.

2. **`deletePendingChange(id:)` deletes all matching records**: The method iterates over all results matching the ID and deletes them. Since `id` should be unique (UUID), this is fine, but the loop pattern is defensive.

3. **No error propagation from `performAndSave`**: The `performAndSave` method (existing infrastructure) handles saving the context. If the save fails, the error propagates up through the `async throws` chain, which is correct.

## Data Safety (User Data Loss Prevention)

- **Safe**: Pending changes are stored persistently in Core Data, surviving app restarts and device reboots.
- **Safe**: The upsert pattern preserves `originalRevisionDate` from the first offline edit, preventing conflict detection baseline from being overwritten.
- **Risk**: If the Core Data store becomes corrupted, pending changes would be lost. However, this risk is shared with the existing vault data and is inherent to Core Data usage.

## Simplification Opportunities

1. The `id` property could be made non-optional (`String` instead of `String?`) since it's always set. This would eliminate the `if let recordId = pendingChange.id` guards throughout the codebase. However, this would require Core Data schema changes and may conflict with how `NSManagedObject` handles property initialization.

2. The separate `deleteByUserIdRequest` returning `NSBatchDeleteRequest` is consistent with the existing pattern in `CipherData`, `FolderData`, etc.

## Test Coverage

The `PendingCipherChangeDataStoreTests.swift` file (286 lines) covers:
- Fetching pending changes for a user
- Fetching a specific pending change by cipher ID
- Upserting (insert and update paths)
- Preserving `originalRevisionDate` on update
- Deleting by record ID
- Deleting by cipher+user
- Deleting all for user
- Counting pending changes
- Multi-user isolation

**Assessment**: Test coverage is comprehensive for the data store operations.

## Summary

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Architecture compliance | **Good** | Follows established DataStore extension pattern |
| Security | **Good** | Encrypted data stored at same protection level as vault |
| Code style | **Good** | Follows Swift/MARK/DocC conventions |
| Reliability | **Good** | Thread-safe via Core Data context, uniqueness constraints |
| Data safety | **Good** | Persistent storage, proper cleanup on logout |
| Test coverage | **Good** | Comprehensive tests for all operations |
| Schema versioning | **Minor concern** | No explicit Core Data model version added |
