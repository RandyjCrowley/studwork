# Quests kit: Quests and Goals

Two normal kit modules on the public module API ([module reference](../module-reference.md)):

- **Quests:** config-defined quests (daily, weekly, story chains, one-time, repeatable, event),
  progressed only by the server, claimed exactly once inside one framework transaction, with a quest
  board screen, a HUD tracker and claim toasts.
- **Goals:** the first-session goal chain and the next-goal pointer ("no tutorial wall, one arrow to
  the next goal"): a HUD pill and one world beam (with an off-screen edge arrow) toward the current
  goal, a game-supplied "what's next" after the chain, and one analytics funnel step per goal.

Code: `packages/kits/quests/Quests/` and `packages/kits/quests/Goals/` (`module.luau`, `server/`,
`client/`, `shared/`, `net.blink`; Rojo `ReplicatedStorage.Modules.<Name>`,
`ServerScriptService.Modules.<Name>`, generated into every project by `tools/sync-projects`). Added in
v1.8.0. Both declare `framework = "^1.7.0"`. Each works without the other: Goals needs no Quests (game
calls and source thresholds), and Quests needs none of Economy, Inventory, Rarity, Rebirth, Streak or
Leaderboards unless its config references them. **Both boot with no config at all** and then do
nothing (no quests, no chain): `tools/new-game` and `tools/adopt --init` list every kit module by
default, with no `Quests` or `Goals` config section. Entries marked **(contract)** belong in
[kit-contract.md](../kit-contract.md).

```lua
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Quests = require(Modules:WaitForChild("Quests"):WaitForChild("module"))
local Goals = require(Modules:WaitForChild("Goals"):WaitForChild("module"))
```

**The server is authoritative.** No client action advances a quest or a goal, except acknowledge
objectives and goals the config marks client-completable (`kind = "ack"`, "opened the shop"). Those
are rate-limited, never complete a quest that has no server objective, and never grant anything by
themselves. There is no Robux anywhere in this kit: no paid rerolls, skips or passes.

## Quick start

`GameConfig.modules` gets `Quests` (and `Economy` here, because a reward and an objective use it; in an
existing game follow [Add Quests and Goals to an existing game](#add-quests-and-goals-to-an-existing-game)):

```lua
-- GameConfig.config (Balance.luau); shaped as `tools/format` (StyLua) writes it, so `tools/lint` passes as pasted
Quests = {
	daily = { count = 3, rerollsPerSlot = 1 },
	quests = {
		collectCoins = {
			kind = "daily",
			objectives = { { kind = "source", source = "currencyEarned", target = 250 } },
			reward = { { kind = "currency", amount = 100 } },
		},
		openCrates = {
			kind = "daily",
			objectives = { { kind = "counter", key = "crateOpened", target = 3 } },
			reward = { { kind = "currency", amount = 150 } },
		},
		visitShop = {
			kind = "daily",
			weight = 2,
			objectives = { { kind = "counter", key = "shopVisit", target = 1 } },
			reward = { { kind = "currency", amount = 50 } },
		},
	},
},
```

Calls from your game module (server part). `Quests` is **not a global**: require its definition, list it
in your module's `dependsOn` and reach the running module through `ctx.deps` (`ctx.deps[Quests]`,
`ctx.deps[Goals]`; the full wiring is in [Add Quests and Goals to an existing game](#add-quests-and-goals-to-an-existing-game)):

```lua
-- modules/<your-game>/server/init.luau (the module's server part: a table with init/start)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local KitDefs = ReplicatedStorage:WaitForChild("Modules")
local Quests = require(KitDefs:WaitForChild("Quests"):WaitForChild("module")) -- the definition, also in dependsOn

local Game = {}
local ctx

function Game.init(context)
	ctx = context
end

function Game.start(_context)
	-- somewhere your game already handles the event (a crate opened, a block touched):
	local function onCrateOpened(player)
		-- progress only ever comes from the server
		ctx.deps[Quests].progress(player, "crateOpened") -- +1 to every active objective with that key
	end
	-- the board's Claim button calls the same through an action; a game call looks like this:
	local function claimNow(player)
		local ok, reason = ctx.deps[Quests].claim(player, "openCrates")
		return ok, reason
	end
end

return Game
-- from a client script: StudWork.use(QuestsDef); from a sim spec: server:use("Quests")
```

```lua
-- spec (mirrored by packages/kits/quests/tests/QuestsQuickStart.spec.luau)
local h = StudWork.test.harness({ modules = { Economy, Quests }, config = { Quests = cfg, Economy = econ } })
local p = h:addPlayer({ userId = 1 })
```

Goals with no Quests:

```lua
Goals = {
	chain = {
		{
			id = "firstCoins",
			check = { source = "currency", atLeast = 50 },
			target = { tag = "CoinSpot" },
			funnel = "FirstCoins",
		},
		{
			id = "buyUpgrade",
			check = { call = true },
			target = { path = "Workspace.Shop.Counter" },
			funnel = "FirstUpgrade",
		},
	},
},
-- game module: ctx.deps[Goals].complete(player, "buyUpgrade") when the upgrade is bought
-- after the chain: ctx.deps[Goals].setNext(function(player) return { text = "game.next.rebirth", target = { tag = "RebirthPad" } } end)
```

**A chain with different `check` and `target` shapes (as above) fails `tools/typecheck` in a strict
`Balance.luau`** with "Table type ... not compatible". Annotate it with the kit's type first: [Typing a
goal chain in a strict file](#typing-a-goal-chain-in-a-strict-file) has the same chain, typed.

**Run `tools/format` after pasting any config** (then `tools/lint`): `tools/lint` runs `stylua --check`,
and one-line tables that StyLua would wrap fail it with a large diff. The snippets above are already in
the formatted shape; your own edits may not be.

## Add Quests and Goals to an existing game

**Manual step until the generators list the kit.** `tools/new-game --modules` and `tools/new-project
--modules` don't include `Quests` and `Goals` yet (the line to add is in the release notes), so a
game made before that, or with a `--modules` list without them, adds them by hand. The project files
already map both modules (`tools/sync-projects` writes the Rojo entries for every kit); nothing to
change in `default.project.json`. Don't name your own module `Quests` or `Goals` (`tools/make-module
Quests` would collide with the kit; the module names are taken).

1. **List the modules.** A project made with the default module list (`tools/new-game` or
   `tools/new-project` without `--modules`; the template's `GameConfig.modules`, in order
   `tools/lune/KitModules.luau` `ORDER`) already lists `Items`, `Rarity`, `Inventory`, `Economy`,
   `Upgrades`, `Rebirth`, `Offline`, `Streak`, `Leaderboards`, `Badges`, `Notifications`, `Friends`,
   `Mail`, `TextFilter` and `Plot`: **only `Quests` and `Goals` are missing**, so every source and
   reward below already has its module. A project made with a `--modules` list lists just what that
   list named (plus hard dependencies); check `src/shared/Config/init.luau`. In that file, add to
   `modules`, after the kit modules you already have:

   ```lua
   require(Modules:WaitForChild("Quests"):WaitForChild("module")),
   require(Modules:WaitForChild("Goals"):WaitForChild("module")),
   ```

   (`local Modules = ReplicatedStorage:WaitForChild("Modules")`; the file already has it.) If your
   list is a subset, also add whatever the config you write needs: `Economy` for currency rewards and `currencyEarned`,
   `Inventory` and `Items` for items, `Rarity` and `Inventory` for roll rewards, `Rebirth`, `Streak`
   or `Leaderboards` for their sources. A module a config names but the game doesn't list is a boot
   error that names it.
2. **Tell the game module.** In `modules/<your-game>/module.luau`, add the two requires to
   `dependsOn` (boot fails if the game drops them, and they load before your module) or to
   `optional` (guard with `ctx.isEnabled`): `require(KitDefs:WaitForChild("Quests"):WaitForChild("module"))`
   and the same for `Goals`. You need this to call `ctx.deps[Quests]` / `ctx.deps[Goals]`
   (`Quests.progress`, `Goals.complete`, `setNext`) from your server part; a module you don't depend
   on can't be used.
3. **Fix the boot spec.** `src/server/Boot.spec.luau` lists every module in load order. Add
   `"Quests"` and `"Goals"` to `EXPECTED` in the order the framework loads them: **right after the kit
   modules already in the list (after `Economy` and any other kit you have, e.g. `Rarity`, `Plot`) and
   before the game's own module, which is the last entry**. Dependencies load first, so where the game
   module `dependsOn` them decides nothing here. Run `tools/test`: if the order is off, the failing spec
   prints the real loaded order; copy that list into `EXPECTED` and rerun until it passes.
4. **Write the config sections** in `src/shared/Config/Balance.luau`: `Quests = { ... }` and
   `Goals = { chain = { ... } }` (the Quick start and the rest of this page). With none, both boot
   and do nothing. Type a mixed goal chain before you paste it ([typing a goal chain](#typing-a-goal-chain-in-a-strict-file)),
   and check every `widget` id you use (Goals config, "Check every widget id").
5. **Analytics and strings.** List every goal's and quest's `funnel` step in
   `GameConfig.analytics.funnel` (a missing step logs a boot warning, below), and put your own
   text keys in `GameConfig.strings` ([string keys](#string-keys-and-namespaces)).
6. **Calls from your game**, in the game module's server part, always through `ctx.deps`:
   `ctx.deps[Quests].progress(player, key)` for your counters, `ctx.deps[Goals].complete(player, id)`
   for `call` goals, `ctx.deps[Goals].setNext(fn)` for the "what's next" after the chain (`Quests` and
   `Goals` are the definitions from step 2; see the Quick start snippet).
7. **The HUD.** If the template's client passes `nextGoal` to `Client.Hud.mount`, remove it or turn the
   pill off ([`Game.nextGoal` and the Goals pill](#gamenextgoal-and-the-goals-pill)).
8. **Run** `tools/format`, then `tools/test`, `tools/typecheck <game>` and `tools/lint` (lint fails on
   unformatted tables). A mixed goal chain in a strict
   `Balance.luau` needs a type ([typing a goal chain](#typing-a-goal-chain-in-a-strict-file)).

---

# Quests

## Config (`config.Quests`)

| Key | Default | Meaning |
|---|---|---|
| `flag` | none | a feature flag ([environments](environments.md)); while off nothing is progressed, claimed, rotated or written, every call refuses with `"disabled"`, and the replicated board is empty. An undeclared flag is a boot error |
| `quests` | `{}` | `{ [questId] = Quest }` (below). `questId` matches `^[%w_]{1,32}$` |
| `chains` | `{}` | `{ [chainId] = { questId, ... } }`: ordered story steps; each step is a quest of kind `"chain"`. `chainId` matches `^[%w_]{1,32}$` |
| `daily` | `{ count = 3, rerollsPerSlot = 1 }` | `count` 0..6 daily quests dealt per player per day from the `daily` pool (fewer when the player's eligible pool is smaller; an empty pool deals nothing); `rerollsPerSlot` 0..3 free rerolls per slot per day (0 turns rerolls off) |
| `weekly` | `{ count = 2, rerollsPerSlot = 0 }` | the same for the week |
| `poolVersion` | `1` | integer >= 1, part of the deal seed. Bump it when you change a pool and want periods not yet dealt to use a fresh deal; a set already dealt and saved is never re-dealt |
| `utcOffsetHours` | `0` | the time zone days and weeks are counted in, -14..14 (the framework's convention, as in Streak and Leaderboards). The reset is local midnight there, for every player at once: `-5` resets at 05:00 UTC. It is a fixed offset: where your audience observes daylight saving time, the reset moves by an hour of local time twice a year |
| `weekStartsOn` | `"monday"` | `"monday"` or `"sunday"` |
| `autoClaim` | `false` | claim automatically when a quest completes (per quest: `Quest.autoClaim`). Off by default: the claim moment is the reward, and it brings the player to the board |
| `waitingMax` | `6` | 0..12: completed but unclaimed daily, weekly and event quests kept, claimable, after their period or event window ends (oldest dropped first) |
| `pinMax` | `3` | 0..5 quests a player can pin to the HUD tracker |
| `foldSeconds` | `30` | 5..120: pending progress joins the save at least this often per player (staggered), see [Batching](#batching-progress) |
| `replicateSeconds` | `1` | 0.25..5: the shortest interval between two live-progress sends to one player |
| `sourcePollSeconds` | `5` | 1..60: how often a registered source without a `changed` signal is re-read, only for players with an active objective on it |
| `rotatePerTick` | `10` | 1..100: players moved to a new period per framework tick after a reset (spreads the work; `progress` never deals, see [Periods](#periods-the-deal-and-rerolls)) |
| `maxAmount` | `1000000` | the largest `amount` one `progress` call accepts |

**A story chain, end to end** (`chains` and the quests it names; each step is a quest of kind
`"chain"`, shown one at a time: the next step opens when the previous one is claimed):

```lua
Quests = {
	quests = {
		story1 = {
			kind = "chain",
			objectives = { { kind = "counter", key = "talkedToGuide", target = 1 } },
			reward = { { kind = "currency", amount = 20 } },
		},
		story2 = {
			kind = "chain",
			objectives = { { kind = "counter", key = "coinTouched", target = 5 } },
			reward = { { kind = "currency", amount = 30 } },
		},
		story3 = {
			kind = "chain",
			objectives = { { kind = "counter", key = "reachedTower", target = 1 } },
			reward = { { kind = "currency", amount = 100 } },
		},
	},
	chains = { story = { "story1", "story2", "story3" } },
},
-- game module: ctx.deps[Quests].progress(player, "talkedToGuide") when the player talks to the guide, and so on
```

(Mirrored by `packages/kits/quests/tests/QuestsDocChains.spec.luau`.)

**Quest** (`quests[questId]`):

| Field | Default | Meaning |
|---|---|---|
| `kind` | required | `"daily"`, `"weekly"` (dealt from the pool), `"chain"` (a step in `chains`), `"oneTime"`, `"repeatable"`, `"event"` |
| `objectives` | required | 1..4 objectives (below); the quest is complete when every objective is |
| `reward` | `{}` | 0..4 rewards (below), granted together in the claim's transaction |
| `title` | `"Quests.quest.<id>"` | a string key ([localization](localization.md)); the module's `strings` function gives the English default = the id until the game sets it |
| `text` | none | an optional description key |
| `weight` | `1` | `daily`/`weekly`: pool weight, a finite number > 0 |
| `requires` | none | `{ quests = { questId }?, rebirths = number?, items = { itemId }? }`: the quests claimed, `Rebirth.count` at least this, each item owned (Inventory). An unmet requirement keeps a quest out of the deal and `"locked"` elsewhere |
| `cap` | `1` | `repeatable`: claims per `period`, 1..100 |
| `period` | `"daily"` | `repeatable`: `"daily"` or `"weekly"` |
| `event` | none | `event` (required there): an id in `GameConfig.events` |
| `offer` | `"auto"` | `oneTime`/`repeatable`: `"auto"` (active once unlocked) or `"grant"` (active only after the game calls `Quests.grant`, e.g. an NPC hands it out) |
| `autoClaim` | `config.autoClaim` | per-quest override (never for a quest with an `ack` objective) |
| `retired` | `false` | never offered again, but kept so old claims still count; retire a `oneTime` quest instead of deleting it (a deleted id is forgotten, so re-adding it would let it be claimed again) |
| `funnel` | none | an analytics funnel step (`ctx.analytics.funnel`) logged on this quest's first claim |

**Objective:**

| `kind` | Fields | Completes when |
|---|---|---|
| `"counter"` | `key` (`^[%w_]{1,32}$`), `target` | `Quests.progress(player, key, amount)` adds up to `target` |
| `"source"` | `source`, `target`, `params?` | an **add** source reports amounts adding up to `target` (built-ins below) |
| `"threshold"` | `source`, `target`, `params?` | a **value** source reads at least `target` (for `leaderboardRank`: at most `target`) |
| `"ack"` | `key` | the client sends `ackQuest(key)` (rate-limited) while the quest is active |

`target` is an integer 1..1e9. `label` (optional, any kind) is a string key for the objective's line.
Set it: without one the line shows the raw config key or source name (`"crateOpened"`), which is
only a placeholder.

**Built-in sources** (each needs its module enabled; a quest naming one whose module is off is a
boot error naming the quest and the module to add):

| Source | Mode | Needs | `params` | Reads |
|---|---|---|---|---|
| `currencyEarned` | add | Economy | `currency?` (default primary) | `CurrencyChanged` with `delta > 0`, except deltas whose reason starts with `"Quests:"` (quest rewards don't feed quests) |
| `itemCollected` | add | Inventory (+ Items for `rarity`) | `item?`, `rarity?` | `ItemAdded`, 1 per copy matching every given param, except copies whose `source` starts with `"Quests:"` |
| `rebirthDone` | add | Rebirth | none | `Rebirthed`, 1 per rebirth |
| `currency` | value | Economy | `currency?` | `balance(player, currency)`, re-read on `CurrencyChanged` |
| `rebirths` | value | Rebirth | none | `count(player)`, re-read on `Rebirthed` |
| `streakDay` | value | Streak | none | `get(player).day`, re-read on `StreakAdvanced` |
| `itemOwned` | value | Inventory | `item` | copies of `item` in `list(player)`, re-read on `ItemAdded`/`ItemRemoved` |
| `leaderboardRank` | value | Leaderboards | `board` | `rank(player, board)` (nil = not ranked = not done), re-read on `BoardRefreshed` |

A game adds **value** sources with the `registerSource` extension (below). For **add** amounts the
game just uses counters (`progress`).

**Reward:**

| `kind` | Fields | Granted with (inside the claim tx) | Needs |
|---|---|---|---|
| `"currency"` | `amount` (integer >= 1), `currency?` | `ctx.depsTx[Economy].grant(tx, amount, "Quests:<questId>", currency)` | Economy |
| `"item"` | `item`, `count?` (1..10) | `ctx.depsTx[Inventory].add(tx, item, { source = "Quests:<questId>" })` per copy | Inventory |
| `"roll"` | `table` | `ctx.depsTx[Rarity].roll(tx, table, 1, { grant = true, reason = "Quests:<questId>" })`: a **free** roll at luck **exactly 1** (passed explicitly, never the player's session luck) through Compliance, from a free table (boot validation); its odds are **disclosed by Quests itself** (`extra.questOdds`, below) and every roll reward chip on the board has an Odds button | Rarity + Inventory |
| `"custom"` | `handler`, `params?` | the game's `registerReward(handler, fn)` handler, called as `fn(tx, player, params, questId)` | the registration |

**Roll rewards: disclosed, luck 1, never paid.**

- **Disclosed:** at start Quests reads `Rarity.getOddsDetail(table, nil, 1)` (Rarity's public API)
  for every table a `roll` reward names and replicates those details to every player as
  `extra.questOdds` (`ctx.replicate.setAll`). The board's Odds button opens the UI kit's Odds
  screen with that detail, so the odds a player sees are exactly the odds the claim rolls at,
  whatever the table's own `luckDisclosed`/`cost` flags and whatever the player's session luck.
- **Luck exactly 1:** the claim passes `luck = 1`; Rarity's `nil` would mean the player's session
  luck, which the disclosed odds wouldn't match.
- **Never paid:** a table whose detail says `paid = true` (a `paid = true` table, or a `cost` in a
  `compliance.paidCurrencies` currency) is a boot error: Rarity would treat a roll on it as paid
  even outside a purchase (restricted players would get `"restricted"` and could never claim).
  The claim tx is not a purchase and spends nothing, so Compliance treats the roll as free, and the
  paid-random and luck guardrails stay in force for every other roll. A custom handler that spends a
  paid currency is refused by Economy as everywhere else.

**A chest-roll quest, and a reward that rolls a table.** Rarity fires no signal for a roll; the
chest roll is a client action on Rarity (`actions.roll(tableId)`), and a game can't hook it. Two
ways to make "open a chest" a quest, both server-side:

- *Count what the roll grants.* A roll with `grant = true` adds the item to Inventory, and Inventory's
  `ItemAdded` feeds the built-in `itemCollected` source (one per copy, optionally filtered by
  `item` or `rarity`; quest rewards are excluded):
  `{ kind = "source", source = "itemCollected", target = 3, label = "game.objective.openChests" }`.
  It counts every item that arrives, not only rolls; add `params = { rarity = "Rare" }` (needs
  `Items`) to narrow it.
- *Count your own roll.* When the game rolls in its own server code (a priced chest action in the
  game module), call the counter in the same place; `progress` is safe inside a transaction:
  `Quests.progress(player, "chestOpened")` with `{ kind = "counter", key = "chestOpened", target = 3 }`.

To make a quest's **reward** a Rarity roll, use a `roll` reward on a **free** table (no `paid`, no
`cost`); Rarity and Inventory must be in `modules`:

```lua
Rarity = { rarityTables = { ChestRoll = { entries = {
	{ itemId = "gem", weight = 70 }, { itemId = "star", weight = 25 }, { itemId = "comet", weight = 5 },
} } } },
Quests = { quests = {
	openChests = { kind = "daily", title = "game.quest.openChests",
		objectives = { { kind = "counter", key = "chestOpened", target = 3, label = "game.objective.openChests" } },
		reward = { { kind = "roll", table = "ChestRoll" } } },
} },
```

The claim rolls once, at luck 1, and the board shows an Odds button on the chip. A table with a
`cost` or `paid = true` is a boot error.

### Config validation (at boot)

Run in Quests' `start`, after every module's `init` (so the `registerSource`/`registerReward`
extensions are in), with all problems reported together, each naming the quest, chain or key. Any
problem fails the boot (closed, like every boot error):

- unknown `kind`, objective `kind`, reward `kind`; a bad id; 0 or more than 4 objectives or rewards;
- a `source` that is neither built in nor registered, a built-in whose module isn't enabled, a
  `threshold` on an add source or a `source` objective on a value source, a missing `params.item` /
  `params.board`;
- a reward `handler` nobody registered; an `item` that `Items.get` doesn't know; a `roll` table for
  which `Rarity.getOddsDetail(table, nil, 1)` is nil (unknown; `getOdds` is not used: it returns
  `{}` for an unknown id) or whose detail has `paid = true`; a reward module that isn't enabled;
- a quest whose objectives are all `ack` (an acknowledge can't complete a quest on its own). Pair an
  ack with a counter or source the server moves. A quest with an `ack` objective plus an already-met
  threshold completes on the ack alone, because the ack is the only unmet objective. The ack never
  grants anything by itself and the claim still goes through the server, but the player alone decides
  when the quest completes;
  `autoClaim = true` on a quest with an `ack` objective;
- chains: a step id that isn't a quest (dangling), a step whose kind isn't `"chain"`, a `"chain"`
  quest in no chain or in two, an empty chain, a step listed twice;
- `requires`: an unknown quest id, a quest requiring itself, a requirement cycle, `rebirths` without
  Rebirth, `items` without Inventory or with an unknown item;
- `weight` not finite or <= 0; `daily.count` (`weekly.count`) larger than a **non-empty** pool of
  non-retired quests of that kind (an empty pool is not an error: that kind just deals nothing, so
  the defaults `count = 3` / `2` with `quests = {}` boot); `cap` out of range; an `event` quest whose
  id isn't in `GameConfig.events` (`ctx.gameConfig.events`);
- schema errors (types, ranges) come from the framework's config check as usual.

With no config at all (every default) validation passes and Quests is idle: no deal, an empty board,
no HUD button dot. A spec boots `modules = { Quests, Goals }` with no config, and both next to every
other kit module at its defaults (what `tools/adopt --init` writes).

## Periods, the deal and rerolls

**Periods** are counted on the framework clock (`ctx.now()`, module-api §19.2; the harness and the
sim move it), in `utcOffsetHours`, the same way Streak and Leaderboards count them:

```
day    = floor((now + utcOffsetHours * 3600) / 86400)            -- the daily period id
week   = floor((day + s) / 7) * 7 - s,  s = 3 (monday) or 4 (sunday) -- the weekly period id: the day index of the week's first day
endsAt = (periodId + days) * 86400 - utcOffsetHours * 3600       -- days = 1 or 7; a period is [startsAt, endsAt)
```

There is one boundary per game, not one per player: a client's clock is never asked (it could be
set to anything), and the same boundary on every server makes a server hop change nothing.

**Periods only move forward.** Servers' clocks differ by a few seconds. A player's saved period id
(and every saved period or window key: `prog.p`, `waiting.p`) is only ever replaced by a **larger**
one. When the server's current id is greater than the saved one, the new period is dealt. When the
saved id is **ahead** of this server's clock (the player came from a server a few seconds ahead,
across the boundary), the saved set stays the current set: nothing is re-dealt, its claims stand,
and the next deal waits until this server's clock reaches a larger id. So a hop across the boundary
can't re-deal yesterday's set and claim it twice. The same `>` rule resets a repeatable's per-period
claim count and opens a new event window.

**The deal** (`daily` and `weekly`). When the current period id is greater than the player's saved
one, the period's set is dealt in one transaction. That happens in exactly these places: the
player's first tx on load (`onPlayerLoaded`, together with the config pruning in [Save
data](#save-data)), the rotation tick after a reset (`rotatePerTick` players per tick), and at the
start of `claim`, `reroll`, `grant` and `pin` (inside their own tx). `progress`, `active` and
`state` never deal and never write: until a player's rotation, `active`/`state` show the saved set
(its quests still complete and claimable; they move to `waiting` at the deal), and `progress` drops
increments for that player's slot quests of the ended period (a cheap `savedId < currentId` check;
other kinds are unaffected). The fold also drops pending progress of a slot quest whose set has
ended (`now >= endsAt`), so nothing completes after its period.

1. Completed-but-unclaimed quests of the old period move to `waiting` (at most `waitingMax`, oldest
   dropped). Pending progress for the old quests is dropped.
2. The **eligible pool** = quests of that kind, not `retired`, with `requires` met, sorted by id. It
   is snapshotted into `seen` (every eligible id a key, `false` until dealt or shown).
3. For slot `s = 1..min(count, #pool)`: draw from the pool minus the quests already dealt this
   period, with
   `seed = fnv1a32(userId .. "|" .. kind .. "|" .. periodId .. "|" .. poolVersion .. "|" .. s .. "|" .. 0)`.

The draw: `x = seed` (or `0x9E3779B9` if 0); `x = xorshift32(x)` (`x ^= x << 13; x ^= x >> 17; x ^= x << 5`,
32-bit, `bit32`); `u = x / 2^32 * totalWeight`; walk the candidates in id order and take the first
whose running weight sum exceeds `u`. `fnv1a32` is FNV-1a over the UTF-8 bytes (offset
`2166136261`, prime `16777619`; the multiply is done as `(h << 24) + h * 403` mod 2^32 so it stays
exact in doubles). The algorithm is pure (`Quests/shared/Deal.luau`) and pinned by a spec with known
values, so every server, the harness and the sim deal the same set.

The dealt set is **saved**, and a saved set for the current period is never re-dealt: a rejoin or a
server hop shows the same quests with the same progress. The seed only matters when there is no
saved set yet (a new period, or a save from before the period that was rolled back by a crash): it
then deals the same set again. A quest removed from config is dropped from its slot in the load tx
and the slot is refilled with the same seed formula (`rerollIndex` unchanged), so the refill is
deterministic too, **only when the slot isn't claimed** (`s < 2`). A claimed slot whose quest was
removed stays as a claimed placeholder until the period ends (it isn't shown), so a removal can't
hand the player a second claim in that slot.

**Rerolls.** `reroll(player, kind, slot)` replaces an active, not-yet-complete slot quest. The new
quest is drawn with `rerollIndex = n` (the slot's n-th reroll this period) from the pool snapshotted
at the deal: the `seen` entries still `false` (eligible then, never dealt or shown this period) that
are still configured and not retired. `requires` aren't re-checked, so a player can't steer a reroll
by changing what they own; and a reroll can't bring back a quest the player rerolled away. Each slot has `rerollsPerSlot` free rerolls per period; the count is saved
with the set. Because the result is a function of (user, period, slot, n), a rejoin, a server hop
or a crash that rolls the save back can't give a different reroll result or a free extra one.
Progress on the replaced quest is discarded. An empty remaining pool refuses with `"pool_empty"`.

**Chains** have one active step per chain: the first step not yet claimed whose `requires` are met.
Claiming step k activates step k+1 in the same transaction. **oneTime** quests are active from the
moment they unlock (or `grant`) until claimed. **repeatable** quests reset their progress after each
claim and refuse with `"cap_reached"` after `cap` claims in the current `period`. **event** quests
are active while `ctx.events.isActive(event)`; their progress and claim belong to the event's
window (below) and reset with the next (larger) window key. An event quest that is complete but
unclaimed when its window ends moves to `waiting` (`k = "event"`, `p` = the window key), like daily
and weekly quests.

**Event quests** read only the framework's public surface: `ctx.events.isActive(id)`,
`ctx.signals.framework.EventStarted` / `EventEnded` (the `EventContext` with `id`, `startedAt`,
`endsAt`) and `ctx.gameConfig.events`. Quests never calls `ctx.events.schedule` (one handler per event
belongs to the game). The window key is a number of unix seconds: `startedAt` for an event with a
`schedule` (derived from the clock, so every server agrees), and the start of `startedAt`'s UTC day
(`floor(startedAt / 86400) * 86400`) for an event that is only ever triggered by hand (servers start
those at different times), so a server hop during a hand-triggered event can't open a second claim
the same day. By design, a second hand trigger on the same UTC day doesn't reopen a quest claimed in
the first.

## API (server)

All functions return immediately (nothing yields). A refused call returns `(false, reason)`, never
errors, except programming errors (a non-player, a non-string id, see below), which error with the
function name.

**Calling from inside a transaction.** The framework allows one `ctx.tx` at a time and errors on a
nested one, which would discard the caller's tx. So:

- `progress` is **safe anywhere**, including inside your own tx, a Mail `claimFn`, a Rebirth reset
  step or a `registerReward` handler: it only adds to memory and never opens a tx (a completing
  increment is folded on the next tick, see [Batching](#batching-progress)).
- `claim`, `reroll`, `grant` and `pin` open their own tx. Calling one while a tx is open is a
  programming error (the framework's nested-tx error). From inside your tx, defer it:
  `tx.after(function() Quests.grant(player, "findTheCat") end)`.

- `progress(player, key: string, amount: number?) -> boolean` **(contract)**: adds `amount`
  (default 1; finite, > 0, <= `maxAmount`, floored to an integer >= 1) to every active `counter`
  objective with that `key`. `true` when at least one objective moved. `false` when nothing matched,
  for a bad amount, an unloaded player or while the flag is off. Batched in memory
  ([Batching](#batching-progress)).
- `claim(player, questId: string) -> (boolean, string?)` **(contract)**: grants the quest's rewards
  and records the claim in **one** `ctx.tx` (below). Reasons: `"disabled"`, `"not_loaded"`,
  `"unknown_quest"`, `"not_active"` (not dealt, locked, not granted, or its event window is over),
  `"not_complete"`, `"claimed"` (already claimed in this period, window or ever for oneTime/chain),
  `"cap_reached"`, `"inventory_full"`, `"reward_failed"` (a grant returned false: unknown currency,
  item refused, roll refused). A refused claim changes nothing. Waiting quests (`waiting`) are claimed
  by the same call. When the same id is both in the current period and in `waiting` (dealt again),
  `claim` takes the **first complete, unclaimed instance** in this order: the current period's (or
  the active one), then `waiting` oldest first; a second call claims the next one. `state` reports
  the current instance.
- `reroll(player, kind: "daily" | "weekly", slot: number) -> (boolean, string)` **(contract)**: the new
  quest id, or a reason: `"disabled"`, `"not_loaded"`, `"bad_kind"`, `"bad_slot"`, `"no_rerolls"`,
  `"slot_done"` (the slot's quest is complete or claimed), `"pool_empty"`.
- `active(player) -> { QuestView }` **(contract)**: frozen; every quest the player can see now, board
  order (daily slots, weekly slots, chains, oneTime, repeatable, event, waiting). Empty for an
  unloaded player.
- `state(player, questId) -> QuestState?` **(contract)**: frozen; nil for an unknown id.
- `def(questId) -> Quest?` **(contract)**: the frozen, validated config entry (with defaults filled
  in), nil for an unknown id. No player needed; Goals uses it to validate its `quest` checks.
- `grant(player, questId) -> (boolean, string?)` **(contract)**: makes an `offer = "grant"` quest
  (oneTime or repeatable) active for this player, e.g. when the game's NPC hands it out. Server only
  (no action exists). Reasons: `"disabled"`, `"not_loaded"`, `"unknown_quest"`, `"not_grantable"`,
  `"locked"` (requirements), `"already_active"`, `"claimed"` (a oneTime already claimed).
- `pin(player, questId, on: boolean) -> (boolean, string?)`: adds or removes a quest on the HUD
  tracker. Reasons: `"disabled"`, `"not_loaded"`, `"unknown_quest"`, `"not_active"`, `"pin_limit"`.
- **extensions** **(contract)**, callable during `init` (through `ctx.depsExt[Quests]`), because
  boot validation runs in `start`:
  - `registerSource(name: string, spec: { read: (player) -> number?, changed: SignalLike? })`: a
    **value** source for `threshold` objectives. `read` must not yield (it's called inside
    transactions); nil means "no value yet". `changed` is anything with `:Connect(fn(player))`;
    without it the source is polled every `sourcePollSeconds` for players with an active objective
    on it. A built-in name or a second registration errors.
  - `registerReward(handler: string, fn: (tx, player, params, questId) -> ())`: a game reward. It
    runs inside the claim transaction and writes only through `ctx.section(tx)` of the registering
    module and `ctx.depsTx`; an error discards the whole claim (nothing granted, nothing recorded,
    `claim` returns `(false, "reward_failed")`). A second registration errors.
- **signals** **(contract)**, fired after the commit:
  - `Progressed(player, questIds: { string })`: once per live-values send to that player (at most once
    per `replicateSeconds`; not once per `progress` call), with the quests whose live values moved
    since the last send; read the values with `state(player, questId).values`;
  - `Completed(player, questId)`: once per completion (per period for daily/weekly/repeatable/event);
  - `Claimed(player, questId, rewards: { Reward })`: once per claim;
  - `Rotated(player, kind: "daily" | "weekly", periodId: number)`: after a new set is dealt.
- **txApi:** none. **purchaseOps:** none (no Robux in this kit).
- **Console** (`quests ...`): `quests state [userId]` (read-only, Studio or admins);
  `quests progress <key> <amount> [userId]`, `quests complete <questId> [userId]` (fills every
  objective through the same path as server progress) and `quests timeshift <seconds>` (shifts the
  module's period clock, in memory, for this server) are **Studio only** (`ctx.isStudio`), refused
  anywhere else. The console is the framework's server-side `StudWorkConsole` BindableFunction: no
  client can call it.

Types (`Quests/shared/Types.luau`):

```lua
export type QuestView = {
	id: string, kind: string, status: "active" | "complete" | "claimed",
	slot: number?, periodId: number?, endsAt: number?, rerollsLeft: number?,
	claims: number?, cap: number?, pinned: boolean, waiting: boolean?,
	objectives: { { kind: string, key: string?, source: string?, value: number, target: number } },
	reward: { any }, -- the frozen config rewards
}
export type QuestState = {
	status: "locked" | "available" | "active" | "complete" | "claimed" | "inactive",
	values: { number }?, claims: number?, periodId: number?,
}
```

`"available"` = an `offer = "grant"` quest that is unlocked but not granted; `"inactive"` = a daily
or weekly quest not dealt to this player this period, or an event quest outside its window.

## Actions (client to server)

| Action | Arguments (Blink) | Limit | Server checks |
|---|---|---|---|
| `claimQuest` | `questId: string(1..32)` | rate 2/s, burst 4 | the id is a configured quest (looked up in config: the client's string is never used past the lookup); then `claim` |
| `rerollQuest` | `kind: enum("daily","weekly")`, `slot: u8` | rate 1/s, burst 2 | `1 <= slot <= count`; then `reroll` |
| `pinQuest` | `questId: string(1..32)`, `on: boolean` | rate 2/s, burst 4 | as `pin` |
| `ackQuest` | `key: string(1..32)` | rate 1/s, burst 3 | the key is an `ack` key in config; completes matching `ack` objectives of active quests once each; never claims (quests with an `ack` objective are never auto-claimed) |

All four are declared in `Quests/net.blink`; the framework routes, rate-limits and `pcall`s them and
holds them until the player's data is loaded (module-api §9). There is no action that adds progress,
completes a quest or grants one. Handlers pass the config's own id (`def.id`) downstream, never the
client's string, which also keeps the `textfilter` lint check quiet.

## Claims: exactly once

A claim is one `ctx.tx(player, fn)`:

1. fold this player's pending progress for the quest into the working copy;
2. check `status == complete` and the claim record for this period/window (or `done[questId]` for
   oneTime and chain);
3. write the claim record (`status = claimed`, `claims += 1`, `done[questId] = now`, the next chain
   step) **and** grant every reward through `ctx.depsTx` / the registered handler, in the same tx;
4. any refusal or error inside discards the whole working copy (nothing granted, nothing recorded);
   `tx.after` fires `Claimed`, the funnel step and the replication update.

**How a refusal aborts.** A refusal is never an `error()` (the framework re-raises it with a logged
traceback). The claim function sets the reason in an upvalue, calls `tx.retryLater()` (which
discards the working copy; `ctx.tx` returns `(false, nil)`) and returns; `claim` returns
`(false, reason)`. Checks run before any grant:

- **capacity:** with item rewards, `ctx.depsTx[Inventory].count(tx) + n > Inventory.cap(player)`
  (`n` = item copies plus roll rewards) refuses with `"inventory_full"` (`txApi.add` alone returns
  nil for unknown, full and bad meta alike, so it can't tell them apart);
- a currency or item grant that returns false/nil: `"reward_failed"`; a roll that returns nil:
  `"inventory_full"` when Rarity's `info.reason` is a capacity refusal, else `"reward_failed"`.

Only a custom handler can raise: `claim` calls `pcall(ctx.tx, player, fn)`, so a handler error
discards the whole tx, is logged once with the quest id, and returns `(false, "reward_failed")`.

The tx doesn't yield, and one tx per player runs at a time, so:

| Case | Why it grants once |
|---|---|
| Double-tapped Claim (two actions in one frame) | the second tx runs after the first committed and sees `claimed` |
| Two servers | the framework's session lock: one server owns the save; another loads only after release |
| A save failure | the claim record and the grant are in the same in-memory commit; the framework retries the save. Both are saved or neither is |
| Server shutdown mid-claim | a tx can't be interrupted (no yield); `onShutdown` folds pending progress, then the framework's final save writes the claim and the grant together |
| A server crash after the claim | both are lost together (the save before the claim loads); the quest is complete again and claimable once |
| Rejoin on another server | that server loads the save with the claim record |
| A waiting quest | its claim record is in `waiting`; claiming removes it in the same tx |
| A reroll racing a claim | both are txs on the same player; the reroll refuses a complete slot (`"slot_done"`) |

## Batching progress

`progress` never writes the save. Per player, the server keeps an index `key -> { (questId,
objective) }` over the active quests (rebuilt on deal, claim, reroll, grant and load) and a
`pending` table of increments.

- An increment that **doesn't** complete an objective stays in memory. Pending progress joins the
  section in one `ctx.data.update` per player every `foldSeconds`, on the player's own staggered phase
  (`userId % foldSeconds`), plus before any claim, reroll or deal (inside that tx), on leave
  (`onPlayerRemoving`, before the final save) and on shutdown.
- An increment that **completes** an objective is still only added to memory (so `progress` is
  safe inside any tx) and flags the player. Quests' 1-second `onTick` folds every flagged player's
  pending progress in one tx per player on the next tick (at most one tx per player per tick), so a
  completion is pending for at most about a second: the save has it as soon as the framework next
  saves, and `Completed` (and `autoClaim`, in its own claim tx right after) follow that commit.
- The live values go to the client through `extra.progIds` / `extra.prog` at most every
  `replicateSeconds`. A counter increment that can't complete an objective only adds to a per-key
  total in memory (one table write per `progress` call, whatever the number of quests on the key);
  it is spread over the quests before anything reads them.
- **What a crash loses:** at most `foldSeconds` of non-completing increments, like the rest of the
  session since the last autosave. Never a completion that was committed, never a claim.
- Value sources are re-read only for players with an active objective on that source, on the
  source's signal or poll; a threshold that is met is a completion (flagged, folded on the next tick).

## Save data

Section `quests`, version 1, **not replicated** (`replicate = false`; the client gets `extra`):

```lua
{
	day  = { id = -1, slots = {}, seen = {} }, -- slots[i] = { q = questId, n = { numbers }, s = 0|1|2, r = rerollsUsed }
	week = { id = -1, slots = {}, seen = {} }, -- s: 0 active, 1 complete, 2 claimed; seen = { [questId] = boolean }: the pool at the deal, true = dealt or shown
	prog  = {}, -- [questId] = { n = { numbers }, s = 0|1|2, p = periodId | windowKey?, k = claimsThisPeriod? } (chain, oneTime, repeatable, event); p is a number
	done  = {}, -- [questId] = claimedAt (oneTime and chain steps; read by `requires.quests`); never pruned
	waiting = {}, -- { { q = questId, k = "daily"|"weekly"|"event", p = periodId | windowKey } }, at most waitingMax
	pins  = {}, -- { questId }, at most pinMax
	granted = {}, -- [questId] = true (offer = "grant" quests the game activated, until claimed)
}
```

- **Removed ids are dropped, never crash a load,** in two steps (the framework's `data.sanitize`
  is `fn(section) -> section` with no config, and an error in it fails the load and kicks):
  1. `data.sanitize` (after migrations, every load) does **config-free shape repair only** and never
     errors: wrong types are reset to the default, malformed entries are dropped, and lists are cut at
     the hard maxima (`slots` 6, objective values 4, `waiting` 12, `pins` 5).
  2. The **config pruning** runs in Quests' `onPlayerLoaded`, as the player's first tx (together with
     the deal): it drops every quest id the config no longer has from `slots` (refilled only when
     `s < 2`, above), `prog`, `waiting`, `pins` and `granted`; drops `prog` entries of quests that
     changed kind; clamps `waiting` to `waitingMax` and `pins` to `pinMax`; and cuts or pads objective
     values to each quest's current objective count (missing ones start at 0). Until it has run,
     every reader treats an unknown id as absent.
  `done` is **never pruned**: it is the claim ledger, so a oneTime or chain id removed and re-added
  later can't be claimed a second time (retiring is still the clean way to stop offering one).
  Removing a quest needs no migration; `tools/make-migration` is for future shape changes
  (`data.version` 2+).
- **Bounded over months:** `day`/`week` hold only the current period (the deal replaces them);
  `seen` is at most the pool size; `prog` and `granted` hold at most one entry per configured quest
  and `done` one per oneTime/chain id ever configured; `waiting` <= 12, `pins` <= 5. Nothing grows
  per day or per claim. Worst case with 60 configured quests of 4 objectives each is about 6 KB of
  the 4 MB save.

## Replication

`ctx.replicate.set(player, ...)` (per player; nothing is sent to other players):

- `extra.board` **(contract)**: `{ day = { id, endsAt, slots = { { q, s, r } } }?, week = <same>?,
  list = { { q, s, k?, cap?, p? } }, waiting = { { q, k, p } }, pins = { questId } }`. Sent only when the
  structure changes (deal, claim, reroll, grant, pin, completion). Titles, objective targets and
  rewards are not sent: the client reads them from the module's config, which it already has.
  `list` rows have no `endsAt`; the client takes an event quest's end from the framework's
  replicated `activeEvents`.
- `extra.progIds` **(contract)**: `{ questId }`, sorted: the quests `extra.prog` covers (the board's
  active quests). Sent only when that set changes, so the framework reuses its copy.
- `extra.prog` **(contract)**: a string, the live values including pending progress: per quest of
  `progIds`, in order, its objective values joined by `,`, the quests joined by `;` (`"3;0,12;7"`;
  whole numbers). Coalesced to at most one send per `replicateSeconds`; nothing is sent when nothing
  moved. A string is copied and diffed as one value, where a table per quest costs a copy and a walk
  per send. The client part decodes it (`State.prog(state) -> { [questId]: { number } }`).
- `extra.questOdds` **(contract)**: `{ [tableId] = OddsDetail }`, the same for every player
  (`ctx.replicate.setAll`, once at start): `Rarity.getOddsDetail(tableId, nil, 1)` for every table a
  `roll` reward names. Empty when no quest has a roll reward.
- While the flag is off `board` and `progIds` are `{}` and `prog` is `""`.

So 50 players with 10 active quests progressed every tick cost: one table write per `progress` call,
at most one `extra.prog` string per player per `replicateSeconds`, and one fold tx per player per
`foldSeconds`.

Tradeoff: `replicateSeconds` 1 / 3 / 5 costs about 1.34 / 1.23 / 1.14 ms per tick in the 50-player stress bench (`KITS-QUESTS`, the 5 s figure with `foldSeconds = 120`; known issue O21).

## Client part and UI

`StudWork.use(Quests)` on the client:

- `active() -> { QuestView }` (from state + config), `board()` (the raw `extra.board`),
  `onCompleted(fn(questId)) -> () -> ()` (fires when a quest's status turns complete in state; not for
  the first state after joining), `onClaimed(fn(questId)) -> () -> ()`, `open(tab?)` (opens the
  `"Quests"` screen), `actions.claimQuest/rerollQuest/pinQuest/ackQuest`. `.read` holds the pure state
  readers (`Quests/client/State.luau`, specced).
- **Quest board** (screen `"Quests"`, `UI.registerScreen`, registered at start unless the game
  registered its own first): a `UI.Modal` with tabs Daily / Weekly / Story (and Event while an event
  quest is active; Rewards waiting when `waiting` isn't empty). A row: title, objective lines with
  `value/target` bars, reward chips (every `roll` reward chip shows an Odds button, always visible,
  that opens the UI kit's Odds screen with `detail = extra.questOdds[table]`), Claim (complete), Reroll with the free count (daily slots), pin toggle, and "Resets in
  h:mm" (or "Resets in {days}d {hours}h" from 24 h on; from `endsAt` and server time; a daily or weekly row's `endsAt` is its set's in `extra.board`, an
  event row's is the framework's `state.framework.activeEvents[event]`, since `list` rows carry no end time). Opened only by the player (the HUD button
  `"Quests.button"` or the game calling `open`); never opened automatically.
- **HUD tracker** (widget `"Quests.tracker"`, slot `right`, order 5): up to `pinMax` pinned quests,
  one line each with a bar; a complete one shows a claim hint; tapping a line opens the board. Not
  `Selectable` (it never takes gamepad focus from the game); nothing pinned = nothing drawn.
- **HUD button** (widget `"Quests.button"`, slot `right`, order 4): opens the board; a dot when
  something is claimable.
- **Toasts:** a complete quest and a claimed reward show a UI kit toast (`UI.ToastHost`, theme
  tokens, reduce motion: fade only), queued, never modal.
- **Mobile (667x375) and input:** rows at least `metrics.minTouchTarget` tall; text never below
  `metrics.minTextSize` (the list scrolls instead); the modal fits the short side. Gamepad: every
  button is a UI kit `Button` (`Selectable`); when the board opens from a gamepad, `GuiService.SelectedObject`
  is set to the first Claim (else the first tab), only inside the board the player opened; B closes.
  Touch and mouse work the same.
- Theme tokens only (colours `accent`, `success`, `surface`, `textMuted`; no module colours). Every
  label goes through `UI.text`.

**String keys** (English defaults in `Quests/module.luau`'s `strings` function):
`Quests.title` "Quests", `Quests.button` "Quests", `Quests.tab.daily` "Daily", `Quests.tab.weekly`
"Weekly", `Quests.tab.chain` "Story", `Quests.tab.event` "Event", `Quests.tab.waiting` "Rewards waiting",
`Quests.claim` "Claim", `Quests.claimed` "Claimed", `Quests.reroll` "Reroll",
`Quests.rerollsLeft` "{n} free", `Quests.resetsIn` "Resets in {time}", `Quests.resetsInDays` "Resets in {days}d {hours}h" (from 24 h on), `Quests.pin` "Track",
`Quests.unpin` "Untrack", `Quests.locked` "Locked", `Quests.capReached` "Come back later",
`Quests.progress` "{value}/{target}", `Quests.odds` "Odds", `Quests.empty` "No quests right now",
`Quests.toast.completed` "Quest complete: {title}", `Quests.toast.claimed` "Reward claimed: {title}",
`Quests.reward.currency` "{amount} {currency}", `Quests.reward.item` "{item}",
`Quests.reward.roll` "Roll: {table}", `Quests.reward.custom` "Reward",
`Quests.objective.counter` "{key}", `Quests.objective.source` "{source}",
`Quests.objective.threshold` "Reach {target} {source}", `Quests.objective.ack` "{key}"; and from
config `Quests.quest.<id>` = the id. A game rewords any of them in `GameConfig.strings`.

## Guardrails it relies on

- **Exactly-once claim:** the claim record and every grant in one `ctx.tx` (above); specs and the
  claim-race sim.
- **Client can't progress:** no action adds progress; `ackQuest` only completes `ack` objectives,
  is rate-limited, and boot validation refuses ack-only quests and auto-claim with acks.
- **Random rewards:** only through Rarity's `txApi.roll` (Compliance underneath), at luck exactly 1
  (passed explicitly), from a free table (a paid one is a boot error), with its luck-1 odds disclosed
  by Quests (`extra.questOdds`, the board's Odds button); the paid-random and luck guardrails stay
  in force for every other roll.
- **Nested transactions:** `progress` and `Goals.complete` never open a tx synchronously, so a game
  can call them from inside its own tx.
- **No Robux:** no `ctx.shop`, no `purchaseOps`, no paid-currency spend.
- `special`: only `ctx`, the `StudWork` facade, the UI kit and other modules' public APIs.
- `strings`: every label is a key with an English default; `textfilter`: no client string reaches
  replication.

## Override levels

1. **Defaults:** list `Quests`, define `quests`.
2. **Config:** counts, rerolls, time zone, auto-claim, cadences, per-quest fields, strings.
3. **Replace a piece:** register your own `"Quests"` screen; replace or remove `"Quests.tracker"` /
   `"Quests.button"` (`client.hud.widgets`); build your own UI from `active()`; `registerSource` and
   `registerReward` for what only your game knows.
4. **Switch it off:** leave it out of `modules` (the save section is kept as-is), or flip its `flag`.
5. **Write your own:** `tools/make-module`, the same public API.

## Failure behaviour

| Situation | Behaviour |
|---|---|
| A reward refuses (inventory full, unknown currency) | the claim is refused with a reason; the quest stays complete; nothing was written |
| A custom reward handler errors | the claim tx is discarded; `(false, "reward_failed")`; the error is logged with the quest id |
| A save fails | the framework retries; claim and grant stay together in the session |
| Crash | up to `foldSeconds` of non-completing progress is lost; completions and claims since the last save are lost together with their grants |
| Reset while playing | the tick after the boundary deals new sets to `rotatePerTick` players per tick; `claim`/`reroll`/`grant`/`pin` deal first for that player; `progress` drops increments to the ended period's slot quests until the player's rotation |
| Servers' clocks differ across the boundary | periods only move forward: a set saved by a server that is ahead stays current on one that is behind; nothing is re-dealt or claimable twice |
| A quest removed from config | pruned in the load tx; its slot refilled deterministically unless already claimed; its `done` entry kept |
| A game calls `progress` inside its own tx | fine: it only writes memory; a completion folds on the next tick |
| A game calls `claim`/`reroll`/`grant`/`pin` inside its own tx | the framework's nested-tx error (a programming error); use `tx.after` |
| A source's module disabled later | boot error naming the quest (fix the config or re-enable the module) |
| Flag off | nothing moves; calls refuse `"disabled"`; the board is empty |

---

# Goals

## Config (`config.Goals`)

| Key | Default | Meaning |
|---|---|---|
| `flag` | none | a feature flag; while off nothing is evaluated or written and the pointer is hidden |
| `chain` | `{}` | the first-session chain: an ordered list of Goal (below), at most 20 |
| `chainVersion` | `1` | integer >= 1; bump when you change the chain, so saves made with the old one are re-checked (below) |
| `skippable` | `true` | the player may hide goals (`skipGoals` action / a settings toggle) |
| `nextSeconds` | `5` | 1..60: the provider runs at most once per `nextSeconds` per player past the chain. Relevant signals (`CurrencyChanged` fires on every income tick) only mark the player dirty; a timer wheel re-runs the provider for dirty players when their slot comes up (no per-tick loop over idle players) |
| `sourcePollSeconds` | `5` | 1..60: polling for registered sources without a `changed` signal |
| `pointer` | `{ beam = true, edgeArrow = true, updateSeconds = 0.1, nearStuds = 8, maxStuds = 2000 }` | client: draw the beam / the edge arrow; the shortest interval between two pointer updates (0.05..1); hide the beam within `nearStuds` of the target; hide everything beyond `maxStuds` |

**Goal:**

| Field | Default | Meaning |
|---|---|---|
| `id` | required | `^[%w_]{1,32}$`, unique in the chain |
| `text` | `"Goals.goal.<id>"` | the pill's string key (English default = the id; set the wording in `GameConfig.strings`) |
| `check` | required | one of: `{ quest = id, on = "complete" \| "claimed" }` (default `"complete"`; needs Quests), `{ quest = id, objective = n }` (that objective reached its target; needs Quests), `{ source = name, atLeast = number, params? }` (a value source: `currency`, `rebirths`, `streakDay`, `itemOwned` built in, or registered), `{ call = true }` (the game calls `Goals.complete`), `{ ack = true }` (the client sends `ackGoal(id)` while it is the current goal: "open the shop") |
| `target` | none | the world target: `{ tag = "<CollectionService tag>" }` (the nearest tagged instance to the character), `{ path = "Workspace.Map.Shop" }` (resolved with `FindFirstChild` from the root), `{ position = { 0, 3, 0 } }` or `{ position = { x = 0, y = 3, z = 0 } }` (three finite numbers, array or named), or `{ picker = "<name>" }` (a client function registered with `registerPicker`, e.g. "the nearest open crate") |
| `fallback` | none | a position, `{ x, y, z }` or `{ x = , y = , z = }` (same two forms): where to point when the target isn't streamed in and was never seen on this client |
| `widget` | none | a HUD widget id (`"Economy.currency"`): the pill shows a chevron toward that widget's slot (from `UI.widgets()`); no world beam unless `target` is set too |
| `funnel` | none | an analytics funnel step, logged once per player when the goal is done |

Any goal may also be completed by `Goals.complete` (a game call), whatever its `check`.

**What to point the arrow at.** A goal whose action is on the screen (buying an upgrade from a HUD
button, opening the quest board) has no world object, so use `widget` (the HUD widget id from
`UI.widgets()`, e.g. `"Quests.button"`): the pill shows a chevron toward that button and nothing is
drawn in the world. `target` is optional then. Add a `target` only when there is a real place for the
player to go (a shop counter, a pad): that gives the beam and the edge arrow. Don't aim a UI goal at an
unrelated position (a spawn pad) just to get an arrow. For a "claim your first quest" goal, point it at the
board's HUD button with `widget = "Quests.button"` and say so in the goal's text
(`"Open the Quests button and claim your first quest"`), since nothing else tells a new player where the
board is.

**Check every widget id.** A goal's `widget` (the pill's target) must equal the id of a
widget the HUD registered (`"Quests.button"`, `"Economy.currency"`, `"Goals.goal"` ...; the list is
`UI.widgets()`). Boot can't check it and the offline sim never renders the HUD, so a typo (`"Quest.button"`)
shows only in Studio as a goal pill with no chevron: open a playtest and look at each widget goal
once.

**Validation at boot** (Goals' `start`, all problems together): a bad or duplicate id; a `check`
that isn't exactly one of the forms; `quest` checks while Quests isn't enabled, or naming a quest
Quests doesn't have, or an objective index it doesn't have; an unknown source or a built-in whose
module is off; a non-finite `atLeast`; a `target` that isn't one of the forms; a position that isn't three numbers (array or named `x`, `y`, `z`);
more than 20 goals. A goal whose `funnel` step isn't in `GameConfig.analytics.funnel` is a boot
**warning**, not an error ([Funnel steps](#funnel-steps)).

## How the chain moves

- The **current goal** is the first goal in `chain` that isn't done. A goal whose check is met while
  it isn't current (**out of order**: the player bought the upgrade before collecting coins) is marked
  done at once, and its funnel step is logged then; the pointer skips it when it gets there.
- Checks are evaluated on the signals that can change them (Quests `Completed`/`Claimed`/
  `Progressed`, Economy `CurrencyChanged`, Rebirth `Rebirthed`, Streak `StreakAdvanced`, Inventory
  `ItemAdded`/`ItemRemoved`, a registered source's `changed`), on load, and by polling for registered
  sources without a signal, for not-done goals only. A signal marks the player dirty only when it can
  change one of the player's not-done goals: `Completed`/`Claimed` for a goal on that quest,
  `Progressed` for an objective goal on a quest that moved, `CurrencyChanged` when the new balance
  reaches an open currency goal's `atLeast`, the others for a goal on their source (past the chain,
  every signal marks the player for the `setNext` provider). Dirty players are checked on Goals' next
  1-second tick, at most once per player per tick (so an income tick's `CurrencyChanged` costs a
  lookup, not a check). Each change is one `ctx.data.update`.
- **Returning players don't get a tutorial.** A `goals` section is new when its `v` is 0 (the
  default). On that first load, a player with `ctx.framework.sessions(player) > 1` (they played
  before the game added Goals) starts finished: `fin = true`, no funnel steps, no `ChainDone`; only
  the `setNext` provider applies. A new player (`sessions == 1`) starts the chain. Either way `v`
  becomes `chainVersion`.
- When the last goal is done: `fin = true`, `ChainDone` fires once, and the pointer hands over to the
  `setNext` provider; with no provider (or when it returns nil) the pill and pointer hide.
- **The chain changing between versions:** on load, when the saved `v` differs from `chainVersion`,
  done ids no longer in the chain are dropped, the current goal is recomputed in the new chain, and
  every not-done goal is checked once. A player who had **finished** the old chain stays finished
  (new goals added later are for new players; a veteran isn't sent back to a tutorial).
- Goals never grant rewards. A goal can point at a quest, which has its own reward and claim.

### Typing a goal chain in a strict file

A chain whose goals use different `check` and `target` shapes makes a strict `Balance.luau` report
"Table type ... not compatible" when it is written inline in a table whose type is inferred. Annotate
the chain with the kit's type; it is a list of `Goal` whose `check` and `target` fields are all
optional:

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GoalTypes = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Goals"):WaitForChild("shared"):WaitForChild("Types"))

local CHAIN: GoalTypes.Chain = {
	{ id = "firstCoins", check = { source = "currency", atLeast = 50 }, target = { tag = "CoinSpot" }, funnel = "FirstCoins" },
	{ id = "openShop", check = { ack = true }, widget = "Quests.button" },
	{ id = "reachTower", check = { call = true }, target = { position = { x = 0, y = 3, z = 0 } }, fallback = { 0, 3, 0 } },
}
-- then:  Goals = { chain = CHAIN }
```

`Types` also exports `Goal`, `Check`, `Target`, `Position` (array or named) and `Config`. A cast
(`:: { any }`) also works but turns off every check of the chain.

### `Game.nextGoal` and the Goals pill

The scaffolded client (`src/client/Main.client.luau`) passes `nextGoal` to `Client.Hud.mount`, which
draws the framework's `"Game.nextGoal"` pill ("Next: rebirth at 1.2K"). With Goals on there are two
pills. Pick one:

- **Keep Goals' pill, remove the scaffold's:** delete the `nextGoal = function(): string? ... end,`
  entry from the `Client.Hud.mount({ ... })` call, then delete what only it used or `tools/lint` fails
  on unused variables: in the scaffold that is `rebirthCost`, `economy` (with the `EconomyDef`
  require) and `PRIMARY`; keep `rebirth` and `Balance` if the Rebirth button or the Rarity/Upgrades code
  still use them. Run `tools/lint`; it names every unused local.
- **Keep the scaffold's pill, hide Goals':** `client.hud.widgets["Goals.goal"] = false` in
  `GameConfig.client.hud`.
- **Or just hide the framework's:** `client.hud.widgets["Game.nextGoal"] = false` (the `nextGoal`
  function stays but nothing draws it).

## API (server)

- `current(player) -> GoalView?` **(contract)**: frozen, nil when hidden by the flag, before load,
  or after the chain with no next.
  `GoalView = { id: string?, index: number, count: number, text: string, args: { [string]: any }?,
  target: Target?, widget: string?, isNext: boolean, hidden: boolean }` (`isNext` = it came from
  `setNext`; `id` is nil then).
- `complete(player, goalId) -> (boolean, string?)` **(contract)**: marks a goal done (any check
  kind). Reasons: `"disabled"`, `"not_loaded"`, `"unknown_goal"`, `"done"`, decided from the
  committed state. **Safe inside a transaction:** it never opens a tx itself; an accepted completion
  is queued and written on Goals' next tick (with its funnel step and `GoalChanged`), so `true` means
  accepted. `skip` opens its own tx (don't call it inside one; use `tx.after`).
- `setChain(chain: { Goal }, version: number?)`: replaces the config chain with one built in code,
  validated the same way; errors when invalid or after the first player loaded (call it in `start`).
- `setNext(fn: (player) -> NextGoal?)`: the "what's next" provider, `NextGoal = { text: string,
  args: { [string]: any }?, target: Target?, widget: string? }` (`text` a string key; wire-safe values
  only: a position is the array `{ x, y, z }` or the named form; the wire carries the array). Must not yield; an error counts as nil and is logged once per
  minute. A second call replaces the provider. Every `text` it can return (`"game.next.rebirth"`)
  must be in `GameConfig.strings`, or the framework warns about a missing key.
- `skip(player, hidden: boolean) -> boolean` **(contract)**: the player's "hide goals" setting
  (saved). Goals keep being tracked and funnel steps logged while hidden; only the UI hides. `false`
  when `skippable` is false.
- **extensions:** `registerSource(name, { read: (player) -> number?, changed: SignalLike? })`
  (during `init`; as in Quests, its own registry: Goals works without Quests).
- **signals:** `GoalChanged(player, goalId: string?, previousId: string?)`, `ChainDone(player)`.
- **Console:** `goals state [userId]` (Studio or admins); `goals complete <goalId> [userId]` and
  `goals reset [userId]` (Studio only).

## Actions

| Action | Arguments | Limit | Server checks |
|---|---|---|---|
| `skipGoals` | `hidden: boolean` | rate 0.5/s, burst 2 | `skippable`; then `skip` |
| `ackGoal` | `goalId: string(1..32)` | rate 1/s, burst 3 | the id is a chain goal with `check = { ack = true }`, not done, and **the current goal** (an out-of-order ack is refused, so a client can't mark ack goals ahead and log their funnel steps early); marks it done. Nothing is granted (goals have no rewards) |

## Funnel steps

Each goal's `funnel` step is logged with `ctx.analytics.funnel(player, step)` in `tx.after` of the
update that marked the goal done. The framework logs a step **once per player** (it records it in
`_framework.funnel`) and only if the step is listed in `GameConfig.analytics.funnel`: list every
goal's step there, in chain order. A goal whose `funnel` isn't listed gets a **boot warning** from
Goals' `start` (`goal 'x': funnel step 'Y' is not in GameConfig.analytics.funnel (it will never be
logged)`; never an error, the game still boots). Quests' per-quest `funnel` works the same way and is
not checked. A first-session spec ([below](#testing-your-first-session)) is what proves the step logs.

**Don't reuse a step your scaffold already logs.** The generated game logs some steps by hand (for
example `FirstCollect` in the template's game module). If a goal's or quest's `funnel` names the same
step, the framework still logs it once per player (it dedupes), but the sim's `server.calls` records
**both calls**, so a spec that counts `funnel` calls for that step sees 2. The same happens when a quest
and a goal share a step. Give every goal its own new step name (`GoalCollect`, not `FirstCollect`), or
make the spec count each step once per distinct name (collect the `args` of the `funnel` calls into a
set) instead of counting calls. Add the new names to `GameConfig.analytics.funnel` and to `STEPS` in your spec.

## Save data

Section `goals`, version 1, not replicated:
`{ done = { [goalId] = true }, fin = false, hide = false, v = 0 }` (`v = 0` = never loaded with
Goals; then the `chainVersion` it was last checked against). `data.sanitize` is config-free shape
repair only (types; `done` cut at 20 entries; never errors). Dropping done ids the chain no longer
has, and the version re-check, run in Goals' `onPlayerLoaded` tx, so a removed goal id in an old save
never crashes a load. At most 20 entries; nothing grows over time.

## Replication

`extra.goal` (per player) **(contract)**: `{ id?, i, n, text, args?, target?, widget?, next, hidden }`:
sent when the current goal changes, when `setNext`'s answer changes (compared by value), and when
`hide` changes. `target` here is the config's target or the provider's, wire-safe. Nothing per tick.

## Client part: the pill and the pointer

`StudWork.use(Goals)` on the client: `goal() -> GoalView?` (from state), `pointer() -> { position:
Vector3?, onScreen: boolean, distance: number?, from: "instance" | "lastKnown" | "fallback" |
"position" | nil }`, `onChanged(fn(GoalView?)) -> () -> ()`, `registerPicker(name, fn(character) ->
(Vector3 | BasePart | Model)?)`, `setHidden(boolean)` (fires `skipGoals`), `actions.skipGoals/ackGoal`.

- **Pill** (widget `"Goals.goal"`, slot `topCenter`, order 4): the goal's text (one line,
  ellipsized, at most 60% of the screen width), a chevron toward the `widget`'s slot when set.
  `Active = false` and not `Selectable`: it never takes input or gamepad focus. It sits next to the
  framework's `"Game.nextGoal"` pill (use one or the other, see
  [below](#gamenextgoal-and-the-goals-pill)). `topCenter` may also hold `Economy.currency` and
  `Social.mailbox`: check at 667x375 that nothing overlaps (the Studio block does).
- **World beam:** exactly one `Beam` per client between two `Attachment`s parented to
  `workspace.Terrain` (a Beam renders only with both attachments under Workspace), from just in front
  of the character toward the target, `FaceCamera`, `Segments = 1`, colour from the theme token
  `colors.goalPointer` (Goals' theme contribution, default `#FFB547`). Hidden within `nearStuds`, beyond
  `maxStuds`, with no target, or while hidden. Updated at most every `updateSeconds` and only when the
  target or the character moved more than half a stud: never per frame per goal.
- **Edge arrow:** one `ImageLabel` in the HUD layer, shown when the target is off-screen or behind the
  camera (`Camera:WorldToViewportPoint`), clamped to the screen edge inside the safe area and rotated
  toward the target; same budget as the beam. Not `Active`, not `Selectable`.
- **Target resolution and StreamingEnabled:** `tag` = the nearest instance with that tag that is
  currently streamed in (the client keeps the tagged set with `CollectionService:GetTagged` once
  plus `GetInstanceAddedSignal`/`GetInstanceRemovedSignal`, and re-picks the nearest at most every
  0.5 s, not on every pointer update); `path` = `FindFirstChild` along the path; `picker` = the registered function
  (pcall'd). The client remembers the **last known position** of each goal's target. When the target
  isn't present (streamed out instances are parented to nil), it points at the last known position,
  else at `fallback`, else at a `position` target; with none of those it shows the pill only (no
  beam, no edge arrow). A game whose targets are small and must always resolve can also set those
  models' `ModelStreamingMode` to `Persistent` (Roblox recommends it only for a few parts).
- **Never blocks, never forces:** no modal, no screen opened, no camera change, no input sink, no
  `GuiService.SelectedObject` change, no movement lock. The first three minutes play exactly as they
  would without Goals, plus a pill and an arrow.
- **Reduce motion** (the framework's `CoreReducedMotion` attribute or `GuiService.ReducedMotionEnabled`):
  no pulse or bob; the edge arrow moves without easing.
- **Strings:** `Goals.hide` "Hide goals", `Goals.show` "Show goals", `Goals.goal.<id>` = the id; the
  next goal's `text` is the game's key.

## Override levels

1. Defaults: list `Goals`, define `chain`.
2. Config: targets, fallbacks, pointer budget and looks, `goalPointer` colour, strings.
3. Replace a piece: replace `"Goals.goal"` in `client.hud.widgets`; turn the beam or edge arrow off
   and draw your own from `pointer()`; `registerPicker`, `registerSource`, `setChain`, `setNext`.
4. Switch it off: leave it out of `modules` (the section stays) or flip its `flag`.
5. Your own module on the same API.

---

# Both modules

## String keys and namespaces

A key is `<namespace>.<name>` ([localization](localization.md)). The rules for this kit:

- **Your own text uses `game.*`**: quest `title`/`text`, objective `label`, goal `text` and a
  `setNext` `text` (`"game.quest.openChests"`, `"game.objective.touchCoins"`, `"game.goal.firstCoins"`,
  `"game.next.rebirth"`), each with its English in `GameConfig.strings`. Any `game.*` key is allowed.
- **The kit's own keys** (`Quests.*`, `Goals.*`, listed above) have English defaults; reword them in
  `GameConfig.strings`. `Quests.quest.<id>`, `Quests.objective.*` and `Goals.goal.<id>` are the
  fallbacks used when you set no key: the id or the raw config key.
- **Don't invent keys in the kit's namespace** (`Quests.label.coins`): a key outside `game.*` that no
  module defines is an "unknown key" boot warning, and a module's own `strings` may only define
  `<ModuleName>.*` keys. Use `game.*`.
- A key with no English shows the key itself and warns once. In `GameConfig.strings`:

```lua
strings = {
	["game.quest.openChests"] = "Open 3 chests",
	["game.objective.openChests"] = "Chests opened",
	["game.goal.firstCoins"] = "Collect your first coins",
	["game.next.rebirth"] = "Rebirth for a boost",
	["Quests.claim"] = "Collect", -- rewording a kit key
},
```

## Dependencies

| Module | `dependsOn` | `optional` |
|---|---|---|
| Quests | none | `Economy`, `Items`, `Inventory`, `Rarity`, `Rebirth`, `Streak`, `Leaderboards` (each used only when the config references it; referenced but not enabled = boot error) |
| Goals | none | `Quests`, `Economy`, `Inventory`, `Rebirth`, `Streak` (and `ctx.framework.sessions` for returning players) |

Every use checks `ctx.isEnabled(Ref)` first. **Your game module** needs `Quests` / `Goals` in its own
`dependsOn` (or `optional`) to call them ([step 2](#add-quests-and-goals-to-an-existing-game)). A game listing only `Goals` (game calls, registered
sources) or only `Quests` with counters and custom rewards boots and works.

## Analytics

Goals: one funnel step per goal (above). Quests: the optional per-quest `funnel` on first claim, and
`ctx.analytics.custom(player, "QuestClaimed", 1, { quest = id, kind = kind })` on every claim (in
`tx.after`).

## Retention design

- **Days, not hours.** Playtime is understood to count for discovery only up to about an hour per
  player per day, while returning on more days keeps counting, so the defaults reward coming back
  over staying longer: 3 daily quests that take minutes (targets a
  new player reaches in 5–10 minutes of normal play), 2 weekly quests that need several days, no
  quest that needs a long single session, and a reset at one fixed time (a fixed UTC offset: with
  daylight saving time the local reset hour shifts by one twice a year). The examples on this page
  follow that; scale targets to your game's normal per-minute rates in `Balance.luau`.
- **No tutorial wall before 3 minutes.** Goals adds a pill and one arrow and nothing else: no modal,
  no forced camera, no forced screen, no input lock. The first goal should be something a new player
  does in the first 30 seconds anyway; the board is never auto-opened.
- **Why the daily set is deterministic and saved.** Players compare and talk about "today's
  quests", and a set that changed on rejoin would invite rejoin-fishing for an easier set. A saved
  set plus a deterministic seed (user, period, pool version, slot, reroll index) means a rejoin, a
  server hop or a crash rollback gives the same set and the same reroll results, so the one free
  reroll per slot is the only way to change a quest.
- **Rewards waiting.** A complete quest that wasn't claimed before the reset is kept (`waiting`), so a
  player who logs off at 23:58 doesn't lose it.
- **Story chains and one-time quests** give a direction past the first session; repeatables have a
  cap per period so they top up a session without becoming a grind.

## Tests

Specs live in `packages/kits/quests/tests/` (Lune; the kit folder's `tests/` isn't synced by Rojo),
plus `Quests/client/State.spec.luau` and `Goals/client/*.spec.luau`, and the fixture game's
`examples/quests-demo/src/**/*.spec.luau`:

- Quests: the quick start; each objective kind and built-in source with and without its module
  (boot errors); validation (dangling chain steps, unknown sources and rewards, bad weights,
  ack-only); the deal (pinned seed values, same set after rejoin, after a server hop, after a crash
  rollback; a removed quest refilled, a claimed slot not refilled); rerolls (count, determinism,
  `seen` snapshot, requirements changed after the deal don't change the pool); periods at the
  boundary at `utcOffsetHours` -5, 0 and +9 and for both `weekStartsOn`; **clock skew** (two harnesses
  sharing a `memoryStore()` with `startTime`s on either side of the boundary: no re-deal, no second
  claim); batching (no `data.update` per increment; fold cadence; leave and shutdown folds; a crash
  loses only pending; a completion folds on the next tick); `progress` from inside a game tx and from
  inside a `registerReward` handler; claims (every row of the exactly-once table, waiting quests, the
  same id current and waiting, chains, repeatable caps, event windows and event quests to `waiting`,
  `inventory_full` writing nothing); roll rewards (luck 1 with a player luck boost, a paid table is a
  boot error, `extra.questOdds`); a client can't progress (no action exists; `ackQuest` limits); an
  old save with a removed id, a changed kind and over-long lists loads, prunes on load, never errors;
  no config at all boots.
- Goals: works with no Quests; out-of-order completion; a removed goal id in an old save; the chain
  changing between versions (finished stays finished); a returning player starts finished; funnel
  steps logged once; an out-of-order `ackGoal` refused; `complete` from inside a game tx; `setNext`
  hand-over and its `nextSeconds` throttle; `skip`; pointer resolution with the target streamed out
  (last known, fallback, none); the tag cache.
- Sims (`StudWork.test.sim`): the claim race (a double claim, a claim during shutdown, a claim then
  rejoin on a second server, each granting once); a daily reset across the boundary with the same set
  after a rejoin; a new player's first 3 minutes in the fixture game (every funnel step once, no
  kick, no errors) plus a client-side check with the Quests and Goals client parts running (no screen
  opened, `GuiService.SelectedObject` and the camera untouched). The same server sim runs in a game
  of your own: see [Testing your first session](#testing-your-first-session).
- Bench: `tools/bench 5 KITS-ALL KITS-QUESTS` (both modules on, 50 players x 10 active quests
  progressed every tick).

## Testing your first session

Put a spec next to your game's `Boot.spec.luau` (`src/server/FirstSession.spec.luau`) that boots
your real game in the multi-server sim, plays a new player's first 3 minutes with the same calls
your game makes, and checks that every goal's funnel step is logged exactly once with nothing
blocking. Adapt the scripted steps to your chain:

```lua
--!nocheck
local StudWork = require(game:GetService("ReplicatedStorage"):WaitForChild("Framework"))
local F = StudWork.test.sim

-- relative to where tools/test runs: the project root in a single-game project,
-- "games/<game>/default.project.json" in a games repo
local PROJECT = "default.project.json"
local STEPS = { "FirstCoins", "OpenedBoard", "FirstClaim", "ReachedTower" } -- your analytics.funnel steps

local function funnelCount(server, step: string): number
	local n = 0
	for _, c in server.calls do
		if c.service == "Analytics" and c.fn == "funnel" and table.find(c.args, step) then
			n += 1
		end
	end
	return n
end

describe("first session", function()
	it("a new player's first 3 minutes: every goal once, nothing blocking", function()
		local world = F.world()
		local server = F.gameServer(world, PROJECT)
		local p = server:join(101)
		assert(world:advanceUntil(function() return server:isLoaded(p) end, 30), "loaded")
		local Goals = server:use("Goals")
		expect(Goals.current(p).id).toBe("firstCoins") -- the first goal is set on load: no world:advance needed

		-- the player's first 3 minutes, scripted with what your game does on the server
		server:use("Economy").grant(p, 25, "test")              -- picked up coins
		world:advance(2)
		server:action(p, "Goals", "ackGoal", "openBoard")        -- opened the quest board
		server:use("Quests").progress(p, "talkedToGuide")       -- your counter: the key that completes `story1`
		world:advance(2)
		server:action(p, "Quests", "claimQuest", "story1")
		Goals.complete(p, "reachTower")                          -- your game's call
		world:advance(180)

		for _, step in STEPS do
			expect(funnelCount(server, step)).toBe(1)
		end
		expect(Goals.current(p) == nil or Goals.current(p).isNext).toBe(true) -- chain done
		expect(server:isLoaded(p)).toBe(true) -- not kicked
		expect(world:errors()).toEqual({})
	end)
end)
```

**Daily quests are dealt per player, so don't assume a quest id in a spec.** The deal is a function of
the user id, the period and the pool (a user may not be dealt `collectCoins` today), so a spec that
needs a quest and silently skips when it isn't dealt proves nothing. Read what was dealt and drive
that:

```lua
local Quests = server:use("Quests")
for _, q in Quests.active(p) do -- QuestView: id, kind, status, objectives = { { kind, key, source, value, target } }
	if q.kind == "daily" then
		for _, o in q.objectives do
			if o.kind == "counter" then
				Quests.progress(p, o.key :: string, o.target - o.value)
			end
		end
		-- source/threshold objectives: move the source (Economy.grant for currencyEarned) instead
	end
end
world:advance(2) -- a completion is written on the next 1 s tick
-- then claim whatever is complete: Quests.state(p, id).status == "complete"
```

To make sure a particular quest is dealt, give the spec a config whose daily pool has exactly
`daily.count` entries (then every player is dealt all of them), or loop `server:join(userId)` over a few
user ids until `Quests.active` contains it and `assert` that it did. Don't skip silently.

The server sim can't see the UI. That Goals never opens a screen, sets `GuiService.SelectedObject`
or moves the camera is checked by the kit's own specs and in Studio; in your game, check in a Studio
playtest that nothing you add opens a screen in the first 3 minutes.

## Not verifiable offline

The board and the beam on real phones (Device Emulator and a device), the reset time against real
players' days, save size after weeks of play, `StreamingEnabled` behaviour on a large map, and
whether the first-session goals help without nagging. Live checklist: `docs/manual-qa.md` (entries
in `docs/pending/quests.md`).
