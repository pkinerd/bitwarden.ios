---
id: 120
title: Reduce issues skill sync polling intervals
status: closed
labels: [enhancement]
priority: low
created: 2026-02-22
closed: 2026-02-22
author: claude
---

## Description

The issues skill's post-push sync verification and sequential-operation wait
guidance used polling intervals that were longer than necessary given that the
GitHub Action typically completes in a few seconds.

### Changes

1. **Post-push sync verification** (Step 4 in SKILL.md): Changed from polling
   every 5 seconds (12 attempts / 60s total) to every 2 seconds (30 attempts /
   60s total). This detects sync completion faster without changing the overall
   timeout.

2. **Sequential operations wait guidance**: Changed recommended polling interval
   from ~15 seconds to ~5 seconds, and updated the description from "typically
   completes within 30 seconds" to "typically completes within a few seconds"
   to reflect observed behavior.

### Rationale

The sync GitHub Action (which merges session branches into `claude/issues` and
deletes the session branch) consistently completes in under 10 seconds. The
previous 5-second and 15-second polling intervals meant unnecessary waiting
before the skill could confirm success to the user or proceed with follow-up
operations.

## Comments
