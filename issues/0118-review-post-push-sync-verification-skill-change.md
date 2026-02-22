---
id: 118
title: Review and test post-push sync verification skill change
status: open
labels: [enhancement]
priority: medium
created: 2026-02-22
author: pkinerd
---

## Description

Review and test the changes made to the issues skill (`SKILL.md`) that added a
post-push sync verification step (Step 4). The change adds polling logic that
checks every 5 seconds (up to 60 seconds) whether the GitHub Action has merged
the session branch into `claude/issues` after each write operation.

Key areas to verify:
- The polling logic correctly detects session branch deletion as a sync signal
- Timeout messaging is clear and accurate when sync doesn't complete within 60s
- All write operations (create, update, comment, close, reopen, docs add, bulk)
  correctly reference Step 4
- The verification step integrates cleanly with the existing "Sequential
  Operations — Waiting for Sync" section without duplication or conflict

Branch: `claude/issues-post-verification-gK2tR`

## Comments
