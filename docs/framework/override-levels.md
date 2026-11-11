# The five override levels

Go only as deep as you need ([philosophy §2](../philosophy.md)). Each level is a supported path.
Examples use the generated game layout (`games/<g>/src/shared/Config/`).

| Level | You do | Where |
|---|---|---|
| 1. Use the defaults | nothing | `modules = { ... }` |
| 2. Change config | set values | `Balance.luau` (`config.<Module>`), `GameConfig.theme` |
| 3. Replace a piece | supply your own preset, theme, screen or widget | `GameConfig.theme`, `GameConfig.client.hud`, `UI.registerScreen` |
| 4. Switch a kit off | leave it out of `modules` | `tools/new-game --modules`, or delete the line |
| 5. Write your own module | the public module API | `tools/make-module` |

## 1. Use the defaults

```lua
modules = {
	require(Collection:WaitForChild("Items")),
	require(Collection:WaitForChild("Rarity")),
	require(Collection:WaitForChild("Inventory")),
	require(EconomyKit:WaitForChild("Economy")),
},
```

That is a working collect-and-earn game: 7 rarity tiers, weighted rolls with pity and full odds
disclosure, items that earn every second, a HUD with the currency and the rate. The defaults and
why they were chosen: [philosophy §1](../philosophy.md#1-opinionated-defaults), and each kit page.

## 2. Change config

Every module's config lives under `GameConfig.config.<ModuleName>`, which generated games keep in
`Balance.luau`. It is merged over the module's defaults and checked against its schema at boot.
Unknown keys are reported as warnings, so typos show up.

```lua
-- Balance.luau
Economy = {
	primaryCurrency = "Coins",
	income = { tickSeconds = 5, source = "owned" }, -- earn every 5 s, from every owned item
	multiplierStacking = "add",
},
Streak = {
	streak = { graceHours = 36, rewards = { { day = 1, amount = 100 } }, loopAfter = 7 },
},
```

The keys of each kit module are on its kit page. In core v1.3.0 the kit modules still take their
v1.2 balance keys under `config.<Module>`; the Phase 1 kit rewrite keeps names and meanings
(PHASE1-CONTRACT.md "Additive only").

## 3. Replace a piece

**A rarity preset.** Rarity tiers come from config, owned by the Collection kit (pinned by
PHASE1-CONTRACT.md, being built in Phase 1):

```lua
Rarity = {
	tiers = {
		{ id = "Bronze", color = "#CD7F32" },
		{ id = "Silver", color = "#C0C0C0" },
		{ id = "Gold", color = "#FFD23F", soundKey = "r3" },
		{ id = "Diamond", color = "#7DF9FF", glow = "#FFFFFF" },
	},
	rarityTables = { ... }, -- items now use rarity = "Bronze" ... "Diamond"
},
```

**Your own theme.** Partial overrides deep-merge over the `framework-default` preset and every
module's contribution ([theme guide](theme.md)):

```lua
theme = {
	colors = { accent = "#FF5DA2" },
	metrics = { cornerRadius = 8 },
	sounds = { coin_tick = { id = 123456, volume = 0.3 } },
},
```

**A screen.** Register a screen under the same name as a module's to replace it, or under a new
name to add one:

```
tools/make-screen my-game Inventory
```

**A HUD widget, or the whole HUD.** `client.hud.widgets = { ["Social.mailbox"] = false }` removes
one widget; `client.hud = MyHud` (a ModuleScript returning a React component) replaces the layout;
`client.hud = false` turns it off. See the [theme guide](theme.md#hud) for the slot names.

## 4. Switch a kit off

Leave its modules out of `modules`. A collection game without Economy:

```
tools/new-game card-game --modules Items,Rarity,Inventory
```

Items without an `economy` field earn nothing, which is valid: they are cards, cosmetics or quest
items. Calling a module that isn't listed fails with `"Economy is not enabled in GameConfig.modules"`
(never a silent nil). A module's hard dependencies must stay listed: removing Items while
Inventory is listed fails the boot and names the missing module. A switched-off module's save
section is kept untouched.

Some config only makes sense with another module. The boot check says which, for example
`balance.income.source = "displayed" needs the Plot module`; `tools/new-game --modules` already
writes the right value for the modules you chose.

## 5. Write your own module

```
tools/make-module Quests --game my-game
```

A module gets the same API the kits use: its own config with defaults, its own save section and
migrations, replicated state, the shared ticker, dependencies (hard or optional) and their APIs,
signals and extensions, purchase operations, client actions, theme tokens, screens and HUD
widgets. If a kit can do something, so can your module.

```lua
-- module.luau
return StudWork.defineModule({
	name = "Quests",
	version = "0.1.0",
	framework = "^1.3.0",
	optional = { Economy },
	config = { schema = { dailyCount = "integer(1..10)" }, defaults = { dailyCount = 3 } },
	data = { key = "quests", version = 1, default = { done = {} }, replicate = { "done" } },
})

-- server/init.luau
function Quests.start(ctx)
	ctx.lifecycle.onPlayerLoaded(function(player)
		ctx.data.update(player, function(section) ... end)
	end)
	if ctx.isEnabled(Economy) then
		ctx.deps[Economy].signals.CurrencyChanged:Connect(function(player, currency, balance, delta) ... end)
	end
end
```

A complete, tested example: [SessionLeaderboard](../../examples/modules/session-leaderboard/README.md).
Reference: [module API](module-reference.md).
