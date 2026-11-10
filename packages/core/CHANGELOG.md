# Core changelog

Core's public interface (`packages/core/shared/Types.luau`, `packages/core/shared/net/core.blink`)
only gains things: no renames, no removals; old calls are marked deprecated instead.
Every change is recorded here, newest first.

## 0.1.1 (2026-11-10, before Phase 1 dispatch)

Additive, approved by the core owner after Gate 0:

- `Data.saveAsync(player) -> boolean`: yields until the profile is committed. Needed so
  `Shop` returns `PurchaseGranted` only after the receipt id is saved.
- Server console (`core/server/Console.luau`, `ctx.console.register`): a server-only
  BindableFunction `ServerScriptService.CoreServer.CoreConsole` for the Studio command bar,
  admin tools and MCP playtests (`:Invoke("help")`).

## core-contract-v0 (2026-11-10)

Phase 0 contract, frozen for Phase 1.

- `Types.luau`: ItemDef, ItemInstance, RarityTier/RarityTierDef, Mutation, PlayerData (schema
  version, multi-currency map, inventory by uid, displayed slots, upgrades, rebirths, persisted
  multipliers, streak, lastSeen, firstJoin, purchases, pity, stats, funnel, per-game `game` table),
  GameConfig (items, balance, products, events, palette, admins, data, analytics), all namespace APIs.
- Namespaces: Items, Rarity, Economy, Inventory, Plot, Rebirth, Upgrades, Offline, Streak, Friends,
  Events, Shop, Policy, Data, Mail, Analytics, Signals; client: state, Feedback, Input, Actions, Hud.
- Network: `core.blink` (RemoteScope CORE) with StateInit, RequestDisplay, RequestClearDisplay,
  RequestRebirth, RequestUpgrade, RequestRoll, RequestGift, AdminTriggerEvent, ClientFunnel,
  StateSync, Feedback, EventState.
- Every service is a working in-memory stub; `_sandbox` boots against them.
