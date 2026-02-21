---
id: 56
title: "[R2-TEST-2] Core Data lightweight migration has no automated test"
status: closed
created: 2026-02-21
author: claude
labels: [enhancement]
priority: medium
closed: 2026-02-21
---

## Description

Core Data lightweight migration (adding `PendingCipherChangeData` entity) has no automated test.

**Severity:** Medium
**Rationale:** Entity addition is the safest lightweight migration; no other entities have migration tests; SQLite fixture effort unjustified for entity-add risk level.

**Related Documents:** AP-36 (Accepted As-Is)

**Disposition:** Accepted — no code change planned.

## Comments
