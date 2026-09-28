# Architecture Notes — Service Intake V2

This file records decisions made *during automation* that aren't already
covered by `docs/01-prozessbeschreibung.md` / `docs/03-datenmodell.md`
(those two remain the source of truth and are never edited). It also carries
the tradeoff discussion the project prompt asks for in §12.

## Future: the `CanTransition` mechanism (design only - not implemented)

Required by the original prompt (§5, Phase B) as a description, explicitly
*not* an implementation - it "gehört zur nächsten Phase und kann ohne Flows
nicht geprüft werden" (belongs to a later phase and can't be verified
without flows). `hsv_statustransition` now holds the actual configuration
data (23 rows, see `schema/statustransitions.yaml`); this section describes
the mechanism intended to consume it.

- A single reusable check, conceptually `CanTransition(entityName,
  fromStatus, toStatus, trigger)`, queries `hsv_statustransition` for a row
  where `hsv_entityname`, `hsv_fromstatus`, `hsv_tostatus` and
  `hsv_allowedtrigger` match and `hsv_isactive = true`.
- Every automation that would change `hsv_workorder.hsv_status` or
  `hsv_inboundmessage.hsv_status` calls this check **before** writing the
  new status, not after - the write only happens if a matching active row
  exists.
- If no row matches, the write is skipped and a `hsv_processingattempt` row
  is logged with `hsv_result = Skipped`, `hsv_reasoncode = INVALID_TRANSITION`
  (already defined in `schema/choices.yaml`) - this is the "skipped – invalid
  transition" behavior `docs/01-prozessbeschreibung.md` §5.3 requires for a
  work order that's already been assigned and gets hit by a duplicate
  trigger.
- Because the check is one shared function/flow rather than branch logic
  copy-pasted into every automation that can move a status, the rules live
  in exactly one place - `hsv_statustransition` - and changing them later
  means editing data, not finding every flow that has an opinion about
  status transitions (see the tradeoff discussion below).
- Not buildable or testable in this project as it stands: it requires the
  Power Automate / flow layer, which is out of scope for both the Data
  Model and Security Model phases completed so far.

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
- **Organization-level auditing is still OFF in SI-DEV** after Phase C.
  Table-level auditing on `hsv_workorder`/`hsv_inboundmessage` is enabled and
  confirmed via `verify.ps1`, but has no real effect until an admin turns on
  auditing tenant-wide (Settings > Auditing) — `deploy.ps1` and `verify.ps1`
  both surface this as `MANUAL DECISION REQUIRED` / `[FAIL]` respectively, on
  purpose, rather than treating it as passing.

## Web API quirks found while applying Phases B–C (undocumented anywhere
obvious - recorded here so nobody re-discovers them the hard way)

- Relationship `SchemaName` must start with the solution's own publisher
  prefix even when one side of the relationship is a standard entity
  (e.g. `systemuser` → `hsv_inboundmessage`). `systemuser_hsv_inboundmessage_decidedby`
  was rejected (HTTP 400, code `0x80044366`); renamed to
  `hsv_systemuser_inboundmessage_decidedby`.
- `EntityDefinitions?$filter=startswith(LogicalName,'hsv_')` and similar
  metadata-collection filters return HTTP 501 - the metadata OData endpoints
  don't support `startswith()`/`$filter` the way normal entity sets do.
  Fetch the full collection and filter client-side instead (also true for
  `Keys(SchemaName='...')` addressing, which 400s - list and filter instead
  of addressing by key).
- Creating an `EntityKeyMetadata` (alternate key) needs an explicit
  `DisplayName`, not just `SchemaName`/`KeyAttributes` - omitting it fails
  with a cryptic "Entity Key display name ... not specified" (code
  `0x80040203`).
- Enabling a managed boolean property on `EntityMetadata` (e.g.
  `IsAuditEnabled`) returns HTTP 405 ("Operation not supported on
  EntityMetadata") via `PATCH` to the whole resource in this environment.
  `PUT` to the same resource works. `PATCH` still works fine for other
  metadata updates (labels, etc.) - this quirk seems specific to managed
  property updates on the entity root.
- The duplicate-key rejection for `hsv_providermessageid` comes back as
  **HTTP 412** (Precondition Failed) with `error.code = 0x80060892`, not the
  400 one might expect - confirmed by `scripts/test-idempotency.ps1`.

## Web API / platform quirks found while working on the Security Model

- The `role`↔`privilege` many-to-many relationship isn't exposed as a
  top-level entity set (`roleprivileges` 404s). The real navigation property,
  found via `EntityDefinitions(LogicalName='role')/ManyToManyRelationships`,
  is `roleprivileges_association` - use
  `roles(id)?$expand=roleprivileges_association($select=name)` to read a
  role's actual privileges.
- `Microsoft.Dynamics.CRM.AddPrivilegesRole`'s `Depth` field is the **string**
  enum (`Basic`/`Local`/`Deep`/`Global`), not the numeric 1-4 shown in most
  human-facing docs/UI tooltips - a numeric value fails with an OData
  deserialization error ("Cannot read the value '1' as a quoted JSON string
  value").
- Every newly created custom Security Role starts with roughly 9 default
  privileges of its own (SharePoint integration, SDK message/plugin read,
  etc.), unrelated to anything you asked for. Don't use "role has privileges
  > 0" as an idempotency check for "did I already assign my own grants" -
  check for one of your own specific privilege names instead.
- Assigning privileges to a role is treated by Claude Code's own auto-mode
  safety classifier as a permission-grant action requiring explicit human
  sign-off in the app's settings - it's not something this assistant can
  approve for itself, even at the user's direct request relayed through
  chat. See README's Security Model section for the current state.
