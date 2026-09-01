# AGENTS.md

## Using a2 itself

The kernel bin `a2` is the product's only required interface: run `a2 <subcommand> --json` as a
subprocess and read one JSON envelope from stdout. See `docs/agents/a2-cli.md` (exit codes,
dangerous arbitration, guidance-on-refusal, plugins). The CLI's own `--help` is the spec — the
doc points at it rather than duplicating it.

## Git conventions

Trunk is `main` — git flow with the `develop`/`main` pair collapsed into `main` until releases
need separating. Short-lived branches off `main`, merged back into `main`, deleted on merge:

- `feature/<slug>` — new work (tickets, refactors)
- `fix/<slug>` — bug fixes; `hotfix/<slug>` for emergencies on a shipped version
- `release/<version>` — release stabilisation; tag `v<version>` on merge
- `research/<slug>` — investigation docs; the doc merges into `main` even when the idea is rejected

Agent worktree branches (`worktree-*`) count as feature branches: merge, then delete.
Commit subjects follow conventional commits — `type(scope): summary`, Chinese summary (see `git log`).

## Agent skills

### Issue tracker

Issues and specs live as markdown files under `.scratch/<feature>/` in this repo (no remote tracker). See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical vocabulary — `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context — one `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
