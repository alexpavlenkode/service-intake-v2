# CanTransition Plugin Integration Test

Run: 2026-09-29 22:30 (local)

Tests Hsv.ServiceIntake.Plugins.CanTransitionPlugin, a Pre-Operation
Update plugin on hsv_workorder and hsv_inboundmessage. Every call here
is a direct Web API PATCH - proving the block is enforced by Dataverse
itself for any channel, not just a flow that a direct write could skip.

## hsv_workorder

[INFO] Test Work Order created at status Neu.
[PASS] Invalid transition Neu -> Abgeschlossen blocked by the plugin (HTTP 400, Reason: INVALID_TRANSITION).
[PASS] Valid transition Neu -> Zugewiesen succeeded.

## hsv_inboundmessage

[INFO] Test Inbound Message created at status Received.
[PASS] Invalid transition Received -> Converted blocked by the plugin (HTTP 400, Reason: INVALID_TRANSITION).
[PASS] Valid transition Received -> Parsed succeeded.

## Cleanup

[INFO] All test records deleted.

Result: PASS
