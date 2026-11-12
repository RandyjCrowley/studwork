# Badges (engagement kit, v1.7.0 module)

Badge definitions in config, awarded on game events: recorded first, sent to Roblox afterwards, never twice.

Layout (one folder per module, module-api.md §1): `module.luau` (the definition: config schema and
defaults, save section, strings), `server/` (server part), `client/` (the toast), `net.blink` (Awarded; generated `server/Net.luau` and `client/Net.luau`), Rojo:
`ReplicatedStorage.Modules.Badges`, `ServerScriptService.Modules.Badges`.

Design and API: [docs/framework/kits/badges.md](../../../../docs/framework/kits/badges.md).

Status: built in v1.7.0. `server/BadgeRules.luau` holds the pure rules (config validation, backoff,
budgets, batches); specs: `packages/kits/engagement/tests/Badges*.spec.luau`.
