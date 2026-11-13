# Player kit: Codes and Settings

Two independent modules provide free promotion redemption and player preferences. List either or both references in `GameConfig.modules`; leaving one out does not affect the other. Map their normal module folders in the game project, as for other kits. Codes optionally uses Economy, Inventory, Rarity and Rebirth; enable the dependencies used by your rewards and requirements. Settings needs no other kit.

```lua
local Modules = game:GetService("ReplicatedStorage"):WaitForChild("Modules")
local Codes = require(Modules.Codes.module)
local Settings = require(Modules.Settings.module)
return {
    gameId = "example-game",
    modules = { Codes, Settings },
    config = {
        Codes = { definitions = {} },
        Settings = { schema = {} },
    },
}
```


For a normal single-game project with the framework submodule named `studwork`, add the following entries to the existing project tree. Preserve its framework, UI, package and dependency mappings:

```json
{
  "ReplicatedStorage": {
    "Modules": {
      "Codes": {
        "module": { "$path": "studwork/packages/kits/player/Codes/module.luau" },
        "shared": { "$path": "studwork/packages/kits/player/Codes/shared" },
        "client": { "$path": "studwork/packages/kits/player/Codes/client" }
      },
      "Settings": {
        "module": { "$path": "studwork/packages/kits/player/Settings/module.luau" },
        "shared": { "$path": "studwork/packages/kits/player/Settings/shared" },
        "client": { "$path": "studwork/packages/kits/player/Settings/client" }
      }
    }
  },
  "ServerScriptService": {
    "Modules": {
      "Codes": { "$path": "studwork/packages/kits/player/Codes/server" },
      "Settings": { "$path": "studwork/packages/kits/player/Settings/server" }
    }
  }
}
```

The mappings above are fragments, not a complete project. Network generation supplies the module's generated files; preserve the generated mappings produced by project synchronization. Shared optional dependency definitions must also be mapped even when their module is disabled, as for other kit refs.

## Codes configuration

`config.Codes` defaults: `definitions = {}`, `flag = nil`, `maxLength = 64`, `maxDefinitions = 256`, `maxRewards = 16`, `maxRequirements = 16`, `maxGlobalUses = 10000`, `failureLimit = 5`, `failureWindowSeconds = 300`, `lockoutSeconds = 300`, `rate = { rate = 1, burst = 3 }`, `sharedOpsPerMinute = 120`, `live = { enabled = false, key = "player_codes", refreshSeconds = 60, maxEntries = 256 }`.

Each definition has a permanent `id`, typed `code`, `rewards`, optional `startsAt`/`expiresAt` Unix seconds, optional global `maxUses`, `oncePerPlayer` (omitted or true; explicit false is rejected in version 1), `requires`, and `testOnly` (false). IDs contain up to 24 letters, digits or underscores and must never be reused after retirement. Definitions in shared game config are visible to clients. Keep unreleased promotions in the server entry's separate config:

```lua
-- ServerConfig, passed only to the server StudWork.start call
return {
    Codes = {
        definitions = {
            {
                id = "spring_bonus", code = "SPRING",
                rewards = { { kind = "currency", amount = 100, currency = "Coins" } },
                maxUses = 1000,
            },
        },
    },
}
```

Enable Economy for this currency example and keep that currency free of Robux value. The merged server catalog is never replicated. `ServerConfig.Codes.definitions` and live definitions use the same validation as base definitions.

Rewards use `kind = "currency"` with `amount` and `currency`, `"item"` with `itemId` and optional `count`, or `"roll"` with `tableId`. Requirements use `"rebirth"` with `count`, `"item"` with `itemId`, `"group"` with `groupId`, or `"newPlayer"` with `maxAgeSeconds`. Games register custom kinds through data-only reward handlers and eligibility predicates. Rewards never spend money or run paid rolls. All random rewards use Rarity and its disclosed odds.

The optional live JSON value is `{ definitions = { ... }, disabled = { "promotion_id" } }`. A cached server snapshot adds definitions or disables base definitions. Refreshes run no more often than `refreshSeconds`; failures retain the last good snapshot, and malformed entries are skipped with a generic warning. No player-specific fetch occurs. The server uses `ctx.configValues.snapshot()`, which yields a ConfigSnapshot supporting `GetValue`, `Refresh`, `UpdateAvailable` and `Outdated`. The full merged catalog, disabled list, strings and arrays are bounded; live payloads are limited to 90,000 characters or an equivalently bounded validated structure. Fetch and refresh are single-flight. A malformed whole payload retains the last good catalog; a valid empty catalog is a real update. Catalog replacement is atomic. A definition changed while a redemption yields must be retried, rather than silently granting its replacement.

Server API: `redeem(player, raw) -> string` (yields; returns the preset directly, such as `"ok"` or `"expired"`, rather than a result table), `define(definition)`, `disable(id)`, `uses(id)` (yields; uncapped returns nil and `uncapped`), `registerReward(kind, handler)`, `registerRequirement(kind, predicate)`, and `signals.Redeemed(player, id)`. A reward handler receives `(tx, player, reward)` and must return true without yielding or causing external effects. It writes through declared dependencies' transaction APIs. A false result or error cancels the entire grant. Console commands are `codes list`, `codes add` (test only), and `codes inspect <id>`.

Client API: `open()` opens the Codes screen; `redeem(raw)` submits. Outcomes are localized presets: `ok`, `invalid`, `expired`, `not_yet`, `already_used`, `limit_reached`, `not_eligible`, and `try_later`. The input is not echoed in results, console inspection, warnings or analytics. Console output contains IDs and safe metadata only. Hashes are pseudonyms, not secret storage, and may be guessed from a dictionary. The screen provides the existing odds view for free roll rewards. Only roll-source IDs are sent as disclosure metadata, including live and server-only promotions; code text and promotion definitions remain on the server.

## Codes: abuse and limits

Raw input is capped before normalization, rejects control characters, trims and folds ASCII case. Inputs never go to other clients or plain-text analytics. Attempts are rate-limited, failed eligibility/input attempts count toward a lockout, and state is removed when players leave. This lockout is local to the server session: rejoining resets it, so it is not distributed brute-force prevention. Invalid, expired, not-yet, already-used, limit-reached and ineligible results all count. Codes are discoverable promotions rather than secrets: publish public redemption details and do not use unique per-user promotional codes.

Every code first verifies its permanent policy in a durable shared ledger, including uncapped codes. The ledger stores `{ version = 1, limit, used, reserved }`; `limit = 0` means uncapped. Changing an existing ID's cap or switching capped/uncapped is refused even across different deployments. A capped code reserves a durable slot with the framework shared store's atomic update. The limit includes reserved and completed uses. Grants and the player's redemption marker share one transaction. Save confirmation precedes Codes success results and `Redeemed`. Normal dependency transaction hooks, such as Inventory signals, may run at the in-memory commit before confirmation; the atomic reward and receipt state remain together. Failed transactions release their reservations. A committed grant whose save cannot be confirmed retains its reservation: later retries confirm the same grant rather than granting again. A reservation token belongs to one in-flight attempt and is retained exactly in a saved pending receipt. An unsaved crash can abandon that attempt's slot. Reservations never expire automatically; a crashed server can leave capacity unavailable, but cannot cause a cap overrun. Lowering a cap or reusing an ID is unsupported. Uncapped codes still check the durable policy, but do not reserve a cap slot. Finalization increments completed uses only when its reservation token is still present; retrying a completed finalization is harmless. An ambiguous shared-store response never permits compensation or releasing capacity.

`sharedOpsPerMinute` counts public shared-store operations, including diagnostics, recovery, release and finalization, with capacity reserved for recovery. Each public operation may make up to four backend requests through framework retries. The budget is per server and does not guarantee an experience-wide or per-key throughput bound. Saturation refuses new work and retains pending receipts.

The flag, environment, time bounds and captured catalog generation are rechecked after yielding and inside the grant transaction. Owned-item and rebirth requirements are checked again against current transaction state; group and yielding custom predicates are eligibility snapshots. Version 1 rejects repeat-redemption definitions: two transport submits cannot safely express distinct intended repeat rewards without another durable request protocol.

The player's nonreplicated `codes` section is `{ redeemed = { [id] = true }, pending = { [id] = { token, capped } }, sequence = number }`. Pending receipts and their redeemed markers are never pruned, even if a definition disappears, expires or is disabled. Recovery uses the same per-player busy gate as new redemption, needs no active definition and never executes rewards again. It confirms the save, finalizes capped tokens idempotently, then clears only the exact pending entry. Uncapped pending receipts also require confirmation.

Settled removed-code markers are pruned only after a complete successful catalog resolution. Base and disabled IDs remain in the retention set. Retirement is a deployment-wide commitment: never reintroduce a pruned ID, including through a config rollback, because it would become redeemable again. Pending records can survive retirement until recovered; the active catalog limit alone does not bound unresolved history. Sequence state is retained and must remain an exact finite safe integer. `testOnly` is checked on every redemption path and is refused in live, including dynamically added definitions.

Promotions must follow [Roblox's virtual reward rules](https://en.help.roblox.com/hc/en-us/articles/10549651908244-Promo-Offers-for-Virtual-Rewards): experience-only rewards, free public redemption, no Robux or real-world value, and no unique per-user promotional codes. The kit cannot infer the sale value of arbitrary custom rewards; games must review their reward catalog.

## Settings configuration and API

`config.Settings` defaults: `flag = nil`, `builtins = {}`, `schema = {}`, `debounceSeconds = 0.5`, `saveDebounceSeconds = 2`, `maxSettings = 128`, `maxBatch = 32`, `rate = { rate = 4, burst = 8 }`, `audio = { musicGroup = "CoreMusic", effectsGroup = "CoreEffects" }`.

A definition contains `id`, `type` (`toggle`, `slider`, `choice`), `default`, `category`, `labelKey`, optional `descriptionKey`, and `scope` (`client` or `saved`). Sliders require `min`, `max`, `step`; choices require the `choices` field containing a finite list of strings. For example:

```lua
schema = {
    { id = "cameraMode", type = "choice", default = "game.cameraNear",
      choices = { "game.cameraNear", "game.cameraFar" }, category = "gameplay",
      labelKey = "game.cameraMode", scope = "saved" },
},
-- In GameConfig.strings:
-- ["game.cameraMode"] = "Camera distance",
-- ["game.cameraNear"] = "Near", ["game.cameraFar"] = "Far",
```

 An optional client `apply(value)` hook applies game effects. Saved definitions must also be registered on the server; a client cannot invent saved schema. Server registration freezes before the first player loads. Server `set` rejects client-scoped settings. IDs are up to 32 letters, digits or underscores.

| Built-in ID | Default | Scope |
|---|---|---|
| musicVolume / effectsVolume | 1; range 0–1, step 0.05 | saved |
| reduceMotion | current platform preference | client |
| lowDetail | false | client |
| uiScale | 1; range 0.8–1.2, step 0.05 | client |
| textSize | platform; choices platform, standard, large | client |
| colorBlind | false | client |
| haptics | true | client |
| showTips | true | saved |

Configured categories receive default labels at `Settings.category.<category>`. Choice labels use `Settings.choice.<settingId>.<index>`; a choice value that is already a localization key resolves directly. For example, runtime-registered choices can use `game.cameraNear` and `game.cameraFar`, with their English defaults in `GameConfig.strings` and an existing category such as `gameplay`.

Set `builtins.<id> = false` to omit a built-in, or supply an override definition. Games add definitions through `schema`; other modules can call server `register` before player loads and client `register`. Register client apply hooks separately so functions never travel across the network. The server sends sanitized saved-schema metadata only to the owning client. A saved client registration can defer its apply hook until that metadata arrives; it cannot authorize a new saved ID.

Server API: `get(player, id)`, `set(player, id, value)`, `register(definition)`, and `signals.Changed(player, id, value)`. Client API: `get(id)`, `set(id, value)`, `onChanged(callback)`, `register(definition)`, `open()`, and `reset()`.

The network action has a ceiling of four writes per second with burst eight. `rate` applies an additional server throttle; increasing it does not raise that network ceiling. Client sends are paced, and dropped requests eventually roll back their optimistic drafts. Controls for sliders step by the configured exact increment, supporting touch without requiring a drag gesture.

Client edits apply immediately and send the latest value after the debounce. The server validates exact type, finite range, slider step, choice membership and scope. Saved changes use a bounded typed `Set` action and an owner-only `Ack` with a request ID and authoritative revision. Replicated `values` carry that revision too. The client keeps optimistic drafts separate from confirmed state, ignores older acknowledgements/snapshots, and rolls the latest rejected draft back to the confirmed value. A newer explicit server change wins. Request/revision counters never wrap; reconnect resets the client request state. Dirty saves are debounced from the first dirty edit, so continuous edits cannot postpone the save forever. Delayed callbacks are generation-checked after leave or shutdown. The `settings` save section holds only `{ values = { ... } }`; unknown/removed IDs and invalid stored values are dropped during load. Validated values replicate only to their owner. Client-scoped values stay on the current client session; the framework does not provide device disk persistence. Neither module runs a per-frame loop while idle.

## Settings: accessibility

Reduce motion owns the `CoreReducedMotion` local-player attribute consumed by framework feedback. Its default and reset follow `GuiService.ReducedMotionEnabled`. Text mode `platform` follows `PreferredTextSize`; explicitly choosing a size overrides that preference for these screens. UI scale uses the UI kit's scaled root and stays bounded. Labels and controls preserve minimum readable text and 44 real-pixel touch targets at the composed responsive and user scale, including the smallest scale. Both screens scroll within the available viewport, including at 667×375; code entry accounts for keyboard space.

Music and effects use the configured SoundGroups. Settings publishes the configured effects name in the local `CoreEffectsGroup` attribute; feedback observes it and reroutes existing pooled sounds. Without Settings the default is `CoreEffects`. A name resolving to an object of the wrong class is refused. Framework feedback routes to the effects group; game music should assign its SoundGroup to the music group. Group volume multiplies original sound volume. Low detail, colour accessibility and haptics expose change hooks and local attributes for games to consume. Do not write Roblox's graphics-quality setting. `SavedQualityLevel` is only a preference hint, and Automatic does not reveal current quality. Games should apply low detail to their own particles/shadows and use the colour hook to select a rarity palette with redundant text labels.

## Existing settings and overrides

Move an old preference through the owning game module's normal migration path. Define the new saved schema before player loading. In the module that owns the legacy preference, declare Settings as a dependency and run this transfer after load, in a thread because confirmation yields:

```lua
local function transferPreference(player)
    local old = ctx.data.get(player) -- this game's own section
    if old == nil or old.settingsTransferred then return end
    local ok = ctx.deps[Settings].set(player, "showTips", old.showTips ~= false)
    if not ok then return end
    -- Saves all player sections, including Settings; set alone is not durable confirmation.
    if not ctx.data.saveAsync(player) then return end
    ctx.data.update(player, function(mine)
        mine.settingsTransferred = true
        mine.showTips = nil
    end)
    -- A failed marker save only causes an idempotent transfer retry.
    ctx.data.saveAsync(player)
end
```

Keep the legacy value until the first confirmation. Retry the transfer after a failure or at the next join. Never read another module's section directly. If a separate legacy module owns the value, read it through that module's public API and have its owner record/clear its own migration state.

Level 1 lists the modules. Level 2 changes config, schema and flags. Level 3 replaces the registered `Codes` or `Settings` UI screen or individual apply hooks. Level 4 leaves either module out. Level 5 supplies another normal module using the same public APIs. A configured false flag blocks mutations and closes or disables the corresponding controls.

## Offline and published checks

Specs use fake services. Multi-server simulations cover duplicate submissions, rejoin, a three-server cap, ambiguous saves, lockout, live catalog changes and owner-only settings. Real ConfigService propagation, shared-store throttling under production load, device accessibility preferences and audible group mixing require a published test experience. Do not claim those checks from in-memory tests.

## Adding the kit to an existing scaffold

After adding module references, update the generated game's `Boot.spec.luau` expected-module list. A strict game config containing heterogeneous code definitions can annotate the catalog as a list:

```lua
local definitions: { any } = {
    { id = "welcome", code = "WELCOME", maxUses = 100, rewards = { { kind = "currency", amount = 10 } } },
    { id = "ended", code = "ENDED", expiresAt = 1, rewards = { { kind = "currency", amount = 10 } } },
}
```

Validate this list through the normal module config; the annotation does not bypass runtime validation. Promotion currency must not be listed as paid in `GameConfig.compliance.paidCurrencies`.

Keep live config disabled in service-free offline boot specs. Enable it explicitly in a fake-backed focused harness test:

```lua
local fake = StudWork.test.fakes.configService({ values = {
    player_codes = { definitions = {
        { id = "liveWelcome", code = "LIVEWELCOME", rewards = { { kind = "currency", amount = 5 } } },
    }, disabled = {} },
} })
local h = StudWork.test.harness({
    modules = { Economy, Codes },
    services = { ConfigService = fake },
    config = { Codes = { live = { enabled = true } } },
})
```

Public project scaffolds require a released `vX.Y.Z` pin. For an unreleased local evaluation, create the scaffold from an existing release, then move only the throwaway project's submodule pin to the candidate commit. Expect pin lint to refuse that development pin; do not suppress the guardrail or treat this as a released game. Release-pinned tooling validation is a separate check.
