# Logging Standards (Acme Engineering Handbook)
- All services emit structured JSON logs to stdout; no log files on disk.
- Required fields: `ts` (RFC3339), `level`, `service`, `trace_id`, `msg`.
- Levels: ERROR pages on-call, WARN is reviewed weekly, INFO is business events, DEBUG is off in production.
- Never log secrets, tokens, card numbers or personal data. Mask with `***`.
- Retention: 30 days hot, 1 year cold storage. Sampling above 1,000 lines/s per pod is allowed for DEBUG only.
- Every request log must carry the gateway request ID (`x-request-id`) so it can be traced end to end.
