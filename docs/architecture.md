# Architecture Notes — Service Intake V2

This file records decisions made *during automation* that aren't already
covered by `docs/01-prozessbeschreibung.md` / `docs/03-datenmodell.md`
(those two remain the source of truth and are never edited). It also carries
the tradeoff discussion the project prompt asks for in §12.

## The `CanTransition` mechanism - implemented as a C# plugin

Originally scoped (§5, Phase B of the prompt) as design-only - "gehört zur
nächsten Phase und kann ohne Flows nicht geprüft werden" (belongs to a later
phase, can't be verified without flows). Implemented later, at the user's
explicit request, as `Hsv.ServiceIntake.Plugins.CanTransitionPlugin`
(`plugins/Hsv.ServiceIntake.Plugins/`) rather than a flow - a **plugin**
was chosen deliberately over a Power Automate child flow or a Power Fx
low-code plugin, because it runs inside Dataverse's own transaction
pipeline: no channel (model-driven UI, Web API, a flow, a future integration)
can write an invalid status without going through it. A flow-based check can
always be bypassed by a direct API write; this can't.

**How it works:**

- Registered as a **Pre-Operation** step on `Update` of `hsv_workorder` and
  `hsv_inboundmessage`, filtered to fire only when `hsv_status` is part of
  the update (`filteringattributes = hsv_status`), with a Pre-Image
  (`hsv_status`) so the plugin can see the record's *current* status, not
  just the one being written.
- If the new status differs from the pre-image status, it queries
  `hsv_statustransition` for an active row matching
  `(hsv_entityname, hsv_fromstatus, hsv_tostatus)`. `hsv_fromstatus`/
  `hsv_tostatus` are stored as text labels (`"Neu"`, `"Zugewiesen"`, ...),
  not the numeric choice value, so the plugin hardcodes a numeric-value →
  label map per entity (`schema/choices.yaml`'s own documented, frozen
  values) to translate the `OptionSetValue` it receives into the label the
  transition table actually stores.
- No matching active row → `InvalidPluginExecutionException`, which aborts
  the whole transaction. Verified with a direct Web API `PATCH` (bypassing
  any UI or flow) in `tests/cantransition-report.md` /
  `scripts/test-cantransition.ps1`: `Neu → Abgeschlossen` and
  `Received → Converted` are both rejected outright; `Neu → Zugewiesen` and
  `Received → Parsed` both succeed.
- **Deliberately not enforced**: `hsv_allowedtrigger`. That column's values
  are an unconfirmed placeholder (flagged at the top of
  `schema/tables.yaml` - neither source doc enumerates them). Enforcing an
  unconfirmed rule in code that blocks production writes would be worse
  than not enforcing it; only the from/to transition itself is validated.
  Confirm the trigger values with the source-of-truth docs before adding
  that check.
- **Deliberately not this plugin's job**: logging a `hsv_processingattempt`
  row with `Result = Skipped` / `ReasonCode = INVALID_TRANSITION` for a
  blocked attempt (`docs/01-prozessbeschreibung.md` §5.3's "skipped –
  invalid transition" behavior). A Pre-Operation step that's about to fail
  the whole transaction shouldn't also try to commit a separate log write
  in the same breath - that's the calling flow's job, once the flow layer
  exists: catch this plugin's exception, then log it.

**Build/registration mechanics** (`plugins/Hsv.ServiceIntake.Plugins/`,
`scripts/register-plugin.ps1`): targets `net462` - Dataverse's plugin
sandbox only loads .NET Framework assemblies, not .NET Core/5+, so this is
the one piece of the project that needed the .NET Framework 4.6.2 Developer
Pack rather than just the .NET SDK. Dataverse's `pluginassemblies` API
rejects an unsigned assembly outright ("Public assembly must have public key
token") - the project's `.snk` strong-name key is committed (not a security
secret, just an assembly identity token; regenerating it on every redeploy
would just churn the assembly's identity for no benefit). Registration
itself (assembly content, plugin type, processing step, pre-image) goes
through the same `Invoke-DataverseApi` helper as everything else in this
project, not the Plugin Registration Tool - consistent with the project's
"everything scripted, nothing manual" approach.

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
one place to change it, and a single `CanTransition` check (now a plugin -
see above) can enforce it everywhere instead of every flow author having to remember the
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
- ~~Organization-level auditing is still OFF in SI-DEV~~ **Resolved**: the
  user explicitly asked for it to be turned on after reviewing the gap.
  `organizations.isauditenabled` was set to `true` via a plain data-record
  update (not a metadata or security-privilege change, so it wasn't subject
  to the same permission-grant gate as the Security Roles work) and
  `verify.ps1` now confirms it - table-level auditing on
  `hsv_workorder`/`hsv_inboundmessage` is genuinely active, not just
  configured and dormant.

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
- To read the *actual per-role depth* of a privilege (not just whether the
  role has it at all - "Read WorkOrder" existing tells you nothing about
  whether it's at User or Organization scope), use the unbound function
  `RetrieveRolePrivilegesRole(RoleId=<guid>)`. It returns `RolePrivileges`
  with `PrivilegeName` and `Depth` (same string enum as `AddPrivilegesRole`:
  `Basic`/`Local`/`Deep`/`Global`). `verify.ps1` uses this to check exact
  depth per privilege, not just presence (2026-09 hardening pass).

## Critical bug: non-ASCII strings silently corrupted end-to-end (2026-09)

Found while hardening `verify.ps1` to check Choice option labels exactly
(not just existence): the global choice `hsv_Trade`'s option 209710504
("Schließanlage") was stored in SI-DEV as `Schlie<U+FFFD>anlage` - the `ß`
had been destroyed. Root cause was two independent, compounding bugs, both
now fixed in `lib/Dataverse.psm1` / the various `Read-Yaml` helpers:

1. **Reading**: `schema/*.yaml` files have no BOM. Windows PowerShell 5.1's
   `Get-Content -Raw` without an explicit `-Encoding` falls back to the
   system codepage (not UTF-8) to decode them, which corrupts every German
   special character (`ß`, `ü`, `ö`, ...) at the moment the file is read -
   confirmed empirically: the UTF-8 bytes for `ß` (`C3 9F`) get
   misinterpreted as two Windows-1252 characters and then re-encoded as
   *four* UTF-8 bytes. Every script that reads schema YAML now passes
   `-Encoding UTF8` explicitly (`deploy.ps1`, `deploy-security.ps1`,
   `verify.ps1`, `seed-statustransitions.ps1`).
2. **Writing**: `Invoke-DataverseApi` passed `Invoke-WebRequest` a `[string]`
   body. PowerShell 5.1 encodes a string `-Body` using the system codepage
   regardless of the `Content-Type: charset=utf-8` header (setting it via
   `-Headers` rather than the dedicated `-ContentType` parameter does not
   make the call charset-aware) - so any non-ASCII character already
   correctly in memory still got mangled on the wire. Fixed by converting
   the JSON body to UTF-8 bytes ourselves
   (`[System.Text.Encoding]::UTF8.GetBytes($json)`) before assigning it to
   `-Body`, which bypasses PowerShell's string encoding entirely.

Both bugs had to compound to produce this specific corruption, which is
probably why it went unnoticed: labels without non-ASCII characters, and
the one place a literal was typed directly into a `-Command` string with
the right console codepage active, would have looked fine. Fixed live by
re-running `UpdateOptionValue` after both fixes landed, and verified by
writing the retrieved value to a file with `[System.IO.File]::WriteAllLines`
and reading the raw bytes rather than trusting a terminal's rendering
(terminal display encoding is a separate, cosmetic concern from what's
actually stored in Dataverse or in a file on disk).

## Schema-authoring gap found by the same hardening pass (2026-09)

`schema/tables.yaml` has always declared `hsv_inboundmessage.hsv_Account`
and `hsv_inboundmessage.hsv_ServiceObject` as Lookup columns ("Ergebnis der
Zuordnung"), but `schema/relationships.yaml` never listed the corresponding
relationships - and `deploy.ps1` creates Lookups exclusively by iterating
`relationships.yaml` (a Lookup column has no standalone "create column"
call in the Web API; it's always created together with its relationship).
Net effect: those two lookups were never actually created in SI-DEV, and
the *original* `verify.ps1` never caught it because it explicitly excluded
Lookup-typed columns from its per-column checks. Fixed by adding
`hsv_account_inboundmessage` and `hsv_serviceobject_inboundmessage` to
`relationships.yaml` (both `Restrict`, matching the sibling
`hsv_workorder` relationships to the same two tables) and creating them
live. `verify.ps1` now checks every Lookup's existence and target
entity too.
