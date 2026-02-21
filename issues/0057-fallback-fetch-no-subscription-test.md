---
id: 57
title: "[P2-T4] Fallback fetch in ViewItemProcessor doesn't re-establish subscription"
status: closed
created: 2026-02-21
author: claude
labels: [enhancement]
priority: low
closed: 2026-02-21
---

## Description

Fallback fetch in `ViewItemProcessor` doesn't re-establish subscription; no test for cipher update after fallback.

**Severity:** Low
**Rationale:** Negative timeout tests are inherently flaky; existing positive-path coverage sufficient; subscription gap is an intentional design simplification.

**Related Documents:** AP-40 (Accepted As-Is)

**Disposition:** Accepted — no code change planned.

## Comments
