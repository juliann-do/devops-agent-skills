# Changelog

All notable changes to DevOps Skills. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the collection uses
semantic versioning, and each skill also carries its own `metadata.version`.

## [Unreleased]

### Added

- **`/friday-logwork`** (v1.0.0) — personal Jira timesheet assistant. Creates
  native Jira worklogs (never Tempo, never edits or deletes) against INF
  tickets that reached Done during the week, distributing 7h/day by
  complexity. Idempotent, so re-running mid-week never double-logs. The one
  skill in this collection that writes, and the one hardcoded to a single
  identity.

### Changed

- **All skills** — new "Sources and reasoning" section: conclusions drawn
  from research end with a **References** list of doc links, and every
  log/event/metric/error trace is preceded by one line saying what it looks
  for and why.
- **`/friday-logwork`** (v1.0.0 → v1.1.0) — now asks about time off before
  logging anything. A single consolidated question covers full annual leave
  days, half days, and partial absences (late start, early finish,
  appointment, given as `HH:MM–HH:MM`), and the answer becomes a per-day
  capacity table that drives both the hour totals and the worklog start
  times. A 0h day gets no worklog; a `09:00–10:00` late start yields 6h
  starting at `10:00`. Absence overlapping the `12:00–13:00` lunch break is
  not deducted. With no answer, the run still assumes a full 7h/day but must
  say so in its summary.
- **`/friday-logwork`** (v1.1.0 → v1.2.0) — holidays and time off now get
  logged instead of left empty. A Vietnam public holiday gets 7h on HAE-17
  ("[TORILAB] Holidays & Events"). Annual leave, half days, and partial
  absences go on the MISC absence ticket whose date range contains the
  absence date (e.g. a September day goes on `[HR] [Sep 2026] Absence`), at
  the absence's real start time. If no MISC ticket covers the date yet, the
  absence is reported but not logged, and no ticket is created. Every weekday
  now totals 7h.
- **`/friday-logwork`** (v1.2.0 → v1.3.0) — the time-off question now also
  asks about overtime (day, window, ticket). Each OT entry is logged once,
  on top of the 7h, at its real start time on the ticket the user named.
- **`/friday-logwork`** (v1.3.0 → v1.4.0) — OT worklogs now have Tempo's
  **OT** checkbox ticked. They are created through the Tempo REST API
  (`POST /4/worklogs` with the OT work attribute, token from
  `TEMPO_API_TOKEN`), and an existing OT worklog with no tick gets it added
  via `POST /4/worklogs/work-attribute-values`. The skill never calls Tempo
  `PUT`/`DELETE`. Worklogs outside office hours no longer count as normal
  hours in the idempotency check. Without a token, it asks before falling
  back to plain Jira worklogs and lists the ones to tick by hand.

## [1.1.0] — 2026-08-01

### Added

- **`/dr-review`** (v1.0.0) — backup, restore, and disaster-recovery readiness.
  Produces a recovery posture table (stated vs. achievable RPO/RTO, last proven
  restore), distinguishes config evidence from restore-proven evidence, and
  checks backup isolation and immutability. Includes a `scenario <what is lost>`
  variant that walks a single loss end to end.
- **`/db-review`** (v1.0.0) — database operations and schema-change safety.
  Produces a migration verdict table (lock taken, what it blocks, estimated
  duration at real row counts, reversibility), plus connection-pool math,
  indexing, and replication review. `migration <path|branch>` works as a
  pre-merge gate.
- **`/runbook`** (v1.0.0) — writes one runbook per failure mode under
  `runbooks/`, with detection signal, first-60-seconds checks, a triage decision
  tree, mitigations carrying blast radius and rollback, and escalation. `audit`
  mode reviews existing runbooks for staleness and coverage gaps.
- **`docs/skill-contract.md`** — the shared contract every skill links to: hard
  rules, environment preflight, output locations, effort levels, the canonical
  findings table, the reporting contract, cross-skill routing, and the finishing
  quality bar.
- **`docs/skill-template.md`** — authoring template and review checklist for new
  skills.
- **Environment preflight** — skills now confirm and report which cluster,
  account, workspace, and commit their findings describe before making live
  claims, and downgrade confidence when tooling is missing or unauthenticated.
- **`CONTRIBUTING.md`** and this changelog.
- Second sample output: `examples/incident-2026-03-11-checkout-5xx.md`, an
  `/incident` investigation document.
- Every skill gained a **Related skills** section (explicit handoffs instead of
  overlapping depth) and a domain-specific **Before you finish** self-check.

### Changed

- **Findings tables now carry a `Conf` (confidence) column** in every skill —
  previously the finding format required confidence but the summary tables
  dropped it, which invited false certainty. Tables also render correctly now
  (they were missing separator rows).
- `/release-readiness` gate table is explicit, and adds an **`UNVERIFIED`**
  verdict that must never be counted as `PASS`.
- `/cost` must state the **basis** of every saving estimate (billing line item,
  list price × count, utilization window) plus currency and period.
- Effort keywords (`quick` / `standard` / `deep`) are now defined once in the
  contract with concrete coverage, subagent, and probe budgets, instead of being
  described loosely per skill.
- `docs/finding-format.md` defines the canonical summary table and links the
  contract.
- Plan output fallback directory standardized to `devops-plans/` (was
  `advisor-plans/` in `/audit` only).
- All ten original skills bumped to `metadata.version` 1.1.0.

### Fixed

- `.claude-plugin/plugin.json` `homepage` and `repository` pointed at the
  placeholder `github.com/your-org/devops-skills`; they now point at the real
  repository. Added an author URL and keywords for the new skills.

## [1.0.0] — 2026-07-12

### Added

- Initial release: `/incident`, `/audit`, `/k8s-review`, `/terraform-review`,
  `/pipeline-review`, `/docker-review`, `/observability`, `/security-review`,
  `/cost`, `/release-readiness`.
- Shared `docs/finding-format.md`, `docs/plan-template.md`, and
  `docs/investigation-template.md`.
- Plugin and marketplace manifests under `.claude-plugin/`.
- Sample output: `examples/k8s-review-001-api-reliability-hardening.md`.
