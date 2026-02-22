---
id: 19
title: "[R2-RES-11] Hardcoded threshold — unlikely to need remote tuning"
status: closed
created: 2026-02-21
author: claude
labels: [enhancement]
priority: low
closed: 2026-02-21
---

## Description

Hardcoded soft conflict threshold. Unlikely to need remote tuning — accepted as-is.

**Disposition:** Accepted
**Action Plan:** AP-75 (Accepted)

**Related Documents:** Review2

## Action Plan

*Source: `ActionPlans/Accepted/AP-75_HardcodedConflictThreshold.md`*

> **Issue:** #75 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Triaged
> **Source:** Review2/02_OfflineSyncResolver_Review.md

## Problem Statement

The review (R2-RES-11) observes that `softConflictPasswordChangeThreshold` is hardcoded as a `static let` constant set to 4 in `DefaultOfflineSyncResolver`. Tuning this value based on user feedback would require a code change and app recompilation. The suggestion is to consider making this configurable (e.g., via server-provided configuration or a feature flag).

## Current Code

`BitwardenShared/Core/Vault/Services/OfflineSyncResolver.swift:58-60`:
```swift
// MARK: Constants

/// The minimum number of offline password changes that triggers a server backup
/// even when no conflict is detected (soft conflict threshold).
static let softConflictPasswordChangeThreshold: Int16 = 4
```

This constant is used at `OfflineSyncResolver.swift:201-202`:
```swift
let hasSoftConflict = pendingChange.offlinePasswordChangeCount
    >= Self.softConflictPasswordChangeThreshold
```

When `hasSoftConflict` is true and there is no hard conflict (server version unchanged), the resolver creates a backup of the server version before pushing the local version. This is a safety measure to preserve the server state when a user has made many offline password changes.

## Assessment

**This issue is valid but the concern is speculative.** The threshold of 4 is a reasonable default chosen during implementation. The considerations are:

1. **The threshold is a safety heuristic, not a user-facing setting.** It determines when to proactively create a backup during conflict resolution. Users never interact with this value directly.

2. **Server-side configuration would add complexity.** Making this configurable via the server configuration API would require:
   - A new server-side config field
   - A `ConfigService` query in the resolver
   - Fallback handling when the config value is unavailable
   - Server team coordination to deploy the config

3. **The value is unlikely to need frequent tuning.** Once set, the threshold defines a conservative safety boundary. The consequences of being slightly too high or too low are minor -- at worst, a backup copy is created unnecessarily (too low) or a backup is skipped for a borderline case (too high).

4. **Current approach is simple and auditable.** The `static let` makes the value immediately visible, searchable, and testable. Tests reference `DefaultOfflineSyncResolver.softConflictPasswordChangeThreshold` directly.

5. **The feature is behind feature flags.** The entire offline sync resolution system is gated by `offlineSyncEnableResolution` and `offlineSyncEnableOfflineChanges` feature flags. If the threshold proves problematic, the entire feature can be disabled remotely.

## Options

### Option A: Make Server-Configurable
- **Effort:** ~2 hours, 3-4 files, server coordination
- **Description:** Add a server configuration key for the threshold. Have the resolver query `ConfigService` for the value with a fallback to 4.
- **Pros:** Remote tunability without app release
- **Cons:** Adds complexity to an already feature-flagged system; requires server team coordination; adds a `ConfigService` dependency to the resolver; the value is unlikely to need remote tuning

### Option B: Make an Init Parameter
- **Effort:** ~15 minutes, 2 files modified
- **Description:** Pass the threshold as an init parameter with a default value of 4:
  ```swift
  init(
      cipherAPIService: CipherAPIService,
      ...
      softConflictPasswordChangeThreshold: Int16 = 4
  )
  ```
- **Pros:** Testable with different values; configurable without server coordination; minimal change
- **Cons:** Still requires app recompilation for production changes; adds a parameter that will almost never vary in production

### Option C: Accept As-Is (Recommended)
- **Rationale:** The threshold is a conservative safety heuristic that is unlikely to need remote tuning. The entire feature is already behind server-controlled feature flags that can disable it entirely if needed. Making a single constant remotely configurable adds disproportionate complexity. If the value needs to change, it is a one-line code change with no risk.

## Recommendation

**Option C: Accept As-Is.** The `static let` constant is the simplest, most auditable approach. The threshold is a safety heuristic that is unlikely to need remote tuning. The existing server-controlled feature flags provide the necessary escape hatch if the offline sync system behaves unexpectedly. If user feedback indicates the threshold needs adjustment, a one-line code change is the appropriate response.

## Dependencies

None. The constant is self-contained within `DefaultOfflineSyncResolver`.

## Comments
