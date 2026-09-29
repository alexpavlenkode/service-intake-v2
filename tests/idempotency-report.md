# Idempotency Integration Test

Run: 2026-09-29 21:52 (local)
Target: hsv_inboundmessage.hsv_providermessageid = TEST-IDEMPOTENCY-001

[PASS] Attempt 1 (first create): HTTP 201, record 98ecac5e-3fbc-f111-aaad-002248d8a892 created.
[PASS] Attempt 2 (duplicate create): correctly rejected. HTTP 412, error.code=0x80060892
[PASS] Control query: exactly 1 record exists with hsv_providermessageid = TEST-IDEMPOTENCY-001.
[PASS] The single message now has 2 ProcessingAttempts: 1=Success, 2=Skipped/TECHNICAL_DUPLICATE (linked via hsv_PreviousAttempt) - the rejected repeat delivery is recorded, not silently dropped.
[INFO] Cleanup: test record 98ecac5e-3fbc-f111-aaad-002248d8a892 (and its ProcessingAttempts) deleted.

Result: PASS
