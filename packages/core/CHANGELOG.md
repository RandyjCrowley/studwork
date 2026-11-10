# Core changelog

Core's public interface (`packages/core/shared/Types.luau`, `packages/core/shared/net/core.blink`)
only gains things: no renames, no removals; old calls are marked deprecated instead.
Every change is recorded here, newest first.

## core-v1.0.0 (2026-11-10)

Phase 1 real services merged (A Data, C Items, B Economy, D Plot, E Meta, G Client, F UI) and the
Phase 2 review fixes applied.

Added (additive interface changes):
- `Policy.isKnown(player) -> boolean`: lets Robux handlers tell "policy lookup still running"
  (retry) from "known restricted" (grant a non-random fallback).
- `BalanceConfig.paidCurrencies: { string }?`: currencies sold for Robux. Rolls priced in them are
  paid random items (policy check before spending, results tagged `paid:<table>`, untradeable for
  restricted players).
- UI kit: `UI.ScaledRoot` (full-screen root with the responsive UIScale).

Services:
- Data: ProfileStore 1.0.3 sessions, versioned migrations (`Data/migrations/`), reconcile/sanitize,
  per-game table versioning (`game[gameId]._version`), Studio Mock, `saveAsync`, Mail via MessageAsync.
- Economy/Upgrades/Rebirth/Offline: cached per-player rate, one batched write per tick, stacking
  multipliers with expiry and persistence, cost curves, offline cap.
- Items/Rarity/Inventory/Policy: validation, luck, pity, mutations, exact odds, inventory cap with
  upgrades, atomic transfer with paid-random policy, fail-closed PolicyService lookup with retries.
- Plot: any `CorePlot`-tagged model, `SlotId`/`SlotTag` slots, queueing, Trove clean-up, spawn.
- Shop/Streak/Friends/Events/Analytics: idempotent ProcessReceipt with save-before-grant, gamepass
  cache, UTC streak with grace, co-play detection + multiplier, UTC weekday scheduler + admin and
  console triggers, AnalyticsService wrappers.
- Client: charm-sync replication (local player only, patches), feedback (pops, flash, sounds,
  shake, reduced motion), input abstraction; React UI kit + HUD.

Fixed (review High findings):
- `Data.saveAsync` no longer breaks after one failed save (stamped save sequence checked against
  the successful save's payload instead of counting OnSave vs OnAfterSave).
- Coin-priced rolls where Coins are sold for Robux are now treated as paid random items.
- Restricted players' Robux egg purchases get a non-random fallback instead of looping unprocessed.
Also fixed: shutdown/leave no longer kicks with "opened in another server" (only a stolen session
does); HUD/Panel/CurrencyCounter layout runaway (shadow inside list layouts, UIScale on a
full-screen frame).

Known issues: `docs/known-issues.md`.

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
