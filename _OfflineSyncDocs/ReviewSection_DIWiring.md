# Detailed Review: Dependency Injection & Wiring

> **Reconciliation Note (2026-02-21):** This document was corrected after verifying against the actual source code. The original review incorrectly stated that a `HasPendingCipherChangeDataStore` protocol exists in `Services.swift` and is part of the `Services` typealias. In reality, **no such protocol exists anywhere in `Services.swift`**. Only `HasOfflineSyncResolver` was added to the `Services` typealias (at line 40). The `pendingCipherChangeDataStore` dependency is passed directly via initializer injection to `DefaultVaultRepository`, `DefaultSyncService`, and `DefaultOfflineSyncResolver` — it is not exposed through a `Has*` protocol and is not a stored property on `ServiceContainer`. The `ServiceContainer+Mocks.swift` `withMocks()` factory similarly does NOT include a `pendingCipherChangeDataStore` parameter — only `offlineSyncResolver` is present. All sections below have been updated to reflect these corrections. Issue DI-1 has been narrowed accordingly.

## Files Covered

| File | Type | Lines Changed |
|------|------|---------------|
| `BitwardenShared/Core/Platform/Services/Services.swift` | Has* protocol (modified) | +8 lines |
| `BitwardenShared/Core/Platform/Services/ServiceContainer.swift` | DI container (modified) | +30 lines |
| `BitwardenShared/Core/Platform/Services/TestHelpers/ServiceContainer+Mocks.swift` | Test helper (modified) | +6 lines |
| `BitwardenShared/Core/Platform/Services/Stores/DataStore.swift` | Data store (modified) | +1 line |
| `BitwardenShared/UI/Platform/Application/AppProcessor.swift` | UI layer (modified) | ~~+1 line (whitespace)~~ Net zero (reverted) |

---

## End-to-End Walkthrough

### 1. Services.swift — Has* Protocol Composition

One new `Has*` protocol is added to the `Services` typealias composition:

```swift
/// Protocol for an object that provides an `OfflineSyncResolver`.
protocol HasOfflineSyncResolver {
    /// The service used to resolve pending offline cipher changes against server state.
    var offlineSyncResolver: OfflineSyncResolver { get }
}
```

This is defined at `Services.swift:265-268` and added to the `Services` typealias in alphabetical order:
- `& HasOfflineSyncResolver` (at line 40, between `HasNotificationService` and `HasOrganizationAPIService`)

**Correction (2026-02-21):** The original review stated that a `HasPendingCipherChangeDataStore` protocol was also added to the `Services` typealias. This is incorrect — no such protocol exists anywhere in `Services.swift`. The `pendingCipherChangeDataStore` dependency is passed directly via initializer injection to the objects that need it (`DefaultVaultRepository`, `DefaultSyncService`, `DefaultOfflineSyncResolver`) rather than being exposed through a `Has*` protocol.

~~**Note:** A blank line was introduced in the `Services` typealias between `& HasConfigService` and `& HasDeviceAPIService`.~~ **[Resolved]** The stray blank line was removed in commit `a52d379`.

### 2. ServiceContainer.swift — Container Registration

The `ServiceContainer` class gains one new stored property:

```swift
let offlineSyncResolver: OfflineSyncResolver
```

This is added:
- In the properties section, in alphabetical order (after `notificationService`)
- In the main initializer parameter list, in alphabetical order
- In the main initializer body, with the corresponding assignment
- In the DocC parameter docs for the main initializer

**Correction (2026-02-21):** `pendingCipherChangeDataStore` is NOT a stored property on `ServiceContainer`. It does not appear in the main `init` parameter list, body, or DocC block. Instead, it is only used within the convenience initializer (`init(appContext:application:errorReporter:nfcReaderService:)`) where it is passed directly to `DefaultOfflineSyncResolver`, `DefaultSyncService`, and `DefaultVaultRepository` via their initializers.

### 3. ServiceContainer.swift — Object Graph Wiring

In the `ServiceContainer` convenience initializer (`init(appContext:application:errorReporter:nfcReaderService:)`), the wiring is:

```swift
// 1. Create the resolver (before SyncService, after its dependencies exist)
let preSyncOfflineSyncResolver = DefaultOfflineSyncResolver(
    cipherAPIService: apiService,
    cipherService: cipherService,
    clientService: clientService,
    pendingCipherChangeDataStore: dataStore,
    stateService: stateService,
)
// NOTE: timeProvider and folderService were removed in earlier commits (conflict folder eliminated)

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

**Important naming note:** The local variable is named `preSyncOfflineSyncResolver` to distinguish it from the `let offlineSyncResolver` variable that's assigned later for the container. Both refer to the same instance. This two-step approach is necessary because the container assignment happens much later in the convenience initializer.

### 4. ServiceContainer+Mocks.swift — Test Helper

The `ServiceContainer.withMocks()` factory gains one new parameter with a mock default:

```swift
offlineSyncResolver: OfflineSyncResolver = MockOfflineSyncResolver(),
```

This is added in the parameter list and forwarded to the `ServiceContainer` initializer.

**Correction (2026-02-21):** The original review stated that `pendingCipherChangeDataStore` was also a parameter in `withMocks()`. This is incorrect — since `pendingCipherChangeDataStore` is not a stored property on `ServiceContainer` and is not in the main `init`, it does not appear in `withMocks()` either. Only `offlineSyncResolver` is present (at line 48 of `ServiceContainer+Mocks.swift`).

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
| Has* protocol composition pattern | **Pass** | `HasOfflineSyncResolver` follows naming convention. ~~`HasPendingCipherChangeDataStore`~~ does not exist — `pendingCipherChangeDataStore` is passed via direct init injection instead. |
| Protocol-typed properties in container | **Pass** | `let offlineSyncResolver: OfflineSyncResolver` (protocol, not concrete type). `pendingCipherChangeDataStore` is not a container property. |
| Alphabetical ordering in Services typealias | **Pass** | `HasOfflineSyncResolver` inserted in correct alphabetical position (line 40) |
| ServiceContainer.withMocks updated | **Pass** | Mock default provided for `offlineSyncResolver`. `pendingCipherChangeDataStore` not applicable (not a container property). |
| User data cleanup | **Pass** | `PendingCipherChangeData` included in batch delete |

### Code Style Compliance

| Guideline | Status | Details |
|-----------|--------|---------|
| DocC on Has* protocols | **Pass** | `HasOfflineSyncResolver` has summary and property-level documentation. ~~`HasPendingCipherChangeDataStore`~~ does not exist. |
| DocC on container properties | **Pass** | `offlineSyncResolver` stored property documented. `pendingCipherChangeDataStore` is not a container property. |
| DocC on init parameters | **Pass** | `offlineSyncResolver` parameter documented in init DocC |
| Alphabetical ordering | **Pass** | Stored properties, init parameters, assignments, and DocC parameter documentation are in correct alphabetical order |

### Security Compliance

| Principle | Status | Details |
|-----------|--------|---------|
| Data cleanup on logout | **Pass** | Pending changes deleted with other user data |
| No exposed crypto material | **Pass** | Only protocol references; no raw keys in container |

---

## Issues and Observations

### ~~Issue DI-1: `HasPendingCipherChangeDataStore` in `Services` Typealias Exposes Data Store to UI Layer~~ [Corrected — Not Applicable]

**Correction (2026-02-21):** The original review stated that a `HasPendingCipherChangeDataStore` protocol was added to the `Services` typealias, raising a concern about exposing a data store to the UI layer. After verifying against the actual source code, **no `HasPendingCipherChangeDataStore` protocol exists anywhere in `Services.swift`**. The `pendingCipherChangeDataStore` dependency is passed directly via initializer injection to the three objects that need it:

- `DefaultOfflineSyncResolver` (core layer) — receives `dataStore` via init
- `DefaultSyncService` (core layer) — receives `dataStore` via init
- `DefaultVaultRepository` (core layer) — receives `dataStore` via init

It is not a stored property on `ServiceContainer`, not in the `Services` typealias, and not exposed to the UI layer at all. Only `HasOfflineSyncResolver` is in the `Services` typealias, which narrows the original concern significantly. See updated DI-2 below for that remaining (smaller) concern.

### Issue DI-2: `HasOfflineSyncResolver` in `Services` Typealias (Low)

Similarly, `HasOfflineSyncResolver` is added to the `Services` typealias. The resolver is currently used only by `DefaultSyncService`, which receives it via init injection. The `Services` typealias exposure is broader than needed.

**Assessment:** Same as DI-1 — follows existing precedent and enables future UI-layer usage if needed.

### ~~Issue DI-3~~ [Resolved]

Same as CS-1 (stray blank line). See [AP-CS1](ActionPlans/Resolved/AP-CS1_StrayBlankLine.md). Removed in commit `a52d379`.

### ~~Issue DI-5: DocC Parameter Order Mismatch in `ServiceContainer` Init~~ [Resolved]

~~The DocC parameter documentation block in `ServiceContainer.swift` init lists `pendingAppIntentActionMediator` and `pendingCipherChangeDataStore` after `rehydrationHelper` and `reviewPromptService` (lines 259–262), but the actual init parameter list has them in correct alphabetical order before `policyService` (lines 323–324). This means the DocC parameter order does not match the actual parameter order. The mismatch appears to be from the offline sync parameters being appended to the DocC block near where they semantically fit rather than in strict alphabetical position.~~

**[Resolved]** The DocC parameter documentation block in the `ServiceContainer` init has been reordered so that `pendingAppIntentActionMediator` now appears in its correct alphabetical position (after `pasteboardService`, before `policyService`), matching the actual init parameter order. Note: `pendingCipherChangeDataStore` is not a stored property on `ServiceContainer` and does not appear in the main init's parameter list or DocC block — it is only passed through the convenience initializer when constructing other objects.

### Observation DI-4: Same Resolver Instance Shared Between SyncService and Container

The `preSyncOfflineSyncResolver` instance is injected into both `DefaultSyncService` and the `ServiceContainer`. ~~Since `DefaultOfflineSyncResolver` has mutable state (`conflictFolderId`), sharing the same instance means the `SyncService`'s resolver and any other consumer of `offlineSyncResolver` from the container share that cache.~~

**[Updated]** The `conflictFolderId` mutable state has been removed (conflict folder eliminated). The resolver has been converted to an `actor` for general thread safety. Sharing the same instance is safe — the resolver no longer has per-batch cached state.

**Assessment:** Currently fine because `SyncService` is the only active consumer.
