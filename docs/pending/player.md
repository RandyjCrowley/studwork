# Player kit integration additions

Apply these additions when integrating the player kit with the other changes. Shared documentation and scaffolds are intentionally left for integration.

## CHANGELOG under Unreleased / Added

- Player kit: independent Codes and Settings modules, transactional free promotion rewards, durable cross-server use limits, cached live promotion definitions, owner-only validated preferences and accessible screens.
- Public server configuration snapshots for modules, local UI scale preferences and feedback sound-group routing.

## Decisions

- Durable global cap: use ctx.data.shared.update backed by UpdateAsync, not expiring MemoryStore. Retain ambiguous reservations forever; availability can underfill after crash. https://create.roblox.com/docs/reference/engine/classes/GlobalDataStore#UpdateAsync and https://create.roblox.com/docs/reference/engine/classes/MemoryStoreService . Callbacks must be pure/non-yielding; retries may execute callbacks repeatedly.
- Generic configuration snapshot API: ctx.configValues.snapshot() through framework, avoiding any kit-specific framework names or direct service access. https://create.roblox.com/docs/production/configs supports global snapshots, UpdateAvailable/Refresh, stale snapshot retention and JSON values. Values are not refreshed merely by receiving UpdateAvailable. Cache with bounded refresh and entry size. Official guide allows 1000 active configs; inspect current limits table before choosing payload cap.
- Accessibility: https://create.roblox.com/docs/reference/engine/classes/GuiService (ReducedMotionEnabled, PreferredTextSize), https://create.roblox.com/docs/reference/engine/classes/UserGameSettings (SavedQualityLevel). Automatic is not actual current rendering quality; never attempt to set Roblox quality.
- SoundGroup.Volume multiplies sound gain; route feedback to effects group and game music to music group. https://create.roblox.com/docs/reference/engine/classes/SoundGroup . Minimal generic client preference attributes make existing scaled roots respond to player choice without framework naming a kit.
- Promotion policy: https://en.help.roblox.com/hc/en-us/articles/10549651908244-Promo-Offers-for-Virtual-Rewards requires experience-only virtual rewards with no Robux/real-world value, public redemption details, no exchange needed, and prohibits unique per-user promotion codes. Custom rewards require author catalog review.

Known issue proposal: A capped code can underfill after a server dies with an unconfirmed reservation. The slot remains reserved to avoid granting beyond the cap. IDs are permanently retired; pruning removed-code history intentionally prevents safe reuse.

## Review amendments

- Version 1 rejects explicit oncePerPlayer=false. All definitions verify durable immutable cap policy, including uncapped limit=0. Never expire ambiguous reservations, never prune pending or sequence; finalize is token-idempotent. Public op budgets include recovery and up to four backend calls per operation.
- Catalog retirement is permanent across deployments and rollbacks; only settled history can be pruned. Pending recovery has no catalog/flag eligibility prerequisite and grants nothing anew.
- Settings uses owner-only authoritative revisions plus per-ID request sequences and distinct optimistic draft state; first-dirty timer prevents indefinite save postponement. Migration must confirm saveAsync before clearing legacy data.
- Config JSON maximum is 100,000 characters; kit uses 90,000 cap. Service propagation is eventual (official guide roughly 15 seconds to one minute for normal immediate rollout). Never claim real propagation from fake tests.
- CoreEffectsGroup generic local-player routing convention allows configurable groups and reroutes existing feedback sounds. CoreUIScale is multiplicative with responsive scale; touch minimum is physical pixels.

## Module reference and kit contract additions

Codes: optional Economy, Inventory, Rarity and Rebirth; save section `codes`, never replicated. Server `redeem`, `define`, `disable`, `uses`, `registerReward`, `registerRequirement`, signal `Redeemed`; client `redeem`, `open`. All rewards and redemption records commit in one transaction. Capped reservations use the public shared store, retain uncertain saves and finalize idempotently after confirmation. No paid rewards or paid rolls.

Settings: independent save section `settings`, never directly replicated. Server `get`, `set`, `register`, signal `Changed`; client `get`, `set`, `register`, `onChanged`, `open`, `reset`. Only validated saved values and acknowledgements replicate to their owner. Client apply functions never travel over the network.

See [the kit guide](../framework/kits/player.md) for configuration defaults and override levels.

## Module API addition

`ctx.configValues.snapshot() -> ConfigSnapshot` yields and returns an experience configuration snapshot through the framework. It is server-only, fakeable with `services.ConfigService`, and does not bypass the service allow-list. A module must cache snapshots, bound refresh cadence, handle errors and validate each value before use. Raw configuration values are never automatically replicated.

## New-project and new-game module lists

Both tools discover module definitions through the manifest, so the new definitions already accept these exact selections without manually editing either shared script:

```sh
tools/new-project ../example-game --name example-game --modules Codes,Settings --no-install
tools/new-game example-game --modules Codes,Settings
```

Update their help/documentation examples with these lines during integration. Include the two normal module references only when selected; unused reward dependencies need not be enabled.

## Sandbox and template snippets

```lua
local Codes = require(Modules.Codes.module)
local Settings = require(Modules.Settings.module)
-- Add the selected references to GameConfig.modules:
modules = { Codes, Settings },
config = {
    Codes = { definitions = {} },
    Settings = { schema = {} },
},
```

Map `Codes.module`, `Codes.client`, `Codes.shared` and `Settings.module`, `Settings.client`, `Settings.shared` beneath `ReplicatedStorage.Modules`; map each `server` folder beneath `ServerScriptService.Modules`, as with other kit modules. Keep unpublished promotion definitions in `ServerConfig.Codes`, or in experience configs.

## Existing framework and UI files touched

- `packages/framework/server/Context.luau`: bind generic `ctx.configValues` to each module.
- `packages/framework/server/Services.luau`: internal experience-config snapshot adapter; direct module service access remains refused.
- `packages/framework/shared/Types.luau`: optional configuration snapshot API types.
- `packages/ui/ScaledRoot.luau`: observe `CoreUIScale` and compose it with responsive scale.
- `packages/framework/client/Feedback/init.luau`: route pooled sounds through the generic `CoreEffectsGroup` preference. New `SoundRouting` helper reroutes existing voices and preserves gain.

## Tooling validation

`tools/lune/NewGame.spec.luau` updates the discovered-module count from 15 to 17 and adds explicit assertions for both module references and dependencies. The test count is preserved.

## Regenerated shared files

Generated by `tools/sync-projects` to map the two ordinary modules:

- `examples/modules/session-leaderboard/tests/fixture-game/default.project.json`
- `examples/overrides/ov-a/default.project.json`
- `examples/overrides/ov-b/default.project.json`
- `examples/overrides/ov-c/default.project.json`
- `examples/overrides/ov-d/default.project.json`
- `examples/overrides/ov-e/default.project.json`
- `examples/overrides/ov-f/default.project.json`
- `examples/sandbox/default.project.json`
- `examples/sandbox/foundation-only.project.json`
- `templates/new-game/default.project.json`

## Client entry-point snippets

```lua
local codes = StudWork.use(Codes)
local settings = StudWork.use(Settings)
-- Wire these callbacks to the game's chosen HUD controls:
local function openCodes() codes.open() end
local function openSettings() settings.open() end
```

## Additional accessibility decisions

Preferred text sizes use Roblox's [PreferredTextSize enum](https://create.roblox.com/docs/reference/engine/enums/PreferredTextSize), and keyboard bounds use [UserInputService](https://create.roblox.com/docs/reference/engine/classes/UserInputService). Controls preserve physical touch minima under the combined responsive, user and modal scale. Slider schemas are rendered as exact-step touch controls.

## Known-issue additions

### Medium: promotion retirement is permanent

Settled removed-code history is pruned to bound player saves. Never reintroduce a retired ID, including by config rollback: its discarded once-only history cannot be recovered. Pending receipts and their markers are never pruned. Explicit `oncePerPlayer = false` is refused in this version.

### Low: abandoned promotion reservations can reduce capacity

A crash before receipt confirmation can leave a capped slot reserved. Reservations never expire automatically, preserving the global cap at the cost of availability. Diagnose counts through `Codes.uses`; do not decrement completed uses or release an uncertain reservation.
