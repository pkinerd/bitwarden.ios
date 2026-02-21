# Bitwarden iOS Password Manager & Authenticator Apps Claude Guidelines

Core directives for maintaining code quality and consistency in the Bitwarden iOS project.

## Core Directives

**You MUST follow these directives at all times.**

1. **Adhere to Architecture**: All code modifications MUST follow patterns in `./../Docs/Architecture.md`
2. **Follow Code Style**: ALWAYS follow https://contributing.bitwarden.com/contributing/code-style/swift
3. **Follow Testing Guidelines**: Analyzing or implementing tests MUST follow guidelines in `./../Docs/Testing.md`.
4. **Best Practices**: Follow Swift / SwiftUI general best practices (value over reference types, guard clauses, extensions, protocol oriented programming)
5. **Document Everything**: Everything in the code requires DocC documentation except for protocol properties/functions implementations as the docs for them will be in the protocol. Additionally, mocks do not need DocC documentation, because the docs for the public interface will be in the protocol.
6. **Dependency Management**: Use `ServiceContainer` as established in the project
7. **Use Established Patterns**: Leverage existing components before creating new ones
8. **File References**: Use file:line_number format when referencing code

## SwiftLint Rules

**This project enforces SwiftLint (`.swiftlint.yml`). You MUST ensure generated code passes all lint rules.**

### File Length (Critical)
- Files MUST NOT exceed **1000 lines** (`file_length` error threshold)
- When writing or modifying test files, **check the file's current line count** before adding code
- If a **new** file would exceed 1000 lines, split into extension files using the pattern: `<Type>Tests+<Category>.swift` (e.g., `VaultListProcessorTests+SearchTests.swift`)
- If a file already has `// swiftlint:disable file_length`, you may continue adding code to it
- Do NOT add `// swiftlint:disable file_length` to new files — split them instead

### Key Rules
- **`sorted_imports`**: Imports must be in alphabetical order
- **`trailing_comma`**: Trailing commas are **required** in all multiline collections and parameter lists
- **`type_contents_order`**: Members within types must follow this order: cases, type aliases, associated types, subtypes, type properties, instance properties, initializers, deinitializer, type methods, view lifecycle methods, other methods, subscripts
- **`type_name`**: Type names must not exceed 50 characters
- **`file_name`**: File name must match the primary type declared in the file
- **`weak_navigator`**: Navigator properties must be declared `weak` (except in test files)
- **`style_guide_font`**: Use `.font(.styleGuide(...))` instead of `.font(.system(...))`
- **`todo_without_jira`**: TODOs must include a JIRA reference: `// TODO: BIT-123`

See `.swiftlint.yml` for the complete rule configuration.

## Security Requirements

**Every change must consider:**
- Zero-knowledge architecture preservation
- Proper encryption key handling (iOS Keychain)
- Input validation and sanitization
- Secure data storage patterns
- Threat model implications

## Workflow Practices

### Before Implementation

1. Read relevant architecture documentation
2. Search for existing patterns to follow
3. Identify affected targets and dependencies
4. Consider security implications

### During Implementation

1. Follow existing code style in surrounding files
2. Write tests alongside implementation
3. Add DocC to everything except protocol implementations and mocks
4. Validate against architecture guidelines

### After Implementation

1. Ensure all tests pass
2. Verify compilation succeeds
3. Review security considerations
4. Update relevant documentation

## Linting

SwiftLint is enforced via `.swiftlint.yml`. Key constraints to keep in mind:
- **File length**: Files must not exceed **1000 lines** (`file_length`). Extract helpers or split files proactively.
- **Tuple size**: Tuples must have at most **2 members** (`large_tuple`). Use structs for grouped data instead.
- **Type body length**: Large type bodies will trigger `type_body_length`. Use `// swiftlint:disable:next type_body_length` only when splitting is impractical (e.g., large test classes).
- **Trailing commas**: Trailing commas are **mandatory** in multi-line collections (`trailing_comma`).
- **Missing docs**: Public declarations require documentation (`missing_docs`), consistent with the DocC directive above.

See `.swiftlint.yml` for the full rule configuration including custom rules.

## Anti-Patterns

**Avoid these:**
- Creating new patterns when established ones exist
- Exception-based error handling in business logic
- Direct dependency access (use DI)
- Undocumented public APIs
- Tight coupling between targets

## Build Logs (CI)

Build logs from the `Build, Test & Package Simulator` workflow are pushed to dedicated branches after each run. When the user reports a build error, compile failure, or test failure, **immediately fetch the logs** rather than asking the user for details.

### Branch naming

Pattern: `build-logs/<run_number>-<run_id>-<timestamp>-<pass|fail>`

Only the 10 most recent branches are kept; older ones are automatically cleaned up. List available branches:

```bash
git ls-remote --heads origin 'refs/heads/build-logs/*'
```

### Log files

| File | Contents |
|------|----------|
| `build-summary.md` | Build metadata: run number, commit, PR info, result, artifact list, coverage |
| `jobs.json` | Job details from the GitHub Actions API |
| `test.log` | Console output from the Test job (build + test) |
| `<job-name>.log` | Per-job console logs (e.g. `process-test-reports.log`) |

### Reading logs

Use `git fetch` + `git show` (do **not** use `WebFetch` with GitHub URLs):

```bash
git fetch origin build-logs/<branch-name>
git show origin/build-logs/<branch-name>:test.log
git show origin/build-logs/<branch-name>:build-summary.md
```

### Grepping test.log

- Passing tests: `✓` (tick symbol)
- Failing tests: `✖︎` (cross symbol)
- Compiler/build errors: `error:` (with colon)

Example: `git show origin/build-logs/<branch>:test.log | grep '✖︎\|error:'`

### When user reports a build error

1. `git ls-remote --heads origin 'refs/heads/build-logs/*'` — find the most recent (or `fail`) branch
2. `git fetch` + `git show` the `test.log`, grep for `✖︎` or `error:` to find failures
3. `git show` the `build-summary.md` for context (commit, PR, branch)
4. Diagnose and fix

### Polling for build logs (web sessions)

After pushing code, use the `poll-build-logs` skill to automatically monitor for CI results. This runs `Scripts/poll-build-logs.sh` as a **background task**, which keeps the web session alive while CI runs.

```bash
# Start polling (run with run_in_background: true)
./Scripts/poll-build-logs.sh <commit_sha> --interval 60 --delay 60 --timeout 2700
```

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `--delay` | 60s | Initial wait before first poll |
| `--interval` | 60s | Seconds between `git ls-remote` checks |
| `--timeout` | 2700s (45 min) | Maximum wait before giving up |

The script snapshots existing build-log branches at start, then polls for new ones matching the commit SHA. On match, it fetches and displays `build-summary.md` and (for failures) error lines from `test.log`.

## Communication & Decision-Making

Always clarify ambiguous requirements before implementing. Use specific questions:
- "Should this use [Approach A] or [Approach B]?"
- "This affects [X]. Proceed or review first?"
- "Expected behavior for [specific requirement]?"

Defer high-impact decisions to the user:
- Architecture/module changes, public API modifications
- Security mechanisms, database migrations
- Third-party library additions

## References

### Critical resources:
- `./../Docs/Architecture.md` - Architecture patterns and principles
- `./../Docs/Testing.md` - Testing guidelines
- https://contributing.bitwarden.com/contributing/code-style/swift - Code style guidelines

**Do not duplicate information from these files - reference them instead.**

### Additional resources:
-   [Architectural Decision Records (ADRs)](https://contributing.bitwarden.com/architecture/adr/)
-   [Contributing Guidelines](https://contributing.bitwarden.com/contributing/)
-   [Accessibility](https://contributing.bitwarden.com/contributing/accessibility/)
-   [Setup Guide](https://contributing.bitwarden.com/getting-started/mobile/ios/)
-   [Security Whitepaper](https://bitwarden.com/help/bitwarden-security-white-paper/)
-   [Security Definitions](https://contributing.bitwarden.com/architecture/security/definitions)
