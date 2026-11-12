# Leaderboards (engagement kit, v1.7.0 module)

All-time boards (`ctx.data.ordered`) and daily or weekly boards (`ctx.data.sortedMap`), a top N shared by every server, the player's own rank, and `UI.Leaderboard`.

Layout (one folder per module, module-api.md §1): `module.luau` (the definition: config schema and
defaults, save section, strings), `server/` (server part), `client/` (rows from state), Rojo:
`ReplicatedStorage.Modules.Leaderboards`, `ServerScriptService.Modules.Leaderboards`.

Design and API: [docs/framework/kits/leaderboards.md](../../../../docs/framework/kits/leaderboards.md).

Files: `server/init.luau` (the part: stores, shared top N with the reader lease, writes, replication),
`server/Period.luau` and `server/Merge.luau` (pure rules), `client/init.luau` (api, screen registration),
`client/State.luau` (pure readers), `client/Views.luau` (React: the screen and the single board view).
Specs: `packages/kits/engagement/tests/Leaderboards*.spec.luau`, `client/State.spec.luau`,
`packages/ui/Leaderboard.spec.luau`.
