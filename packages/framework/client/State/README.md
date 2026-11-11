# client/State (agent G)

`Core.Client.state` = `State.atom`: a Charm atom of `Types.ReplicatedState`, same identity forever. Read it (`state()`, Charm `computed`, ReactCharm `useAtom`); never write it from game code.

`State.start(ctx)`:
1. `CharmSync.client.addSignals({ [tostring(LocalPlayer.UserId)] = State.atom })`
2. listens to Blink `StateSync`; each payload list is checked by `PayloadCheck` (array of `init`/`patch`, only our own key, `init` has boolean `loaded`) then applied with `CharmSync.client.patch`. `init` replaces the state, `patch` merges immutably (`patch.apply` clones changed tables only, so selectors see new references exactly where data changed).
3. fires `StateInit` -> server sends the full hydrate.

`loaded` becomes `true` when the server has PlayerData (server sends `loaded = data ~= nil`). `data` is the full PlayerData of the local player.

Tests: `PayloadCheck.spec.luau`.
