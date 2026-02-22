---
id: 37
title: "[R2-RES-4] Backup naming timezone — device-local is user-friendly"
status: closed
created: 2026-02-21
author: claude
labels: [enhancement]
priority: low
closed: 2026-02-21
---

## Description

Device-local timezone for backup naming is more user-friendly — accepted as-is.

**Disposition:** Accepted
**Action Plan:** AP-62 (Accepted)

**Related Documents:** Review2

## Action Plan

*Source: `ActionPlans/Accepted/AP-62_BackupNamingTimezone.md`*

> **Issue:** #62 from ConsolidatedOutstandingIssues.md
> **Severity:** Low | **Complexity:** Low
> **Status:** Triaged
> **Source:** Review2/02_OfflineSyncResolver_Review.md

## Problem Statement

The `createBackupCipher` method in `DefaultOfflineSyncResolver` formats the backup timestamp using a `DateFormatter` with an explicit date format (`"yyyy-MM-dd HH:mm:ss"`) but does not set the `timeZone` property. This means the formatter uses the device's default timezone.

As a result, the timestamp appended to the backup cipher name (e.g., `"GitHub Login - 2026-02-18 13:55:26"`) reflects the device's local time, which may differ from the server's `revisionDate` (which is typically in UTC). This is purely cosmetic — the timestamp is only used in the cipher's display name to help users identify when the backup was created.

## Current Code

- `BitwardenShared/Core/Vault/Services/OfflineSyncResolver.swift:324-326`
```swift
let dateFormatter = DateFormatter()
dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
let timestampString = dateFormatter.string(from: timestamp)
```

The `timestamp` parameter is either `serverCipher.revisionDate` (a `Date` from the server, typically representing UTC) or `localTimestamp` (from `pendingChange.updatedDate`). Both are `Date` objects (absolute points in time), but the string representation will vary by timezone.

## Assessment

**Still valid but truly cosmetic.** The timestamp is used solely in the backup cipher's display name to help users identify which version was backed up and when. It does not affect conflict resolution logic, data integrity, or any functional behavior.

**Actual impact:** A user in UTC+5 would see `"GitHub Login - 2026-02-18 18:55:26"` instead of `"GitHub Login - 2026-02-18 13:55:26"` for the same underlying `Date`. This could cause minor confusion if a user compares the backup name with server-side timestamps (e.g., in the web vault audit log), but in practice users are unlikely to notice or care about this discrepancy.

**Hidden risks:** None. The timestamp does not affect any logic, sorting, or conflict resolution.

## Options

### Option A: Set Timezone to UTC
- **Effort:** Low (~5 minutes, 1 line)
- **Description:** Add `dateFormatter.timeZone = TimeZone(identifier: "UTC")` before formatting.
- **Pros:** Consistent timestamps regardless of device location, matches server convention
- **Cons:** Users see UTC time which may be less intuitive for their local context

### Option B: Set Timezone to UTC and Add "UTC" Suffix
- **Effort:** Low (~10 minutes, 2 lines)
- **Description:** Use UTC timezone and append "UTC" to the format: `"yyyy-MM-dd HH:mm:ss 'UTC'"`.
- **Pros:** Unambiguous timestamps, clear to the user what timezone is used
- **Cons:** Slightly longer cipher names

### Option C: Accept As-Is (Recommended)
- **Rationale:** The device-local timezone is actually the most user-friendly choice. When a user sees `"GitHub Login - 2026-02-18 13:55:26"`, the time is in their local timezone, which is what they would naturally expect. Server timestamps in UTC would be less intuitive. The original review correctly assessed this as "cosmetic only." The mismatch with server time is a non-issue because users don't typically compare backup cipher names with server audit logs.

## Recommendation

**Option C: Accept As-Is.** Using the device's local timezone for backup naming is the most user-friendly behavior. The timestamp is purely for human identification, not for any programmatic comparison. Changing to UTC would make the names less intuitive for most users without providing meaningful benefit.

## Dependencies

- None.

## Comments
