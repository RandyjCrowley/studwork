# Leaderboards (engagement kit, v1.7.0 module)

All-time boards (`ctx.data.ordered`) and daily or weekly boards (`ctx.data.sortedMap`), a top N shared by every server, the player's own rank, and `UI.Leaderboard`.

Layout (one folder per module, module-api.md §1): `module.luau` (the definition: config schema and
defaults, save section, strings), `server/` (server part), `client/` (rows from state), Rojo:
`ReplicatedStorage.Modules.Leaderboards`, `ServerScriptService.Modules.Leaderboards`.

Design and API: [docs/framework/kits/leaderboards.md](../../../../docs/framework/kits/leaderboards.md).

Status: the foundation skeleton. `module.luau` is final; the server part is a valid empty part whose
API answers with documented safe defaults. Implementation: the leaderboards builder of the v1.7.0 round.
