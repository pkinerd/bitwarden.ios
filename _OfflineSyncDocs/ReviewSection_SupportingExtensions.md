# Detailed Review: Supporting Extensions

> **Reconciliation note (2026-02-21):** All line references, property counts, parameter lists,
> test counts, and deletion records in this document have been verified against the current
> source. `CipherView+OfflineSync.swift` (104 lines): `withId(_:)` at lines 16–24,
> `update(name:)` at lines 34–42, `makeCopy(id:key:name:attachments:attachmentDecryptionFailures:)`
> at lines 66–103. `makeCopy` copies exactly 28 `CipherView` properties (matching the
> `- Important:` DocC comment at lines 53–55). `update(name:)` passes `id: nil`, `key: nil`,
> `attachments: nil`, `attachmentDecryptionFailures: nil` and preserves `folderId` from the
> receiver. `CipherViewOfflineSyncTests.swift` contains 10 tests (3 `withId`, 5 `update`,
> 2 SDK property count guard). `URLError+NetworkConnection.swift` deletion in commit `e13aefe`
> confirmed. No corrections were required.

## Files Covered

| File | Type | Lines | Status |
|------|------|-------|--------|
| ~~`BitwardenShared/Core/Platform/Extensions/URLError+NetworkConnection.swift`~~ | ~~Extension~~ | ~~26~~ | **[Deleted]** |
| ~~`BitwardenShared/Core/Platform/Extensions/URLError+NetworkConnectionTests.swift`~~ | ~~Tests~~ | ~~39~~ | **[Deleted]** |
| `BitwardenShared/Core/Vault/Extensions/CipherView+OfflineSync.swift` | Extension | 104 | Active |
| `BitwardenShared/Core/Vault/Extensions/CipherViewOfflineSyncTests.swift` | Tests | 171 (10 tests) | Active |
| `BitwardenShared/UI/Vault/VaultItem/ViewItem/ViewLoginItem/Extensions/CipherView+Update.swift` | Extension (modified) | 416 | Active — Phase 2 DocC annotations added |

---

## 1. URLError+NetworkConnection — **[Superseded / Deleted]**

> Section moved to [AP-URLError_NetworkConnectionReview.md](ActionPlans/Superseded/AP-URLError_NetworkConnectionReview.md). Files deleted in commit `e13aefe` — error handling now uses a denylist pattern (rethrow `ServerError`, `CipherAPIServiceError`, `ResponseValidationError` < 500; all others trigger offline save). Issues EXT-1, EXT-2, EXT-4 all resolved by this deletion.

---

## 2. CipherView+OfflineSync

### Purpose

Provides extension methods on `CipherView` used by the offline sync system:

1. **`CipherView.withId(_:)`** — Creates a copy of a decrypted `CipherView` with a specified ID. Used by `addCipher()` to assign a temporary client-generated UUID to a new cipher **before encryption**. The ID is baked into the encrypted content so it survives the decrypt round-trip without special handling.

2. **`CipherView.update(name:)`** — Creates a copy of a decrypted `CipherView` with a modified name, retaining the original folder assignment. Used to create backup copies of conflicting ciphers. **[Updated]** The `folderId` parameter was removed; backup ciphers now retain the original cipher's folder rather than being placed in a dedicated "Offline Sync Conflicts" folder.

### Implementation Details

#### ~~`Cipher.withTemporaryId(_ id: String) -> Cipher`~~ → `CipherView.withId(_ id: String) -> CipherView` **[Replaced]**

~~`Cipher.withTemporaryId()` operated after encryption and set `data: nil`, causing the VI-1 bug.~~ **[RESOLVED]** Replaced by `CipherView.withId()` (commit `3f7240a`) which operates **before** encryption. This method delegates to the shared `makeCopy(id:key:name:attachments:attachmentDecryptionFailures:)` helper, passing through `key`, `name`, `attachments`, and `attachmentDecryptionFailures` from the receiver and replacing only `id` with the provided value. Since encryption happens after the ID is set, all encrypted fields (including the ID) are properly populated.

#### `CipherView.update(name:) -> CipherView` **[Updated]**

Delegates to the same `makeCopy` helper, passing the new `name` and setting `id`, `key`, `attachments`, and `attachmentDecryptionFailures` to `nil`. The original `folderId` is retained because `makeCopy` copies it from the receiver. **[Updated]** The `folderId` parameter was removed — backup ciphers now retain the original cipher's folder assignment.

#### `private func makeCopy(id:key:name:attachments:attachmentDecryptionFailures:) -> CipherView` **[New]**

Both `withId` and `update` delegate to this single private helper so the full `CipherView(...)` initializer is called in exactly one place. This reduces the maintenance burden when the SDK adds new properties — only this method needs updating.

**Property count:** 28 properties explicitly copied in the `CipherView(...)` initializer call (including `sshKey` and `archivedDate`). The fragility concern (Issue EXT-3 / CS-2) is now mitigated by the `makeCopy` consolidation, explicit DocC warnings in the helper's documentation, and SDK property count guard tests (see Test Coverage below).

**Intentional nil-outs (when called by `update(name:)`):**

| Property | Set To | Reason |
|----------|--------|--------|
| `id` | `nil` | New cipher, server assigns ID |
| `key` | `nil` | SDK generates new encryption key for the backup |
| `attachments` | `nil` | Attachments not duplicated to backups |
| `attachmentDecryptionFailures` | `nil` | Not relevant for new cipher |

Note: When called by `withId(_:)`, all four of these properties are passed through from the receiver (no nil-outs).

### Test Coverage

#### CipherView.withId Tests **[Updated]**

| Test | Verification |
|------|-------------|
| ~~`test_withTemporaryId_setsNewId`~~ → `test_withId_setsId` | Specified ID is set on a cipher view with nil ID |
| ~~`test_withTemporaryId_preservesOtherProperties`~~ → `test_withId_preservesOtherProperties` | Key properties preserved (name, notes, folderId, organizationId, login username/password/totp) |
| (New) `test_withId_replacesExistingId` | Can replace an existing non-nil ID |

#### CipherView.update Tests

| Test | Verification |
|------|-------------|
| ~~`test_update_setsNameAndFolderId`~~ → `test_update_setsNameAndPreservesFolderId` | Name set correctly; folderId retained from original **[Updated]** |
| `test_update_setsIdToNil` | ID is nil |
| `test_update_setsKeyToNil` | Key is nil |
| `test_update_setsAttachmentsToNil` | Attachments are nil |
| `test_update_preservesPasswordHistory` | Password history preserved with values |

#### SDK Property Count Guard Tests **[New]**

These tests use `Mirror` reflection to detect when the SDK changes the property count of key types, ensuring all manual copy methods are reviewed. They directly mitigate Issue EXT-3 / CS-2.

| Test | Verification |
|------|-------------|
| `test_cipherView_propertyCount_matchesExpected` | Asserts `CipherView` has 28 properties; failure message lists all manual copy methods to review (`makeCopy` in `CipherView+OfflineSync.swift`, `update`/`updatedView` in `CipherView+Update.swift`) and references AP-CS2 |
| `test_loginView_propertyCount_matchesExpected` | Asserts `LoginView` has 7 properties; failure message lists `LoginView.update(totp:)` in `CipherView+Update.swift` and references AP-CS2 |

---

## Compliance Assessment

### Architecture Compliance

| Guideline | Status | Details |
|-----------|--------|---------|
| Extensions organized by domain | **Pass** | ~~`URLError+` in Platform/Extensions~~ (deleted), `CipherView+` in Vault/Extensions |
| File naming convention | **Pass** | `CipherView+OfflineSync.swift` (follows `Type+Feature.swift` convention) |
| Test co-location | **Pass** | Tests in same directory as implementation |
| MARK comments | **Pass** | `// MARK: - CipherView + OfflineSync` and `// MARK: Private` (two MARK sections — the second was added with the `makeCopy` refactor) |

### Code Style Compliance

| Guideline | Status | Details |
|-----------|--------|---------|
| DocC documentation | **Pass** | All three methods (`withId`, `update`, `makeCopy`) have complete DocC with parameter docs; `makeCopy` includes an `- Important:` callout |
| Inline comments | **Pass** | Explanatory comments on key decisions; `makeCopy` DocC includes `- Important:` callout documenting the 28-property fragility concern and review obligation |
| Test naming | **Pass** | `test_<method>_<scenario>` pattern |

### Security Compliance

| Principle | Status | Details |
|-----------|--------|---------|
| No plaintext leakage | **Pass** | `withId`, `update`, and `makeCopy` operate on `CipherView` (in-memory only); encryption happens after ID assignment |
| Encryption key handling | **Pass** | Setting `key = nil` on backup ensures SDK generates new key |

---

## Issues and Observations

### ~~Issue EXT-1~~ [Superseded]

Moved to [Resolved/AP-EXT1](ActionPlans/Resolved/AP-EXT1_TimedOutClassification.md). URLError extension deleted in commit `e13aefe`.

### ~~Issue EXT-2~~ [Superseded]

Same underlying issue as SEC-1. See [Resolved/AP-SEC1](ActionPlans/Resolved/AP-SEC1_SecureConnectionFailedClassification.md). URLError extension deleted in commit `e13aefe`.

### Issue EXT-3: `withId` and `update` Are Fragile Against SDK Type Changes (Low) — **[Mitigated]**

Both methods delegate to a shared `private func makeCopy(...)` which manually copies all 28 properties of `CipherView` by calling the full initializer. If the SDK adds new properties with non-nil defaults, the method will compile but silently drop the new property's value. If the SDK adds new required parameters, compilation will break (which is the safer outcome).

**Scope:** Three methods on `CipherView` — `withId(_:)`, `update(name:)`, and the shared `makeCopy(id:key:name:attachments:attachmentDecryptionFailures:)` helper. **[Updated]** `Cipher.withTemporaryId()` has been removed and replaced by `CipherView.withId(_:)`. `CipherView.update(name:folderId:)` has been simplified to `CipherView.update(name:)` (folderId parameter removed). Both now delegate to a single `makeCopy` helper so the initializer is called in exactly one place.

**Status:** Multiple mitigations have been implemented:

1. **`makeCopy` consolidation** — The full `CipherView(...)` initializer is called in exactly one place (`makeCopy`), reducing the number of sites that must be updated when the SDK changes from two to one.
2. **DocC fragility warning** — The `makeCopy` method includes an `- Important:` DocC callout explicitly noting the 28-property count and the obligation to review when the SDK type changes.
3. **SDK property count guard tests** — `test_cipherView_propertyCount_matchesExpected` (asserts 28 properties) and `test_loginView_propertyCount_matchesExpected` (asserts 7 properties) use `Mirror` reflection to fail when the SDK adds or removes properties. Failure messages list all manual copy methods that must be reviewed and reference AP-CS2.

~~**Additional concern:** `Cipher.withTemporaryId()` sets `data: nil`, which is the root cause of VI-1.~~ **[Resolved]** `Cipher.withTemporaryId()` replaced by `CipherView.withId(_:)` operating before encryption. The `data: nil` problem no longer exists.

**Remaining risk:** If the SDK adds a new property with a non-nil default value, the property count guard test will catch the change, but developers must still manually add the property to `makeCopy`. The test failure message provides clear guidance on which methods to update.

### ~~Issue EXT-4~~ [Resolved]

Same as T6. See [Resolved/AP-T6](ActionPlans/Resolved/AP-T6_IncompleteURLErrorTestCoverage.md). URLError extension and tests deleted in commit `e13aefe`.

---

## 3. CipherView+Update.swift (Phase 2 Annotations)

### Changes

Three `- Important:` DocC annotations were added to existing methods in `CipherView+Update.swift` (which is NOT part of the offline sync feature but is adjacent — it also manually copies `CipherView` and `LoginView` properties):

| Method | Property Count Documented | Line |
|--------|--------------------------|------|
| `updatedView(with:timeProvider:)` | 28 CipherView properties | 139-141 |
| `update(archivedDate:collectionIds:deletedDate:folderId:login:organizationId:)` | 28 CipherView properties | 340-343 |
| `LoginView.update(totp:)` | 7 LoginView properties | 398-400 |

Each annotation includes the property count and a note that the method must be reviewed when the SDK type changes.

### Purpose

These annotations complement the SDK property count guard tests in `CipherViewOfflineSyncTests.swift`. When a guard test fails (property count changed), the failure message lists all manual copy methods, including these three in `CipherView+Update.swift`, so developers know which methods to review.

### Compliance

| Guideline | Status | Details |
|-----------|--------|---------|
| DocC documentation | **Pass** | Uses `- Important:` callout per Apple's documentation markup |
| No code changes | **Pass** | Documentation only — no functional changes |
| Cross-reference | **Pass** | References AP-CS2 action plan for traceability |
