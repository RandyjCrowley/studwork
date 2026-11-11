# Playbook: migrate an existing Roblox game to StudWork

You are a coding agent. The user gave you a StudWork checkout and an existing Roblox game and asked
you to migrate the game to StudWork. Follow this page from step 0 to step 11, in order. Don't skip
steps. Each step ends with a **Check**; don't start the next step until it passes.

The design behind every tool and API named here is [docs/framework/adopting.md](../framework/adopting.md)
(cited as "adopting.md §n"). The module API is [module-api.md](../framework/module-api.md).

**Names used on this page:**

- `<studwork>`: the StudWork checkout the user gave you (it has `tools/adopt`).
- `<game>`: the game's folder. It's either a **Rojo repo** (it has a `*.project.json`) or a
  **Studio-only game** (a folder with a `.rbxl` / `.rbxlx` place file and no project file).
- `<gameId>`: the game id you choose in step 3 (example: `my-game`).
- Commands that start with `tools/` run **from `<game>`** after step 3 (the project's own wrappers),
  unless the step says "from `<studwork>`".

---

## 0. Preconditions, and what you never do

**Never, at any step:**

1. **Never publish.** No `tools/publish --live`, no `tools/publish --test`, no publishing from
   Studio. Publishing and the cutover are the user's (step 11).
2. **Never touch live data or Roblox.** No Open Cloud calls, no API keys, no real DataStores. All
   tests run offline on synthetic data.
3. **Never write the old save store.** New code reads old saves only through
   `ctx.data.importLegacy` (step 5). Never add a `SetAsync`/`UpdateAsync`/`RemoveAsync`/
   `IncrementAsync` anywhere.
4. **Never edit `studwork/`** (the submodule) or the `<studwork>` checkout. If the framework is
   missing something, write it down for the report (step 11) and work around it in the game.
5. **Never put a real player's save, user id or name in a fixture.** Fixtures are made up.
6. **Never `git commit --no-verify`, never push, merge, tag or rewrite history.**
7. **Never raise `legacyBaseline`** in `studwork.json` or add entries to `studwork-legacy.json` to
   make lint pass. The legacy list may only shrink.

**Stop and ask the user** (write the question, then wait) before:

- installing anything outside `<game>` and `<studwork>` (Rokit itself, Homebrew packages, Rosetta),
  or anything with `sudo`;
- anything that costs money (Robux, paid services);
- touching files outside `<game>` (don't edit files in the `<studwork>` checkout; running its
  `tools/` is fine, including `tools/install`, which writes only that checkout's toolchain cache,
  Wally packages and git hook setting);
- deleting a feature of the game (as opposed to porting it).

Everything else you decide yourself, with the rules on this page. Write each decision down as you
go (keep a `MIGRATION_NOTES.md` in `<game>`; it becomes your report).

**Check:** you know `<studwork>` and `<game>`, and `<studwork>/tools/adopt` exists.

## 1. Set up

1. If `<game>` is not a git repo: `git -C <game> init -b main`, then commit everything as it is
   (`git -C <game> add -A && git -C <game> commit -m "The game before StudWork"`). This is the
   one place `add -A` is right: nothing in the folder is yours yet.
2. If `<game>` is a git repo with uncommitted changes: stop and ask the user whether to commit them.
3. Create a branch: `git -C <game> switch -c studwork-migration`.
4. Install the toolchain in the StudWork checkout (it needs Rokit; if `rokit` isn't on `PATH`,
   stop and ask the user to install it):

   ```sh
   cd <studwork>
   tools/install    # the pinned toolchain (Rojo, Lune, StyLua, Selene, luau-lsp, Blink) + Wally packages
   tools/doctor     # every line should say ok
   ```

**Check:** `tools/doctor` in `<studwork>` prints only `ok` lines, and `git -C <game> status` is clean
on branch `studwork-migration`.

## 2. Audit

The audit only reads. It writes `studwork-adopt-report.json` and `studwork-adopt-report.md` into
the project root (adopting.md §1).

**Studio-only game first:** turn the place's code into a Rojo project (only the code containers;
the map, models and UI stay in the place file, which is never modified):

```sh
cd <studwork>
tools/adopt --from-place <game>/<Place>.rbxl --out <game>
```

Other files already in `<game>` (notes, sample saves) are left alone; the run stops only if a
file it would write already exists. Every renamed instance (a name that isn't a safe file name) is
printed: fix code that finds it by its old name.

Commit the generated files (`git -C <game> add` the new files, including `.studwork-from-place.json`,
then commit "Extract code from the place file").

**Then audit** (every game):

```sh
cd <studwork>
tools/adopt --audit <game>
```

If the game is several places of one universe (a lobby and a game, each its own folder or place
file), give all of them: `tools/adopt --audit <game> <lobby>`. The report then lists the stores they
share (`sharedStores`); the user must migrate those places too (cutover item 1).

Commit both report files (`git -C <game> add studwork-adopt-report.json studwork-adopt-report.md`,
commit "StudWork adoption audit"), so later audits show up as a diff. Read
`<game>/studwork-adopt-report.md` fully. Then, from the JSON, note:

- `risks[]`: every `critical` and `high` entry. Each one must be gone (or, for `high`, fixed) by
  step 10.
- `datastores[]` and `libraries[]`: every old store, its scope and key pattern (step 5).
- `purchases`: products, passes, `processReceipt[].historyCheck`, each product's `sold` fields (steps 4, 6).
- `remotes[]` (step 7), `leaderstats[]`, `ui[]`, `globals[]` (step 8), `notExtracted[]`.
- `plan[]`: the numbered plan. This playbook follows the same order.

From here on, after any change, you can re-run `tools/adopt --audit <game>` (from `<studwork>`, or
`tools/adopt --audit .` from `<game>` after step 3) to see what's left. The report is stable, so
`git diff studwork-adopt-report.md` shows your progress.

**Check:** both report files exist, and you've written the list of critical/high risks into
`MIGRATION_NOTES.md`.

## 3. Init

### Choose `--name <gameId>`

1. Lowercase letters, digits and dashes only, starting with a letter. Take the game's folder or
   place name and convert it (`My Cool Game` -> `my-cool-game`).
2. **It must not collide with an old store.** StudWork saves to `PlayerData_<gameId>` (and
   `PlayerData_<gameId>_Studio`). If the audit lists a store with that name, pick another id (add
   `-sw`: `my-cool-game-sw`). Init refuses a colliding id anyway.

### Choose `--modules`

Enable a kit module only when the old game has that feature. Use the report (`datastores` keys,
`leaderstats` values, `remotes` names, product `sold` fields) and the scripts' names:

| The old game has... | Add |
|---|---|
| a currency (coins, cash, gems) | `Economy` |
| items, pets, tools or units the player owns | `Items,Inventory` |
| random eggs, crates, gacha or spins | `Items,Rarity,Inventory` |
| upgrades bought with currency | `Economy,Upgrades` |
| rebirth / prestige | `Economy,Rebirth` |
| offline earnings | `Economy,Offline` |
| a plot or base that displays items | `Items,Inventory,Plot` |
| daily login rewards or streaks | `Streak` |
| gifting or a mailbox | `Mail` |
| a bonus for playing with friends | `Friends` |
| none of these | `--modules ""` (foundation only; everything lives in the game module) |

When a feature is only close to a kit (the old game's rules differ in a way the kit's config can't
express), don't enable the kit for it: port that feature into the game module (or a module made
with `tools/make-module`). Record the choice. Missing dependencies are added by the tool and
reported.

### Run it

Preview first, then for real:

```sh
cd <studwork>
tools/adopt --init <game> --name <gameId> --modules Items,Rarity,Inventory,Economy --dry-run
tools/adopt --init <game> --name <gameId> --modules Items,Rarity,Inventory,Economy
```

Init needs a clean git tree. It adds the `studwork/` submodule pinned to a release tag (from
GitHub), `studwork.json` (`"adopted": true`), the `tools/` wrappers, the game module
`modules/<gameId>/`, the boot scripts `studwork-boot/` (`StudWork.start` on the server and the
client; StudWork saves only to its own store, so booting it next to the old scripts is safe),
`src/shared/Config/` when missing (mapped as `ReplicatedStorage.Game.Config`), merges
`default.project.json`, and writes `studwork-legacy.json` with every old file that breaks a
guardrail. A service the old project maps with `"$path"` (e.g. `"ServerScriptService": {
"$path": "src/server" }`) is fine: StudWork's entries are added next to it.

**Init's GameConfig is empty on purpose** (when the game had no `src/shared/Config/`): the
modules you chose at their defaults, no items, no starter items, no events,
`paidCurrencies = {}`, and the audit's product and pass ids as `Product<id>` / `Pass<id>`
placeholders. Fill it from the old game in steps 4-6 (names, items, paid currencies). Never copy
the sandbox's or a template's content into it: a starter item there is granted to every imported
player.

**If the old game assigns `ProcessReceipt`** (init lists that file as "must fix before lint
passes"): do step 6 for its products now, in the first commit: port each product to
`ctx.shop.onProduct` in `modules/<gameId>/server/init.luau` and delete the `ProcessReceipt`
assignment. Lint never accepts it, even in a listed file.

**If init says the tag doesn't exist on GitHub** (an unreleased StudWork, or no network), it prints
the exact `--url <studwork>` to rerun with. Use it, and write in your report that the user must run
`git submodule set-url studwork https://github.com/RandyjCrowley/studwork.git` once the tag is
published (a local path in `.gitmodules` must not be shared). It never overwrites an
existing project entry; a name clash stops it with a message naming the entry (rename the old
entry in `default.project.json`, commit, run again).

Then, in `<game>`:

```sh
cd <game>
tools/install
tools/doctor
tools/lint && tools/typecheck && tools/test && tools/build
git add studwork studwork.json studwork-legacy.json .gitmodules .gitignore .githooks tools modules studwork-boot src default.project.json studwork-adopt-report.json studwork-adopt-report.md
git commit -m "Adopt StudWork"
```

(Add only what init created or changed; `--dry-run` printed the list.) **This first commit fixes
`legacyBaseline`.** Lint compares it with this commit from now on.

**Check:** `tools/lint`, `tools/typecheck`, `tools/test`, `tools/build` pass in `<game>`, and the
commit exists. Old code shows up as `warning: [legacy] ...` lines, which is expected: files listed
in `studwork-legacy.json` skip selene and StyLua (`warning: [legacy] <path>: selene/stylua skipped
(legacy: <reason>)`), and their guardrail findings print as warnings. Don't reformat old files.
If `tools/typecheck` fails on old code, fix the old code minimally (a type annotation, an `:: any`)
or delete it if step 5-8 replaces it; note each in `MIGRATION_NOTES.md`.

## 4. The save map

Write one table in `modules/<gameId>/README.md`: every field of every old save, and where it goes.

| Old store / field | Type | New home | How (txApi call or section field) | Notes |
|---|---|---|---|---|
| `PlayerData` / `coins` | number | Economy `Coins` | `ctx.depsTx[Economy].grant(tx, old.coins, "legacy_import")` | |
| `PlayerData` / `gems` | number | Economy `Gems` (paid) | `grant(tx, old.gems, "legacy_import", "Gems")` | sold by product `GemPack` |
| `PlayerData` / `pets` | `{string}` | Inventory | `ctx.depsTx[Inventory].add(tx, id, { source = "legacy_import" })` per id | tagged `paid:legacy` |
| `PlayerData` / `settings` | table | game module section | `ctx.section(tx).settings = old.settings` | |
| `PlayerData` / `lastJoin` | number | dropped | | StudWork tracks this itself |
| `PlayerData` / `purchases` | `{string}` | receipt history | `receipts = function(old) return old.purchases end` | step 6 |

Rules:

1. **Every field gets a row.** A field you don't bring over is `dropped` with a reason. Nothing is
   silently lost; `tools/test-migration` enforces it.
2. **A field a kit owns goes through that kit's `txApi`** (`ctx.depsTx[Kit]`, declared in the game
   module's `dependsOn`). Never write another module's section. Everything else goes into the game
   module's own section (`ctx.section(tx)`; add the field to `data.default` in
   `modules/<gameId>/module.luau`).
3. **The paid-currency rule:** a field a Robux product sells (the report's
   `purchases.products[].sold`) maps to a currency listed in `GameConfig.compliance.paidCurrencies`
   (`src/shared/Config/init.luau`). If the game sells coins, `Coins` is paid. Paid currencies can't
   be spent with `Economy.spend`; they go through `ctx.compliance.spendPaid` / `spendForRoll`.
4. **The itemTag rule:** keep the default `itemTag = "paid"` (imported items are tagged
   `paid:legacy`: not tradeable or mailable, kept on rebirth). Use `itemTag = "free"` only when the
   report shows **no product, pass or paid currency** that ever gave items. When unsure, `"paid"`.
5. Balance numbers you find in old code (prices, rates) go into `src/shared/Config/Balance.luau` or
   the kit's config, never into code.

**Check:** the table lists every field you saw in the old save code (every key written by each
`SetAsync`/`UpdateAsync`/profile `Data`), each with a new home or a drop reason.

## 5. The legacy import

Each old store becomes one `ctx.data.importLegacy` call in `modules/<gameId>/server/init.luau`,
inside `init` (init left a commented stub there). Register **once**; for several old stores use one
call with a map of named sources (`source = { main = {...}, stats = {...} }`, then `old.main`,
`old.stats`). Copy the store name, scope and key pattern **exactly** from the report.

The `import` function must not yield and must not roll: it only copies. Use `old.x or default`
for every field (old saves are often partial).

### 5a. A raw DataStore

Old code: `DataStoreService:GetDataStore("PlayerData"):GetAsync("Player_" .. player.UserId)`.

```lua
ctx.data.importLegacy({
	id = "v1-save",          -- never reuse or rename
	version = 1,
	source = { kind = "datastore", name = "PlayerData", key = "Player_{userId}" },
	import = function(tx, old, info)
		if (old.coins or 0) > 0 then -- a 0 grant is a refusal, and a refusal fails the import
			ctx.depsTx[Economy].grant(tx, old.coins, "legacy_import")
		end
		ctx.depsTx[Economy].grant(tx, old.gems or 0, "legacy_import", "Gems")
		for _, id in old.pets or {} do
			ctx.depsTx[Inventory].add(tx, id, { source = "legacy_import" })
		end
		ctx.section(tx).settings = old.settings
	end,
	receipts = function(old) return old.purchases end,  -- only if the old save kept PurchaseIds
})
```

A scoped store (`GetDataStore("PlayerData", "global")`): add `scope = "global"` to `source`.

### 5b. ProfileService (or ProfileStore)

Old code: `ProfileService.GetProfileStore("PlayerData", template):LoadProfileAsync("Player_" .. id)`
(ProfileStore: `ProfileStore.New("PlayerData", template)` and `StartSessionAsync`).

```lua
source = { kind = "profileservice", name = "PlayerData", key = "Player_{userId}" },
-- ProfileStore: kind = "profilestore"
```

`old` is the profile's `Data` table. A profile locked by a live old server reads as busy; the
player is asked to rejoin.

### 5c. DataStore2 with Combine

Old code: `DataStore2.Combine("DATA", "coins", "inventory")`, then `DataStore2("coins", player)`.

```lua
source = { kind = "datastore2", name = "DATA", combined = { "coins", "inventory" } },
import = function(tx, old, info)
	if (old.coins or 0) > 0 then -- a 0 grant is a refusal, and a refusal fails the import
		ctx.depsTx[Economy].grant(tx, old.coins, "legacy_import")
	end
	for _, id in old.inventory or {} do
		ctx.depsTx[Inventory].add(tx, id, { source = "legacy_import" })
	end
end,
```

`name` is the Combine master key. Without `Combine`, use the single key as `name` and leave out
`combined`. If the old code set `DataStore2.Constants.SavingMethods.Standard`, add
`savingMethod = "Standard"`.

### When a key isn't importable

The key may use only `{userId}`. If the audit marked a key `"<dynamic>"` or flagged it critical
(it uses a name, a slot number, a timestamp), stop and ask the user how the key is built; don't
guess.

### Fixtures

Write at least one synthetic sample old save per old store in
`modules/<gameId>/tests/legacy/<name>.json`. Make the values up (user id `1`, fake item ids that
exist in your item config). One fixture with every field filled in, one "new player" fixture with
almost nothing, and one with more items than the Inventory cap if the game has items:

```json
{
  "description": "a mid-game player",
  "old": { "coins": 1500, "gems": 20, "pets": ["cat", "dog"], "settings": { "music": false },
           "lastJoin": 1700000000, "purchases": { "p-1": 1700000000, "p-2": 1700000100 } },
  "expect": { "coins": "economy.currency.Coins", "gems": "economy.currency.Gems",
              "pets": { "items": "inventory.inventory" }, "settings": "<gameId>.settings",
              "purchases": "_framework.legacyPurchases" },
  "dropped": { "lastJoin": "StudWork tracks join times itself" },
  "sold": { "gems": "currency" },
  "changed": { "coins": 1700, "gems": 20, "pets": ["cat", "dog", "owl"], "settings": { "music": false },
               "lastJoin": 1700000500, "purchases": { "p-1": 1700000000, "p-2": 1700000100 } },
  "afterMerge": { "economy.currency.Coins": 1700 },
  "overCap": { "path": "pets", "count": 60 }
}
```

The exact format is the header of `studwork/tools/lune/MigrationCheck.luau` (read it once):

- `old`: the old save value as the old game stored it in the import's source (ProfileService /
  ProfileStore: the profile's `Data`; DataStore2 combined: the combined table; a map of sources:
  `{ "main": {...}, "stats": {...} }`). The runner stores it in the source's real format for you.
- `expect`: old path -> StudWork save path (`<dataKey>.<field>...`, dots; list indexes are
  numbers). A string target must equal the old value; `{ "items": "<path>" }` means the old value
  is a list (or map) of item ids and the inventory at that path holds exactly those ids (entries
  may be plain ids or tables with `id` / `itemId`, e.g. pets saved as `{ "id": "cat", "uid": 7 }`).
  `_framework.legacyPurchases` is compared as the set of old receipt ids (the framework stores a
  time per id, whatever the old value was).
  `dropped`: old path -> reason. Every leaf of `old` must be covered by one of them (an entry
  covers everything under its path).
- `sold`: old path -> `"currency"`, `"items"` or another kind (e.g. `"stat"` for a sold rebirth;
  reported as not checked): fields a product sold (from the audit report's
  `purchases.products[].sold`). A sold currency must map to a `compliance.paidCurrencies` currency.
- `changed` / `afterMerge`: only if the module has a `merge`: the old save as an old server changed
  it later, and the StudWork values expected after the merge (`{ "<save path>": value }`).
- `overCap`: grows that list to `count` entries, to prove items over the Inventory cap all arrive.

### Run it until green

```sh
tools/test-migration                # every module with tests/legacy/*.json
tools/test-migration <module>       # just one module's fixtures (in a single-game project)
```

It checks, per fixture: nothing lost field by field, importing twice changes nothing, a failed
read kicks without changing data, a partial save never half-imports, `merge` is idempotent, items
over the cap all arrive, and sold fields stay paid (adopting.md §3). Fix the import (or the
fixture's `expect` path) and re-run until it exits 0.

### `merge`: add one only when needed

Without `merge`, a player whose old save changes after their import (the user rolled back to the
old game) is refused until a merge ships. Add a `merge` when the user tells you a rollback is
possible, or when you bump `version`. It must be idempotent: compute from `old` and the CURRENT StudWork values, never "add
again". The marker doesn't keep the old values, so a typical merge raises a balance to the old
one only when the old one is higher (grant `old.coins - have` when positive) and adds only the
item ids the StudWork inventory doesn't have yet.

**Check:** `tools/test-migration` exits 0; `tools/lint` and `tools/test` pass.

## 6. Purchases

For **every** product in the report's `purchases.products`:

1. Add the product to `src/shared/Config/Products.luau` (`devProducts = { GemPack = <id> }`) with
   the id from the report. Passes go under `passes`.
2. Register a handler in the game module's `init` that does what the old handler did, through
   `tx`:

   ```lua
   ctx.shop.onProduct("GemPack", function(tx)
   	tx.use(Economy).grant(100, "Gems")   -- the amount comes from config in real code
   end)
   ```

   A product that gave a **random** item: use `tx.use(Rarity).roll(tableId)` (odds are disclosed by
   Compliance) and a fixed fallback for `info.reason == "restricted"`, like the template's
   `EggRoll`. Never `math.random` in a product handler.
3. Passes: `ctx.shop.onPassOwned("VIP", function(player) ... end)` and
   `ctx.shop.ownsPass(player, "VIP")` instead of `UserOwnsGamePassAsync`. Perk flags the old save
   kept come over with the import.
4. Delete the old `ProcessReceipt` assignment and the old product code. (An assignment to
   `ProcessReceipt` fails lint even in a listed file: Shop owns it.)

**Old receipts must not grant twice:**

- If the old save kept PurchaseIds, return them from `importLegacy`'s `receipts` (step 5).
- If the old game kept a **separate history store** (the report shows a `processReceipt` with
  `historyCheck = true` and a store keyed by user and purchase id), register it once in `init`
  with the key pattern from the report:

  ```lua
  ctx.shop.legacyReceipts({ name = "PurchaseHistory", key = "{userId}_{purchaseId}" })
  ```

  Leave `until` out; the user sets it to the cutover time later (put that in the report).
- If neither exists: write that in the report (the old game had no duplicate protection).

**The bridge (`ctx.shop.onLegacyProduct`)** lets an old handler keep running through Shop while
you migrate, in Studio and test places only. Use it only if a product's port is blocked and you
need the game playable meanwhile. Rules:

- Never for a handler that writes the old save when an import is registered
  (`writesLegacyData = true` + `importLegacy` = boot error).
- Never for a handler the audit marked critical (randomness, no history check).
- **Every `onLegacyProduct` must be gone before step 10**: `tools/adopt --verify` fails while one is left.

**Check:** every product and pass in the report has an `onProduct` / `onPassOwned` handler, no
`ProcessReceipt` assignment is left, and `grep -rn onLegacyProduct modules src` prints nothing.

## 7. Remotes -> module actions

Every remote in the report becomes a module action (client -> server) or a module event
(server -> client), declared in the module's `net.blink` and server part (module-api.md §9). The
server validates everything; the client only says what it wants.

**Before** (old code, unsafe: the client sends the price):

```lua
-- client
ReplicatedStorage.BuyUpgrade:FireServer("speed", 250)
-- server
ReplicatedStorage.BuyUpgrade.OnServerEvent:Connect(function(player, upgradeId, price)
	local data = Sessions[player]
	if data.coins >= price then
		data.coins -= price
		data.upgrades[upgradeId] = (data.upgrades[upgradeId] or 0) + 1
	end
end)
```

**After** (game module; the price comes from config, every argument is checked):

```lua
-- modules/<gameId>/server/init.luau, in the server part's actions table
actions = {
	buyUpgrade = {
		limit = { rate = 4, burst = 8 },
		handler = function(player, upgradeId: string)
			local def = ctx.config.upgrades[upgradeId]   -- Balance.luau; unknown id -> refuse
			if def == nil then return end
			ctx.tx(player, function(tx)
				local mine = ctx.section(tx)
				local level = mine.upgrades[upgradeId] or 0
				if level >= def.maxLevel then return end
				if not ctx.depsTx[Economy].spend(tx, def.cost(level), "upgrade:" .. upgradeId) then return end
				mine.upgrades[upgradeId] = level + 1
			end)
		end,
	},
},
-- client: StudWork.use(GameModule).actions.buyUpgrade("speed")
```

(If the game uses the Upgrades kit, call its API instead of writing your own.)

For each remote, write one line in `MIGRATION_NOTES.md`: old name -> action/event name, its
arguments, and what the server validates (type, range, ownership, cooldown). Remotes that only
pushed state to clients usually become replicated section fields (`data.replicate`) instead of events.

**Check:** the audit shows no `OnServerEvent`/`OnServerInvoke` handlers outside listed legacy
files you still plan to delete, and no `high` risk about client-sent amounts is left.

## 8. leaderstats, UI, everything else

**leaderstats:** StudWork has no leaderstats; keep them if the game shows them, as a **display
only**. In the game module's server, create the folder when a player loads and set the values from
the save (Economy's `CurrencyChanged` signal for currencies; after your own transactions for your
fields). Never read leaderstats back as the truth, and never write them from the client.

**UI:** decide per screen:

- **Keep** the old UI (the default for a migration): its instances stay in the place /
  `StarterGui`. Its code goes in the game module's client part, `modules/<gameId>/client/init.luau`
  `start()` (init created and mapped it; it runs after `StudWork.start` on the client). Change only
  its server calls: old `FireServer` calls become `StudWork.use(Module).actions.x(...)`, and values
  it read from remotes or leaderstats come from replicated state
  (`StudWork.use(Module).state()`, module-api.md §10).
- **Move** a screen to the UI kit (`tools/make-screen`) only when the old screen is broken, or the
  framework already shows the same thing (the HUD's currency, the odds UI). A paid random item
  must show odds through the framework's odds UI either way.

**Other systems** (`globals`, `wait()` loops, round systems, NPCs): port each into the game module
or its own module (`tools/make-module <Name>`). `_G`/`shared` state becomes module state or
`StudWork.use(Module)` calls; loops become `ctx.lifecycle.onTick`.

**Parallel agents:** systems that share no files can be split. Give each agent a list of files it
owns (one feature's old scripts + one new module folder) and these rules: it edits only its files,
never `studwork.json`, `studwork-legacy.json` (except removing its own entries), `default.project.json`
or another module's folder; you (the lead) merge and run step 10. Good splits: one agent per
remote group, one per UI screen. Don't split the save map or the import (step 4-5): one owner.

**Check:** `tools/lint && tools/test && tools/test-migration` pass after each system.

## 9. Shrink `studwork-legacy.json`

Each entry is an old file that still breaks a guardrail. For each one:

1. If its job moved to StudWork (steps 5-8), **delete the file**, then remove its entry.
2. If part of it is still needed, port that part, delete the rest, re-run `tools/lint`: findings
   drop; when none are left lint warns "nothing legacy left; remove the entry". Remove it.
3. Keep an entry only with a true reason (old UI code you decided to keep, say), and never with the
   `purchases` check: an entry listing `purchases` blocks `tools/adopt --verify`.

**Place-file game:** scripts left in the place (the report's `notExtracted[]`, e.g. a shop screen's
LocalScript that prompts a purchase) can't be deleted from the original place file, which is never
modified. Once their job moved to StudWork, retire them:

```sh
tools/adopt --strip-place . "StarterGui.ShopGui.ShopGuiClient" "ReplicatedStorage.Remotes"
```

This writes `<name>.studwork.rbxlx` next to the place without those instances (paths as in
`notExtracted[].path`), points `studwork.json` `placeFile` at the copy and keeps the original for
rollback. Run it again to remove more. Commit the copy and `studwork.json`.

Lint fails if a listed file gets **more** findings than at init, so don't add old-style code to a
listed file (reformatting can't raise a count: findings are counted per statement). Never edit
`legacyBaseline`.

**Check:** `studwork-legacy.json` is `{ "files": [] }`, or each remaining entry has a real reason
and none lists `purchases`.

## 10. Verify

Run, in `<game>`:

```sh
tools/adopt --verify .
tools/lint
tools/typecheck
tools/test
tools/test-migration
tools/build
```

**Done means all of these hold:**

1. All six commands exit 0.
2. `tools/adopt --verify` reports no critical risk, no `onLegacyProduct`, no legacy entry listing
   `purchases`, and (place-file games) no script left in the place that uses DataStores or purchases.
3. Every old save field is in the save map (step 4) and covered by a fixture's `expect` or `dropped`.
4. Every product and pass from the audit has a StudWork handler; every sold field is a paid
   currency or a paid-tagged item.
5. Every remote is an action or event with server-side validation, or deleted with a reason.
6. No new code calls `DataStoreService`, ProfileService/ProfileStore, DataStore2, `ProcessReceipt`
   or raw remotes.
7. Everything is committed on `studwork-migration` (small commits, one per step or system, only
   your files).

If a command fails, read "When you're stuck" below, fix, and run all six again.

## 11. Report to the user

Write the report (from `MIGRATION_NOTES.md`) as your final answer and commit it as
`MIGRATION_REPORT.md`:

1. What was migrated: modules enabled, the save map, products, remotes, systems.
2. Decisions you made and why (game id, modules, itemTag, kept UI, dropped fields).
3. What's left: remaining legacy entries with reasons, framework gaps you worked around, anything
   you couldn't do.
4. Things the user must set: the real `.gitmodules` URL (if you used `--url`), `until` on
   `ctx.shop.legacyReceipts` (the cutover time), product ids still `0`.
5. Test accounts to use: any account that played the old game.
6. The cutover checklist below, copied as it is.

**You never do the cutover.** You don't publish, not even to a test place. State that plainly in
the report.

### Cutover checklist (for the user)

1. **Every place of the universe** that reads or writes an imported store is migrated too, or has
   its old save code removed (the audit's `sharedStores`). A lobby still on old code would keep
   writing the old store after its players were imported.
2. Publish the migrated place to a **test place in the same universe** (it shares DataStores with
   live, so it can read real old saves). Every account that joins it is imported for real: use test
   accounts that played the old game. `tools/publish --test`, or Studio for a place-file game.
3. In the test place, join with such an account and compare: the save matches the old one field by
   field (the console's `data dump <userId>` and `adopt status <userId>`).
4. Buy one product in the test place and confirm one grant.
5. Publish live with **"Shut down all servers"** (not a migrate-to-latest update, which keeps old
   servers running while they have players), so no old server writes the old store after its
   players are imported. The import also refuses to read a save written in the last 120 seconds,
   which covers the old servers' final saves.
6. `tools/publish --live` refuses while `tools/adopt --verify` would fail.
7. Watch the logs and analytics for `LegacyImportFailed`, `LegacyChangedAfterImport` and the share
   of `LegacyNotFound` for a few days.

**Rollback:** StudWork never changes the old store, so publishing the previous place version
(Roblox version history) brings the old game back with every save as it was at import. Progress made
in the old game during a rollback is seen as "changed after import" when StudWork is published
again: the module's `merge` runs, and without a `merge` those players can't join until one ships.

---

## When you're stuck

| You see | Cause | Fix |
|---|---|---|
| init: the game id collides with an old store | `PlayerData_<gameId>` is an old store name | pick another `--name` (step 3) |
| init stops on a project entry clash | the old `default.project.json` uses a name StudWork needs (`ReplicatedStorage.Framework`, `.Modules`, `.Packages`, `.UI`, `.GameModule`, `ServerScriptService.Framework`, `.Modules`) | rename the old entry, commit, re-run init |
| init refuses: tree not clean | uncommitted changes | commit or ask the user (step 1) |
| boot error: a legacy source equals StudWork's own save store | `source.name` is `PlayerData_<gameId>` | wrong name in `source`, or the game id collides; fix whichever is wrong |
| boot error *"legacy product CoinPack writes the old save, but <id> imports it (importLegacy); migrate CoinPack to ctx.shop.onProduct first"* | a `writesLegacyData = true` bridge plus an import | port the product to `onProduct` (step 6) |
| boot error: a product has both `onProduct` and `onLegacyProduct` | one handler per product | remove the bridge |
| boot warning naming a product | an `onLegacyProduct` is left | port it; verify won't pass while it's there |
| kick *"We couldn't bring over your save from the previous version yet. Nothing was lost. Please rejoin in a minute."* | the import failed (`LegacyImportFailed` with `read_error`, `busy`, `import_error`, `lost_session` or `merge_missing`) | in tests, read the logged reason: `import_error` = your `import` errored (often `old.x` is nil: use `or`), `merge_missing` = add a `merge` |
| `legacy import: <Module>.<fn> refused (<value>)` | a kit's txApi call returned `nil`/`false` in the import (unknown item id, unknown currency) | add the missing item/currency to config, or map the field elsewhere |
| *"ctx.compliance: no rolls or paid spends inside a legacy import"* | `import` rolls or spends | an import copies; grant the old result directly |
| test-migration names an old field | that leaf is in neither `expect` nor `dropped` | add it to the save map and the import, or to `dropped` with a reason |
| test-migration: a sold field maps to a currency that isn't paid | the paid-currency rule | add the currency to `compliance.paidCurrencies` |
| test-migration: `itemTag = "free"` with a sold item | the itemTag rule | use `itemTag = "paid"` |
| `warning: [legacy] <path>:<line>: [<check>] <message> (legacy: <reason>)` | expected: old code in a listed file | shrink it in step 9 |
| lint: a listed file has more findings than its baseline | you added old-style code to a listed file | move the new code into a module |
| lint: `legacyBaseline` differs from the first commit | `studwork.json`'s baseline was edited | `git checkout` the baseline back; never raise it |
| lint: history not available | a shallow clone | `git fetch --unshallow` |
| lint: *"remove it from studwork-legacy.json"* | a listed file no longer exists | remove the entry |
| lint: *"nothing legacy left; remove the entry"* (warning) | the file is clean now | remove the entry |
| lint: an entry without a reason | every entry needs a non-empty `reason` | add one, or remove the entry |
| lint fails on `ProcessReceipt` in a listed file | Shop owns `ProcessReceipt`; never downgraded | delete the assignment (step 6) |
| `tools/adopt --verify` lists lines | each line is one thing left | fix them top to bottom, re-run |

If a fix would need a change inside `studwork/`, don't make it: write the request in the report.

## Time budget

Rough guide for a small or medium game (a few thousand lines):

| Step | Time |
|---|---|
| 0-3 setup, audit, init | 10-20 min |
| 4-5 save map, import, fixtures | 30-60 min (the most important part; don't rush it) |
| 6 purchases | 15-30 min |
| 7-8 remotes, UI, systems | the rest; split across parallel agents when they don't share files |
| 9-10 shrink, verify | 15-30 min |

Do steps 4-6 before anything else after init: they're where saves and Robux are at stake. If time
runs out, stop after a passing `tools/test-migration` with steps 7-9 listed as "left" in the report;
never leave the save import half done.
