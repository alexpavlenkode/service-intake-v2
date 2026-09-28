# Idempotency Integration Test

Run: 2026-09-28 23:51 (local)
Target: hsv_inboundmessage.hsv_providermessageid = TEST-IDEMPOTENCY-001

[PASS] Attempt 1 (first create): HTTP 201, record d122f4cf-86bb-f111-aaad-002248d8a892 created.
[PASS] Attempt 2 (duplicate create): correctly rejected. HTTP 412, error.code=0x80060892
[PASS] Control query: exactly 1 record exists with hsv_providermessageid = TEST-IDEMPOTENCY-001.
[INFO] Cleanup: test record d122f4cf-86bb-f111-aaad-002248d8a892 deleted.

Result: PASS
