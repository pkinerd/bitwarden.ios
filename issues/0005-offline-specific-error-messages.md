---
id: 5
title: "[U2-B] No offline-specific error messages for unsupported operations"
status: open
created: 2026-02-21
author: claude
labels: [enhancement]
priority: medium
---

## Description

Archive, unarchive, restore, and collection assignment show generic network errors when attempted offline.

**Severity:** Medium
**Complexity:** Low
**Est. Effort:** ~20-30 lines, 1 file (VaultRepository.swift)

**Recommendation:** Add `OfflineSyncError.operationNotSupportedOffline` and catch blocks in 4 methods. Low effort, could ship in initial release.

**Related Documents:** AP-U2, AP-00, OfflineSyncCodeReview.md, ReviewSection_VaultRepository.md, Review2/00_Main, Review2/03_VaultRepository

## Comments
