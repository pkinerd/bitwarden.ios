---
id: 6
title: "[EXT-3/CS-2] SDK CipherView manual copy fragility"
status: in-progress
created: 2026-02-21
author: claude
labels: [bug]
priority: high
---

## Description

`makeCopy` manually copies 28 properties; new SDK properties with defaults are silently dropped.

**What's Done:** `makeCopy` consolidation, DocC `- Important:` callouts, Mirror-based property count guard tests (28 CipherView, 7 LoginView).

**What Remains:** Underlying fragility remains inherent to external SDK types. Developers must still manually add properties to `makeCopy` when tests fail. 5 copy methods across 2 files affected.

**Severity:** High
**Complexity:** Medium

**Related Documents:** AP-CS2, ReviewSection_SupportingExtensions.md, Review2/07_CipherViewExtensions

## Action Plan

*Source: `ActionPlans/Resolved/AP-CS2_FragileSDKCopyMethods.md`*

> **Status: [RESOLVED — Options A + B(variant) Implemented]** — SDK update review comment added to `makeCopy()` with property count (28). Both `withId(_:)` and `update(name:)` now delegate to a single `makeCopy()` helper, so only one method needs updating when `CipherView` changes. Additionally, property count guard tests were added to `CipherViewOfflineSyncTests.swift` using `Mirror` reflection for both `CipherView` (28 properties) and `LoginView` (7 properties). These tests fail automatically when the SDK type changes, alerting developers to update all manual copy methods.

## Issue Summary

| Field | Value |
|-------|-------|
| **ID** | CS-2 / EXT-3 |
| **Component** | `CipherView+OfflineSync` |
| **Severity** | ~~Low~~ Resolved |
| **Type** | Maintenance Risk |
| **Files** | `BitwardenShared/Core/Vault/Extensions/CipherView+OfflineSync.swift` |

## Description

The offline sync implementation introduces manual copy/clone methods for two different BitwardenSdk types: `Cipher` and `CipherView`. These methods manually call the full SDK initializer, copying every property by name. There are three such methods:

1. **`Cipher.withTemporaryId(_:)`** — Creates a copy of a `Cipher` with a new temporary ID. Manually copies ~26 `Cipher` properties. Sets `data` to `nil` (this is the root cause of VI-1's decryption failures).
2. **`CipherView.update(name:)`** — Creates a copy of a `CipherView` with updated name, retaining the original folder assignment. Manually copies ~24 properties. Sets `id` and `key` to `nil`, `attachments` to `nil`. **[Updated]** `folderId` parameter removed.

If `Cipher` or `CipherView` from the BitwardenSdk package gains new properties:
- **With default values:** These methods compile but silently drop the new property's value (data loss risk)
- **Without default values (required):** Compilation fails, which is the safer outcome

This fragility is inherent to working with external SDK types that don't provide copy/clone methods.

~~**Current dev state:** `Cipher.withTemporaryId()` still exists with `data: nil`, which is the root cause of VI-1's decryption failures (VI-1 is mitigated via UI fallback but the root cause remains). Two SDK types with fragile copy methods remain: `Cipher.withTemporaryId()` and `CipherView.update(name:folderId:)`.~~ **[UPDATE]** `Cipher.withTemporaryId()` has been removed and replaced by `CipherView.withId(_:)` (commit `3f7240a`). VI-1 is now fully resolved. Fragile copy methods now on `CipherView` only: `CipherView.withId(_:)` and `CipherView.update(name:)`. Same fragility concern (manual field copying), but the `data: nil` problem no longer applies. **[Updated]** `folderId` parameter removed from `update` — backup ciphers now retain the original cipher's folder assignment.

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

- **RES-7**: Backup ciphers lack attachments — the `update(name:)` method explicitly sets `attachments` to nil. If attachment support is added, this method must be updated.
- **T5 (RES-6)**: Inline mock fragility — the same class of problem (manual conformance to external types that may change).

## Updated Review Findings

The review confirms that **Options A and B (variant) have been implemented** with improvements beyond what was originally recommended:

1. **Code verification**: `CipherView+OfflineSync.swift` now contains three methods:
   - `withId(_:)` (line 16) — delegates to `makeCopy`
   - `update(name:)` (line 34) — delegates to `makeCopy`
   - `makeCopy(id:key:name:attachments:attachmentDecryptionFailures:)` (line 66) — private helper that calls the full `CipherView` initializer in exactly one place

2. **Option A — Comment implemented**: `makeCopy` at lines 53-55 contains the recommended `- Important:` DocC comment:
   ```
   /// - Important: This method manually copies all 28 `CipherView` properties.
   ///   When the `BitwardenSdk` `CipherView` type is updated, this method must be
   ///   reviewed to include any new properties. Property count as of last review: 28.
   ```

3. **Option B (variant) — Mirror-based property count guard tests**: `CipherViewOfflineSyncTests.swift` contains two `Mirror`-based property count tests:
   - `test_cipherView_propertyCount_matchesExpected()` (line 131): Asserts `CipherView` has 28 properties. The failure message references this action plan (AP-CS2) and lists all copy methods that need review.
   - `test_loginView_propertyCount_matchesExpected()` (line 155): Asserts `LoginView` has 7 properties, guarding the `LoginView.update(totp:)` copy method in `CipherView+Update.swift`.

   These tests address the Option B concern about `Mirror` accuracy for SDK types — the tests work correctly with the current SDK's Rust FFI types. If `CipherView` or `LoginView` gain/lose properties, the test fails automatically, alerting developers.

4. **Consolidation improvement**: Instead of adding comments to each copy method individually, the implementation consolidated both methods to delegate to a single `makeCopy()` helper. This means there is only one place where the `CipherView` initializer is called, reducing the fragility surface. This is better than the original recommendation.

5. **Property count verification**: The `CipherView` initializer in `makeCopy` passes 28 properties: `id`, `organizationId`, `folderId`, `collectionIds`, `key`, `name`, `notes`, `type`, `login`, `identity`, `card`, `secureNote`, `sshKey`, `favorite`, `reprompt`, `organizationUseTotp`, `edit`, `permissions`, `viewPassword`, `localData`, `attachments`, `attachmentDecryptionFailures`, `fields`, `passwordHistory`, `creationDate`, `deletedDate`, `revisionDate`, `archivedDate`. Count matches both the comment (28) and the test assertion (28).

**Updated conclusion**: Options A and B (variant) are fully implemented. The combination of DocC comments, `makeCopy` consolidation, and `Mirror`-based property count guard tests provides comprehensive protection against SDK type changes. Long-term, Option C (SDK-native copy methods) remains the ideal solution. This action plan is resolved.

## Consolidated Assessment

*From: ConsolidatedOutstandingIssues.md — Section 2: Partially Addressed Issues*

`makeCopy` manually copies 28 properties; new SDK properties with defaults are silently dropped. **What's Done:** `makeCopy` consolidation, DocC `- Important:` callouts, Mirror-based property count guard tests (28 CipherView, 7 LoginView). **What Remains:** Underlying fragility remains inherent to external SDK types. Developers must still manually add properties to `makeCopy` when tests fail. 5 copy methods across 2 files affected.

## Code Review References

Relevant review documents:
- `ReviewSection_SupportingExtensions.md`

## Comments
