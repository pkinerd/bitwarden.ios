---
id: 49
title: "[DI-1] HasOfflineSyncResolver in Services typealias exposes resolver to UI layer"
status: closed
created: 2026-02-21
author: claude
labels: [enhancement]
priority: low
closed: 2026-02-21
---

## Description

`HasOfflineSyncResolver` in `Services` typealias exposes resolver to UI layer. `HasPendingCipherChangeDataStore` does NOT exist in `Services.swift` — the data store is passed directly via initializers. Only `HasOfflineSyncResolver` (line 40) is in the typealias.

**Severity:** Low
**Rationale:** Consistent with existing project patterns. Enables future U3.

**Related Documents:** AP-DI1, ReviewSection_DIWiring.md, Review2/05_DIWiring

**Disposition:** Accepted — no code change planned.

## Comments
