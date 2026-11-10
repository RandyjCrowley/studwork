# Decisions

Why core looks the way it does. Newest decisions are appended; superseded ones are marked, not deleted.
Fixed by the user (not revisited here): Luau `--!strict`, one repo, one Roblox experience per game,
core reusable by unlimited games.

## Toolchain and libraries (checked 2026-11-10)

| Need | Chosen | Version (pinned) | Install | Check |
|---|---|---|---|---|
| Sync/build | Rojo | 7.7.1 | `rokit add rojo-rbx/rojo@7.7.1` | release 2026-10-02, active |
| Packages | Wally | 0.3.2 | rokit | CLI last released 2023-06 but the registry is active; still the default. x86_64-only macOS binary → needs Rosetta 2 on Apple Silicon |
| Lint | Selene | 0.32.0 | rokit | release 2026-10-01 |
| Format | StyLua | 2.6.0 | rokit | release 2026-10-10 |
| Scripts/tests | Lune | 0.11.1 | rokit | release 2026-10-21 |
| Networking IDL | Blink | 0.18.9 | rokit (`1Axen/blink`) | release 2026-09-19, active. CLI tool, not a Wally package: it generates committed Luau |
| Type check | luau-lsp | 1.70.1 | rokit | release 2026-09-27; `luau-lsp analyze` + Roblox definitions pinned to the same tag |
| Player data | ProfileStore | 1.0.3 | Wally `lm-loleris/profilestore` (server realm) | upstream repo's own wally.toml publishes this name, so provenance is confirmed |
| State replication | Charm + charm-sync | 0.11.1 / 0.4.1 | Wally `littensy/charm`, `littensy/charm-sync` | release 2026-10-01 |
| UI | React-lua (`jsdotlua/react`, `react-roblox`) + `littensy/react-charm` | 17.2.1 / 0.4.1 | Wally | react-lua last release 2024-12 (stable, used by Roblox); react-charm matches Charm 0.11 |
| Utilities | `sleitnick/signal`, `sleitnick/trove`, `evaera/promise` | 2.0.3 / 1.8.0 / 4.0.0 | Wally | RbxUtil active 2026-08; Promise 4.0.0 is the final stable release (2022), still the standard |
| Analytics | `AnalyticsService` | built in | — | |

Not used:
- **ByteNet** (Blink fallback): not needed, Blink is maintained.
- **Jest-Lua**: requires a running Roblox engine; its CLI runner `run-in-roblox` has had no release
  since 2020. Pure logic is tested under Lune with a small Jest-style harness
  (`packages/core/tests/harness.luau`). Engine behaviour is verified with the Studio MCP playtest
  checklist instead. Revisit if an Open Cloud Luau-execution test runner becomes the standard.
- **Vide** (React fallback): not needed.

## Repo layout deviations

- **`deps/wally.toml` instead of a root `wally.toml`.** macOS filesystems are case-insensitive, so
  Wally's fixed output folder `Packages/` *is* our `packages/` folder. Wally always installs next
  to its manifest, so the manifest lives in `deps/` and installs to `deps/Packages` and
  `deps/ServerPackages`. Every game project maps those paths.
- **Generated Blink code is committed** (`packages/core/server/Net/Generated.luau`,
  `packages/core/client/Net/Generated.luau`, `packages/core/shared/net/Generated.Types.luau`) so a
  build never needs blink; regenerate with `tools/net`. Excluded from lint/format.
- **Spec files live next to the code they test** (`*.spec.luau`) so each Phase 1 agent owns its
  tests inside its own folder. Rojo ignores them through `globIgnorePaths`.

## Interface choices (Phase 0)

- **One facade, both sides.** `require(ReplicatedStorage.Core)` works on server and client.
  Server namespaces are real tables on the server and error on the client; `Core.Client` is the
  reverse. `Core.start(config)` is called once per side.
- **Multi-currency from day one.** `PlayerData.currency` is a map; every Economy call takes an
  optional trailing `currency` (default `balance.primaryCurrency`). Example Shop tips/stars and event
  tokens need this; adding it later would have been a breaking change.
- **Items earn from the plot by default.** `balance.income.source = "displayed"` (Example Courier:
  delivered items earn; Example Shop: evidence shelf) or `"owned"`. Economy derives item income itself
  from `PlayerData.displayed` / `inventory`; `addIncomeSource` is for extra game-defined sources.
- **Plots are game-supplied models** tagged `CorePlot`, with BasePart slots carrying a `SlotId`
  attribute. `Plot.display(player, uid, slotId?)` lets a game target a specific slot (Example Shop's
  evidence shelf = slots it names, e.g. `shelf01`).
- **Per-game data** lives at `PlayerData.game[gameId]` with defaults, a version and migrations in
  `GameConfig.data`; `Data.getGame/updateGame` (Example Shop star rating, Example Garden waterers).
- **Offline is game-defined**: `Offline.onReturn(player, secondsAway)` always fires (capped by
  `offline.capSeconds`); core only auto-pays when `offline.autoPay` (Example Garden turns it off
  and pays growth from its own visit data).
- **Inventory transfer** is in core (`Inventory.transfer`, `Actions.gift`) with a policy check, for
  Example Gifts gifting/trading. Offline/cross-server delivery uses **`Core.Mail`** (added to the
  given interface; ProfileStore `MessageAsync`).
- **Rarity roll takes `luck` and returns `(ItemDef?, RollInfo)`** instead of a bare ItemDef:
  callers need to know why a roll failed (restricted player, full inventory, unknown table) and
  whether pity fired. Example Collector maps its clean-run meter to `luck`. Paid rolls pass
  `{ paid = true }` and are refused for `ArePaidRandomItemsRestricted` players (fail closed until
  the policy is known).
- **Upgrades added as a core namespace.** The sandbox loop is "collect → earn → upgrade → rebirth";
  every shortlisted game has level-based upgrades, so `Core.Upgrades` with config-driven cost
  curves avoids five copies.
- **Robux purchases never use a remote.** Paid rolls go through a developer product and
  `Shop.onProduct`; `RequestRoll` only accepts tables with an in-game currency `cost`.
- **Config is pure data** (hex colours, model names as strings, no Instances) so it validates and
  tests under Lune. `ConfigValidate` rejects NaN/inf and unknown ids; `Core.start` refuses to boot
  on an invalid config.
- **Rate limits live in `core/server/Net`** (anti-spam safety rails, not balance). Net owns every
  Blink listener, rate-limits per player per event, then calls the single registered service
  handler; Blink validates wire types/ranges first.
- **Signals** are sleitnick/signal instances typed by `Types.CoreSignals`; `DataChanged` is
  coalesced to once per player per frame.
- **Big numbers**: plain Luau numbers (doubles, exact to 2^53 ≈ 9e15). Enough for the planned games;
  if a game needs idle-game magnitudes, add a formatting/scientific layer then.
- **Studio admin**: in Studio every player may trigger events (agent E implements), live servers use
  `GameConfig.admins`.

## core-v1.1.0 (hardening before the games)

User decisions (implemented as written):
1. **Migration failure kicks the player** with "We couldn't load your save safely. Please rejoin.
   Your progress is safe.", logs an analytics event, and never saves default data over an existing
   profile.
2. **Rebirth keeps Robux-bought items by default** (`ItemDef.keepOnRebirth`, nil = keep copies
   whose `source` starts with `paid:`). Fixes L2.
3. **Core is modular** (foundation + `GameConfig.modules`).
4. **Each game records its core version** (`deploy.json` `coreVersion`/`coreCommit`,
   `tools/core-status`, `GAMES.md` "Core" column).

Contract choices (Phase 0, core-contract-v1.1):
- **Module split as proposed**, with Items as its own module (Inventory and Rarity require it).
  The code argued for these hard dependencies: Inventory → Items (ItemDef lookups), Rarity →
  Items, Upgrades → Economy (spend), Rebirth → Economy (cost), Plot → Inventory (it displays owned
  copies). Everything else is an optional integration guarded by `ctx.isEnabled`: Economy uses
  Rebirth/Upgrades multipliers and Items income only when on; Offline autoPay, Streak rewards
  and Friends' co-play multiplier need Economy only when configured (ConfigValidate enforces it).
  Mail has no module dependency (it rides Data's ProfileStore, which is foundation).
  `income.source = "displayed"` requires Plot.
- **Manifest in a pure module** (`shared/Modules.luau`): module specs, boot order and the public
  function names per namespace. The facade builds frozen tables from it (M7), and the loader and
  ConfigValidate use the same `Modules.resolve`.
- **Disabled modules are present but erroring**, not nil: `Core.Rebirth.rebirth()` errors with
  "Rebirth is not enabled in GameConfig.modules" instead of a nil-index crash, and code that
  captures `Core.Rebirth` before `Core.start` keeps working.
- **Receipt-safe purchases (M4) use a transaction object.** The prompt's shape
  `(data, receiptInfo) -> ()` got a third argument, `tx: PurchaseTx`, because a Robux grant usually
  needs core logic (currency rules, inventory cap, a paid roll with pity) that must write into the
  same `data`. `tx.grant/addItem/roll` call ctx-only `*Into` functions that write into the
  transaction and queue their signals until it commits. `tx.retryLater()` replaces "return false".
- **`paid:` means "obtained with Robux"**, random or not: `tx.addItem` tags `paid:<product>`. Such
  copies are kept on rebirth and (conservatively) untradeable for paid-random-restricted players.
- **Nested `Data.update` for the same player errors.** With working-copy semantics (L6) a nested
  update would be overwritten by the outer commit; failing loudly is safer than merging.
- **Per-section versions live in Data** (`Data.sectionVersion`, ctx-only) so Replication (M2) can
  reuse unchanged sections; Data, not Replication, knows which sections a commit touched.
- **M7 data ownership:** Rebirth runs registered reset steps inside its single update (Upgrades
  resets levels, Plot drops displayed slots); Inventory no longer writes `displayed` (Plot clears
  it on `ItemRemoved`); Rebirth no longer requires `Upgrades/UpgradeMath`.
- **No new Blink events:** odds travel in `ReplicatedState.odds` via `StateSync`.
- **Phase 1 file ownership deviations from the prompt:** L7 (sanitize logging) moved from agent E
  to agent A because `Data/Sanitize.luau` is in A's folder. `games/_sandbox/src/client/Main.client.luau`
  belongs to agent B (the sandbox must show server odds, M1); the rest of `games/_sandbox/` is E's.
  `core/server/init.luau` and `core/client/init.luau` (boot code) go to E with
  `core/shared/init.luau`, since the module loader lives there.
