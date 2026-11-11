# Manual QA: what still needs Roblox Studio (core v1.2)

Everything that can run offline is automated: `tools/test` runs the multi-server simulation in
`packages/core/tests/sim/` (real Core.Data + ProfileStore 1.0.3 with session locks, Offline,
Economy, Inventory, Friends, Shop and Mail on a mock DataStore), and `tools/test-sim` adds the
soak test. This list covers only what the simulation can't cover: the real engine (Players,
remotes, replication, GUI layout, audio) and the real DataStore service. Run it after merging,
on the sandbox example game (`rojo serve examples/sandbox/default.project.json`).

Console commands below run in the Studio command bar in the **Server** context during a test:
`game.ServerScriptService.CoreServer.CoreConsole:Invoke("<command>", ...)` (`"help"` lists them).

Automated coverage you don't need to repeat by hand:

| Behaviour | Spec |
|---|---|
| leave/rejoin on the same or another server, saved data intact, lastSeen stamped | `sim/Lifecycle.spec.luau` |
| offline payout, `capSeconds`, `minSeconds`, `payoutFraction`, `autoPay = false` still fires handlers | `sim/Offline.spec.luau` |
| `Inventory.transfer` and the `gift` action handler: ownership, restricted paid sources, full inventory, cooldown | `sim/Gifting.spec.luau` |
| friend detection, co-play multiplier on/off, invite kind, lookup failures | `sim/CoPlay.spec.luau` |
| BindToClose with saves in flight, receipts across shutdown/crash never doubled or lost | `sim/Shutdown.spec.luau` |
| session lock held by another server (release request, steal after 40 s, stale lock, outage, newer data) | `sim/SessionLock.spec.luau` |
| cross-server gifting, mailbox, claim | `sim/GiftingCrossServer.spec.luau`, `Inventory/server/Gift.spec.luau` (never-duplicated/never-lost property test) |

## Checklist

1. **Leave and rejoin through the real engine (Local Server, 1 client).**
   Steps: Test tab > Clients and Servers > Local Server, 1 player > Start. Touch the block until
   you own an item on your plot and have some coins; note the coin count. In the Server command
   bar run `CoreConsole:Invoke("lastseen", 600)`. Close the client window, then start another
   client the same way (known-issues: solo Play can't rejoin the same server).
   Expected: the second client shows the same coins/items/plot, plus an offline payout pop
   ("+N") about `rate × 600 × 0.5`; no "opened in another server" kick; the Output shows the
   ProfileStore Mock warning only once.

2. **Two players in one server: gifting and co-play UI (Local Server, 2 clients).**
   Steps: Local Server, 2 players > Start. Get Player1's item uids with
   `CoreConsole:Invoke("data", "dump", -1)` in the Server command bar (Studio test players have
   UserIds -1, -2). The sandbox has no gift button, so in Player1's client command bar run
   `require(game.ReplicatedStorage.CoreClient).api.Actions.gift(-2, "<uid>")` (real client
   remote through Blink and core's rate-limited Net). Then, in the Server command bar,
   `CoreConsole:Invoke("coplay", "server")` (Studio test players are not real friends).
   Expected: the item disappears from Player1's inventory at once and appears on Player2's within
   a few seconds (with Mail on, a same-server gift goes through the crash-safe mail outbox: one
   save, then delivery on Player2's next save), both HUDs update; gifting the same item again does nothing; a quick second gift
   inside 2 s is ignored. The co-play toast "Playing with ..." appears on the first player.
   A paid-roll item (from the Egg product) can't be gifted when a player is restricted (only
   checkable if the Studio account's PolicyService answer is restricted; otherwise skip).

3. **Phone and tablet layout (Device Emulator).**
   Steps: Test tab > Device, pick the smallest phone preset, a large phone preset and a tablet
   preset; check each in landscape and portrait. Play the loop once per preset: touch the
   block, open the odds modal, open the shop, wait for a toast.
   Expected: nothing is clipped or under the top bar / notch; buttons are at least thumb sized;
   the odds modal draws above the sandbox action screen and the HUD (known-issues re-check);
   the mailbox badge (when shown) doesn't overlap the currency counter; text stays readable.

4. **Listen to every sound in `packages/core/shared/Sounds.luau`.**
   Steps: in Play, trigger each key: `rarity_*` (roll items of each tier; use the Block, Chest
   and Egg rolls), `coin_tick` (earn coins), `purchase` (`CoreConsole:Invoke("receipt",
   "CoinPack")`), `rebirth`, `ui_click` / `ui_error` (press a button / try an unaffordable
   upgrade), `streak` (daily reward), `event_start` (`CoreConsole:Invoke("event", "CoinRain")`).
   Expected: each plays once, fits its moment, rarity stingers get bigger with the tier, and no
   sound is much louder than the others. Ids were picked from names only, so swap any that
   don't fit (keys must stay).

5. **Real DataStore on a published TEST place (needs the user's explicit OK to publish).**
   Steps: only on a separate test place, never the production place, and only after the user
   approved publishing. Enable Studio API access for it (Game Settings > Security) or play the
   published test place. (a) Play, earn coins, leave, rejoin: data kept and no Mock warning in
   the Output. (b) Join server 1, leave, and join a second server within a few seconds (a
   private server or a second device): data kept, no kick. (c) Buy the CoinPack dev product as
   a Studio test purchase, then stop the session immediately: on the next join the coins are
   there exactly once. (d) Gift an item to an alt account that is offline (server code:
   `Core.Inventory.sendGift`), then join with the alt in another server: it arrives once (or
   waits in the mailbox, HUD "Mailbox (N)", when the alt's inventory is full).
   Expected: as described; the Output has no `[Core.Data]` load-failure or "refusing to load"
   warnings.
