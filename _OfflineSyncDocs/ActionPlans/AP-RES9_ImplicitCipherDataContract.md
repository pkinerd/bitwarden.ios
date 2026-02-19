# Action Plan: RES-9 — Implicit `cipherData` Contract for `resolveSoftDelete`

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | RES-9 |
| **Component** | `OfflineSyncResolver` |
| **Severity** | Low |
| **Type** | Code Quality / Contract |
| **File** | `BitwardenShared/Core/Vault/Services/OfflineSyncResolver.swift` |

## Description

`resolveSoftDelete` decodes `cipherData` from the pending change record to get a local `Cipher` for the `softDeleteCipherWithServer(id:, localCipher)` call. If `cipherData` is nil, it throws `OfflineSyncError.missingCipherData`. This means the `handleOfflineSoftDelete` caller must always provide cipher data. This is guaranteed by the current `VaultRepository.handleOfflineSoftDelete` implementation (which passes the encrypted cipher), but it's an implicit contract — nothing in the `PendingCipherChangeDataStore` or type system enforces it.

## Context

The `cipherData` field is optional in the Core Data schema because `.delete` operations (if they existed as a type) wouldn't need cipher data. Currently, all three change types (`.create`, `.update`, `.softDelete`) require `cipherData`, making the optionality a relic of the schema design rather than a functional requirement.

The implicit contract is: "all pending changes created by VaultRepository will have `cipherData` populated." If this contract is violated (e.g., by a future code change that queues a pending change without data), the resolver will throw `missingCipherData` and the item will remain pending, blocking sync.

---

## Options

### Option A: Document the Contract

Add a comment to `PendingCipherChangeDataStore.upsertPendingChange` and `VaultRepository`'s offline handlers documenting that `cipherData` must be non-nil for all current change types.

**Approach:**
```swift
/// - Important: `cipherData` must be non-nil for `.create`, `.update`, and `.softDelete` change types.
///   The resolver requires cipher data for all resolution paths.
```

**Pros:**
- Documents the implicit contract
- Low effort
- No behavioral change

**Cons:**
- Relies on developers reading the comment
- No compile-time enforcement

### Option B: Make `cipherData` Required (Non-Optional) in the Convenience Init

Change the convenience init to require `cipherData: Data` (non-optional), enforcing the contract at the creation point.

**Pros:**
- Compile-time enforcement
- Cannot create a pending change without data

**Cons:**
- If a future change type genuinely doesn't need cipher data, the required parameter is a hindrance
- Core Data's `@NSManaged` property remains `Data?` regardless
- Would need to change the upsert method signature

### Option C: Accept Current Design (Recommended)

Accept the implicit contract. The `missingCipherData` error handling in the resolver is defensive and correct — if the contract is violated, the error is thrown and logged, which is the appropriate behavior.

**Pros:**
- No code change
- The defensive error handling already exists
- The contract is effectively enforced by the VaultRepository implementations
- The optional `cipherData` type accurately reflects Core Data's type system

**Cons:**
- Contract is implicit, not explicit

---

## Recommendation

**Option C** — Accept the current design. The defensive `missingCipherData` error in the resolver is the correct safety net. If the contract is violated, the error will be logged and the item will be retried (and eventually expired if R3 retry backoff is implemented). Adding a comment (Option A) is a nice addition but not necessary.

## Estimated Impact

- **Files changed:** 0
- **Risk:** None

## Related Issues

- **PCDS-1**: id optional/required mismatch — same category of Core Data type precision.
- **PCDS-2**: dates optional but always set — same pattern of "optional in schema, always set in practice."
- **R3 (SS-5)**: Retry backoff — if `missingCipherData` is a permanent failure, retry backoff/expiry would eventually clean up the stuck item.

## Updated Review Findings

The review confirms the original assessment. After reviewing the implementation:

1. **Code verification**: All three resolution methods check for nil `cipherData`:
   - `resolveCreate` (line 152): `guard let cipherData = pendingChange.cipherData else { throw OfflineSyncError.missingCipherData }`
   - `resolveUpdate` (line 180): `guard let localCipherData = pendingChange.cipherData else { throw OfflineSyncError.missingCipherData }`
   - `resolveSoftDelete` (line 303): `guard let cipherData = pendingChange.cipherData else { throw OfflineSyncError.missingCipherData }`

2. **Contract enforcement in VaultRepository**: All four offline handlers set `cipherData` to non-nil values:
   - `handleOfflineAdd` (line 1015): `cipherData: cipherData` from `JSONEncoder().encode(cipherResponseModel)`
   - `handleOfflineUpdate` (line 1047): `cipherData: cipherData` from `JSONEncoder().encode(cipherResponseModel)`
   - `handleOfflineDelete` (line 1127): `cipherData: cipherData` from `JSONEncoder().encode(cipherResponseModel)`
   - `handleOfflineSoftDelete` (line 1165): `cipherData: cipherData` from `JSONEncoder().encode(cipherResponseModel)`

3. **Core Data schema**: `PendingCipherChangeData.swift:43` declares `@NSManaged var cipherData: Data?` — optional in Core Data. The convenience init at line 89 accepts `cipherData: Data?` — also optional. The contract is enforced by the callers (VaultRepository), not by the type system.

4. **Defensive error handling**: The `missingCipherData` error thrown by the resolver is the correct safety net. If the contract is violated, the error is caught by the per-item catch, logged, and the item remains pending. This is the right behavior.

**Updated conclusion**: Original recommendation (Option C - accept current design) confirmed. The defensive guards in the resolver correctly handle the violation case. The implicit contract is well-maintained by the 4 VaultRepository callers. Adding a comment (Option A) is nice but not necessary. Priority: Low, no change needed.

---

## Resolution

**Approach taken:** Neither Option A, B, nor C. Instead, the implicit contract was eliminated entirely by replacing the `cipherData` decode + `cipherService.softDeleteCipherWithServer(id:cipher:)` call with a direct call to `cipherAPIService.softDeleteCipher(withID:)`. The local storage upsert that `softDeleteCipherWithServer` performed is redundant in the resolver context because the resolver runs during sync, and the subsequent full sync updates local storage from the server.

**Changes:**
- `OfflineSyncResolver.swift`: `resolveSoftDelete` no longer decodes `cipherData` or calls `softDeleteCipherWithServer`; calls `cipherAPIService.softDeleteCipher(withID:)` directly
- `MockCipherAPIServiceForOfflineSync.swift`: `softDeleteCipher(withID:)` stub replaced with working mock
- `OfflineSyncResolverTests.swift`: 5 soft delete tests updated to assert against `cipherAPIService` instead of `cipherService`

**Result:** The `cipherData` dependency and implicit contract are eliminated for soft delete resolution. The `missingCipherData` error and guard remain in `resolveCreate` and `resolveUpdate` where they are still needed.
