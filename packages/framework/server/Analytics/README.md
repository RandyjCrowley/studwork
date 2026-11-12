# Core.Analytics

Public API (`Types.AnalyticsAPI`): `funnel(player, step)`, `economy(player, flow, currency, amount, transactionType, sku?)`, `custom(player, name, value?)`.

- `AnalyticsUtil.luau` - pure validation (step index, amount, string sanitize, client whitelist); tests in `AnalyticsUtil.spec.luau`.
- `init.luau` - pcall'd AnalyticsService wrappers.

Signatures verified against creator-docs (2026-11, none deprecated): `LogOnboardingFunnelStepEvent(player, step, stepName?, customFields?)`,
`LogEconomyEvent(player, Enum.AnalyticsEconomyFlowType, currencyType, amount, endingBalance, transactionType, itemSku?, customFields?)`,
`LogCustomEvent(player, eventName, value?, customFields?)`. The config funnel is onboarding (logged once per player), so
`LogFunnelStepEvent` (recurring funnels with a session id) is not used.

`funnel`: step must be in `analytics.funnel`, number = index, once per player (`PlayerData.funnel`); "Joined" auto-logged on load
if configured. `economy`: finite amount > 0, ending balance from `Economy.balance`. `ClientFunnel` remote: `analytics.clientSteps` only.

Framework events sent with `custom` (v1.6.1):

- `PlayerLoadTiming`, once per join when the save loaded: value = join -> loaded seconds; fields
  `totalSeconds`, `loadSeconds` (data load), `passSeconds` (how long the gamepass lookups took, or until
  the wait ended), `passesPending` (lookups still open when the player loaded), `timedOut` (`"true"` when
  `GameConfig.shop.passPrefetchTimeout` ran out first).
- `LegacyCodeLive`, once per live (non-Studio) server, carried by its first loaded player, when
  `ServerConfig.legacyList` still lists files or a `ctx.shop.onLegacyProduct` bridge is registered (the
  boot also warns once): fields `entries`, `bridges`, `products` (comma list, cut to 100 characters),
  `writesLegacyData` (`product:Owner` of every bridge that declared it).
