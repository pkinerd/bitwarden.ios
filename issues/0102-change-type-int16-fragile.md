---
id: 102
title: "[CD-TYPE-1] PendingCipherChangeType stored as Int16 — fragile"
status: closed
created: 2026-02-21
author: claude
labels: [bug]
priority: low
closed: 2026-02-21
---

## Description

**Resolution:** Changed to String-backed storage and Integer 64. Commits: `1bc17cb`, `d7a77c9`

**Disposition:** Resolved / Superseded

## Resolution Details

Changed `changeTypeRaw` to String-backed storage and `offlinePasswordChangeCount` to Integer 64; also fixed `changeTypeRaw` optionality (`String` → `String?`). Commits: `1bc17cb`, `d7a77c9`.

## Comments
