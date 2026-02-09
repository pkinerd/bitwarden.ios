# Detailed Review: Dependency Injection & Wiring

## Files Covered

| File | Type | Lines Changed |
|------|------|---------------|
| `BitwardenShared/Core/Platform/Services/Services.swift` | Has* protocols (modified) | +18 lines |
| `BitwardenShared/Core/Platform/Services/ServiceContainer.swift` | DI container (modified) | +30 lines |
| `BitwardenShared/Core/Platform/Services/TestHelpers/ServiceContainer+Mocks.swift` | Test helper (modified) | +6 lines |
| `BitwardenShared/Core/Platform/Services/Stores/DataStore.swift` | Data store (modified) | +1 line |
| `BitwardenShared/UI/Platform/Application/AppProcessor.swift` | UI layer (modified) | +1 line (whitespace) |

---

## End-to-End Walkthrough

### 1. Services.swift — Has* Protocol Composition

Two new `Has*` protocols are added to the `Services` typealias composition:

```swift
/// Protocol for an object that provides an `OfflineSyncResolver`.
protocol HasOfflineSyncResolver {
    var offlineSyncResolver: OfflineSyncResolver { get }
}

/// Protocol for an object that provides a `PendingCipherChangeDataStore`.
protocol HasPendingCipherChangeDataStore {
    var pendingCipherChangeDataStore: PendingCipherChangeDataStore { get }
}
```

These are added to the `Services` typealias in alphabetical order:
- `& HasOfflineSyncResolver` (between `HasNotificationService` and `HasOrganizationAPIService`)
- `& HasPendingCipherChangeDataStore` (between `HasPendingAppIntentActionMediator` and `HasPolicyService`)

~~**Note:** A blank line was introduced in the `Services` typealias between `& HasConfigService` and `& HasDeviceAPIService`.~~ **[Resolved]** The stray blank line was removed in commit `a52d379`.

### 2. ServiceContainer.swift — Container Registration

The `ServiceContainer` class gains two new stored properties:

```swift
let offlineSyncResolver: OfflineSyncResolver
let pendingCipherChangeDataStore: PendingCipherChangeDataStore
```

These are added:
- In the properties section, in alphabetical order
- In the initializer parameter list, in alphabetical order
- In the initializer body, with corresponding assignments
- In the DocC parameter docs for the initializer

### 3. ServiceContainer.swift — Object Graph Wiring

In the `ServiceContainer` static factory method (`defaultServices()`), the wiring is:

```swift
// 1. Create the resolver (before SyncService, after its dependencies exist)
let preSyncOfflineSyncResolver = DefaultOfflineSyncResolver(
    cipherAPIService: apiService,
    cipherService: cipherService,
    clientService: clientService,
    folderService: folderService,
    pendingCipherChangeDataStore: dataStore,
    stateService: stateService,
)
// NOTE: [Updated] timeProvider was removed in commit a52d379 (was unused — see A3)

// 2. Inject into SyncService
let syncService = DefaultSyncService(
    ...
    offlineSyncResolver: preSyncOfflineSyncResolver,
    ...
    pendingCipherChangeDataStore: dataStore,
    ...
)

// 3. Inject dataStore into VaultRepository
let vaultRepository = DefaultVaultRepository(
    ...
    pendingCipherChangeDataStore: dataStore,
    ...
)

// 4. Assign to a protocol-typed variable for the container
let offlineSyncResolver: OfflineSyncResolver = preSyncOfflineSyncResolver
```

**Dependency Flow:**

```
DataStore (PendingCipherChangeDataStore)
    ├── → DefaultOfflineSyncResolver
    │       ├── → DefaultSyncService (pre-sync resolution)
    │       └── → ServiceContainer (for potential UI-layer access)
    ├── → DefaultSyncService (count checks)
    └── → DefaultVaultRepository (offline save operations)
```

**Important naming note:** The local variable is named `preSyncOfflineSyncResolver` to distinguish it from the `let offlineSyncResolver` variable that's assigned later for the container. Both refer to the same instance. This two-step approach is necessary because the container assignment happens much later in the factory method.

### 4. ServiceContainer+Mocks.swift — Test Helper

The `ServiceContainer.withMocks()` factory gains two new parameters with mock defaults:

```swift
offlineSyncResolver: OfflineSyncResolver = MockOfflineSyncResolver(),
pendingCipherChangeDataStore: PendingCipherChangeDataStore = MockPendingCipherChangeDataStore(),
```

These are added in the parameter list and forwarded to the `ServiceContainer` initializer.

### 5. DataStore.swift — User Data Cleanup

A single line is added to the `deleteDataForUser(userId:)` method's batch delete array:

```swift
PendingCipherChangeData.deleteByUserIdRequest(userId: userId),
```

This ensures that when a user logs out or their account is deleted, all pending offline changes are cleaned up. Without this line, orphaned pending changes would remain in Core Data indefinitely.

### 6. AppProcessor.swift — ~~Whitespace Only~~ [Reverted]

~~The only change to `AppProcessor.swift` is the addition of a blank line at line 136 (after the closing brace of a block).~~ **[Updated]** The blank line was removed in commit `a52d379`. Net zero change to this file.

---

## Compliance Assessment

### Architecture Compliance

| Guideline | Status | Details |
|-----------|--------|---------|
| Has* protocol composition pattern | **Pass** | `HasOfflineSyncResolver`, `HasPendingCipherChangeDataStore` follow naming convention |
| Protocol-typed properties in container | **Pass** | `let offlineSyncResolver: OfflineSyncResolver` (protocol, not concrete type) |
| Alphabetical ordering in Services typealias | **Pass** | New protocols inserted in correct alphabetical position |
| ServiceContainer.withMocks updated | **Pass** | Mock defaults provided for all new dependencies |
| User data cleanup | **Pass** | `PendingCipherChangeData` included in batch delete |

### Code Style Compliance

| Guideline | Status | Details |
|-----------|--------|---------|
| DocC on Has* protocols | **Pass** | Both have summary documentation |
| DocC on container properties | **Pass** | Stored properties documented |
| DocC on init parameters | **Pass** | Both new parameters in init DocC |
| Alphabetical ordering | **Pass** | Properties, parameters, and assignments in alphabetical order |

### Security Compliance

| Principle | Status | Details |
|-----------|--------|---------|
| Data cleanup on logout | **Pass** | Pending changes deleted with other user data |
| No exposed crypto material | **Pass** | Only protocol references; no raw keys in container |

---

## Issues and Observations

### Issue DI-1: `HasPendingCipherChangeDataStore` in `Services` Typealias Exposes Data Store to UI Layer (Low)

The `HasPendingCipherChangeDataStore` protocol is added to the top-level `Services` typealias. Per the architecture guidelines, the `Services` typealias defines dependencies that may be used in the UI layer. `PendingCipherChangeDataStore` is a data store — the architecture docs state:

> "A store may only need to be accessed by services or repositories in the core layer and wouldn't need to be exposed to the UI layer in the `Services` typealias."

**Current usage:** `PendingCipherChangeDataStore` is used by:
- `DefaultVaultRepository` (core layer)
- `DefaultSyncService` (core layer)
- Neither uses it from the `Services` typealias — both receive it via direct init injection

Adding it to the `Services` typealias makes it accessible to any UI-layer component (coordinators, processors), which is broader exposure than necessary. However, it also needs to be on the `ServiceContainer` for it to be injectable, and `ServiceContainer` conforms to `Services`.

**Assessment:** This follows existing precedent in the project (other data stores are also in the `Services` typealias). Not a violation, but slightly broader than the architecture prefers.

### Issue DI-2: `HasOfflineSyncResolver` in `Services` Typealias (Low)

Similarly, `HasOfflineSyncResolver` is added to the `Services` typealias. The resolver is currently used only by `DefaultSyncService`, which receives it via init injection. The `Services` typealias exposure is broader than needed.

**Assessment:** Same as DI-1 — follows existing precedent and enables future UI-layer usage if needed.

### ~~Issue DI-3: Stray Blank Line in Services Typealias~~ [Resolved]

~~A blank line was introduced between `& HasConfigService` and `& HasDeviceAPIService` in the `Services` typealias.~~ **[Resolved]** — The stray blank line was removed in commit `a52d379`.

### Observation DI-4: Same Resolver Instance Shared Between SyncService and Container

The `preSyncOfflineSyncResolver` instance is injected into both `DefaultSyncService` and the `ServiceContainer`. Since `DefaultOfflineSyncResolver` has mutable state (`conflictFolderId`), sharing the same instance means the `SyncService`'s resolver and any other consumer of `offlineSyncResolver` from the container share that cache.

**Assessment:** Currently fine because `SyncService` is the only active consumer. If a second consumer were added, they could share the `conflictFolderId` cache, which could lead to stale references if one consumer invalidates the folder.
