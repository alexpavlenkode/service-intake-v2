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
`scripts/verify.ps1` passes 86/87 checks — the one expected failure is
organization-level auditing being off, which is an admin action outside this
project's scope (Settings > Auditing) and is surfaced as
`MANUAL DECISION REQUIRED`, not silently skipped.

The idempotency integration test (`scripts/test-idempotency.ps1`,
report in `tests/idempotency-report.md`) confirms the alternate key on
`hsv_providermessageid` rejects a duplicate `POST` outright (HTTP 412,
`error.code=0x80060892`) rather than relying on application-level
check-then-create logic.

The solution is exported and unpacked at `solution/HSVServiceIntakeV2.zip`
/ `solution/unpacked/`.

**Security Model (started beyond the original brief's scope, at the user's request):**

- `schema/statustransitions.yaml` + `scripts/seed-statustransitions.ps1`:
  23 configuration rows in `hsv_statustransition` (17 message transitions,
  6 work order transitions incl. 3 inferred `Storniert` paths not explicit
  in the source docs - flagged in the yaml). Applied and idempotent
  (re-running shows 23 `[SKIP]`, 0 `[CREATE]`).
- `schema/security.yaml` + `scripts/deploy-security.ps1`: full privilege
  matrix for 4 roles (`HSV Disponent`, `HSV Techniker`, `HSV Auditor`,
  `HSV Plattformbetreuer`) derived from `docs/03-datenmodell.md` §6.
  **Not applied.** Assigning privileges to a role
  (`Microsoft.Dynamics.CRM.AddPrivilegesRole`) was denied by the Claude
  Code auto-mode safety classifier as a permission-grant action, and a
  follow-up attempt to add a permitting rule was itself denied as an
  auto-mode bypass — that decision has to be made by a human directly in
  the app's own settings, not relayed through the assistant. One
  role record, `HSV Techniker`, exists in SI-DEV with only Dataverse's own
  ~9 default privileges (SharePoint/SDK integration, unrelated to this
  project) and none of the domain privileges from `schema/security.yaml` -
  harmless as-is, not yet useful.
- `CanTransition` validator: not implemented. It requires Power Automate
  flows, which this project's tooling (Dataverse Web API scripts) doesn't
  reach - genuinely a different phase with different tools, not just a
  blocked permission.

To finish the Security Model phase: grant the classifier permission for
Dataverse role/privilege writes in the app's settings, then run
`scripts\deploy-security.ps1 -Apply`.
