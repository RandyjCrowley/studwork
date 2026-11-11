# UI kit (`ReplicatedStorage.UI`)

React-lua (jsdotlua React 17.2.1 + ReactRoblox) components themed from the one merged theme
(`GameConfig.theme`, module-api.md §13; `Framework/shared/Theme`). No component hardcodes a colour,
font, size or sound id. Games require it and never edit it (requests go to `CORE_REQUESTS.md`).

```lua
local UI = require(ReplicatedStorage:WaitForChild("UI"))
```

Sizes are **design pixels** for a phone-landscape baseline (short side 400 px). Render your screen
inside `UI.ScaledRoot` (full-screen root that applies the responsive UIScale and sizes itself to
1/scale so nothing is pushed off screen) so everything grows on tablets/desktop and never drops below
`Responsive.MIN_SCALE` (0.85). `Theme.touchTarget` (52) stays >= 44 real px at that scale.

## Components

| Component | Props |
|---|---|
| `Button` | `text`, `variant?` (`"primary"`\|`"secondary"`\|`"danger"`), `disabled?`, `onActivated?`, `icon?`, `size?`, `position?`, `anchorPoint?`, `layoutOrder?`. Press tween (UIScale 0.94), min size = touch target. |
| `Panel` | `title?`, `color?` (palette key, default `surface`), `size?` (default full width, auto height), `automaticSize?`, `position?`, `anchorPoint?`, `layoutOrder?`, children (vertical list). Rounded, stroke, gradient, drop shadow, padding. |
| `ItemCard` | `name`, `rarity`, `icon?` (nil = rarity-coloured placeholder initial), `incomePerSec?`, `mutation?`, `mutationColor?` (hex), `size?`, `layoutOrder?`, `onActivated?`. Aspect 0.75 held by UIAspectRatioConstraint; stroke glows by tier. |
| `RarityBadge` | `rarity`, `size?`, `layoutOrder?`. Tier colour pill + glow stroke from `glowStrength`. |
| `Toast` | `text`, `rarity?`, `count?` (shows `x3`), `layoutOrder?`, `onDismiss?` (tap). Pops in. |
| `ToastHost` | `subscribe(push) -> unsubscribe`, `maxVisible?` (3), `duration?` (3 s), `position?`, `anchorPoint?`, `size?`. Queue + auto-dismiss + duplicate merge (pure `ToastQueue`). |
| `Modal` | `open`, `title?`, `onClose?` (X button + backdrop tap), `dismissOnBackdrop?`, `size?`, children. Dimmed backdrop, panel capped 320-640 px wide. |
| `CurrencyCounter` | `value`, `rate?` (`+12/s` line), `icon?`, `label?`, `animate?` (default true), `duration?` (0.35 s), `size?`, `position?`, `anchorPoint?`, `layoutOrder?`. Abbreviated (1.2K / 3.4M / 5.6B ...). |
| `OddsTable` | `detail` (server `Types.OddsDetail`, `Core.Client.state().odds[tableId]`: item odds, mutation line, every item x mutation outcome, pity line "Guaranteed Legendary+ at least every N rolls"; preferred) or legacy `odds` (`{[itemId]: probability}`), `items` (`{id,name,rarity}` defs), `sortBy?` (`"rarity"` = rarest last, default; or `"probability"`), `title?`, `restricted?`, `restrictedText?`, `maxHeight?`, `size?`, `position?`, `anchorPoint?`, `layoutOrder?`. Exact percentages; never `0%` for a non-zero chance. |
| `ScaledRoot` | children. Full-screen root with the responsive UIScale (use this for screens). |
| `AutoScale` | none. Bare UIScale following the viewport; only under a content-sized frame (under a full-screen frame it pushes content off screen - use `ScaledRoot`). |

Helpers: `UI.Theme` (`set`, `current`, `color`, `rarity`, `tiers`, `tierOrder`, `sound`, `font`,
`gradient`, `setOverrides`, `subscribe`, `metrics`, `text`, `touchTarget`), pure `UI.ThemeTokens`, `UI.Primitives` (corner/stroke/padding/gradient/shadow/list/textSize elements),
pure `UI.Format` (`abbreviate`, `percent`), `UI.Odds` (`rows`, `total`, `mutationRows`, `outcomeRows`, `pityLine`), `UI.ToastQueue`,
`UI.Responsive`. The pure ones have `*.spec.luau` tests.

## Theme

The framework HUD installs the runtime's merged theme at boot (`framework-default` preset, then
each enabled module's `theme`, then `GameConfig.theme`). The `framework-default` preset is the v1.2
look token for token (golden test in `packages/framework/shared/Theme.spec.luau`).

```lua
theme = {
	colors = { accent = "#FF5DA2" },
	fonts = { display = "rbxasset://fonts/families/LuckiestGuy.json" },
	metrics = { cornerRadius = 8, text = { body = 20 } },
	sounds = { coin_tick = { id = 123, volume = 0.3 } },
	rarity = { preset = "standard7" }, -- or { tiers = { { id = "Bronze", color = "#CD7F32" } } }
}
```

## Screens

`UI.registerScreen(name, component)` adds or replaces a screen; `UI.open(name, props?)`,
`UI.close(name)`, `UI.isOpen(name)`. Open screens render in a `CoreScreens` ScreenGui
(DisplayOrder 10, created on first open) and get `onClose`. A `bind` prop (a function / Charm
selector returning a table) is re-read on state changes and merged into the props. Default screens:
`Odds` (`detail`, `items`, `restricted?`, `actions?`), `Inventory` (`items`, `onSelect?`), `Mailbox`
(`messages`, `onClaim?`).

## HUD slots and widgets

The framework HUD (`StudWork.Client.Hud.mount(opts?)`) is a layout with slots `topLeft`,
`topCenter`, `topRight`, `left`, `right`, `bottom`. Default widgets: `Economy.currency`,
`Game.nextGoal`, `Social.mailbox` (all `topCenter`). `UI.registerWidget(id, { slot, order?,
component, module? })` contributes one (or `false` removes it); widgets get props
`{ state, opts, primary, layoutOrder }`. `GameConfig.client.hud` = `"default"` | `false` |
`<ModuleScript or component>` | `{ layout = ..., widgets = { ["Social.mailbox"] = false } }`. A
custom layout gets `{ slots = { [slot] = elements }, toasts, state, opts }`.

## Mounting a screen

```lua
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local React = require(ReplicatedStorage.Packages.React)
local ReactRoblox = require(ReplicatedStorage.Packages.ReactRoblox)
local ReactCharm = require(ReplicatedStorage.Packages.ReactCharm)
local StudWork = require(ReplicatedStorage.Framework)
local Config = require(ReplicatedStorage.Game.Config)
local UI = require(ReplicatedStorage.UI)
local e = React.createElement

local function ChestScreen(props: { open: boolean, onClose: () -> (), odds: { [string]: number } })
	local state = ReactCharm.useAtom(StudWork.Client.state)
	return e(UI.Modal, { open = props.open, title = "Chest", onClose = props.onClose }, {
		Odds = e(UI.OddsTable, {
			detail = state.odds and state.odds.Chest, -- server-computed, never client-side
			items = Config.items,
			-- required for Robux-bought rolls: tell restricted players up front
			restricted = state.paidRandomRestricted,
			layoutOrder = 1,
		}),
		Open = e(UI.Button, {
			text = "Open (250)",
			layoutOrder = 2,
			onActivated = function()
				Core.Client.Actions.roll("Chest")
			end,
		}),
	})
end

local screen = Instance.new("ScreenGui")
screen.Name = "ChestScreen"
screen.ResetOnSpawn = false
screen.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
local root = ReactRoblox.createRoot(screen)
root:render(e(UI.ScaledRoot, nil, {
	Chest = e(ChestScreen, { open = true, onClose = function() root:unmount() end, odds = odds }),
}))
```

**Where odds come from.** `Core.Rarity.getOdds(tableId, luck?)` is server-side. Either have the
server send it (your own remote / replicated value) or compute it on the client from the same
`Config.rarityTables[tableId]` weights the server uses (only when luck is not involved). Never show
client-guessed odds for a Robux purchase if the server applies luck; send the server's numbers.

## Mobile checklist

- ScreenGui: `DisplayOrder` above 5 (the core HUD) for screens that open modals, or the HUD
  pills draw over the modal (seen live on the odds table).
- ScreenGui: `ScreenInsets = CoreUISafeInsets` for interactive UI (clear of the top bar, notch and
  home indicator), `ResetOnSpawn = false`, `SafeAreaCompatibility = FullscreenExtension` (default).
- One `UI.ScaledRoot` per screen; author in design pixels, don't hand-scale per device.
- Touch targets: buttons/pills use `Theme.touchTarget` (>= 44 px at the smallest scale). Don't
  shrink them with your own `size`.
- Text: fixed design sizes (`Theme.text`) + UIScale; when you use `TextScaled`, add
  `Primitives.textSize(12, max)` so it never becomes unreadable.
- Shapes that must hold (cards, icons, coin dots) use `UIAspectRatioConstraint`.
- Never put a `UIListLayout` next to a scale-sized sibling (e.g. a drop shadow) inside an
  auto-sized frame: the layout lays the sibling out and the frame grows without bound. Put the
  layout in an inner body frame (see `Panel`, `CurrencyCounter`).
- Keep the bottom-right (jump/thumbstick area on touch) and bottom-left free of HUD elements.
- Test in the Device Simulator on a small phone in landscape and portrait, plus a tablet.
- Open/close each screen repeatedly; `root:unmount()` must leave no ScreenGui or connections.
