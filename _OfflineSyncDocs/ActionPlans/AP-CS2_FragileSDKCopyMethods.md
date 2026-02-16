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

**[Updated]** `Cipher.withTemporaryId(_:)` has been deleted and replaced with `CipherView.withId(_:)` as part of the VI-1 fix (commits `8ff7a09` through `3f7240a`). The new method operates on `CipherView` (before encryption) rather than `Cipher` (after encryption), eliminating the `data: nil` problem that contributed to the offline spinner bug.

The remaining fragile method is `CipherView.update(name:folderId:)` which manually copies ~24 properties and `CipherView.withId(_:)` which manually copies ~26 properties. Both call the full `CipherView` SDK initializer. If `CipherView` from the BitwardenSdk package gains new properties:
- **With default values:** These methods compile but silently drop the new property's value (data loss risk)
- **Without default values (required):** Compilation fails, which is the safer outcome

This fragility is inherent to working with external SDK types that don't provide copy/clone methods.

**Change from original:** The issue scope has been reduced from two different SDK types (`Cipher` + `CipherView`) to a single type (`CipherView`) with two methods. The `CipherView.withId(_:)` method also now copies `attachmentDecryptionFailures` which was not present in the old `Cipher.withTemporaryId()`.

---

## Options

### Option A: Add SDK Update Review Comment (Recommended)

Add a prominent comment to both methods noting that they must be reviewed when the BitwardenSdk is updated. Include the property count in the comment as a reference.

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

## Updated Review Findings (Post-VI-1 Fix)

**[Updated 2026-02-16]** The VI-1 fix significantly changed the landscape for this issue:

1. **`Cipher.withTemporaryId(_:)` has been deleted.** It was replaced by `CipherView.withId(_:)` which operates on the decrypted type before encryption. This eliminates the `data: nil` problem and the associated decryption failures.

2. **Two `CipherView` copy methods now exist:**
   - `CipherView.withId(_:)` at `CipherView+OfflineSync.swift:16-47`: Copies ~26 properties, replacing the specified ID. Includes `attachmentDecryptionFailures` which the old `Cipher.withTemporaryId()` did not have.
   - `CipherView.update(name:folderId:)` at `CipherView+OfflineSync.swift:49-90`: Copies ~24 properties. Sets `id` and `key` to `nil`, `attachments` to `nil`, `attachmentDecryptionFailures` to `nil`.

3. **Scope reduced**: The fragility concern now applies to a single SDK type (`CipherView`) rather than two types (`Cipher` + `CipherView`). Both methods are in the same file and call the same initializer pattern.

4. **Mirror-based detection (Option B)**: Still NOT recommended — Rust FFI-generated Swift structs may not accurately reflect properties via `Mirror`.

5. **Recommendation unchanged**: Option A (SDK update review comments) remains the pragmatic approach. The property count note should now reference `CipherView` only.

**Updated conclusion**: The issue severity remains Low, but the scope is reduced. One fragile SDK type instead of two. The recommendation stands: add review comments noting property counts for verification during SDK updates.
