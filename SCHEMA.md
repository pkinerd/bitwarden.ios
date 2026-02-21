# Issue Schema

This document defines the format for issue files stored in the `issues/`
directory.

## File Naming

```
<id>-<slug>.md
```

- **id**: Zero-padded to 4 digits (e.g., `0001`, `0042`)
- **slug**: Lowercase, hyphen-separated, derived from the title
  (e.g., `vault-sync-bug`)
- **Example**: `0001-vault-sync-bug.md`

## Frontmatter

Issues use YAML frontmatter with the following fields:

### Required Fields

| Field     | Type    | Description                        |
|-----------|---------|------------------------------------|
| `id`      | integer | Unique issue identifier            |
| `title`   | string  | Short, descriptive title           |
| `status`  | string  | Current status (see valid values)  |
| `created` | date    | Creation date (YYYY-MM-DD)         |
| `author`  | string  | Who created the issue              |

### Optional Fields

| Field      | Type   | Description                              |
|------------|--------|------------------------------------------|
| `labels`   | list   | Categorization tags                      |
| `priority` | string | `low`, `medium`, `high`, `critical`      |
| `assignee` | string | Who is working on it                     |
| `closed`   | date   | Date closed (YYYY-MM-DD)                 |
| `related`  | list   | Related issue IDs (e.g., `[1, 5]`)       |

### Valid Statuses

- `open` — Issue is active and unresolved
- `in-progress` — Actively being worked on
- `closed` — Issue is resolved or no longer relevant

### Valid Labels

Labels are defined in `state.json` and can be extended. Default labels:

- `bug` — Something isn't working correctly
- `feature` — New functionality request
- `enhancement` — Improvement to existing functionality
- `question` — Needs discussion or clarification
- `documentation` — Documentation-related
- `refactor` — Code improvement without behavior change

## Body Format

```markdown
---
id: 1
title: Vault sync fails on poor connection
status: open
labels: [bug, sync]
priority: high
created: 2026-02-20
author: pkinerd
---

## Description

A clear description of the issue. Include:
- What is happening vs. what should happen
- Steps to reproduce (for bugs)
- Context and motivation (for features)

## Comments

### pkinerd — 2026-02-21

Comment text here. Use markdown formatting as needed.
Reference code with `file:line_number` format.

### claude — 2026-02-21

Another comment...
```

## Notes

- The `## Description` section is required
- The `## Comments` section should always be present (even if empty initially)
- Comments are appended chronologically
- Use `claude` as the author name for Claude-generated comments
- Keep descriptions concise but complete
