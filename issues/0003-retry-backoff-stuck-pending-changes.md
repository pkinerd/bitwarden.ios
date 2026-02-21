---
id: 3
title: "[R3] No retry backoff for permanently failing resolution items"
status: open
created: 2026-02-21
author: claude
labels: [bug]
priority: high
---

## Description

A single permanently failing pending change blocks ALL syncing indefinitely via the early-abort pattern in `SyncService.swift:348-352`. No retry count, backoff, or expiry mechanism exists.

**Severity:** High
**Complexity:** Medium
**Est. Effort:** ~30-50 lines, 2-3 files, Core Data schema change

**Recommendation:** Option D (`.failed` state) + Option A (retry count after 10 failures). Requires re-adding `timeProvider` dependency (removed in A3).

**Related Documents:** AP-R3, AP-00, OfflineSyncCodeReview.md, OfflineSyncChangelog.md, ReviewSection_SyncService.md, Review2/00_Main, Review2/02_OfflineSyncResolver

**Priority:** Most impactful remaining reliability issue.

## Comments
