---
id: 119
title: Sync workflow accidentally triggered by unrelated claude/issues-* session branches
status: closed
labels: [bug]
priority: medium
created: 2026-02-22
closed: 2026-02-22
author: claude
---

## Description

The `sync-issues-branch.yml` GitHub Action was configured to trigger on pushes
to branches matching `claude/issues-*`. This pattern was intended to match
session-scoped branches created by the `/issues` skill (e.g.,
`claude/issues-aBc12`), which the Action would merge into the canonical
`claude/issues` orphan branch and then delete.

**Problem:** The `claude/issues-*` glob pattern is too broad. Any Claude Code
web session whose development branch happened to start with `claude/issues-`
would accidentally trigger the workflow. For example, a branch like
`claude/issues-post-verification-gK2tR` (created for a normal development task)
would match the pattern. When triggered, the Action would attempt to merge the
development branch into `claude/issues` and then **delete the development
branch**, causing data loss.

**Root cause:** The session branch naming convention (`claude/issues-<suffix>`)
used a common prefix that overlapped with legitimate development branch names.

### Fix

Renamed the session branch prefix from `claude/issues-<suffix>` to
`claude/zzsysissuesskill-<suffix>`. The new prefix is deliberately obscure and
unlikely to collide with any naturally-named development branch. Changes were
made in four places:

1. **`.github/workflows/sync-issues-branch.yml` on `main`** — Updated the
   trigger pattern from `claude/issues-*` to `claude/zzsysissuesskill-*`.

2. **`.github/workflows/sync-issues-branch.yml` on `claude/issues`** — Updated
   the same trigger pattern on the orphan branch, which is critical because
   GitHub Actions uses the workflow file from the branch being pushed (session
   branches inherit this file from `claude/issues`).

3. **`.claude/skills/issues/SKILL.md`** — Updated all references to the session
   branch prefix throughout the skill instructions.

4. **`.claude/CLAUDE.md`** — Updated the issues skill documentation section.

### Impact

- **Severity:** Medium — could cause deletion of active development branches
- **Likelihood:** Low to medium — only triggers when a Claude session branch
  happens to start with `claude/issues-`
- **Affected component:** `.github/workflows/sync-issues-branch.yml`

## Comments
