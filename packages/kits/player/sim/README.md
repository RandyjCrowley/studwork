# Player multi-server scenarios

Run `tools/test-sim packages/kits/player/sim/Player.spec.luau` or `tools/test packages/kits/player`.
The default shared simulation runner selects its own folder; pass this kit path explicitly.

The scenarios boot the real Codes, Settings and Economy server parts through the normal module
loader. Servers share the simulated cloud and use real ProfileStore session logic. Only external
services and the generated Settings wire transport are faked.

The suite covers double submit and rejoin, three concurrent servers filling a ten-use cap,
profile-save uncertainty, transaction rollback and reservation release, lockout and live test
codes, ConfigService additions/disables, owner-only setting snapshots and acknowledgements,
malformed writes and removed save IDs, cap-policy disagreement, and recovery after catalog
removal. Every write of the contended capped ledger is checked against its durable limit.

This does not establish real-service quota behavior or production latency. The benchmark beside
this folder measures enabled idle module cost on a real all-kit workload, separately from these
transaction and fault scenarios.
