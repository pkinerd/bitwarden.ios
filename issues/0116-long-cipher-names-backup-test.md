---
id: 116
title: "[R2-TEST-4] Very long cipher names in backup naming not tested"
status: closed
created: 2026-02-21
author: claude
labels: [bug]
priority: low
closed: 2026-02-21
---

## Description

**Resolution:** Added 2 backup name format tests. AP-42 (Resolved)

**Disposition:** Resolved / Superseded

## Action Plan

*Source: `ActionPlans/Resolved/AP-42_LongCipherNamesInBackupNaming.md`*

> **Issue:** #42 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Resolved
> **Source:** Review2/08_TestCoverage_Review.md (R2-TEST-4)

## Problem Statement

The `createBackupCipher` method at `OfflineSyncResolver.swift:316-339` creates backup cipher names using the pattern:

```swift
let backupName = "\(decryptedCipher.name) - \(timestampString)"
```

Where `timestampString` is a fixed-format date string like `"2026-02-18 13:55:26"` (19 characters). The separator ` - ` adds 3 characters. So the backup name is `originalName.count + 22` characters.

If the original cipher name is very long (hundreds or thousands of characters), the backup name could be extremely long. There is no test verifying the behavior with edge-case name lengths.

## Current Test Coverage

- **Backup cipher creation is tested** in `OfflineSyncResolverTests.swift` through conflict resolution tests (e.g., `test_processPendingChanges_update_conflict_localNewer` at line 168). These tests verify that `addCipherWithServer` is called to create the backup, but they use short fixture names.
- **No test uses a long cipher name.** All fixture names in the test suite are short strings like "Local Cipher", "Server Cipher", etc.
- **No test uses an empty cipher name.**

## Missing Coverage

1. Backup naming with a very long original name (e.g., 1000+ characters).
2. Backup naming with an empty original name.
3. Backup naming with special characters (Unicode, emoji, newlines).
4. Whether the Bitwarden server imposes a name length limit and how the client handles rejection.

## Assessment

**Still valid:** Yes. No edge-case name length tests exist.

**Risk of not having the test:** Very Low.
- The backup name is a simple string concatenation. There is no truncation, validation, or formatting logic that could break with long names.
- `CipherView.name` is a `String` with no known client-side length limit.
- The Bitwarden server may impose a name length limit, but this would be enforced server-side and would cause `addCipherWithServer` to fail with a `ServerError`. The existing error handling (catch in `processPendingChanges`) would log the error and retain the pending change for retry.
- Long cipher names are an existing capability of the vault -- they are not unique to the offline sync feature.
- The timestamp suffix adds only 22 characters, which is negligible even for very long names.
- String concatenation in Swift handles arbitrary lengths without issues.

**Priority:** Very Low. The code is trivially simple string concatenation. The server-side length limit (if any) would be caught by existing error handling.

## Options

### Option A: Add Edge-Case Name Tests
- **Effort:** ~30 minutes, ~40 lines
- **Description:** Add tests to `OfflineSyncResolverTests.swift` or `CipherViewOfflineSyncTests.swift` for edge-case names.
- **Test scenarios:**
  - `test_createBackupCipher_longName_succeeds` -- cipher with a 1000-character name; verify backup name is formed correctly
  - `test_createBackupCipher_emptyName_succeeds` -- cipher with empty string name; verify backup name is ` - 2026-02-18 13:55:26`
  - `test_createBackupCipher_unicodeName_succeeds` -- cipher with Unicode/emoji name; verify no encoding issues
- **Pros:** Documents behavior for edge cases.
- **Cons:** Tests trivial string concatenation. Very low value.

### Option B: Add Name Formation Unit Test to CipherView+OfflineSync
- **Effort:** ~15 minutes, ~15 lines
- **Description:** Test the `update(name:)` method in `CipherView+OfflineSync` with a long name to verify the name is correctly assigned.
- **Test scenarios:**
  - `test_update_name_longName_preservesFullName` -- verify `update(name:)` does not truncate
- **Pros:** Tests the extension method directly.
- **Cons:** Tests trivial assignment. `update(name:)` just passes the name through to `makeCopy`.

### Option C: Accept As-Is (Recommended)
- **Rationale:** The backup naming is trivial string concatenation with no truncation, validation, or formatting logic. Long names are an existing capability of the vault, not unique to offline sync. Swift string concatenation handles arbitrary lengths. Any server-side length limit would be caught by existing error handling (`processPendingChanges` catch block). The effort of writing these tests provides negligible value.

## Recommendation

**Option C (Accept As-Is).** The code under test is trivial string concatenation. There is no logic to test beyond `"\(a) - \(b)"`. The server-side behavior (if any name length limit exists) is already covered by the generic error handling in the resolver. Adding tests for this would be testing Swift string concatenation, not application logic.

## Dependencies

- None.

## Resolution Details

Added `test_processPendingChanges_update_conflict_backupNameFormat` and `test_processPendingChanges_update_conflict_emptyNameBackup` to `OfflineSyncResolverTests`.

## Comments
