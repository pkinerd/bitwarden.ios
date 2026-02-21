# AP-81: Core Data Store Does Not Configure Explicit `NSFileProtectionComplete`

> **Issue:** #81 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Medium
> **Status:** Triaged
> **Source:** OfflineSyncPlan.md (Section 10: Security Considerations)

## Problem Statement

The `DataStore` class initializes a Core Data persistent store without configuring explicit file protection attributes. The `NSPersistentStoreDescription` is created with a URL but no `setOption` call for `NSPersistentStoreFileProtectionKey`. This means the SQLite database file relies on iOS default file protection settings:

- **Default protection level:** `NSFileProtectionCompleteUntilFirstUserAuthentication` (Class C protection). This means the file is encrypted at rest but becomes accessible after the first device unlock and remains accessible until the next device restart.
- **`NSFileProtectionComplete`** (Class A protection) would make the file inaccessible whenever the device is locked, providing stronger protection but preventing background access.

This is an existing architectural characteristic of the entire data store, predating the offline sync feature. The offline sync changes inherit the same protection level without modification.

## Current Code

- `BitwardenShared/Core/Platform/Services/Stores/DataStore.swift:61-83`
```swift
init(errorReporter: ErrorReporter, storeType: StoreType = .persisted) {
    self.errorReporter = errorReporter
    persistentContainer = NSPersistentContainer(name: "Bitwarden", managedObjectModel: Self.managedObjectModel)
    let storeDescription: NSPersistentStoreDescription
    switch storeType {
    case .memory:
        storeDescription = NSPersistentStoreDescription(url: URL(fileURLWithPath: "/dev/null"))
    case .persisted:
        let storeURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Bundle.main.groupIdentifier)!
            .appendingPathComponent("Bitwarden.sqlite")
        storeDescription = NSPersistentStoreDescription(url: storeURL)
    }
    persistentContainer.persistentStoreDescriptions = [storeDescription]
    persistentContainer.loadPersistentStores { _, error in
        if let error {
            errorReporter.log(error: error)
        }
    }
    persistentContainer.viewContext.automaticallyMergesChangesFromParent = true
}
```

No `storeDescription.setOption(...)` call for file protection is present.

## Assessment

**Still valid as an observation; not actionable within the offline sync scope.** The OfflineSyncPlan correctly notes this as an "existing architectural characteristic, unchanged by this feature."

**Defense-in-depth layers already present:**

1. **Application-level encryption:** All sensitive cipher fields (name, login, notes, password history, custom fields) within `CipherData` and `PendingCipherChangeData.cipherData` are encrypted by the Bitwarden SDK using the user's master key derivative before storage. An attacker who accesses the SQLite file sees encrypted blobs, not plaintext secrets.

2. **iOS sandbox:** The SQLite database is within the app group container, accessible only to the Bitwarden app (and its extensions).

3. **iOS default file protection:** `NSFileProtectionCompleteUntilFirstUserAuthentication` provides encryption at rest when the device has not been unlocked since boot.

**Why `NSFileProtectionComplete` is not used:**
- The app uses extensions (AutoFill, Share) and background operations (push notification sync, periodic background refresh) that need database access when the device is locked.
- `NSFileProtectionComplete` would make the database inaccessible during these operations, breaking core functionality.
- This is a well-known tradeoff in iOS password managers that require background access.

**What an attacker gains without `NSFileProtectionComplete`:**
- Access to the encrypted SQLite database after the first device unlock.
- From the offline sync data: plaintext metadata (`cipherId`, `userId`, `changeTypeRaw`, `originalRevisionDate`, `createdDate`, `updatedDate`, `offlinePasswordChangeCount`). These reveal activity patterns but not vault content.
- From the cipher data: encrypted blobs that cannot be decrypted without the user's master key.

**Hidden risks:** None introduced by offline sync. The `PendingCipherChangeData` entity stores the same type of encrypted data as `CipherData` and inherits the same protection level.

## Options

### Option A: Accept As-Is (Recommended)
- **Rationale:** This is a pre-existing architectural decision that applies to the entire data store, not just offline sync. The offline sync feature correctly inherits the existing protection level without degrading it. Changing file protection to `NSFileProtectionComplete` would break background operations (AutoFill, push sync, periodic background refresh) that are critical to the app's functionality. The application-level encryption (SDK-encrypted cipher data) provides the primary security layer.

### Option B: Configure `NSFileProtectionComplete` for Data Store
- **Effort:** Low code change (~3 lines), but High impact assessment required
- **Description:** Add `storeDescription.setOption(FileProtectionType.complete as NSObject, forKey: NSPersistentStoreFileProtectionKey)` to the `DataStore` initializer.
- **Pros:** Stronger file-level encryption, data inaccessible when device is locked
- **Cons:** Breaks all background operations that access the database while the device is locked (AutoFill credential provider, push notification sync handler, periodic background refresh, widget updates). This would be a significant regression in core app functionality.

### Option C: Separate Store for Sensitive Data
- **Effort:** High (~days-weeks)
- **Description:** Create a second Core Data store with `NSFileProtectionComplete` for highly sensitive data, while keeping the main store at the default protection level for background access.
- **Pros:** Best of both worlds — background access for non-sensitive operations, strong protection for sensitive data
- **Cons:** Significant architectural change, requires splitting entities across stores, complex migration, high risk

### Option D: Evaluate Database-Level Encryption (SQLCipher)
- **Effort:** High (~weeks)
- **Description:** Use SQLCipher or a similar database-level encryption solution to encrypt the entire SQLite database with a key derived from the user's master password.
- **Pros:** Full database encryption regardless of device lock state, independent of iOS file protection
- **Cons:** Major dependency addition, performance impact, key management complexity, must handle database access when master key is unavailable

## Recommendation

**Option A: Accept As-Is.** This is a codebase-wide architectural decision that predates offline sync and cannot be changed in isolation. The application-level encryption (SDK-encrypted cipher data) provides the primary security layer. Changing file protection would break critical background features. If database-level encryption is desired, it should be pursued as a separate initiative (Option D) covering the entire data store, not just the offline sync entities.

## Dependencies

- Related to Issue #83 (SEC-2.a): The decision to not encrypt `offlinePasswordChangeCount` is consistent with this issue — the metadata fields are at the same protection level as all other Core Data metadata.
- If Options B/C/D are ever pursued, they should be done as a separate architectural initiative affecting all of `DataStore`, not just offline sync entities.
