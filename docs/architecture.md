# Architecture Notes — Service Intake V2

This file records decisions made *during automation* that aren't already
covered by `docs/01-prozessbeschreibung.md` / `docs/03-datenmodell.md`
(those two remain the source of truth and are never edited). It also carries
the tradeoff discussion the project prompt asks for in §12.

## Resolved discrepancy: solution name

The project prompt names the solution `HSVServiceIntakeV2` / "HSV Service
Intake V2" throughout (including the `verify.ps1` sample output and the
Definition of Done). `docs/03-datenmodell.md` line 6 says the tables go into
a solution called "Reliable Service Intake" instead.

Per the prompt's own rule ("wenn Dokumentation und Promt divergieren, stop
and show it, don't decide silently"), this was flagged to the user before
any schema file was generated. **Decision (2026-09-28): `HSVServiceIntakeV2`
/ "HSV Service Intake V2" is authoritative.** `docs/03-datenmodell.md` is not
edited to match — it's marked read-only source material — but every
generated artifact (`schema/*.yaml`, `scripts/config.psd1`) uses the
prompt's name.

## V1 in this environment

Discovery found an existing solution `ServiceIntake` ("Service Intake"),
publisher `PavlenkoAutomation` (prefix `pa`), containing five custom tables
across **two** prefixes — `pa_` and `ap_`:

| V1 table | Nearest V2 concept |
| --- | --- |
| `pa_servicecustomer` | Standard `Account`/`Contact` + `hsv_serviceobject` (V2 deliberately prefers standard tables here) |
| `pa_workorder` | `hsv_workorder` |
| `pa_intakemessage` | `hsv_inboundmessage` |
| `ap_processingattempt` | `hsv_processingattempt` |
| `ap_dispatchrequest` | No direct V2 equivalent in the current datamodel |

V1 is read-only reference material per the brief. Nothing in this repo's
scripts ever targets `pa_*` or `ap_*` logical names, and `deploy.ps1` never
issues a DELETE against any metadata endpoint regardless of parameters.

`ap_dispatchrequest` has no mapped V2 concept — flagged here rather than
silently dropped, in case it turns out to matter once the flow/automation
phase starts.

## Tradeoffs (prompt §12)

**UI filter vs. Dataverse security.** A filtered view can always be worked
around by a direct record URL or API call; it's a convenience, not a
boundary. `hsv_workorder` ownership is User/Team precisely so "Techniker
sees only their own work orders" is enforced by the platform's own security
model (row-level, checked on every access path), not by what a particular
app happens to show. Section 9's non-functional requirement ("Rechte im
Datenmodell, nicht in der UI") and the future acceptance test ("Techniker B
liest Auftrag von Techniker A nicht, auch nicht per GUID") both fail if this
is done as a view filter instead.

**`AssignedTo` field vs. Owner.** A separate `AssignedTo` lookup would need
its own security trimming logic, duplicated everywhere ownership already
does this for free. Using `ownerid` means "assign to a technician" *is*
"change owner" — one write, one permission check, no parallel bookkeeping
that can drift from reality.

**Check-before-create vs. alternate key.** A flow step that queries "does
this `hsv_providermessageid` already exist?" before creating is racy under
concurrent execution (two runs can both see "no" and both create). The
alternate key on `hsv_inboundmessage.hsv_providermessageid` moves the
uniqueness guarantee into the database: `create` either succeeds or fails
with a duplicate-key error, and that failure *is* the `Duplicate` signal.
No race window.

**Provider duplicate vs. business duplicate.** These are answered by
different authorities on purpose. The provider (message) ID is
unambiguous — the same ID can only mean "already processed," so stage 1
decides automatically via the alternate key. Content similarity is
inherently fuzzy — "Wasserhahn Küche defekt" and "Wasserhahn Bad defekt" two
hours apart are similar and still two real orders. Automating that decision
risks silently swallowing a paying customer's second, legitimate request —
the most expensive possible mistake in this process (see
`docs/01-prozessbeschreibung.md` §6). So stage 2 only ever proposes; a human
decides, with the match reason shown and the decision recorded
(`hsv_duplicatedecision`, `hsv_decidedby`, `hsv_decidedon`).

**Hardcoded transitions in flows vs. `hsv_statustransition`.** Baking
"Parsed → Validated is allowed, Zugewiesen → Neu is not" into flow branch
logic means the rule is duplicated in every flow that can move a status, and
changing it later means finding and editing all of them. A configuration
table makes the state machine data instead of code: one place to read it,
one place to change it, and a single `CanTransition` check (next phase) can
enforce it everywhere instead of every flow author having to remember the
rules. It also gives the audit trail a concrete `INVALID_TRANSITION` reason
code instead of an inconsistent per-flow error message.

## Known gaps (see also `docs/discovery-report.md` → UNKNOWN / NEEDS DECISION)

- `hsv_statustransition.hsv_allowedtrigger` has no enumerated values in
  either source document. `schema/tables.yaml` ships a placeholder
  (`System`, `Disponent`, `Techniker`, `Plattformbetreuer`) explicitly marked
  as unconfirmed — do not treat it as authoritative.
- DateTime behavior (`UserLocal` vs `TimeZoneIndependent`) per column isn't
  specified in the source docs. `schema/tables.yaml` defaults
  system/audit-relevant timestamps to `TimeZoneIndependent` and the one
  human-facing appointment field (`hsv_workorder.hsv_DueDate`) to
  `UserLocal` — flagged at the top of that file, confirm before Phase B.
- **Organization-level auditing is currently OFF in SI-DEV.** Table-level
  auditing on `hsv_workorder`/`hsv_inboundmessage` (Phase C) will silently do
  nothing until an admin turns this on tenant-wide — `deploy.ps1 -DryRun`
  already surfaces this as `MANUAL DECISION REQUIRED`, not a warning that's
  easy to miss.
