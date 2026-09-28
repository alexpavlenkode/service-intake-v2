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

# 5. Verify actual SI-DEV state against schema/*.yaml (Phase D)
powershell -File scripts\verify.ps1

# 6. Export the solution once everything verifies (Phase D)
pac solution export --path solution\HSVServiceIntakeV2.zip --name HSVServiceIntakeV2
pac solution unpack --zipfile solution\HSVServiceIntakeV2.zip --folder solution\unpacked
```

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

**Phase A (discovery, YAML spec, dry run) complete.** See
`docs/discovery-report.md` for the full inventory and
`scripts/deploy.ps1 -DryRun` output for the plan. Phase B (publisher,
solution, choices, tables) has not started — waiting on review of the above.
