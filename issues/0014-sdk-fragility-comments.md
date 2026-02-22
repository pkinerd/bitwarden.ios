---
id: 14
title: "[R2-EXT-3] SDK fragility comments — guard tests provide centralized protection"
status: closed
created: 2026-02-21
author: claude
labels: [enhancement]
priority: low
closed: 2026-02-21
---

## Description

SDK fragility comments noted in review. Guard tests provide centralized automated protection — accepted as-is.

**Disposition:** Accepted
**Action Plan:** AP-33 (Accepted)

**Related Documents:** Review2

## Action Plan

*Source: `ActionPlans/Accepted/AP-33_SDKFragilityComments.md`*

> **Issue:** #33 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Triaged
> **Source:** Review2/07_CipherViewExtensions_Review.md

## Problem Statement

The review identified that three (actually four) `/// - Important` DocC comments about SDK `CipherView` and `LoginView` property fragility are scattered across two files. Each comment repeats the same pattern: "This method manually copies all N properties. When the SDK type is updated, this method must be reviewed." The suggestion is that these comments could reference a shared document rather than repeating the information.

## Current Code

The `/// - Important` comments appear in 4 locations across 2 files:

1. **`CipherView+OfflineSync.swift:53-55`** (`makeCopy` method):
   ```
   /// - Important: This method manually copies all 28 `CipherView` properties.
   ///   When the `BitwardenSdk` `CipherView` type is updated, this method must be
   ///   reviewed to include any new properties. Property count as of last review: 28.
   ```

2. **`CipherView+Update.swift:139-141`** (`updatedView(with:timeProvider:)` method):
   ```
   /// - Important: This method manually lists all 28 `CipherView` properties.
   ///   When the `BitwardenSdk` `CipherView` type is updated, this method must be
   ///   reviewed to include any new properties. Property count as of last review: 28.
   ```

3. **`CipherView+Update.swift:341-343`** (`update(archivedDate:collectionIds:...)` private method):
   ```
   /// - Important: This method manually copies all 28 `CipherView` properties.
   ///   When the `BitwardenSdk` `CipherView` type is updated, this method must be
   ///   reviewed to include any new properties. Property count as of last review: 28.
   ```

4. **`CipherView+Update.swift:398-400`** (`LoginView.update(totp:)` method):
   ```
   /// - Important: This method manually copies all 7 `LoginView` properties.
   ///   When the `BitwardenSdk` `LoginView` type is updated, this method must be
   ///   reviewed to include any new properties. Property count as of last review: 7.
   ```

Additionally, the property count guard tests in `CipherViewOfflineSyncTests.swift` (lines 131-170) provide automated protection and reference `AP-CS2` in their failure messages, creating a cross-reference.

## Assessment

**This issue is valid but the suggested fix (referencing a shared document) has limited value.** The comments serve two distinct purposes:

1. **Inline discoverability:** When a developer is modifying one of these copy methods, the `/// - Important` comment is right there in the DocC, visible in Xcode's Quick Help and code completion. A reference to an external document would be less immediately actionable.

2. **Property count baseline:** Each comment includes the specific property count (28 or 7), which serves as a quick sanity check even without running the guard tests.

The guard tests in `CipherViewOfflineSyncTests.swift` already provide the centralized protection mechanism. They fail when the SDK adds properties, and their failure messages reference the action plan document (`AP-CS2`). The inline comments are supplementary reminders.

The review itself notes: "since they're in different files, the repetition aids discoverability."

## Options

### Option A: Add Cross-References to Existing Comments
- **Effort:** ~15 minutes, 4 lines modified
- **Description:** Append a reference to the guard tests at the end of each `/// - Important` comment:
  ```
  ///   See `test_cipherView_propertyCount_matchesExpected` in CipherViewOfflineSyncTests.swift.
  ```
- **Pros:** Connects the dots between the inline comments and the automated guard tests; minimal change; maintains inline discoverability
- **Cons:** Adds slightly more text to each comment

### Option B: Create a Shared Document
- **Effort:** ~30 minutes, create new doc + update 4 comments
- **Description:** Create a short document (e.g., `SDK_Property_Copy_Methods.md`) listing all affected methods and reference it from each `/// - Important` comment.
- **Pros:** Single source of truth for all fragile copy methods
- **Cons:** Violates the project's CLAUDE.md directive to not proactively create documentation files; adds indirection; Xcode won't show the linked document in Quick Help; the guard tests already serve as the centralized protection

### Option C: Accept As-Is (Recommended)
- **Rationale:** The current approach prioritizes **inline discoverability** -- when a developer is editing a copy method, the warning is right there in the DocC. The guard tests (`test_cipherView_propertyCount_matchesExpected`, `test_loginView_propertyCount_matchesExpected`) already provide the centralized automated protection. Creating a shared document would add indirection without practical benefit. The review itself acknowledges that "the repetition aids discoverability."

## Recommendation

**Option C: Accept As-Is.** The inline `/// - Important` comments serve their purpose well by being immediately visible to developers editing the affected methods. The property count guard tests provide centralized automated protection. Adding a shared document or cross-references would add minimal value since the guard tests already catch SDK changes at test time.

## Dependencies

- Related to Issue #6 (EXT-3 / CS-2) in the consolidated issues, which tracks the underlying SDK property fragility concern.

## Comments
