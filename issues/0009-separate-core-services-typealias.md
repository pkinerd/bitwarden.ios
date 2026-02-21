---
id: 9
title: "[DI-1-B] Create separate CoreServices typealias for core-layer-only dependencies"
status: open
created: 2026-02-21
author: claude
labels: [refactor]
priority: low
---

## Description

Create separate `CoreServices` typealias for core-layer-only dependencies.

**Note:** Impact reduced since `HasPendingCipherChangeDataStore` was never added to `Services` — only `HasOfflineSyncResolver` is exposed.

**Severity:** Low
**Complexity:** High
**Dependencies:** Significant DI refactoring.

**Related Documents:** AP-DI1

**Status:** Deferred — future enhancement.

## Comments
