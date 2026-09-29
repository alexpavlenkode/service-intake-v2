# Row-Level Security Access Test

Run: 2026-09-29 22:30 (local)

**Setup note**: SI-DEV is a Developer Plan environment with exactly one
licensed interactive human user. A second real browser session isn't
available, so this test impersonates a Dataverse Application User
('Test Techniker B', role HSV Techniker) via the Web API's
\CallerObjectId\ header instead. This exercises the identical
privilege-evaluation path Dataverse uses for every caller - it does
NOT demonstrate an actual second browser hitting a direct record URL,
since no second license exists to do that with.

[INFO] Test Account created: 6d42daa8-44bc-f111-aaad-002248d8a892
[INFO] Test Service Object created: 6e42daa8-44bc-f111-aaad-002248d8a892
[INFO] Test Work Order created: 6f42daa8-44bc-f111-aaad-002248d8a892 (owned by System Administrator, owner A)

## Before reassignment (Work Order owned by Owner A)

[PASS] Techniker B denied reading the work order by GUID directly (HTTP 403 - explicit access-rights denial, not a silent empty success).
[PASS] Techniker B's filtered list query for the same GUID returns 0 rows (silent security filtering, not an error).
[PASS] Techniker B denied outright on hsv_inboundmessage (HTTP 403 - role has no privilege on this table).

## Reassigning Owner: A -> Techniker B

[INFO] Owner changed to Techniker B.
[PASS] Techniker B can now read the work order by GUID after becoming its owner.

## Status transitions, as Techniker B (now the owner)

[PASS] Techniker B (owner) can perform the valid transition Neu -> Zugewiesen on their own record.
[PASS] Invalid transition Zugewiesen -> Abgeschlossen correctly blocked for the owning Techniker (business rule, not an access-rights error).

**Note on 'access disappears for Owner A'**: the caller used to create
and own this record (Alex) is System Administrator, with Organization-
level access to every table regardless of ownership - that's the only
real identity available in this Developer Plan environment. A
genuine 'disappears for A' check needs A to be scoped to User-depth
access too (i.e. also a Techniker), which isn't demonstrable without a
second real user or a second Application User configured with a
*non*-admin role - not done here, flagged rather than assumed.

## Create-time status validation (hsv_statustransition as source of truth, not a plugin constant)

[PASS] Creating a hsv_workorder directly in status 'Zugewiesen' correctly blocked (only 'Neu' is a valid initial status).
[PASS] Creating a hsv_workorder in status 'Neu' (the configured initial status) succeeds.
[PASS] Creating a hsv_inboundmessage directly in status 'Parsed' correctly blocked (only 'Received' is a valid initial status).

## Cleanup

[INFO] Test Work Order(s), Service Object, and Account deleted.
