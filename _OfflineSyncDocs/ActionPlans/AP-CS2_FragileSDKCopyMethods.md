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

`Cipher.withTemporaryId(_:)` manually copies 26 properties, and `CipherView.update(name:folderId:)` manually copies 24 properties, by calling the full SDK type initializer. If the `Cipher` or `CipherView` types from the BitwardenSdk package gain new properties:
- **With default values:** These methods compile but silently drop the new property's value (data loss risk)
- **Without default values (required):** Compilation fails, which is the safer outcome

This fragility is inherent to working with external SDK types that don't provide copy/clone methods.

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

## Updated Review Findings

The review confirms the original assessment with code-level detail. After reviewing the implementation:

1. **Code verification**:
   - `CipherView+OfflineSync.swift:16-47`: `Cipher.withTemporaryId(_:)` copies 26 properties explicitly. The 26th property `data` is hardcoded to `nil`.
   - `CipherView+OfflineSync.swift:63-94`: `CipherView.update(name:folderId:)` copies 24 properties explicitly. `id` and `key` are set to `nil`, `attachments` set to `nil`, `attachmentDecryptionFailures` set to `nil`.

2. **Property count verification**:
   - `Cipher` init takes 26 named parameters plus `data` (27 total, but `data` is nil)
   - `CipherView` init takes 24 named parameters
   - These include `archivedDate` (related to the `.archiveVaultItems` feature flag), confirming the methods are up-to-date with current SDK

3. **Fragility confirmation**: Both methods use positional init calls. If the SDK adds a new property with a default value, these methods compile silently but the new property gets the default value instead of being copied. This is the "silent data loss" risk described in the action plan.

4. **Mirror-based detection (Option B) assessment**: After consideration, `Mirror(reflecting:)` on SDK types generated from Rust FFI is unreliable. The Rust-generated Swift structs may not accurately reflect all stored properties via `Mirror`. This option should be deprioritized.

5. **SDK update frequency**: The `BitwardenSdk` is an external dependency. When it's updated, the Xcode build would fail if required parameters are added (good). It would NOT fail if optional parameters with defaults are added (the fragility risk).

**Updated conclusion**: Original recommendation (Option A - add SDK update review comments) confirmed. Option B (Mirror-based test) should be explicitly marked as NOT recommended due to unreliability with Rust FFI types. The comments should note the exact property count for quick verification during SDK updates. Priority: Low.
