# Idempotency Integration Test

Run: 2026-09-29 22:30 (local)
Target: hsv_inboundmessage.hsv_providermessageid = TEST-IDEMPOTENCY-001

[PASS] Attempt 1 (first create): HTTP 201, record 04dd979f-44bc-f111-aaad-002248d8a892 created.
[PASS] Attempt 2 (duplicate create): correctly rejected. HTTP 412, error.code=0x80060892
[PASS] Control query: exactly 1 record exists with hsv_providermessageid = TEST-IDEMPOTENCY-001.
[PASS] The single message now has 2 ProcessingAttempts: 1=Success, 2=Skipped/TECHNICAL_DUPLICATE (linked via hsv_PreviousAttempt) - the rejected repeat delivery is recorded, not silently dropped.
[INFO] Cleanup: test record 04dd979f-44bc-f111-aaad-002248d8a892 (and its ProcessingAttempts) deleted.

Result: PASS
