# Engagement kit: Streak

Daily streaks on UTC days with a grace window. Code: `packages/kits/engagement`. Phase 1 status:
being rebuilt on the module API (agent C). Entries marked **(contract)** are pinned by
[PHASE1-CONTRACT.md]((internal build report, not public)).

```lua
local Streak = require(ReplicatedStorage:WaitForChild("Kits"):WaitForChild("Engagement"):WaitForChild("Streak"))
```

## Config (`config.Streak`)

| Key | Default | Meaning |
|---|---|---|
| `streak.graceHours` | required (>= 0) | a missed UTC day is forgiven if the player returns within this many hours after it ended |
| `streak.rewards` | none | `{ { day, amount, currency? } }`: auto-rewards by streak day, paid with Economy (needs Economy); `currency` defaults to the primary |
| `streak.loopAfter` | none | after this many days the reward table loops (the count keeps going) |

Phase 1 adds the time zone to config with UTC as the default (agent C); the defaults don't move.

## Rules

Day = `os.time() // 86400` (UTC). Same day: nothing. Next day: +1. One missed day is forgiven
within `graceHours` after it ended. Otherwise the streak resets to 1. Clock skew (today before the
last day) leaves it unchanged. It is evaluated on load and every 60 s, so players online across
midnight count.

## API

`onDaily(fn(player, streakDay)) -> Connection`, `get(player) -> { day, lastDay }`. Rewards go through
`ctx.depsTx[Economy].grant` (optional Economy, contract).

## Replicated

`data.streak`.

## Save data

Section `streak`: `{ streak = { day = 0, lastDay = 0 } }`.
