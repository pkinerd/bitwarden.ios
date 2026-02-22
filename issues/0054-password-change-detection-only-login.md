---
id: 54
title: "[VR-3] Password change detection only compares login?.password"
status: closed
created: 2026-02-21
author: claude
labels: [enhancement]
priority: low
closed: 2026-02-21
---

## Description

Password change detection only compares `login?.password`, not other sensitive fields.

**Severity:** Low
**Rationale:** By design — soft conflict threshold targets highest-risk field.

**Related Documents:** ReviewSection_VaultRepository.md

**Disposition:** Accepted — no code change planned.

## Consolidated Assessment

*From: ConsolidatedOutstandingIssues.md — Section 5: Open Issues — Accepted As-Is*

Password change detection only compares `login?.password`, not other sensitive fields. By design — soft conflict threshold targets highest-risk field.

## Code Review References

### From `ReviewSection_VaultRepository.md`

### Issue VR-3: `handleOfflineUpdate` Password Detection Compares Only `login?.password` (Low)

The password change detection only compares `login?.password`. It does not detect changes to other sensitive fields like notes, card numbers, identity SSN, or SSH keys. The `offlinePasswordChangeCount` threshold only tracks password changes.

**Assessment:** This is by design — the soft conflict threshold is specifically about password changes, which are the highest-risk field for drift accumulation. Changes to other fields are still synced correctly; they just don't contribute to the soft conflict threshold.

## Comments
