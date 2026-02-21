# Issue Tracking Guide

This branch (`claude/issues`) is a self-contained issue tracking system managed
directly by Claude Code. It uses git as the storage backend — no GitHub Issues,
GitHub CLI, or external tools required.

## How It Works

Issues are stored as markdown files with YAML frontmatter in the `issues/`
directory. Claude Code manages the full lifecycle: creating, updating,
commenting on, and closing issues.

## Quick Reference

### Reading Issues

```bash
# Fetch the latest issues
git fetch origin claude/issues

# View the issue index
git show origin/claude/issues:INDEX.md

# Read a specific issue
git show origin/claude/issues:issues/0001-example-issue.md

# View the schema for issue files
git show origin/claude/issues:SCHEMA.md

# View system state (next ID, valid labels, etc.)
git show origin/claude/issues:state.json
```

### Managing Issues

Claude Code manages issues by:

1. Fetching the branch into a temporary worktree
2. Making changes (create/update/close issues)
3. Updating INDEX.md
4. Committing and pushing

## File Structure

```
claude/issues (orphan branch)
├── GUIDE.md          # This file — how the system works
├── SCHEMA.md         # Issue file format specification
├── INDEX.md          # Markdown table of all issues
├── state.json        # Next ID counter, labels, statuses
├── docs/             # User documentation, specs, references
└── issues/           # Issue files
```

## Workflows

### Creating an Issue

1. Read `state.json` to get the next available ID
2. Create `issues/<id>-<slug>.md` following the format in SCHEMA.md
3. Increment `next_id` in `state.json`
4. Add a row to INDEX.md
5. Commit with message: `Create issue #<id>: <title>`
6. Push to `origin claude/issues`

### Updating an Issue

1. Modify the issue file's frontmatter or body
2. Update the corresponding row in INDEX.md if title/status/labels changed
3. Commit with message: `Update issue #<id>: <description of change>`
4. Push to `origin claude/issues`

### Adding a Comment

1. Append a comment to the `## Comments` section of the issue file
2. Commit with message: `Comment on issue #<id>`
3. Push to `origin claude/issues`

### Closing an Issue

1. Change `status: open` to `status: closed` in frontmatter
2. Add `closed: <date>` to frontmatter
3. Update the status in INDEX.md
4. Commit with message: `Close issue #<id>: <title>`
5. Push to `origin claude/issues`

## Git Operations

Since this is an orphan branch (no shared history with main), Claude Code should
use a temporary worktree to avoid disrupting the main working tree:

```bash
# Fetch the latest
git fetch origin claude/issues

# Create a temporary worktree
git worktree add /tmp/claude-issues origin/claude/issues

# Make changes in /tmp/claude-issues/...

# Commit and push
cd /tmp/claude-issues
git add -A
git commit -m "Create issue #0001: Example issue"
git push origin HEAD:claude/issues

# Clean up
cd -
git worktree remove /tmp/claude-issues
```

### Handling Worktree Conflicts

If a worktree already exists from a previous session:

```bash
# Remove stale worktree first
git worktree remove /tmp/claude-issues 2>/dev/null || rm -rf /tmp/claude-issues
git worktree prune

# Then create fresh
git worktree add /tmp/claude-issues origin/claude/issues
```

## Notes

- The `state.json` file is the source of truth for the next issue ID
- Always update INDEX.md when creating, updating, or closing issues
- Issue file names use the format `<zero-padded-id>-<slug>.md`
- Slugs are lowercase, hyphen-separated, derived from the title
- Keep commits atomic — one operation per commit
- Use `claude` as the author for Claude-generated issues and comments
