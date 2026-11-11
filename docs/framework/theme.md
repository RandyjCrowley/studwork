# Theme guide

One merged theme drives every colour, font, size and sound in the framework UI (module-api.md §13).
The merge lives in `packages/framework/shared/Theme.luau`; HUD slots are `packages/ui/HudLayout.luau`
and the screen registry is `UI.registerScreen` (`packages/ui`).

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
	metrics = { cornerRadius = 8, minTouchTarget = 48 },
	sounds = { coin_tick = { id = 16480580213, volume = 0.3, pitch = 1 } },
	rarity = { preset = "standard7" },            -- or { tiers = { ... } }
},
```

## Tokens

| Group | Keys (framework defaults) | Notes |
|---|---|---|
| `colors` | `background` `#1E2235`, `surface` `#2B3050`, `surfaceAlt` `#3A4170`, `outline` `#14172A`, `text` `#FFF8EC`, `textMuted` `#B9BEDA`, `accent` `#FFB547`, `accentAlt` `#5ED1C9`, `currency` `#FFD23F`, `success` `#6BD66B`, `danger` `#FF5D6C`, `warning` `#FFD23F`, `sunlight` `#FFE7B8`, `shadow` `#5A6AA8`, `backdrop` `#000000`, `dropShadow` `#000000` | modules add their own (`leaderboardHighlight`) |
| `fonts` | `display` Fredoka One, `displayFallback` Builder Sans, `body` Builder Sans | `rbxasset://fonts/families/*.json` |
| `metrics` | `cornerRadius` 12, `padding` 12, `strokeThickness` 2, `minTouchTarget` 44, `text.small` 14, `text.body` 18, `text.title` 24, `text.number` 28 | pixels; 44 px is the mobile touch minimum |
| `sounds` | `rarity_common` ... `rarity_secret`, `coin_tick`, `purchase`, `rebirth`, `ui_click`, `ui_error`, `streak`, `event_start` | `{ id, volume?, pitch? }` (id 0 = silent) |
| `rarity` | contributed by Collection's Rarity: `{ tiers = <resolved list> }` | tier order is list order |

A key in `GameConfig.theme` (or a preset table) under `colors`, `fonts` or `metrics` that neither
the framework nor an enabled module defines is a boot **warning** naming it
(`theme.metrics.minTouch: unknown theme token (typo?)`), like an unknown config key: no UI reads
an unknown token, so the override would do nothing. An unknown group (`colours`) warns too.

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
| replace a widget's component (same slot and order) | `client = { hud = { widgets = { ["Economy.currency"] = MyCounter } } }` |
| move or add a widget | `client = { hud = { widgets = { ["Game.boost"] = { slot = "right", order = 2, component = MyBoost } } } }` |
| replace the whole HUD | `client = { hud = MyHud }` (a ModuleScript returning a React component) |
| no HUD | `client = { hud = false }` |
| the default | `client = { hud = "default" }` or leave it out |

A bare component (a function, memo or class component) keeps the replaced widget's slot, order and
module gate; it can only replace a widget that exists. A table `{ slot, order?, component }` places
a widget anywhere. Slots: `topLeft`, `topCenter`, `topRight`, `left`, `right`, `bottom`.

A module registers a widget with `UI.registerWidget(id, { slot, order?, component })` (see the
[example](../../examples/modules/session-leaderboard/README.md)); `StudWork.Client.Hud.addWidget`
is the same call on the client facade.

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
  `CurrencyCounter`, `OddsTable`, ...). `tools/lint` flags hex colours, `Color3.fromRGB` literals
  and asset ids in UI and client code outside theme and config files (the `theme` guardrail).
- UI kit buttons fit their text for any theme font (`TextScaled` with the theme size as the
  maximum), so a wider display font doesn't overflow.
- Paid random items: show the server's disclosed odds (`UI.OddsTable` with the replicated
  `odds[tableId]`) before rolling or prompting, and don't prompt players whose
  `state.framework.paidRandomRestricted` isn't `false`.
