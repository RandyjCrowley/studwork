# Core.Friends (agent E)

Public API (`Types.FriendsAPI`): `onCoPlay(handler)`, `friendsInServer(player)` (last detected list, no yield).

- `CoPlay.luau` - pure helpers: kind resolution, gained-set diff, pair cache key (tests in `CoPlay.spec.luau`).
- `init.luau` - detection on data load (for the joiner and everyone already here) and every
  `balance.friends.checkIntervalSec`; `IsFriendsWithAsync` cached per pair (pcall, failures not cached) and deduped in flight by `PairDedupe.luau` (one web call per pair at a time, shared by both players' recomputes; tests in `PairDedupe.spec.luau`).

Kind: `"invite"` when `Player:GetJoinData().ReferredByPlayerId` is a friend in the server; `"private"` when
`game.PrivateServerId ~= ""` and `game.PrivateServerOwnerId ~= 0`; else `"server"`. `CoPlay` signal + handlers +
toast fire only when the friend set gains someone. `balance.friends.coPlayMultiplier` is applied via
`Economy.addMultiplier(player, "coplay", mult)` while >= 1 friend is present, removed otherwise —
only when the optional Economy module is enabled (`ctx.isEnabled("Economy")`).

Console (Studio): `coplay <server|invite|private> [userId]` fires the hook with mock friends (other players, or self).
