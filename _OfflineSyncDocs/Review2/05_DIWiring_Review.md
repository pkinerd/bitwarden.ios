# Review: Dependency Injection Wiring (ServiceContainer, Services)

## Files Reviewed

| File | Status | Lines Changed |
|------|--------|--------------|
| `BitwardenShared/Core/Platform/Services/ServiceContainer.swift` | Modified | +35 |
| `BitwardenShared/Core/Platform/Services/Services.swift` | Modified | +18 |
| `BitwardenShared/Core/Platform/Services/TestHelpers/ServiceContainer+Mocks.swift` | Modified | +4 |

## Overview

These files wire the new offline sync components into the existing dependency injection system. The `ServiceContainer` creates and holds references to the new `OfflineSyncResolver` and `PendingCipherChangeDataStore`, the `Services.swift` file defines the `Has*` protocols for DI composition, and the mock helper adds parameters for test injection.

## Architecture Compliance

### DI Pattern (Architecture.md)

- **Compliant**: Follows the established `Has<Service>` protocol composition pattern. New protocols `HasOfflineSyncResolver` and `HasPendingCipherChangeDataStore` are added to `Services.swift` and included in the `Services` typealias.
- **Compliant**: Both new dependencies are created in `ServiceContainer`'s factory method and injected into their consumers through initializers.
- **Compliant**: Mock extensions in `ServiceContainer+Mocks.swift` allow test injection.

## Detailed Walkthrough

### Services.swift — Has Protocols

```swift
protocol HasOfflineSyncResolver {
    var offlineSyncResolver: OfflineSyncResolver { get }
}

protocol HasPendingCipherChangeDataStore {
    var pendingCipherChangeDataStore: PendingCipherChangeDataStore { get }
}
```

Both are added to the `Services` typealias:

```swift
typealias Services = HasAPIService
    & ...
    & HasOfflineSyncResolver
    & ...
    & HasPendingCipherChangeDataStore
    & ...
```

**Assessment**:
- **Compliant**: Alphabetical ordering maintained in the typealias
- **Compliant**: Proper DocC documentation on each protocol

### ServiceContainer.swift — Property Declarations

```swift
let offlineSyncResolver: OfflineSyncResolver
let pendingCipherChangeDataStore: PendingCipherChangeDataStore
```

**Assessment**: Properties use protocol types (not concrete types), maintaining abstraction.

### ServiceContainer.swift — Factory Wiring

The `OfflineSyncResolver` is created as:
```swift
let preSyncOfflineSyncResolver = DefaultOfflineSyncResolver(
    cipherAPIService: apiService,
    cipherService: cipherService,
    clientService: clientService,
    pendingCipherChangeDataStore: dataStore,
    stateService: stateService,
)
```

It's then injected into `SyncService` and `VaultRepository`:
```swift
let syncService = DefaultSyncService(
    ...
    offlineSyncResolver: preSyncOfflineSyncResolver,
    ...
    pendingCipherChangeDataStore: dataStore,
    ...
)

// VaultRepository receives pendingCipherChangeDataStore
DefaultVaultRepository(
    ...
    pendingCipherChangeDataStore: dataStore,
    ...
)
```

The `offlineSyncResolver` is also stored in the container:
```swift
let offlineSyncResolver: OfflineSyncResolver = preSyncOfflineSyncResolver
```

**Assessment**:
- **Good**: The `DataStore` instance is reused for `PendingCipherChangeDataStore` (since `DataStore` conforms to the protocol via extension). This means no new Core Data stack is created.
- **Concern — `HasPendingCipherChangeDataStore` exposure to UI layer**: The `PendingCipherChangeDataStore` is included in the `Services` typealias, which means it's theoretically accessible from the UI layer. Per Architecture.md, stores should typically "only need to be accessed by services or repositories in the core layer and wouldn't need to be exposed to the UI layer." The data store is currently only used by `VaultRepository` (core layer) and `SyncService` (core layer), so exposing it to the UI layer is unnecessary. This is documented in `AP-DI1_DataStoreExposedToUILayer.md`. However, the current exposure doesn't cause any architectural violation — it just makes the store available where it shouldn't be needed.
- **Good**: The `OfflineSyncResolver` is exposed to the UI layer via `HasOfflineSyncResolver`, but this is less concerning since the resolver is a higher-level service, not a raw data store.

### ServiceContainer+Mocks.swift

```swift
static func withMocks(
    ...
    pendingCipherChangeDataStore: MockPendingCipherChangeDataStore = MockPendingCipherChangeDataStore(),
    ...
)
```

**Assessment**: Follows the existing pattern for mock injection.

### Incidental Fixes

The ServiceContainer changes also include two typo fixes:
- `DefultExportVaultService` → `DefaultExportVaultService` (line 567)
- `Exhange` → `Exchange` (multiple comments)

These are unrelated to offline sync but were included in the same change.

## Security Assessment

- **No concerns**: The DI wiring doesn't introduce any new security surface. Dependencies are injected through the same established patterns.

## Cross-Component Dependencies

The `Services` typealias now includes `HasPendingCipherChangeDataStore`, making the data store accessible across the entire UI layer. This is wider than necessary — ideally only `VaultRepository` and `SyncService` should access it. However, the practical impact is minimal since UI-layer code has no reason to call the data store directly.

**Recommendation**: Consider removing `HasPendingCipherChangeDataStore` from the `Services` typealias and instead passing it directly through initializers of `VaultRepository` and `SyncService` (which is already done). The typealias inclusion is redundant since neither the UI layer nor any coordinator/processor needs direct data store access.

## Code Style Compliance

- **Compliant**: Alphabetical ordering in initializer parameters
- **Compliant**: DocC documentation on all new parameters
- **Compliant**: Naming follows project conventions

## Simplification Opportunities

1. **Remove `HasPendingCipherChangeDataStore` from `Services` typealias**: The data store is only needed in the core layer. Removing it from `Services` would reduce the API surface exposed to the UI layer.
2. **Remove `HasOfflineSyncResolver` from `Services` typealias** if it's not needed by any UI-layer component. Currently it's in the typealias but may not be referenced from any processor or coordinator.

## Summary

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Architecture compliance | **Good** | Follows Has protocol pattern |
| DI wiring correctness | **Good** | All dependencies properly connected |
| Security | **No concerns** | Standard DI patterns |
| Code style | **Good** | Alphabetical, documented |
| API surface | **Minor concern** | DataStore exposed to UI layer unnecessarily |
