---
id: 52
title: "[PCDS-1] PendingCipherChangeData.id optional in Swift but required in Core Data schema"
status: closed
created: 2026-02-21
author: claude
labels: [enhancement]
priority: low
closed: 2026-02-21
---

## Description

`PendingCipherChangeData.id` is optional in Swift but required in Core Data schema.

**Severity:** Low
**Rationale:** Core Data `@NSManaged` limitation, not a design flaw.

**Related Documents:** AP-PCDS1, ReviewSection_PendingCipherChangeDataStore.md

**Disposition:** Accepted — no code change planned.

## Comments
