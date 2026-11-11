# Friends (social kit, v1.3.0 module)

Layout (v1.3.1, one folder per module, module-api.md §1): `module.luau` (definition), `server/` (server part; the code files named below live there). Rojo: `ReplicatedStorage.Modules.Friends` (module, client, shared), `ServerScriptService.Modules.Friends` (server).

Definition: `module.luau` (optional dependency: Economy). Server part: `server/init.luau`.

api: `onCoPlay(handler) -> Connection`, `friendsInServer(player)` (last detected list, no yield),
`signals.CoPlay(player, friends, kind)`. No save data.

- `CoPlay.luau` - pure helpers: kind resolution, gained-set diff, pair cache key (`CoPlay.spec.luau`).
- `init.luau` - detection on player load (for the joiner and everyone already here) and every
  `config.Friends.friends.checkIntervalSec` (default 30, floor 5) on the framework's shared ticker;
  `IsFriendsWithAsync` cached per pair (pcall, failures not cached) and deduped in flight by
  `PairDedupe.luau`.

Kind: `"invite"` when `Player:GetJoinData().ReferredByPlayerId` is a friend in the server; `"private"` when
`game.PrivateServerId ~= ""` and `game.PrivateServerOwnerId ~= 0`; else `"server"`. `CoPlay` + toast fire
only when the friend set gains someone. `config.Friends.friends.coPlayMultiplier` is applied through
`ctx.deps[Economy].addMultiplier(player, "coplay", mult)` while >= 1 friend is present, removed otherwise,
only when Economy is enabled.

Console (Studio): `friends coplay <server|invite|private> [userId]` fires the hook with mock friends.
