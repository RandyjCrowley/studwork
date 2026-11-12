# Framework: localization (string keys)

The UI kit and the framework's own text use **string keys with English defaults**, resolved
through Roblox's `LocalizationService` translators, with Roblox's automatic translation still
working. Modules ship their own English defaults; games override wording and add their own
strings. Added in v1.7.0 (design: [module-api.md §23.9](../module-api.md#23-additions-in-v170)).

This is a **framework feature, not a kit module**: the UI kit needs it whether or not any module
is enabled, so it is always present (why: [decisions.md](../../decisions.md#v170-engagement-text-flags-localization)).
Code: `packages/framework/shared/Strings.luau` (the pure resolver and formatter, both sides),
`packages/framework/client/Text.luau` (translator, locale), `packages/ui/Strings.luau` (the UI kit's
English defaults), `packages/ui/Text.luau` (`UI.text`, `UI.useText`).

## Keys and English defaults

A key is `<namespace>.<name>` (`^[%a][%w_]*%.[%w_.]+$`, at most 100 characters):

| Namespace | Owner | Defaults live in |
|---|---|---|
| `ui.*` | the UI kit | `packages/ui/Strings.luau` |
| `framework.*` | the framework (kick and error messages, console replies shown to players) | `packages/framework/shared/Strings.luau` |
| `<Module>.*` | a module (e.g. `Badges.awarded`) | the module definition's `strings` field |
| `game.*` | the game | `GameConfig.strings` |

```lua
-- module.luau (additive defineModule field, §23.9)
strings = {
	["Badges.awarded"] = "Badge earned: {name}",
	["Badges.title"] = "Badges",
},
-- GameConfig
strings = {
	["ui.close"] = "Done",                      -- reword any key (English)
	["game.welcome"] = "Welcome back, {name}!", -- the game's own keys
	["Badges.badge.firstHatch"] = "First Hatch",
},
localization = { sourceLocale = "en", useTranslators = true },
```

- A module's `strings` keys must start with `<ModuleName>.`; anything else is a definition error.
- `GameConfig.strings` may set any key; an unknown key outside `game.*` is a boot **warning**
  (typo?), like an unknown config key.
- **Every key has an English default:** a key used in the UI kit, framework or a kit without a
  default fails the `strings` lint check; at runtime a missing key renders the key itself and
  warns once per key. **Never blank.**
- Parameters use Roblox's format-string syntax, so the same entry works in a Roblox localization
  table: named `{name}` (args table) or numbered `{1}` (args array). Missing args render the
  placeholder unchanged and warn once.

## Resolving a key

```lua
UI.text(key, args?) -> string             -- client, plain call
UI.useText(key, args?) -> string          -- client, React hook: re-renders on a locale change
StudWork.text(key, args?) -> string       -- client facade (same function)
ctx.text.format(player, key, args?) -> string   -- server: in that player's language
ctx.text.english(key, args?) -> string          -- server: the English text (logs, analytics)
```

Order, on either side:

1. **Translator** (when `useTranslators` and the player's locale isn't `sourceLocale`):
   `translator:FormatByKey(key, args)` in `pcall`, with the player's translator from
   `LocalizationService:GetTranslatorForPlayerAsync` (client: the local player; server: fetched in
   the background at join and cached; until it arrives, step 2). `FormatByKey` errors when no
   table has the key: that's the normal "no manual translation" case, not a warning.
2. **English:** `GameConfig.strings[key]`, else the owner's default, formatted by the framework's
   formatter.
3. **The key itself**, with one warning.

Translations come from Roblox: the experience's cloud localization table (Creator Dashboard >
Localization; entries keyed by these keys) and any `LocalizationTable` instances the game ships
(Rojo builds a `.csv` file into a `LocalizationTable`; the template maps
`src/shared/Localization/` into `LocalizationService`). The framework doesn't ship translations.

**Automatic translation keeps working.** Kit labels keep `AutoLocalize = true` (the default)
and display the English text from step 2 when there is no keyed translation, so Roblox's
automatic text capture and automatic translation translate them as they would any game text. A
string with parameters is captured once per distinct rendered value; give such keys a manual
translation (keyed, with `{params}`) when the variety matters. Text that must not be translated
(player names, filtered player text) is rendered with `AutoLocalize = false` by the components
that show it (`UI.Leaderboard` names, `UI.ItemCard` custom names).

**Locale changes:** the client listens to the translator's `LocaleId` changes and bumps a locale
atom, so `UI.useText` re-renders. `UI.text` (non-hook) reads the current locale each call.

## The UI kit

Every user-visible string in `packages/ui` components comes from `UI.text`/`UI.useText` with a
`ui.*` key (`ui.close`, `ui.odds.title`, `ui.odds.chance`, `ui.inventory.empty`, `ui.mail.claim`,
...), and kits' client parts use their `<Module>.*` keys. Props that take display text (a
`title`, a button `text`) still accept a plain string from game code: the kit doesn't translate
a caller's string, the caller resolves it (`title = UI.text("game.shop")`).

## The `strings` lint check (new)

Scans `packages/ui/**`, `packages/kits/*/*/client/**` and `packages/framework/client/**` (not
specs, not `Strings.luau` default tables, not generated Blink files). Comments stripped. It
flags:

- a string literal containing a letter assigned to a text-like property or prop: `Text`,
  `PlaceholderText`, `text`, `title`, `label`, `placeholder`, `emptyText`, `message` (in a
  table constructor, `e(...)` props, or `x.Text = "..."`), unless the literal is a key passed to
  `UI.text` / `UI.useText` / `StudWork.text`;
- a string literal passed to `ctx.net.feedback(..., "<text>")` / `Feedback.toast("<text>")`;
- a `UI.text("<key>")` / `UI.useText` / `StudWork.text` call whose literal key has no English
  default in any defaults table (the check reads `packages/ui/Strings.luau`, the framework's
  `Strings.luau` and every kit `module.luau` `strings` field).

Allowed: empty strings, strings without letters (`"0"`, `"%"`, `"×"`), font and asset paths
(`rbxasset://`), and `-- guard: allow strings` with a reason. Message:
`hard-coded UI text "<first 30 chars>" (use UI.text with a key; docs/framework/kits/localization.md)`.
Its self-test plants a `Text = "Close"` in a UI component, a toast literal, and a key without a
default (each must fail), plus a keyed `UI.text("ui.close")` and a `"%"` label (must pass).

Game code isn't scanned by this check: games may hard-code their own text (they still benefit from
automatic translation).

## Override levels

1. Defaults: nothing to do; English everywhere, automatic translation if the game enables it.
2. Config: reword any key in `GameConfig.strings`; set `localization.useTranslators = false` to
   skip translators (English plus automatic translation only).
3. Replace a piece: ship `LocalizationTable` CSVs or cloud-table entries keyed by these keys.
4. There is nothing to switch off: with no translations, every key resolves to English.

## Failure behaviour

| Situation | Behaviour |
|---|---|
| `GetTranslatorForPlayerAsync` fails | English until a retry succeeds (retried at 5, 30 and 120 s) |
| `FormatByKey` errors (no entry, wrong args) | English, no warning for a missing entry; one warning for an args mismatch |
| Key unknown everywhere | the key text, one warning per key |

## Tests (mocked)

- `StudWork.test.fakes.translator({ locale = "es", entries = { ["ui.close"] = "Cerrar" } })` as
  `harness({ locale = "es", translator = fake })` (server) and the client runtime option of the
  same name; `fake.setLocale("pt")` fires the change.
- Specs: resolution order; a missing translation falls back to English; a missing key renders
  the key (never ""); named and numbered params; `GameConfig.strings` rewording; a module key
  outside its namespace fails the definition; the `strings` self-test; every key the UI kit
  uses has a default (a spec walks `packages/ui` for literal keys).

## Not verifiable offline

Real translators and cloud tables, automatic text capture of kit labels, whether Rojo-built
`LocalizationTable`s under `LocalizationService` are seen by `GetTranslatorForPlayerAsync` (to
confirm in Studio), and text fit in long languages. Live checklist in the round report.
