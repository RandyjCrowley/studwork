# Framework: localization (string keys)

> **A framework feature, always on: it is not a module and is not listed in `GameConfig.modules`.**

The UI kit and the framework's own text use **string keys with English defaults**, resolved
through Roblox's `LocalizationService` translators, with Roblox's automatic translation still
working. Modules ship their own English defaults; games override wording and add their own
strings. Added in v1.7.0 (design: [module-api.md §23.9](../module-api.md#23-additions-in-v170)).

This is a **framework feature, not a kit module**: the UI kit needs it whether or not any module
is enabled, so it is always present (why: [decisions.md](../../decisions.md#v170-engagement-text-flags-localization)).
Code: `packages/framework/shared/Strings.luau` (the pure resolver and formatter, both sides, and the
locale atom), `packages/framework/server/Text.luau` (`ctx.text`: translators, retries),
`packages/framework/client/Text.luau` (translator proxy, locale), `packages/ui/Strings.luau` (the UI
kit's English defaults), `packages/ui/Text.luau` (`UI.text`, `UI.useText`).

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
- `strings` may also be a function of the module's merged config, `strings = function(config) ->
  table` (the same pattern as `theme = function(config)`, §19.3), for keys built from config: a
  board title `Leaderboards.board.<boardId>` or a badge name `Badges.badge.<key>` gets the board id
  or badge key as its English default this way. It runs once at boot, after config validation.
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
   `LocalizationService:GetTranslatorForPlayerAsync` (client: the local player, through a proxy that
   is English until the real translator arrives, so boot never waits; server: fetched in the
   background at join and cached; until it arrives, step 2). `FormatByKey` errors when no
   table has the key: that's the normal "no manual translation" case, not a warning. A fetch that
   fails is retried at 5, 30 and 120 s (both sides), then English stays.
2. **English:** `GameConfig.strings[key]`, else the owner's default, formatted by the framework's
   formatter.
3. **The key itself**, with one warning.

Translations come from Roblox: the experience's cloud localization table (Creator Dashboard >
Localization; entries keyed by these keys) and any `LocalizationTable` instances the game ships.
**The template maps `src/shared/Localization/*.csv` into `LocalizationService`** (Rojo builds each
`.csv` into a `LocalizationTable`; columns `Key, Source, Context, Example, <locale>...`), from
v1.7.0, in the project files `tools/sync-projects` writes. That translators see these tables is
checked in Studio before the release. The framework doesn't ship translations.

**Automatic translation keeps working.** Kit labels keep `AutoLocalize = true` (the default)
and display the English text from step 2 when there is no keyed translation, so Roblox's
automatic text capture and automatic translation translate them as they would any game text. A
string with parameters is captured once per distinct rendered value; give such keys a manual
translation (keyed, with `{params}`) when the variety matters. Text that must not be translated
(player names, filtered player text) is rendered with `AutoLocalize = false` by the components
that show it (`UI.Leaderboard` names, `UI.ItemCard` custom names).

**Locale changes:** the client listens to the translator's `LocaleId` changes (and the proxy signals one
when the real translator arrives) and bumps a locale atom, so `UI.useText` re-renders. The atom is
`Strings.notifyLocaleChanged` / `Strings.onLocaleChanged` in the shared `Strings` module, which the UI
kit already shares with the framework. `UI.text` (non-hook) reads the current locale each call.
Components with several keyed labels call `useLocale()` once (the hook alone) and `text` anywhere.
On the server a player's `LocaleId` change fetches that player's translator again.

## The UI kit

Every user-visible string in `packages/ui` components comes from `UI.text`/`UI.useText` with a
`ui.*` key (`ui.odds.title`, `ui.odds.empty`, `ui.odds.items`, `ui.odds.mutations`,
`ui.odds.allOutcomes`, `ui.odds.restricted`, `ui.odds.pityEvery`, `ui.odds.pityAlways`,
`ui.odds.luck`, `ui.inventory.title`, `ui.inventory.empty`, `ui.mail.title`, `ui.mail.empty`,
`ui.mail.claim`, `ui.mail.button`, `ui.perSecond`, `ui.modal.closeGlyph`, `ui.close`,
`ui.leaderboard.*`), and kits' client parts use their `<Module>.*` keys, or the `ui.*` keys when the
UI kit shows the text (the Mailbox button). The pure `Odds.pityLine(detail, text?)` and
`Odds.luckLine(detail, text?)` take the resolver (`UI.text`) the component passes; without one they
use the English defaults. Props that take display text (a
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
- a string literal passed as the text of `ctx.net.feedback(player, "<kind>", "<text>")`,
  `Feedback.toast("<text>")` or `Feedback.pop("<text>", ...)`;
- a `UI.text("<key>")` / `UI.useText` / `StudWork.text` / `<name>Text.text` call whose literal key has no English
  default in any defaults table (the check reads `packages/ui/Strings.luau`, the framework's
  `Strings.luau` and every kit `module.luau` `strings` field; for a module whose `strings` is a
  function, which the check can't run, any literal key in that module's namespace is accepted).

Allowed: empty strings, strings without letters (`"0"`, `"%"`, `"×"`) or with only `%d`-style format
specs and `{param}` placeholders, the class name in `e("Frame", ...)` / `Instance.new("...")`, a
literal compared with `==`, font and asset paths (they aren't text properties), and
`-- guard: allow strings` with a reason on the line or the line above. The check reads one line at
a time: a text property whose value continues on the next line isn't followed. Message:
`hard-coded UI text "<first 30 chars>" (use UI.text with a key; docs/framework/kits/localization.md)`.
Its self-test plants a `Text = "Close"` in a UI component, a toast literal, and a key without a
default (each must fail), plus a keyed `UI.text("ui.close")` and a `"%"` label (must pass).

Game code and examples (the sandbox included) aren't scanned by this check: games may hard-code
their own text (they still benefit from automatic translation). The sandbox uses keys by convention,
as a model.

## Override levels

1. Defaults: nothing to do; English everywhere, automatic translation if the game enables it.
2. Config: reword any key in `GameConfig.strings`; set `localization.useTranslators = false` to
   skip translators (English plus automatic translation only).
3. Replace a piece: ship `LocalizationTable` CSVs or cloud-table entries keyed by these keys.
4. There is nothing to switch off: with no translations, every key resolves to English.

## Failure behaviour

| Situation | Behaviour |
|---|---|
| `GetTranslatorForPlayerAsync` fails | English until a retry succeeds (retried at 5, 30 and 120 s; one log line after the last) |
| The player's language changes | the server fetches that player's translator again; the client's `UI.useText` re-renders |
| `FormatByKey` errors (no entry, wrong args) | English, no warning for a missing entry; one warning for an args mismatch |
| Key unknown everywhere | the key text, one warning per key |

## Tests (mocked)

- `StudWork.test.fakes.translator({ locale = "es", entries = { ["ui.close"] = "Cerrar" } })` as
  `harness({ locale = "es", translator = fake })` (server) and the client runtime option of the
  same name; `fake.setLocale("pt")` fires the change.
- Specs: resolution order; a missing translation falls back to English; a missing key renders
  the key (never ""); named and numbered params; `GameConfig.strings` rewording; a module key
  outside its namespace fails the definition; a `strings` function gets the merged config and
  its keys resolve; the `strings` self-test; every key the UI kit uses has a default (a spec walks
  `packages/ui` for literal keys); the template's project file maps `src/shared/Localization`
  into `LocalizationService` (tools spec).

## Not verifiable offline

Real translators and cloud tables, automatic text capture of kit labels, and text fit in long
languages (live checklist: [manual-qa.md](../../manual-qa.md)). Whether Rojo-built `LocalizationTable`s under
`LocalizationService` are seen by `GetTranslatorForPlayerAsync` is on that checklist.
