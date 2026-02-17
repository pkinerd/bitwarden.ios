# Action Plan: CS-2 (EXT-3) — Fragile SDK Type Copy Methods

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | CS-2 / EXT-3 |
| **Component** | `CipherView+OfflineSync` |
| **Severity** | Low |
| **Type** | Maintenance Risk |
| **Files** | `BitwardenShared/Core/Vault/Extensions/CipherView+OfflineSync.swift` |

## Description

The offline sync implementation introduces manual copy/clone methods for two different BitwardenSdk types: `Cipher` and `CipherView`. These methods manually call the full SDK initializer, copying every property by name. There are three such methods:

1. **`Cipher.withTemporaryId(_:)`** — Creates a copy of a `Cipher` with a new temporary ID. Manually copies ~26 `Cipher` properties. Sets `data` to `nil` (this is the root cause of VI-1's decryption failures).
2. **`CipherView.update(name:folderId:)`** — Creates a copy of a `CipherView` with updated name and folder. Manually copies ~24 properties. Sets `id` and `key` to `nil`, `attachments` to `nil`.

If `Cipher` or `CipherView` from the BitwardenSdk package gains new properties:
- **With default values:** These methods compile but silently drop the new property's value (data loss risk)
- **Without default values (required):** Compilation fails, which is the safer outcome

This fragility is inherent to working with external SDK types that don't provide copy/clone methods.

**Current dev state:** `Cipher.withTemporaryId()` still exists with `data: nil`, which is the root cause of VI-1's decryption failures (VI-1 is mitigated via UI fallback but the root cause remains). Two SDK types with fragile copy methods remain: `Cipher.withTemporaryId()` and `CipherView.update(name:folderId:)`.

---

## Options

### Option A: Add SDK Update Review Comment (Recommended)

Add a prominent comment to all copy methods noting that they must be reviewed when the BitwardenSdk is updated. Include the property count in the comment as a reference.

**Example:**
```swift
/// - Important: This method manually copies all 26 `Cipher` properties.
///   When the BitwardenSdk `Cipher` type is updated, this method must be reviewed
///   to include any new properties. Property count as of last review: 26.
```

**Pros:**
- Zero code change to the logic
- Alerts developers during SDK updates
- Property count serves as a quick reference
- Documents the known limitation

**Cons:**
- Relies on developers reading comments during SDK updates
- Does not provide automated detection

### Option B: Add a Compile-Time Property Count Assertion

If Swift's reflection capabilities or a test can detect the property count of SDK types, add a test that fails when the property count changes.

**Approach:**
- Use `Mirror(reflecting: Cipher(...))` to count properties
- Compare against the expected count (26 for Cipher, 24 for CipherView)
- If the count changes, the test fails, alerting developers

**Pros:**
- Automated detection — test fails when SDK types change
- Developers are alerted proactively
- No reliance on reading comments

**Cons:**
- `Mirror` may not accurately reflect all properties (it shows stored properties, but SDK types may have computed properties or internal storage differences)
- SDK types from Rust FFI may not be accurately introspectable via `Mirror`
- Brittle if the SDK changes internal representation without changing the public API
- May produce false positives or false negatives

### Option C: Request SDK Copy/Clone Methods

Work with the SDK team to add `copy(id:)` or `clone()` methods to `Cipher` and `CipherView` in the BitwardenSdk.

**Pros:**
- Eliminates the fragility entirely
- SDK-native copy methods would be maintained alongside the types
- Reusable across all SDK consumers

**Cons:**
- Requires cross-team coordination
- SDK changes have their own release cycle
- May not be prioritized by the SDK team
- Longer timeline than a comment or test

### Option D: Use Protocol-Based Copy Helper

Create a protocol-based approach where the copy method is defined in terms of a builder pattern or key-path mapping, making additions more visible.

**Pros:**
- More structured than manual init calls
- Additions are localized

**Cons:**
- Swift doesn't support key-path-based struct copying natively
- Over-engineering for 2 methods
- External SDK types can't conform to local protocols for copy semantics

---

## Recommendation

**Option A** — Add SDK update review comments. This is the pragmatic approach. The fragility is inherent to working with external types, and a prominent comment is the best balance of effort vs. protection. If the project has a process for SDK updates (e.g., a checklist), add "review offline sync copy methods" to that checklist.

Long-term, **Option C** (SDK-native copy methods) is the ideal solution but depends on cross-team coordination.

## Estimated Impact

- **Files changed:** 1 (`CipherView+OfflineSync.swift`)
- **Lines added:** ~6 (comments)
- **Risk:** None

## Related Issues

- **RES-7**: Backup ciphers lack attachments — the `update(name:folderId:)` method explicitly sets `attachments` to nil. If attachment support is added, this method must be updated.
- **T5 (RES-6)**: Inline mock fragility — the same class of problem (manual conformance to external types that may change).

