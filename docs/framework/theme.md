# Theme guide

One merged theme drives every colour, font, size and sound in the framework UI. Status: the theme
system, HUD slots and the screen registry are being built in core v1.3.0 Phase 1 (agent D) against
module-api.md §13; this page documents that contract. Today's code merges the tree
(`packages/framework/shared/Theme.luau`) and validates colours; presets beyond
`framework-default`, HUD slots and `UI.registerScreen` land with D's branch.

## The merge order

1. the framework defaults (the `framework-default` preset),
2. each enabled module's `theme` contribution, in boot order,
3. the game's `GameConfig.theme`.

Maps deep-merge, so a partial override changes only what it names. The result is frozen:
`ctx.theme` on the server is read-only.

```lua
-- GameConfig
theme = {
	preset = "framework-default",                 -- or a preset table
	colors = { accent = "#FF5DA2" },              -- #RRGGBB, checked at boot
	fonts = { display = "rbxasset://fonts/families/LuckiestGuy.json" },
	metrics = { cornerRadius = 8 },
	sounds = { coin_tick = { id = 16480580213, volume = 0.3, pitch = 1 } },
	rarity = { preset = "standard7" },            -- or { tiers = { ... } }
},
```

## Tokens

| Group | Keys (framework defaults) | Notes |
|---|---|---|
| `colors` | `panel` `#1B2340`, `accent` `#FF8A3D`, `secondary` `#2EC4B6`, `currency` `#FFD23F`, `text` `#FFFFFF` | modules add their own (`leaderboardHighlight`) |
| `fonts` | `display` Fredoka One, `body` Builder Sans | `rbxasset://fonts/families/*.json` |
| `metrics` | `cornerRadius` 12, `padding` 12, `outline` 2, `minTouch` 44 | pixels; 44 px is the mobile touch minimum |
| `sounds` | none by default; modules contribute theirs (`coin_tick`, rarity stingers) | `{ id, volume?, pitch? }` |
| `rarity` | contributed by Collection's Rarity: `{ tiers = <resolved list> }` | tier order is list order |

A module contributes tokens in its definition:

```lua
theme = { colors = { questGold = "#FFD23F" }, sounds = { quest_done = { id = 123, volume = 0.4 } } },
```

The game's `GameConfig.theme` wins over every module. Colour values must be `#RRGGBB` (boot
error otherwise).

## Rarity look

Rarity tiers are owned by Collection: `config.Rarity.tiers = "standard7"` (default) or a custom
ordered list `{ { id, color?, glow?, soundKey? } }`. Rarity contributes the resolved list as
`theme.rarity.tiers`, and the UI reads tier colours, glows and stinger sounds from there. Item
`rarity` strings are validated against the active list. See [Collection](kits/collection.md).

## HUD

The default HUD is a layout of named slots: `topLeft`, `topCenter`, `topRight`, `left`, `right`,
`bottom`. Modules contribute widgets (Economy: currency counter and rate; Social: the mailbox
badge; the game: a next-goal widget). Widget ids are `<Module>.<widget>`.

| You want | GameConfig |
|---|---|
| remove a widget | `client = { hud = { widgets = { ["Social.mailbox"] = false } } }` |
| replace a widget | `client = { hud = { widgets = { ["Economy.currency"] = MyCounter } } }` |
| replace the whole HUD | `client = { hud = MyHud }` (a ModuleScript returning a React component) |
| no HUD | `client = { hud = false }` |
| the default | `client = { hud = "default" }` or leave it out |

How a module registers a widget is part of D's UI work; the example module calls
`UI.registerWidget(id, { slot, component })` when the UI package offers it (see the
[example](../../examples/modules/session-leaderboard/README.md)). Until then generated games mount
the HUD with `StudWork.Client.Hud.mount({ nextGoal = fn, onMailbox = fn })`.

## Screens

```lua
local UI = require(ReplicatedStorage:WaitForChild("UI"))
UI.registerScreen("Leaderboard", LeaderboardScreen) -- a React component
UI.open("Leaderboard", props)
```

Modules register default screens (Collection: `Odds`, `Inventory`; Social: `Mailbox`). A game
replaces one by registering a screen with the same name. `tools/make-screen <game> <Name>` writes
a screen and registers it from `src/client/Screens/init.luau`.

## Rules for UI code

- Every UI component and Feedback call reads theme tokens: no hex colours, font paths, sizes or
  sound ids in UI code. Build from the UI kit (`ReplicatedStorage.UI`: `Button`, `Panel`, `Modal`,
  `CurrencyCounter`, `OddsTable`, ...). A lint rule for hex colours and asset ids outside theme
  files is planned (module-api.md §13).
- Paid random items: show the server's disclosed odds (`UI.OddsTable` with the replicated
  `odds[tableId]`) before rolling or prompting, and don't prompt players whose
  `state.framework.paidRandomRestricted` isn't `false`.
