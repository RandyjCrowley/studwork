# Core.Streak (agent E)

Public API (`Types.StreakAPI`): `onDaily(handler)`, `get(player)`.

- `StreakMath.luau` - pure UTC day math + reward lookup (tests in `StreakMath.spec.luau`).
- `init.luau` - evaluates on data load and every 60 s (players online across UTC midnight).

Rules (day = `os.time() // 86400`): same day -> nothing; next day -> +1; one missed day forgiven when
`now < (lastDay + 2) * 86400 + graceHours * 3600` (i.e. within graceHours after the missed day ended);
clock skew (today < lastDay) -> unchanged; otherwise reset to 1.

On a counted day: `PlayerData.streak` updated, reward from `balance.streak.rewards` (by streak day, wrapped by
`loopAfter`, currency default `balance.primaryCurrency`) via `Economy.grant(..., "streak")`, `StreakAdvanced`,
`onDaily` handlers, "toast", `Analytics.custom("StreakDay", day)`.

Console: `streak dump [userId]`, `streak advance [userId]` (Studio: pretends the last day was yesterday).
