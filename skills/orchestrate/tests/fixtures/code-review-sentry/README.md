# Code-review fixtures: silenced error reporting (claude-agents#180)

Plain unified-diff text files, one per way a "fix" for a Sentry-sourced ticket can silence the error instead of fixing it.
The rule numbers are those of the **HIGH — silenced error reporting (Sentry-sourced tickets)** block in `agents/code-reviewer.md`.
Each positive fixture is described by exactly one rule; `test-issue180-reviewer-sentry-silencing.sh` pins that mapping.
Paths and names are placeholders, not taken from any real repository.

| Fixture | Rule | What the diff does |
|---|---|---|
| `remove-capture.diff` | rule 1 | deletes `Sentry.captureException` from the catch and leaves a `console.warn` in its place |
| `downgrade-level.diff` | rule 2 | changes the capture's level from `error` to `warning` |
| `empty-catch.diff` | rule 3 | wraps the failing call in a catch that neither rethrows nor captures |
| `ignore-list.diff` | rule 4 | adds the error message to `ignoreErrors` in the Sentry init |
| `real-fix.diff` | no rule (negative) | adds a null check before the failing call and keeps the capture call: the actual fix, not a finding |

Rule 5 (deleting or weakening a Sentry guard test) has no fixture here: it concerns test files, and these fixtures are non-test code.
