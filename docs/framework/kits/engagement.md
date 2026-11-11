# Engagement kit: Streak

Daily streaks with a grace window, counted in UTC days by default. Code: `packages/kits/engagement/<Module>/` (one folder per module: `module.luau`, `server/`, `client/`; Rojo `ReplicatedStorage.Modules.<Module>`, `ServerScriptService.Modules.<Module>`). Entries
marked **(contract)** are part of the cross-module surface listed in
[kit-contract.md](../kit-contract.md).

```lua
local Streak = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Streak"):WaitForChild("module"))
```

## Config (`config.Streak`)

| Key | Default | Meaning |
|---|---|---|
| `streak.graceHours` | `6` | a missed day is forgiven if the player returns within this many hours after it ended |
| `streak.rewards` | none | `{ { day, amount, currency? } }`: auto-rewards by streak day, paid with Economy (needs Economy); `currency` defaults to the primary |
| `streak.loopAfter` | none | after this many days the reward table loops (the count keeps going) |
| `streak.utcOffsetHours` | `0` | time zone the days are counted in, -14..14 (0 = UTC) |

## Rules

Day = `(now + utcOffsetHours * 3600) // 86400` (UTC by default). Same day: nothing. Next day: +1. One missed day is forgiven
within `graceHours` after it ended. Otherwise the streak resets to 1. Clock skew (today before the
last day) leaves it unchanged. It is evaluated on load and every 60 s, so players online across
midnight count.

## API

`onDaily(fn(player, streakDay)) -> Connection`, `get(player) -> { day, lastDay }`, signal
`StreakAdvanced(player, day)` (contract). Rewards go through
`ctx.depsTx[Economy].grant` (optional Economy, contract).

## Replicated

`data.streak`.

## Save data

Section `streak`: `{ streak = { day = 0, lastDay = 0 } }`.
