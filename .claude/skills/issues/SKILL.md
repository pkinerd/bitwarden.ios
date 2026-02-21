---
name: issues
description: Manage issues on the claude/issues orphan branch. Supports listing, creating, showing, updating, commenting on, and closing issues. Use when the user says /issues or wants to manage issues tracked on the claude/issues branch.
user_invocable: true
argument: "Optional subcommand and arguments: list, create, show <id>, update <id>, comment <id>, close <id>. If omitted, defaults to list."
---

# Issues

## Instructions

Manage issues stored on the `claude/issues` orphan branch. All operations follow
the conventions defined in `GUIDE.md` and `SCHEMA.md` on that branch.

### Step 1: Fetch the branch and read the guide

Always start by fetching the latest state:

```bash
git fetch origin claude/issues
```

If this is your first time working with issues in this session, read the guide:

```bash
git show origin/claude/issues:GUIDE.md
```

### Step 2: Determine the operation

Parse the argument to determine which operation to perform. If no argument is
given, default to `list`.

| Argument | Operation |
|----------|-----------|
| *(none)* or `list` | List all issues from INDEX.md |
| `create` | Create a new issue |
| `show <id>` | Show a specific issue |
| `update <id>` | Update an existing issue |
| `comment <id>` | Add a comment to an issue |
| `close <id>` | Close an issue |

### Step 3: Execute the operation

#### List Issues

1. Display the contents of INDEX.md:
   ```bash
   git show origin/claude/issues:INDEX.md
   ```
2. Present the table to the user.

#### Show Issue

1. Find the issue file by ID. List files in the issues directory:
   ```bash
   git show origin/claude/issues:issues/ | grep "^<id>-"
   ```
   Where `<id>` is the zero-padded 4-digit ID (e.g., `0001`).
2. Display the full issue:
   ```bash
   git show origin/claude/issues:issues/<filename>
   ```

#### Create Issue

1. Ask the user for the issue details using `AskUserQuestion` if not already
   provided:
   - Title (required)
   - Description (required)
   - Labels (optional — show valid labels from state.json)
   - Priority (optional — low, medium, high, critical)

2. Read the current state:
   ```bash
   git show origin/claude/issues:state.json
   ```

3. Set up a temporary worktree:
   ```bash
   git worktree remove /tmp/claude-issues 2>/dev/null || true
   git worktree prune
   git worktree add /tmp/claude-issues origin/claude/issues
   ```

4. Create the issue file at `/tmp/claude-issues/issues/<id>-<slug>.md` using
   the format from SCHEMA.md. Use the `next_id` from state.json, zero-padded
   to 4 digits.

5. Update `/tmp/claude-issues/state.json` — increment `next_id`.

6. Update `/tmp/claude-issues/INDEX.md` — add a new row to the table. If the
   table contains the "*No issues yet.*" placeholder, remove it first.

7. Commit and push:
   ```bash
   cd /tmp/claude-issues
   git add -A
   git commit -m "Create issue #<id>: <title>"
   git push origin HEAD:claude/issues
   ```

8. Clean up:
   ```bash
   cd -
   git worktree remove /tmp/claude-issues
   ```

9. Confirm creation to the user with the issue ID and title.

#### Update Issue

1. Set up a temporary worktree (same as create step 3).
2. Ask the user what to change (title, status, labels, priority, description).
3. Edit the issue file in the worktree.
4. Update INDEX.md if title, status, labels, or priority changed.
5. Commit: `Update issue #<id>: <description of change>`
6. Push and clean up (same as create steps 7-8).

#### Comment on Issue

1. Set up a temporary worktree (same as create step 3).
2. Ask the user for the comment text if not already provided.
3. Append the comment to the `## Comments` section of the issue file:
   ```markdown
   ### <author> — <YYYY-MM-DD>

   <comment text>
   ```
   Use `claude` as author if Claude is adding the comment, or the user's name
   if they are providing it.
4. Commit: `Comment on issue #<id>`
5. Push and clean up (same as create steps 7-8).

#### Close Issue

1. Set up a temporary worktree (same as create step 3).
2. Update the issue file:
   - Change `status: open` (or `status: in-progress`) to `status: closed`
   - Add `closed: <YYYY-MM-DD>` to the frontmatter
3. Update the status column in INDEX.md.
4. Commit: `Close issue #<id>: <title>`
5. Push and clean up (same as create steps 7-8).
6. Confirm closure to the user.

### Error Handling

- If `git fetch origin claude/issues` fails, the branch may not exist yet.
  Inform the user that the issue tracking branch needs to be initialized.
- If a worktree already exists at `/tmp/claude-issues`, remove it before
  creating a new one.
- If a push fails, retry up to 4 times with exponential backoff (2s, 4s, 8s,
  16s) for network errors. For permission errors (403), inform the user.
- If an issue ID is not found, list available issues and ask the user to
  clarify.
