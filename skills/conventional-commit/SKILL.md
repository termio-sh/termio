---
name: conventional-commit
description: "Conventional Commit - Generate Conventional Commits 1.0.0 compliant messages. MANDATORY for all git commits. Invoke when user says 'commit', 'commit this', or asks to commit code."
---

# Conventional Commit

Generate commit messages following the [Conventional Commits 1.0.0](https://www.conventionalcommits.org/) specification.

## Commit Message Structure

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

## Instructions

When the user asks to commit changes:

1. **Analyze the changes** by running:
   - `git status` to see all modified/added/deleted files
   - `git diff --staged` to see staged changes
   - `git diff` to see unstaged changes
   - `git log -5 --oneline` to match the repository's commit style

2. **Determine the commit type** (REQUIRED):
   | Type | Description | SemVer |
   |------|-------------|--------|
   | `feat` | New feature | MINOR |
   | `fix` | Bug fix | PATCH |
   | `docs` | Documentation only | - |
   | `style` | Formatting, no code change | - |
   | `refactor` | Code change, no feature/fix | - |
   | `perf` | Performance improvement | - |
   | `test` | Adding/updating tests | - |
   | `build` | Build system or dependencies | - |
   | `ci` | CI configuration | - |
   | `chore` | Other changes | - |

3. **Identify breaking changes**:
   - Append "!" after type/scope for breaking changes: "feat!:" or "feat(api)!:"
   - Add "BREAKING CHANGE:" footer for detailed explanation
   - Breaking changes trigger MAJOR version bump

4. **Write the commit message**:
   - Description MUST immediately follow the colon and space
   - Description is a short summary in imperative mood
   - Body MUST begin one blank line after description
   - Footers MUST begin one blank line after body

5. **Stage and commit**:
   - Stage relevant files with `git add`
   - Create commit with the generated message
   - Show `git status` after to confirm success
   - **DO NOT** add any Claude Code references, co-author tags, or "Generated with" footers

## Specification Rules

- Type MUST be a noun (`feat`, `fix`, etc.)
- Scope MUST be a noun in parentheses describing codebase section
- Description MUST use imperative mood ("add" not "added")
- Body is free-form, may have multiple paragraphs
- Footer token MUST use `-` instead of spaces (except `BREAKING CHANGE`)
- `BREAKING CHANGE` MUST be uppercase
- NEVER include AI-generated markers, Claude Code references, or `Co-Authored-By: Claude` footers

## Examples

### Feature with breaking change footer
```
feat: allow provided config object to extend other configs

BREAKING CHANGE: `extends` key in config file is now used for extending other config files
```

### Breaking change with `!`
```
feat(api)!: send an email to the customer when a product is shipped
```

### Breaking change with exclamation mark and footer
```
chore!: drop support for Node 6

BREAKING CHANGE: use JavaScript features not available in Node 6.
```

### Simple docs change (no body)
```
docs: correct spelling of CHANGELOG
```

### Feature with scope
```
feat(lang): add Polish language
```

### Fix with multi-paragraph body and footers
```
fix: prevent racing of requests

Introduce a request id and a reference to latest request. Dismiss
incoming responses other than from latest request.

Remove timeouts which were used to mitigate the racing issue but are
obsolete now.

Reviewed-by: Z
Refs: #123
```

### Revert commit
```
revert: let us never again speak of the noodle incident

Refs: 676104e, a215868
```

## Footer Formats

Footers follow git trailer format:
- `Token: value` or `Token #value`
- Common footers: `Refs:`, `Closes:`, `Reviewed-by:`, `Co-authored-by:`
- `BREAKING CHANGE: description` for breaking changes

## Interactive Mode

If changes are complex or ambiguous, ask the user:
- Which files to include in the commit
- What type of change this represents
- If there are breaking changes
- If they want to split into multiple commits (encouraged by spec)
