---
name: prepare-pr
description: Generates copyable PR fields (URL, title, description) for creating a pull request from the current branch to a specified target branch. Use when preparing a pull request, drafting PR content, or when the user says /prepare-pr. Accepts an optional target branch argument (e.g. /prepare-pr dev).
user_invocable: true
argument: Optional target branch name (e.g. "dev", "main"). If omitted, the user will be prompted.
---

# Prepare PR

## Instructions

Generate pull request information for the current branch and present it as copyable fields the user can paste into a GitHub PR form.

### Step 1: Determine the target branch and repository

1. Check if the user provided a target branch as an argument (e.g. `/prepare-pr dev`).
   - If an argument was provided, use it as the target branch — do NOT prompt.
   - If no argument was provided, ask the user which branch the PR should target (e.g. `main`, `dev`, etc.) using `AskUserQuestion`.
2. Run `git remote get-url origin` to get the repository URL.
3. Convert the remote URL to a GitHub HTTPS URL:
   - SSH format `git@github.com:org/repo.git` → `https://github.com/org/repo`
   - HTTPS format `https://github.com/org/repo.git` → `https://github.com/org/repo`
4. Get the current branch name with `git branch --show-current`.

### Step 2: Gather changes

1. Identify the merge base: `git merge-base <target-branch> HEAD`
2. Get the full diff: `git diff <merge-base>...HEAD`
3. Get the commit log: `git log --oneline <merge-base>..HEAD`
4. Read changed file contents as needed to understand the changes.

### Step 3: Generate PR fields

Based on the changes, generate:

1. **PR URL** — the GitHub "new pull request" URL:
   `https://github.com/<org>/<repo>/compare/<target-branch>...<current-branch>?expand=1`
   IMPORTANT: Use the real `github.com` domain. Do NOT use any local proxy URL.

2. **PR Title** — a concise title (under 72 characters) summarizing the change. Use imperative mood (e.g. "Add offline sync resolver" not "Added offline sync resolver").

3. **PR Description** — a markdown body with:
   - `## Summary` section with 2-5 bullet points describing what changed and why
   - `## Changes` section listing the key files/components modified, grouped logically
   - `## Test Plan` section with a checklist of how to verify the changes

### Step 4: Present to the user

Present the output in this exact format so each section is clearly copyable:

---

**PR URL** (copyable):
```
<url without any decoration>
```
[Open PR on GitHub](<same url>)

**Title** (copyable):
```
<title text>
```

**Description** (copyable):
````
<full markdown description>
````

---

IMPORTANT formatting rules:
- The PR URL must be a plain `github.com` URL — never a localhost or proxy URL
- The PR URL in the copyable block must have no angle brackets or other decoration
- The clickable link must also use the raw `github.com` URL
- The description must be fenced so the user can copy the raw markdown
- Use four backticks (````) to fence the description so that markdown inside it (with triple backticks) is preserved literally
