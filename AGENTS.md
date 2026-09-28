# Project language

Use English for all project content and project-related communication, including
source code identifiers, comments, UI labels, errors, logs, documentation, tests,
file names, commit messages, and pull request descriptions. Keep future additions
and changes in English, even when a request is written in another language.

# Versioning

Keep the app version derived from Git history through `scripts/Get-Version.ps1`.
Each new commit advances `0.1.<reachable commit count>`. Preserve the commit hash
and modified-build marker in the UI and embedded package metadata. Build from
complete history and rebuild packages after commits; do not add manual per-commit
version bumps or commit hooks.
