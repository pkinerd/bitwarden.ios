---
id: 81
title: "[R2-DI-5] DocC parameter block in ServiceContainer.swift init — alphabetical order"
status: closed
created: 2026-02-21
author: claude
labels: [bug]
priority: low
closed: 2026-02-21
---

## Description

**Resolution:** Already in correct alphabetical order. AP-29 (Resolved)

**Disposition:** Resolved / Superseded

## Action Plan

*Source: `ActionPlans/Resolved/AP-29_DocCParameterOrder.md`*

> **Issue:** #29 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Resolved
> **Source:** ReviewSection_DIWiring.md

## Problem Statement

The original review (R2-DI-5) identified that the DocC parameter documentation block in `ServiceContainer.swift`'s initializer had `pendingCipherChangeDataStore` out of alphabetical order. Specifically, the DocC block listed `pendingAppIntentActionMediator` and `pendingCipherChangeDataStore` after `rehydrationHelper` and `reviewPromptService`, rather than in their correct alphabetical positions.

## Current Code

The `ServiceContainer.swift` initializer DocC block at `BitwardenShared/Core/Platform/Services/ServiceContainer.swift:210-278` has been reviewed. The current ordering is:

- Line 254: `///   - offlineSyncResolver:` (after `notificationService`)
- Line 255: `///   - pasteboardService:`
- Line 256: `///   - pendingAppIntentActionMediator:`
- Line 257: `///   - policyService:`
- ...

The `pendingAppIntentActionMediator` parameter now appears in its correct alphabetical position (after `pasteboardService`, before `policyService`). Additionally, `pendingCipherChangeDataStore` does not appear in the main init's DocC block because it is not a stored property on `ServiceContainer` -- it is only passed through the convenience initializer when constructing other objects (the resolver, sync service, and vault repository).

The actual init parameter list (lines 280-341) is also in correct alphabetical order:
- Line 317: `offlineSyncResolver: OfflineSyncResolver,`
- Line 318: `pasteboardService: PasteboardService,`
- Line 319: `pendingAppIntentActionMediator: PendingAppIntentActionMediator,`
- Line 320: `policyService: PolicyService,`

Both the DocC parameter documentation and the actual parameter list are now in correct alphabetical order.

## Assessment

**This issue has already been resolved.** The ReviewSection_DIWiring.md document itself notes at Issue DI-5: **"[Resolved] The DocC parameter documentation block in the `ServiceContainer` init has been reordered so that `pendingAppIntentActionMediator` now appears in its correct alphabetical position."** The document also clarifies that `pendingCipherChangeDataStore` is not a stored property on `ServiceContainer` and therefore does not appear in the main init's parameter list or DocC block.

## Options

### Option A: Close as Resolved (Recommended)
- **Effort:** None
- **Description:** Mark this issue as resolved. No code changes needed.
- **Pros:** Accurate reflection of current state
- **Cons:** None

## Recommendation

Close this issue as **Resolved**. The DocC parameter ordering has been corrected and `pendingCipherChangeDataStore` is correctly absent from the main init (it is not a stored property of `ServiceContainer`).

## Dependencies

None.

## Resolution Details

DocC parameter block in `ServiceContainer.swift` already in correct alphabetical order in current code.

## Comments
