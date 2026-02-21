> **Reconciliation Note (2026-02-21):** This document has been corrected to reflect the actual
> codebase. The original review incorrectly stated that a `HasPendingCipherChangeDataStore` protocol
> existed and was included in the `Services` typealias. In reality, only `HasOfflineSyncResolver`
> is in the `Services` typealias — no `HasPendingCipherChangeDataStore` protocol exists in
> `Services.swift`. All references, code snippets, recommendations, and analysis related to
> `HasPendingCipherChangeDataStore` being in the `Services` typealias have been removed or corrected.

# Review: Dependency Injection Wiring (ServiceContainer, Services)

## Files Reviewed

| File | Status | Lines Changed |
|------|--------|--------------|
| `BitwardenShared/Core/Platform/Services/ServiceContainer.swift` | Modified | +35 |
| `BitwardenShared/Core/Platform/Services/Services.swift` | Modified | +8 |
| `BitwardenShared/Core/Platform/Services/TestHelpers/ServiceContainer+Mocks.swift` | Modified | +4 |

## Overview

These files wire the new offline sync components into the existing dependency injection system. The `ServiceContainer` creates and holds references to the new `OfflineSyncResolver` and `PendingCipherChangeDataStore`, the `Services.swift` file defines the `HasOfflineSyncResolver` protocol for DI composition, and the mock helper adds parameters for test injection. Note: `PendingCipherChangeDataStore` is NOT exposed through the `Services` typealias — it is injected directly through initializers only.

## Architecture Compliance

### DI Pattern (Architecture.md)

- **Compliant**: Follows the established `Has<Service>` protocol composition pattern. `HasOfflineSyncResolver` is added to `Services.swift` and included in the `Services` typealias. `PendingCipherChangeDataStore` is not exposed via a `Has*` protocol in the typealias — it is injected directly through initializers to `VaultRepository` and `SyncService`, keeping it appropriately scoped to the core layer.
- **Compliant**: Both new dependencies are created in `ServiceContainer`'s factory method and injected into their consumers through initializers.
- **Compliant**: Mock extensions in `ServiceContainer+Mocks.swift` allow test injection.

## Detailed Walkthrough

### Services.swift — Has Protocols

Only `HasOfflineSyncResolver` is defined in `Services.swift` and added to the `Services` typealias:

```swift
protocol HasOfflineSyncResolver {
    var offlineSyncResolver: OfflineSyncResolver { get }
}
```

```swift
typealias Services = HasAPIService
    & ...
    & HasOfflineSyncResolver
    & ...
```

There is no `HasPendingCipherChangeDataStore` protocol in `Services.swift`. The `PendingCipherChangeDataStore` is injected directly through initializers to the components that need it (`VaultRepository`, `SyncService`, `OfflineSyncResolver`), keeping it scoped to the core layer.

**Assessment**:
- **Compliant**: Alphabetical ordering maintained in the typealias
- **Compliant**: Proper DocC documentation on the protocol
- **Good architectural decision**: Not exposing the data store in the `Services` typealias keeps the UI layer from having unnecessary access to it

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
    pendingCipherChangeDataStore: dataStore
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
- **Good**: The `PendingCipherChangeDataStore` is NOT included in the `Services` typealias, which correctly keeps it scoped to the core layer. Per Architecture.md, stores should typically "only need to be accessed by services or repositories in the core layer and wouldn't need to be exposed to the UI layer." The data store is only injected directly into `VaultRepository`, `SyncService`, and `OfflineSyncResolver` through their initializers — this is the architecturally correct approach.
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

The `Services` typealias includes `HasOfflineSyncResolver` but does NOT include `HasPendingCipherChangeDataStore`. The data store is correctly scoped — it is only injected directly through initializers into `VaultRepository`, `SyncService`, and `OfflineSyncResolver`, which are all core-layer components. This is the architecturally correct approach: only `HasOfflineSyncResolver` is exposed to the UI layer, since the resolver may be needed by UI-layer components, while the raw data store remains internal to the core layer.

## Code Style Compliance

- **Compliant**: Alphabetical ordering in initializer parameters
- **Compliant**: DocC documentation on all new parameters
- **Compliant**: Naming follows project conventions

## Simplification Opportunities

1. ~~**Remove `HasPendingCipherChangeDataStore` from `Services` typealias**~~ — **Moot**: The data store was never in the `Services` typealias. It is already correctly scoped to core-layer initializer injection only.
2. **Consider removing `HasOfflineSyncResolver` from `Services` typealias** if it's not needed by any UI-layer component. Currently it's in the typealias but may not be referenced from any processor or coordinator.

## Summary

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Architecture compliance | **Good** | Follows Has protocol pattern |
| DI wiring correctness | **Good** | All dependencies properly connected |
| Security | **No concerns** | Standard DI patterns |
| Code style | **Good** | Alphabetical, documented |
| API surface | **Good** | DataStore correctly scoped to core layer (not in Services typealias) |
