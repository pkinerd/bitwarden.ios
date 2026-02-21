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

Build logs from the `Build, Test & Package Simulator` workflow are pushed to dedicated branches after each run. When the user reports a build error, compile failure, or test failure, **you should immediately fetch the logs** rather than asking the user for details.

### How to discover available build log branches

Use `WebFetch` to list branches matching the `build-logs/` prefix:

```
URL: https://api.github.com/repos/pkinerd/bitwarden.ios/git/matching-refs/heads/build-logs/
```

Branch names follow the pattern: `build-logs/<run_number>-<run_id>-<timestamp>-<pass|fail>`

- `run_number` is the human-readable build number (e.g. 138) shown in the GitHub Actions UI
- `run_id` is the API identifier for the workflow run
- `pass`/`fail` indicates the test job result

Only the 5 most recent branches are kept; older ones are automatically cleaned up.

### How to read the logs

Each log branch contains these files at its root:

| File | Contents |
|------|----------|
| `build-summary.md` | Build metadata: run number, commit, PR info, result, artifact list, coverage header |
| `jobs.json` | Full job details from the GitHub Actions API |
| `test.log` | Raw console output from the Test job (build + test output) |
| `push-build-logs.log` | Console output from the log-push job itself |

Fetch raw file content using `WebFetch`:

```
URL: https://raw.githubusercontent.com/pkinerd/bitwarden.ios/<branch-name>/test.log
```

For example, to read the test log from build #138:

```
URL: https://raw.githubusercontent.com/pkinerd/bitwarden.ios/build-logs/138-22244913185-20260221T050510Z-pass/test.log
```

### Typical workflow when user reports a build error

1. Fetch the branch list to find the most recent `fail` branch (or the latest branch)
2. Read `test.log` to find compiler errors, test failures, or warnings
3. Read `build-summary.md` for context (commit SHA, PR, branch)
4. Diagnose and fix the issue based on the log content

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
