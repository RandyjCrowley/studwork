# Offline (economy kit)

Layout (core-v1.3.1, one folder per module, module-api.md §1): `module.luau` (definition), `server/` (server part; the code files named below live there). Rojo: `ReplicatedStorage.Modules.Offline` (module, client, shared), `ServerScriptService.Modules.Offline` (server).

A real StudWork module (v1.3.0), no save section. Definition:
`module.luau`. Pure math: `OfflineMath.luau` (+ spec).

## Config (`config.Offline.offline`, defaults)
`capSeconds = 28800` (8 h), `minSeconds = 60`, `payoutFraction = 0.5`, `autoPay = true` (needs
Economy). The cap is config here so other modules coordinate with it through config, not files.

## API
`onReturn(fn(player, secondsAway)) -> Connection`.

## Behaviour
On `ctx.lifecycle.onPlayerLoaded` (the framework keeps `ctx.framework.lastSeen` at the previous
session's last save until this session's first save): `secondsAway = clamp(now - lastSeen, 0,
capSeconds)`, skipped on the first session (`ctx.framework.sessions == 1`) or below `minSeconds`.
With `autoPay` and Economy enabled it grants `floor(Economy.getRate * secondsAway *
payoutFraction)` (reason `"offline"`) with a `pop` feedback. `onReturn` handlers run each time
(own thread). Session-only boosts aren't in the rate (by design).
