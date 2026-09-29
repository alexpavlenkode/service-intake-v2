# Service Intake V2

Automated Dataverse deployment for the Service Intake V2 data model, targeting
the **SI-DEV** environment. Source of truth for the business process and data
model: [`docs/01-prozessbeschreibung.md`](docs/01-prozessbeschreibung.md) and
[`docs/03-datenmodell.md`](docs/03-datenmodell.md) — this repo automates their
deployment, it doesn't redefine them.

Everything already in SI-DEV before this project started is treated as V1:
reference material, never modified or deleted. See
[`docs/discovery-report.md`](docs/discovery-report.md) for what V1 actually
contains and [`docs/architecture.md`](docs/architecture.md) for how it maps to
V2's tables.

## Prerequisites

- PAC CLI, authenticated against SI-DEV (`pac auth list` shows an active profile).
- Windows PowerShell 5.1 (this project targets it directly; PowerShell 7 is not required).
- `Az.Accounts`, `powershell-yaml` modules (installed to `CurrentUser` scope automatically the first time `scripts/connect.ps1` or `scripts/deploy.ps1` needs them — see `docs/deployment.md` for why `Az.Accounts` and not Azure CLI or device-code auth).

## Usage

```powershell
# 1. Establish / verify the Dataverse connection (interactive browser sign-in on first run)
powershell -File scripts\connect.ps1

# 2. Read-only inventory of SI-DEV -> docs/discovery-report.md
powershell -File scripts\discover.ps1

# 3. Plan the deployment - prints CREATE/SKIP/VERIFY/CONFLICT/MANUAL DECISION REQUIRED, writes nothing
powershell -File scripts\deploy.ps1 -DryRun

# 4. Apply - only after reviewing the dry run and getting sign-off
powershell -File scripts\deploy.ps1 -Apply

# 5. Verify actual SI-DEV state against schema/*.yaml
powershell -File scripts\verify.ps1

# 6. Idempotency integration test - report written to tests\idempotency-report.md
powershell -File scripts\test-idempotency.ps1

# 7. Export and unpack the solution once everything verifies
pac solution export --name HSVServiceIntakeV2 --path solution\HSVServiceIntakeV2.zip --overwrite
pac solution unpack --zipfile solution\HSVServiceIntakeV2.zip --folder solution\unpacked --packagetype Unmanaged --allowWrite true

# 8. Security roles and status-transition config data
powershell -File scripts\deploy-security.ps1 -Apply
powershell -File scripts\seed-statustransitions.ps1 -Apply

# 9. CanTransition plugin: build, register, test
dotnet build plugins\Hsv.ServiceIntake.Plugins -c Release
powershell -File scripts\register-plugin.ps1 -Apply
powershell -File scripts\test-cantransition.ps1
```

`deploy.ps1 -Apply` also accepts `-OnlyTables`, `-OnlyRelationships`, `-OnlyKeys` (arrays) to scope a run to specific components - useful for cautiously rolling out one risky change at a time. Pass arrays natively (`& .\scripts\deploy.ps1 -Apply -OnlyTables @('hsv_workorder')`) rather than through a nested `powershell -File` call with comma-separated values - the latter parses as a single string, not an array, and silently does nothing.

## Repository layout

```
service-intake-v2/
├── docs/          01-prozessbeschreibung.md, 03-datenmodell.md (source of truth, read-only)
│                  architecture.md, deployment.md, discovery-report.md
├── schema/        choices.yaml, tables.yaml, relationships.yaml, keys.yaml, auditing.yaml
├── scripts/       connect.ps1, discover.ps1, deploy.ps1, verify.ps1, config.psd1, lib/
├── solution/      exported/unpacked solution (Phase D)
├── tests/         idempotency integration test report (Phase D)
└── logs/          local run logs, excluded from git
```

## Hard rules enforced in code, not just intent

- No script ever issues `DELETE` against a metadata endpoint
  (`EntityDefinitions`, `Attributes`, `Keys`, `RelationshipDefinitions`,
  `GlobalOptionSetDefinitions`) — enforced in `Invoke-DataverseApi` itself,
  not just by convention.
- Access tokens live only in process memory. Never written to disk, `.env`,
  git, or logs.
- `deploy.ps1` requires an explicit `-DryRun` or `-Apply` — there is no
  implicit default that could write to SI-DEV by accident.

## Status

**Phases A–D complete.** Publisher, solution, 7 global choices, 5 tables,
10 relationships, 4 alternate keys (all `Active`), and table-level auditing
on `hsv_workorder`/`hsv_inboundmessage` are live in SI-DEV.

The idempotency integration test (`scripts/test-idempotency.ps1`,
report in `tests/idempotency-report.md`) confirms the alternate key on
`hsv_providermessageid` rejects a duplicate `POST` outright (HTTP 412,
`error.code=0x80060892`) rather than relying on application-level
check-then-create logic.

The solution is exported and unpacked at `solution/HSVServiceIntakeV2.zip`
/ `solution/unpacked/`.

**Security Model complete (started beyond the original brief's scope, at the user's request):**

- `schema/statustransitions.yaml` + `scripts/seed-statustransitions.ps1`:
  23 configuration rows in `hsv_statustransition` (17 message transitions,
  6 work order transitions incl. 3 inferred `Storniert` paths not explicit
  in the source docs - flagged in the yaml). Applied and idempotent.
- `schema/security.yaml` + `scripts/deploy-security.ps1`: 4 Security Roles
  (`HSV Disponent` 23 privileges, `HSV Techniker` 6, `HSV Auditor` 6,
  `HSV Plattformbetreuer` 17) live in SI-DEV, matching
  `docs/03-datenmodell.md` §6 exactly. Assigning role privileges was
  initially denied by the Claude Code auto-mode safety classifier as a
  permission-grant action - required an explicit allow rule added by the
  user directly in `.claude/settings.local.json` (not something the
  assistant could add on its own) before it could proceed.
  The pre-existing V1 role `SI Auditor` was confirmed untouched throughout.
**`scripts/verify.ps1` passes 94/94 checks.** Organization-level auditing was
turned on at the user's explicit request (`organizations.isauditenabled =
true`, a plain data-record update, not a metadata/security change) -
table-level auditing on `hsv_workorder`/`hsv_inboundmessage` is now actually
active, not just configured and dormant.

**`CanTransition` — implemented as a C# plugin** (`plugins/Hsv.ServiceIntake.Plugins/`,
registered via `scripts/register-plugin.ps1`). A Pre-Operation Update step on
`hsv_workorder` and `hsv_inboundmessage` blocks any status write that isn't
an active row in `hsv_statustransition` - enforced by Dataverse itself, so
no channel (UI, Web API, a future flow) can bypass it, unlike a flow-only
check. Verified with direct Web API `PATCH` calls in
`scripts/test-cantransition.ps1` / `tests/cantransition-report.md`: both
`Neu → Abgeschlossen` and `Received → Converted` are rejected outright;
`Neu → Zugewiesen` and `Received → Parsed` both succeed. Not enforced:
`hsv_allowedtrigger` (its values are an unconfirmed placeholder - see
`docs/architecture.md`).

## Reproducibility & evidence

- Re-running `deploy.ps1 -Apply` against the already-deployed SI-DEV: 0
  `CREATE`, 30 `VERIFY` - nothing manual, nothing drifts.
- The entire Data Model + Security Model was deployed from scratch into a
  second clean environment (SI-TEST) using the same scripts and
  `schema/*.yaml`, only the config file's environment/URL differing - see
  `scripts/config.si-test.psd1` and `evidence/deploy-output-SI-TEST-from-scratch.txt`.
- `evidence/` collects the artifacts backing every claim above: verify
  transcripts, the idempotency/access/CanTransition test reports. See
  `evidence/README.md`.
- Row-level security (the `HSV Techniker` role's User-depth scoping) is
  proven, not just configured, in `tests/access-test-report.md` - via
  `CallerObjectId` impersonation of a Dataverse Application User, since
  SI-DEV's Developer Plan license doesn't allow a second real interactive
  user for an actual two-browser test.
- Repository: private on GitHub, full commit history scanned for
  tokens/secrets before the first push (clean).
