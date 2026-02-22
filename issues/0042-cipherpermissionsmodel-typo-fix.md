---
id: 42
title: "[R2-UP-2] CipherPermissionsModel typo fix — already applied"
status: closed
created: 2026-02-21
author: claude
labels: [enhancement]
priority: low
closed: 2026-02-21
---

## Description

`CipherPermissionsModel` typo fix already applied consistently — resolved.

**Disposition:** Resolved
**Action Plan:** AP-69 (Resolved)

**Related Documents:** Review2

## Action Plan

*Source: `ActionPlans/Resolved/AP-69_CipherPermissionsModelTypoFix.md`*

> **Issue:** #69 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Triaged
> **Source:** Review2/09_UpstreamChanges_Review.md

## Problem Statement

The `CipherPermissionsModel.swift` file contained a typo in its DocC comments: "acive" was corrected to "active." This is an upstream change from the spell check pre-commit hook initiative (`[PM-27525] Add spell check git pre-commit hook (#2319)`), not an offline sync change. The review flagged it as a low-risk upstream change that needs verification to ensure it doesn't affect offline sync cipher operations.

## Current Code

- `BitwardenShared/Core/Vault/Models/API/CipherPermissionsModel.swift:1-9`
```swift
/// API model for cipher permissions.
///
struct CipherPermissionsModel: Codable, Equatable {
    /// Whether `delete` permission is active.
    let delete: Bool

    /// Whether `restore` permission is active.
    let restore: Bool
}
```

The current code shows "active" (the corrected spelling). The original code had "acive" in the DocC comments for both properties.

## Assessment

**Valid but already resolved.** The typo fix has been applied. The change is:
- **Comment-only**: The correction is in DocC documentation strings, not in any code that affects runtime behavior.
- **No API impact**: `CipherPermissionsModel` is a `Codable` struct. Its JSON coding keys are derived from the property names (`delete`, `restore`), not from the documentation strings. The typo fix has zero effect on serialization, deserialization, or any runtime behavior.
- **No offline sync interaction**: The offline sync code does not use `CipherPermissionsModel` directly. The conflict resolution logic operates on `Cipher` objects and `CipherDetailsResponseModel`, which contain `CipherPermissionsModel` as a nested property but do not read or modify its permission fields during offline resolution.

**Hidden risks:** None. This is a documentation-only change with no runtime impact.

## Options

### Option A: Accept As-Is (Recommended)
- **Rationale:** The typo fix is already applied, is comment-only, has no runtime impact, and does not interact with offline sync code. No further action is needed.

## Recommendation

**Option A: Accept As-Is.** The typo has been fixed. The change is purely cosmetic (documentation comments) and has no interaction with offline sync functionality. Verification complete: no risk.

## Dependencies

- None. This is an independent upstream documentation fix.

## Comments
