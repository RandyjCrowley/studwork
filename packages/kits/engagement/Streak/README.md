# Streak (engagement kit, v1.3.0 module)

Layout (v1.3.1, one folder per module, module-api.md §1): `module.luau` (definition), `server/` (server part; the code files named below live there). Rojo: `ReplicatedStorage.Modules.Streak` (module, client, shared), `ServerScriptService.Modules.Streak` (server).

Definition: `module.luau` (optional dependency: Economy). Server part: `server/init.luau`.

api: `onDaily(handler) -> Connection`, `get(player) -> { day, lastDay }` (a copy),
`signals.StreakAdvanced(player, day)`. Save section `streak` = `{ streak = { day, lastDay } }` (v1.2 shape).

- `StreakMath.luau` - pure day math in a time zone + reward lookup (`StreakMath.spec.luau`).
- `init.luau` - evaluates on data load and every 60 s (players online across midnight).

Config (`config.Streak.streak`): `graceHours` (default 6), `utcOffsetHours` (-14..14, default 0 = UTC,
the v1.2 days), `rewards = { { day, amount, currency? } }`, `loopAfter`.

Rules (local day = `(os.time() + utcOffsetHours * 3600) // 86400`): same day -> nothing; next day -> +1;
one missed day forgiven within `graceHours` after the missed day ended (local time); clock skew ->
unchanged; otherwise reset to 1.

On a counted day, ONE tx writes the streak and grants the reward through
`ctx.depsTx[Economy].grant(tx, amount, "streak", currency?)` (Economy's primary currency when `currency`
is nil); then `StreakAdvanced` / `onDaily`, a toast and `analytics.custom("StreakDay", day)`.

Console: `streak dump [userId]`, `streak advance [userId]` (Studio: pretends the last day was yesterday).
