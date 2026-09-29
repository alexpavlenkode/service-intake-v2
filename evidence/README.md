# Evidence

Artifacts proving the claims in the top-level README and `docs/architecture.md`
are actual observed behavior, not just assertions.

| File | Proves |
| --- | --- |
| `verify-output-SI-DEV.txt` | Fresh `scripts/verify.ps1` run against SI-DEV: 94/94 `[PASS]`, zero gaps. |
| `deploy-idempotent-rerun-SI-DEV.txt` | Re-running `deploy.ps1 -Apply` against the already-deployed SI-DEV produces 30 `[VERIFY]`, **0 `[CREATE]`** - nothing was manually clicked, everything is declarative. |
| `deploy-output-SI-TEST-from-scratch.txt` | Full deployment from scratch into a second, previously empty environment (SI-TEST), using the identical scripts and `schema/*.yaml`, only the config file's environment/URL differs. Proves reproducibility - not just idempotency on the one environment that happened to be hand-tuned. |
| `idempotency-report.md` | `hsv_providermessageid`'s alternate key rejects a duplicate `POST` outright (HTTP 412, `error.code=0x80060892`), not application-level check-then-create logic. |
| `access-test-report.md` | The `HSV Techniker` security role's row-level scoping is enforced by Dataverse itself (HTTP 403 before ownership, success after), not just configured and untested. |
| `cantransition-report.md` | The `CanTransition` plugin blocks invalid status transitions (`Neu → Abgeschlossen`, `Received → Converted`) via a direct Web API `PATCH` - not just described in `docs/architecture.md` - while valid ones (`Neu → Zugewiesen`, `Received → Parsed`) still succeed. |
| `demo-flight-report-sample.html` | Open this one directly in a browser. A `scripts/demo-pipeline.ps1` run visualized: 4 synthetic messages, each genuinely processed by SI-DEV (idempotency check, business-key duplicate lookup, real `hsv_processingattempt` rows), shown flying through Ingest → Parse → Validate → Duplicate Check → Decision. Click any node for what happened at that stage. `demo-flight-trace-sample.json` is the raw data behind it. |

## Known gap: no screenshots

A clean `verify.ps1` transcript for SI-TEST specifically is still pending -
three consecutive attempts hit a shared Dataverse SQL elastic-pool
throttling error (`Resource ID: 1. The request limit for the elastic pool
is 840 and has been reached`), which is Developer Plan shared-infrastructure
capacity, not a bug here. `deploy-output-SI-TEST-from-scratch.txt` already
shows every component (including alternate keys reaching `Active`) created
successfully, which is strong evidence on its own.

Screenshots of the Maker Portal (solution, tables, security roles) were
attempted via the built-in browser but require an interactive sign-in
(separate browser context from the PowerShell/Az.Accounts session used for
everything else in this project) - the assistant does not enter user
credentials. If you want these for a demo, sign in once in the Browser pane
yourself and ask for screenshots to be captured then.
