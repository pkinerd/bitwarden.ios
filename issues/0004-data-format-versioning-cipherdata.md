---
id: 4
title: "[R1] No data format versioning for cipherData JSON"
status: open
created: 2026-02-21
author: claude
labels: [bug]
priority: high
---

## Description

If `CipherDetailsResponseModel` changes in a future app update, old pending records fail to decode permanently, blocking sync.

**Severity:** Medium
**Complexity:** Low
**Est. Effort:** ~15-20 lines, 2-3 files, Core Data schema change

**Recommendation:** Add `dataVersion` attribute to Core Data entity (use Integer 64 per current schema conventions from `1bc17cb`). Deprioritize if R3 is implemented (R3 provides more general stuck-item solution). Bundle schema change with R3.

**Related Documents:** AP-R1, AP-00, OfflineSyncCodeReview.md, ReviewSection_PendingCipherChangeDataStore.md, Review2/02_OfflineSyncResolver

## Comments
