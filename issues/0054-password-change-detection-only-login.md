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

## Comments
