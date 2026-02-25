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

Manual property copying of BitwardenSdk types is **pervasive across the codebase** — not limited to offline sync. 15+ distinct methods manually call full SDK initializers, copying every property by name. New SDK properties with defaults are silently dropped (data loss risk).

**What's Done:** `makeCopy` consolidation in offline sync, DocC `- Important:` callouts on 4 methods, Mirror-based property count guard tests (28 CipherView, 7 LoginView).

**What Remains:** 15+ manual copy locations across 8+ files, covering 6 SDK types. Guard tests only cover CipherView and LoginView. Cipher (27 props, 2 methods), IdentityView (16 props, 2 locations), CardView, and SshKeyView have **zero automated protection**.

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

### claude — 2026-02-22

**Codebase validated — in-progress status confirmed ACCURATE.**

Mitigations verified in place:
1. `makeCopy` helper with DocC `- Important:` comment (CipherView+OfflineSync.swift:53-55) documenting 28 properties
2. Mirror-based property count guard tests in CipherViewOfflineSyncTests.swift: CipherView (28 properties, line 131) and LoginView (7 properties, line 155)
3. `withId(_:)` and `update(name:)` both delegate to `makeCopy` — single point of change

Inherent fragility remains: external SDK types require manual property copying. Only SDK-native copy methods (Option C) would fully resolve this.

### claude — 2026-02-25

**Full codebase audit completed — scope is much larger than originally documented.**

Manual property copying of BitwardenSdk types exists in **15+ distinct methods** across the codebase. The offline sync feature inherited this pre-existing pattern and added the most robust mitigations anywhere in the project.

---

#### Complete Inventory of Manual Copy Locations

##### Production Code — CipherView (28 properties)

| File | Method | Lines | Has DocC Warning? | Has Guard Test? |
|------|--------|-------|-------------------|-----------------|
| `CipherView+OfflineSync.swift` | `makeCopy()` (private) | 66-103 | Yes | Yes |
| `CipherView+Update.swift` | `updatedView(with:timeProvider:)` | 184-212 | Yes | No |
| `CipherView+Update.swift` | private `update()` | 362-391 | Yes | No |

`withId(_:)` and `update(name:)` in OfflineSync delegate to `makeCopy`. Five `update(...)` variants in +Update delegate to private `update()`. So there are **3 distinct full-init call sites** for CipherView.

##### Production Code — Cipher (27 properties) — NO MITIGATIONS

| File | Method | Lines | Has DocC Warning? | Has Guard Test? |
|------|--------|-------|-------------------|-----------------|
| `Cipher+Update.swift` | `update(attachments:revisionDate:)` | 13-42 | **No** | **No** |
| `Cipher+Update.swift` | `update(folderId:)` | 51-80 | **No** | **No** |

##### Production Code — LoginView (7 properties)

| File | Method | Lines | Has DocC Warning? | Has Guard Test? |
|------|--------|-------|-------------------|-----------------|
| `CipherView+Update.swift` | `LoginView.update(totp:)` | 406-413 | Yes | No (covered by OfflineSync guard test) |
| `LoginView+Update.swift` | `init(loginView:loginState:)` | 13-21 | **No** | **No** |

##### Production Code — IdentityView (16 properties) — NO MITIGATIONS

| File | Method | Lines |
|------|--------|-------|
| `IdentityView+Update.swift` | `init(identityView:identityState:)` | 13-35 |
| `IdentityItemState.swift` | `identityView` computed property | 108-127 |

##### Production Code — CardView (6 properties) — NO MITIGATIONS

| File | Method | Lines |
|------|--------|-------|
| `CardItemState.swift` | `cardView` computed property | 35-48 |

##### Production Code — SshKeyView (3 properties) — NO MITIGATIONS

| File | Method | Lines |
|------|--------|-------|
| `SSHKeyItemState.swift` | `sshKeyView` computed property | 25-29 |

##### Fixture Files (BitwardenShared + AuthenticatorShared)

`BitwardenSdk+VaultFixtures.swift` contains `.fixture()` factory methods for: `Cipher` (27), `CipherView` (28, with `.cardFixture()`, `.loginFixture()`, `.totpFixture()` variants), `LoginView` (7), `IdentityView`, `CardView` (6), `SshKeyView`, `AttachmentView`, `FieldView`, `PasswordHistoryView`. New required SDK params cause compile errors (safe), but new optional params with defaults are silently missed.

---

#### Mitigation Coverage Summary

| Mitigation | Where Applied | Where Missing |
|------------|---------------|---------------|
| **Mirror-based guard tests** | CipherView (28), LoginView (7) — offline sync tests only | Cipher (27), IdentityView (16), CardView (6), SshKeyView (3), all fixtures |
| **DocC `- Important:` callout** | 4 methods (OfflineSync + CipherView+Update) | Cipher+Update (2), LoginView+Update, IdentityView+Update, state-to-view conversions, all fixtures |
| **Single-helper consolidation** | OfflineSync (`makeCopy`), CipherView+Update (private `update()`) | Cipher+Update has 2 independent full-init copies |

---

#### Risk Assessment

**High Risk — No automated detection:**
- `Cipher` (27 props, 2 methods) — completely unprotected
- `IdentityView` (16 props, 2 locations) — completely unprotected

**Medium Risk:**
- `CipherView` (28 props, 3 methods) — guard tests catch count changes
- `LoginView` (7 props, 2 methods) — guard test covers count but not all call sites

**Lower Risk (fewer properties):**
- `CardView` (6 props, 1 location), `SshKeyView` (3 props, 1 location) — no detection

---

#### Recommended Next Steps

1. **Extend Mirror-based guard tests** to cover Cipher (27), IdentityView (16), CardView (6), SshKeyView (3) — highest-value, lowest-effort improvement
2. **Add DocC warnings** to Cipher+Update.swift (2 methods) and LoginView+Update.swift
3. **Consolidate Cipher+Update.swift** — both methods copy all 27 properties independently; a shared helper would reduce surface
4. **Long-term:** Option C (SDK-native copy/clone methods) remains ideal
