---
id: 15
title: "[R2-EXT-4] @retroactive CipherWithArchive — annotation does not exist in current code"
status: closed
created: 2026-02-21
author: claude
labels: [enhancement]
priority: low
closed: 2026-02-21
---

## Description

`@retroactive CipherWithArchive` annotation does not exist in current code — issue not applicable.

**Disposition:** Resolved
**Action Plan:** AP-34 (Resolved)

**Related Documents:** Review2

## Action Plan

*Source: `ActionPlans/Resolved/AP-34_RetroactiveCipherWithArchive.md`*

> **Issue:** #34 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Triaged
> **Source:** Review2/07_CipherViewExtensions_Review.md

## Problem Statement

The review (R2-EXT-4) noted that the rationale for the `@retroactive` annotation on the `CipherWithArchive` conformance in `CipherWithArchive.swift` is unclear. The file shows conformance extensions for SDK types (`Cipher`, `CipherListView`, `CipherView`) to the `CipherWithArchive` protocol.

## Current Code

`BitwardenShared/Core/Vault/Extensions/CipherWithArchive.swift:39-41`:
```swift
extension Cipher: CipherWithArchive {}
extension CipherListView: CipherWithArchive {}
extension CipherView: CipherWithArchive {}
```

Notably, there is **no `@retroactive` annotation** in the current code. The file contains:
- A `CipherWithArchive` protocol definition (lines 7-13)
- A protocol extension with `isHiddenWithArchiveFF(flag:)` method (lines 16-37)
- Three conformance extensions for SDK types (lines 39-41)
- A `// TODO: PM-30129: remove this file.` comment indicating this is temporary

The file is 41 lines. The SDK types (`Cipher`, `CipherListView`, `CipherView`) are external types from `BitwardenSdk`, and `CipherWithArchive` is a project-defined protocol.

## Assessment

**This issue appears to be either outdated or based on a misread.** The current code at `CipherWithArchive.swift:39-41` does NOT contain `@retroactive`. All three conformance lines are simple `extension Type: Protocol {}` declarations without any annotations.

In Swift, `@retroactive` is used when conforming an external type to an external protocol to suppress compiler warnings about retroactive conformance. Since `CipherWithArchive` is a project-defined protocol (not an external SDK protocol), the `@retroactive` annotation would not be needed or appropriate here.

Possible explanations for the review finding:
1. The `@retroactive` annotation may have existed in an earlier version and was subsequently removed.
2. The review may have been referring to a different file or a planned change that was not implemented.
3. The Swift compiler may have required `@retroactive` in a previous SDK version where `CipherWithArchive` was defined differently.

Regardless, the current code is correct: conforming external SDK types (`Cipher`, `CipherListView`, `CipherView`) to a project-defined protocol does not require `@retroactive`.

The file is also marked with `// TODO: PM-30129: remove this file.` at line 4, indicating the entire `CipherWithArchive` protocol and its conformances are temporary and will be removed when the `archiveVaultItems` feature flag is no longer needed.

## Options

### Option A: Close as Not Applicable (Recommended)
- **Effort:** None
- **Description:** Close this issue. The `@retroactive` annotation does not exist in the current code, so there is no rationale to clarify.
- **Pros:** Accurate assessment of current state
- **Cons:** None

### Option B: Add a Comment Explaining Conformance
- **Effort:** ~5 minutes, 3 lines added
- **Description:** Add a brief DocC comment above the conformance declarations explaining why SDK types conform to the project protocol:
  ```swift
  /// Conform SDK cipher types to `CipherWithArchive` to enable archive-aware
  /// filtering without modifying the SDK types directly.
  ```
- **Pros:** Clarifies the design intent for future developers
- **Cons:** The `// TODO: PM-30129: remove this file.` already signals this is temporary; additional documentation on temporary code has limited value

### Option C: Accept As-Is
- **Rationale:** The conformance is straightforward and self-explanatory. SDK types are being extended to conform to a project protocol -- this is a standard Swift pattern. The file is temporary (per the TODO). No annotation exists to clarify.

## Recommendation

**Option A: Close as Not Applicable.** The `@retroactive` annotation referenced in the review does not exist in the current code. The conformance declarations are standard Swift pattern (extending external types to conform to project-defined protocols). The file is explicitly temporary per `PM-30129`.

## Dependencies

None.

## Comments
