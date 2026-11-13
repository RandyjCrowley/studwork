# Player benchmark

Run `lune run packages/kits/player/bench/run 3` from the repository root.

The runner loads the shared replication benchmark unchanged from disk and adds a local
`PLAYER-ALL` variant in memory. Exact replacement anchors fail closed if the reference changes;
no shared variant list or measurement loop is edited. `Config.luau` enables Codes and Settings
with a capped test promotion and one custom saved preference.

Both variants run the same 50 players, 100 inventory items per player and 60 ticks, including
Economy income, one Leaderboards submission per player per tick, replication snapshots and the
real charm-sync diff. The module load and first-state warm-up precede measurement, as in the
reference. No promotion or preference is changed every tick: this measures their enabled idle
cost on top of the normal game workload, not redemption latency, datastore throughput or UI
rendering. All external services are faked.

Compare the median tick time with the v1.7.0 budget of 0.94 ms/tick and with the simultaneously
measured `KITS-ALL` baseline. Report the spread and GC-inclusive mean separately.
