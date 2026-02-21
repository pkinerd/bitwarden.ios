---
name: issues
description: Manage issues on the claude/issues orphan branch. Supports listing, creating, showing, updating, commenting on, closing, reopening issues, searching/filtering, and managing docs. Use when the user says /issues or wants to manage issues tracked on the claude/issues branch.
user_invocable: true
argument: "Optional subcommand and arguments: list [filter], create [--closed], show <id>, update <id>, comment <id>, close <id>, reopen <id>, search <query>, docs add|show|list. If omitted, defaults to list."
---

# Issues

## Instructions

Manage issues stored on the `claude/issues` orphan branch. All operations follow
the conventions defined in `GUIDE.md` and `SCHEMA.md` on that branch.

### Step 1: Fetch the branch and determine session suffix

Always start by fetching the latest state:

```bash
git fetch origin claude/issues
```

If this is your first time working with issues in this session, read the guide:

```bash
git show origin/claude/issues:GUIDE.md
```

**Determine the session suffix** from your assigned development branch name.
Extract the part after the last hyphen. For example, if your development branch
is `claude/some-task-aBc12`, the suffix is `aBc12`. You will push to
`claude/issues-<suffix>` instead of directly to `claude/issues`. This is required
because the web proxy only allows pushing to session-scoped branches. A GitHub
Action will automatically sync session branches back to `claude/issues`.

### Step 2: Determine the operation

Parse the argument to determine which operation to perform. If no argument is
given, default to `list`.

| Argument | Operation |
|----------|-----------|
| *(none)* or `list` | List all issues from INDEX.md |
| `list <filter>` | List issues filtered by status, label, or priority |
| `create` | Create a new issue (open by default) |
| `create --closed` | Create a new issue in closed state |
| `show <id>` | Show a specific issue |
| `update <id>` | Update an existing issue |
| `comment <id>` | Add a comment to an issue |
| `close <id>` | Close an issue |
| `reopen <id>` | Reopen a closed issue |
| `search <query>` | Search issues by keyword in title/description |
| `docs list` | List documents on the issues branch |
| `docs show <name>` | Show a specific document |
| `docs add <name>` | Add or update a document |

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

Supports an optional `--closed` flag. When present, the issue is created with
`status: closed` and a `closed: <YYYY-MM-DD>` date in the frontmatter. This is
useful for tracking decisions or recording issues that were already resolved.

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
   to 4 digits. If `--closed` was specified, set `status: closed` and add
   `closed: <YYYY-MM-DD>` (today's date) to the frontmatter.

5. Read then update `/tmp/claude-issues/state.json` — increment `next_id`.

6. Read then update `/tmp/claude-issues/INDEX.md` — add a new row to the
   table. If the table contains the "*No issues yet.*" placeholder, remove it
   first. If `--closed`, the status column should show `closed`.

   **Note:** The Write tool requires a prior Read of the file. Always read
   existing worktree files (state.json, INDEX.md, issue files) before writing
   to them.

7. Commit and push to the session-scoped branch:
   ```bash
   cd /tmp/claude-issues
   git add -A
   git -c commit.gpgsign=false commit -m "Create issue #<id>: <title>"
   git push origin HEAD:refs/heads/claude/issues-<suffix>
   ```
   Where `<suffix>` is the session suffix determined in Step 1. A GitHub Action
   will automatically merge this into `claude/issues`.

   **Note:** The worktree uses a detached HEAD, so `commit.gpgsign=false` is
   needed to avoid signing failures, and the push destination must use the full
   refname (`refs/heads/...`) for git to resolve it correctly.

8. Clean up:
   ```bash
   cd -
   git worktree remove /tmp/claude-issues
   ```

9. Confirm creation to the user with the issue ID and title.

#### Update Issue

1. Set up a temporary worktree (same as create step 3).
2. Ask the user what to change (title, status, labels, priority, description).
3. Read then edit the issue file in the worktree.
4. Read then update INDEX.md if title, status, labels, or priority changed.
5. Commit: `Update issue #<id>: <description of change>`
6. Push and clean up (same as create steps 7-8).

#### Comment on Issue

1. Set up a temporary worktree (same as create step 3).
2. Ask the user for the comment text if not already provided.
3. Read the issue file, then append the comment to the `## Comments` section:
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
2. Read then update the issue file:
   - Change `status: open` (or `status: in-progress`) to `status: closed`
   - Add `closed: <YYYY-MM-DD>` to the frontmatter
3. Read then update the status column in INDEX.md.
4. Commit: `Close issue #<id>: <title>`
5. Push and clean up (same as create steps 7-8).
6. Confirm closure to the user.

#### Reopen Issue

1. Set up a temporary worktree (same as create step 3).
2. Read the issue file and verify it currently has `status: closed`. If it is
   already open or in-progress, inform the user and skip.
3. Update the issue file:
   - Change `status: closed` to `status: open`
   - Remove the `closed: <date>` line from the frontmatter
4. Read then update the status column in INDEX.md.
5. Commit: `Reopen issue #<id>: <title>`
6. Push and clean up (same as create steps 7-8).
7. Confirm reopening to the user.

#### List Issues (with filter)

When `list` is called with a filter argument, filter the INDEX.md table before
presenting it. Supported filter formats:

- **By status**: `list open`, `list closed`, `list in-progress`
- **By label**: `list label:bug`, `list label:feature`
- **By priority**: `list priority:high`, `list priority:critical`
- **Combined**: `list open label:bug` (multiple filters are ANDed)

Steps:

1. Read INDEX.md:
   ```bash
   git show origin/claude/issues:INDEX.md
   ```
2. Parse the markdown table rows and filter based on the criteria.
3. Present only matching rows to the user. If no matches, inform them.

#### Search Issues

Search issue titles and descriptions for a keyword or phrase.

1. List all issue files:
   ```bash
   git show origin/claude/issues:issues/
   ```
2. For each issue file, read its contents and check if the query appears in the
   title (frontmatter) or the description body (case-insensitive match):
   ```bash
   git show origin/claude/issues:issues/<filename>
   ```
3. Collect matching issues and present them as a table with ID, title, status,
   and a brief snippet showing where the match was found.
4. If no matches, inform the user.

**Performance note**: For repositories with many issues, read INDEX.md first to
search titles, and only read full issue files if the user needs description-level
search.

#### Docs — List

1. List files in the docs directory:
   ```bash
   git show origin/claude/issues:docs/
   ```
2. Present the list to the user. Exclude `.gitkeep`.

#### Docs — Show

1. Display the specified document:
   ```bash
   git show origin/claude/issues:docs/<name>
   ```
   If the name doesn't include an extension, try `.md` first.
2. Present the contents to the user.

#### Docs — Add

1. Ask the user for the document content if not already provided (they may
   provide it inline or reference content from the current session).
2. Set up a temporary worktree (same as create step 3).
3. If the file already exists, read it first. Then write the file to
   `/tmp/claude-issues/docs/<name>`. If `<name>` doesn't include an extension,
   default to `.md`.
4. Commit: `Add doc: <name>` (or `Update doc: <name>` if the file already
   exists).
5. Push and clean up (same as create steps 7-8).
6. Confirm to the user.

### Bulk Operations

When creating more than ~5 issues at once, or copying a directory of documents,
skip the interactive per-item workflow and operate directly on the worktree. This
avoids repeated AskUserQuestion prompts and produces a single clean commit.

#### When to use bulk mode

- Migrating issues from another tracking system or document
- Importing a batch of related issues (e.g., from a code review)
- Copying a directory tree of documentation files

#### Bulk issue creation

1. **Fetch state and set up worktree** (same as single-issue steps 1-3).

2. **Read `state.json`** to get the starting `next_id`, and **read `INDEX.md`**
   to get the existing table content.

3. **Write a Python script** (to `/tmp/create_issues.py` or similar) that
   generates all issue files at once. The script should:
   - Build a list of issues with title, slug, status, labels, priority, and
     description for each
   - Assign sequential IDs starting from `next_id`
   - Write each issue file to `/tmp/claude-issues/issues/<id>-<slug>.md` using
     the SCHEMA.md frontmatter format (id, title, status, created, author, plus
     optional labels, priority, closed)
   - Every issue body must include `## Description` and `## Comments` sections
   - Append one row per issue to INDEX.md
   - Update `state.json` with the final `next_id`

   Using a script is preferred over writing files one at a time with the Write
   tool because it handles ID assignment, INDEX.md updates, and state.json
   atomically and avoids the Read-before-Write requirement for generated files.

4. **Run the script**:
   ```bash
   cd /tmp/claude-issues && python3 /tmp/create_issues.py
   ```

5. **Commit and push** in a single commit:
   ```bash
   cd /tmp/claude-issues
   git add -A
   git -c commit.gpgsign=false commit -m "Import <N> issues from <source>"
   git push origin HEAD:refs/heads/claude/issues-<suffix>
   ```

6. **Clean up** the worktree.

#### Bulk document import

To copy an entire directory tree of documentation:

1. Set up the worktree (same as above).

2. Create the target directory structure and copy files:
   ```bash
   mkdir -p /tmp/claude-issues/docs/<target-dir>/<subdirs>
   cp -r /path/to/source/docs/* /tmp/claude-issues/docs/<target-dir>/
   ```

3. Commit and push in a single commit:
   ```bash
   cd /tmp/claude-issues
   git add -A
   git -c commit.gpgsign=false commit -m "Import <source> documentation (<N> files)"
   git push origin HEAD:refs/heads/claude/issues-<suffix>
   ```

4. Clean up the worktree.

#### Tips

- **One commit**: Batch all files into a single commit rather than committing
  per-item. This keeps history clean and is much faster.
- **Script for issues, `cp` for docs**: Issue files need generated IDs and
  frontmatter, so a script is the right tool. Docs are plain file copies, so
  `cp -r` is sufficient.
- **Verify counts**: After running the script, check the file count matches
  expectations before committing (e.g., `ls issues/ | wc -l`).
- **Closed issues**: For importing historical/resolved issues, set
  `status: closed` and `closed: <date>` in the frontmatter. This is common
  when migrating from a document that tracks both open and resolved items.

### Error Handling

- If `git fetch origin claude/issues` fails, the branch may not exist yet.
  Inform the user that the issue tracking branch needs to be initialized.
- If a worktree already exists at `/tmp/claude-issues`, remove it before
  creating a new one.
- If a push fails, retry up to 4 times with exponential backoff (2s, 4s, 8s,
  16s) for network errors. For permission errors (403), verify you are pushing
  to `claude/issues-<suffix>` (not `claude/issues` directly) and that the suffix
  matches your session ID.
- If an issue ID is not found, list available issues and ask the user to
  clarify.
