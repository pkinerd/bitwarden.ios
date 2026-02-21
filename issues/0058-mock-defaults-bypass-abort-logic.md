---
id: 58
title: "[TC-6] Mock defaults silently bypass abort logic"
status: closed
created: 2026-02-21
author: claude
labels: [enhancement]
priority: medium
closed: 2026-02-21
---

## Description

24 of 25 `fetchSync` tests use default `pendingChangeCountResult = 0` with no assertions about offline resolution.

**Severity:** Medium
**Rationale:** `test_fetchSync_preSyncResolution_skipsWhenResolutionFlagDisabled` already covers the negative path; feature flag default `false` provides strong gate.

**Related Documents:** AP-41 (Accepted As-Is)

**Disposition:** Accepted — no code change planned.

## Comments
