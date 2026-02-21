---
id: 6
title: "[EXT-3/CS-2] SDK CipherView manual copy fragility"
status: in-progress
created: 2026-02-21
author: claude
labels: [bug]
priority: high
---

## Description

`makeCopy` manually copies 28 properties; new SDK properties with defaults are silently dropped.

**What's Done:** `makeCopy` consolidation, DocC `- Important:` callouts, Mirror-based property count guard tests (28 CipherView, 7 LoginView).

**What Remains:** Underlying fragility remains inherent to external SDK types. Developers must still manually add properties to `makeCopy` when tests fail. 5 copy methods across 2 files affected.

**Severity:** High
**Complexity:** Medium

**Related Documents:** AP-CS2, ReviewSection_SupportingExtensions.md, Review2/07_CipherViewExtensions

## Comments
