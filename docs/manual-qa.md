# Manual QA: what still needs Roblox Studio

Almost everything StudWork does is tested offline. `tools/test` runs every Lune spec, including
the multi-server simulation in `packages/framework/test/sim/` (real ProfileStore session locks on
a mock DataStore and MessagingService, with latency, crashes and failure injection), and
`tools/test-sim` adds the long soak test. What the simulation can't cover is the real engine
(Players, remotes, replication, GUI layout, audio) and the real DataStore service. This page is
the checklist for that part. Run it before a release, or after a change to UI, networking or
saving.

## Start the sandbox

The sandbox (`examples/sandbox`) is a small playable game that uses every kit module. From the
repo root, once per machine:

```
tools/install
tools/doctor        # every line should say ok
```

Then:

```
tools/dev sandbox   # serves examples/sandbox/default.project.json with Rojo (port 34872)
```

In Studio: open a new Baseplate, open the Rojo plugin and connect to `localhost:34872`, then use
the Test tab. The loop: touch the glowing block to get an item, it goes on your plot and earns
coins every second; the action bar has Upgrade, Chest, Robux egg and Rebirth buttons.

**Server console.** During a test, switch the command bar to the **Server** context and run:

```lua
print(game.ServerScriptService.Framework.StudWorkConsole:Invoke("help"))
```

`help` lists every command. Useful ones: `modules`, `data dump [userId]`, `rarity roll <tableId>
[userId]`, `rarity odds <tableId>`, `streak advance [userId]`, `friends coplay
<server|invite|private> [userId]`, `sandbox giftme [itemId]`, `sandbox fill`, `sandbox free`.
Pass a command and its arguments as one string (`StudWorkConsole:Invoke("rarity roll Block")`)
or as separate arguments. Studio test players have UserIds -1, -2, ….

## Already covered by automated tests

You don't need to repeat these by hand:

| Behaviour | Spec (under `packages/framework/test/sim/` unless noted) |
|---|---|
| leave and rejoin on the same or another server, saved data intact, `lastSeen` stamped | `Lifecycle.spec.luau` |
| offline payout: `capSeconds`, `minSeconds`, `payoutFraction`, `autoPay = false` still fires handlers | `Offline.spec.luau` |
| `Inventory.transfer` and the `gift` action: ownership, restricted paid sources, full inventory, cooldown | `Gifting.spec.luau` |
| friend detection, co-play multiplier on and off, invite kind, lookup failures | `CoPlay.spec.luau` |
| shutdown with saves in flight; receipts across shutdown or crash never doubled or lost | `Shutdown.spec.luau` |
| session lock held by another server (release request, steal, stale lock, outage, newer data) | `SessionLock.spec.luau`, `StolenSession.spec.luau` |
| cross-server gifting, mailbox, claim; gifts never duplicated or lost | `GiftingCrossServer.spec.luau`, `GiftSoakReal.spec.luau`, `packages/kits/collection/Inventory/server/Gift.spec.luau` |

## UI text fit

Run `tools/test tools/lune/uifit/Checker.spec.luau` for planted violations and `tools/test tools/lune/uifit/UiTextFit.spec.luau` for named, per-component and per-viewport source/model checks. The full `tools/test` discovers every UI text-bearing component; an unmodeled new component is a failure. Geometry fixtures use component layout modules where available; these model checks do not replace Studio measurements.

In Studio, connect the sandbox, start Play, switch the command bar to **Client**, and paste `tools/studio/ui-text-fit.luau`. The script mounts default components and screens with long text into separate 1280×720 (desktop), 667×375 (small phone), 926×428 (large phone), and 1024×768 (tablet) surfaces. It returns JSON keyed by viewport. Each `clipped` entry includes the full instance path, string, actual box, measured bounds, effective text size, and reason. A failure means a zero-size box, text below the theme's minimum real-pixel size, or a box smaller than `TextService:GetTextBoundsAsync` at the real inner width (not merely `TextFits`, which missed the original bug). `blockedButtons` lists modal buttons whose centre's top hit is not the button or a descendant; no GuiInset is added because the test ScreenGui ignores it. Empty arrays for both keys at every viewport are the target. Set `KEEP = true` at the top to leave the tablet surfaces mounted for screenshots; remove them or stop Play afterward. Review false positives from intentional scroll-window clipping against the screenshot.

## Checklist

1. **Leave and rejoin through the real engine (Local Server, 1 player).**
   Test tab > Clients and Servers > Local Server, 1 player > Start. Touch the block until you own
   an item on your plot and have some coins; note the coin count. Close the client window, wait at
   least a minute (the offline payout's `minSeconds`), then start another client the same way
   (solo Play can't rejoin the same server).
   Expected: the second client shows the same coins, items and plot, plus an offline payout pop
   ("+N"); no "opened in another server" kick; the ProfileStore mock warning appears in the Output
   only once.

2. **Two players in one server: gifting and co-play (Local Server, 2 players).**
   Local Server, 2 players > Start. Get Player1's item uids with
   `StudWorkConsole:Invoke("data dump -1")` in the Server command bar. The sandbox has no gift
   button, so in Player1's client command bar run:

   ```lua
   local RS = game.ReplicatedStorage
   require(RS.Framework).use(require(RS.Modules.Inventory.module)).actions.gift(-2, "<uid>")
   ```

   Then, in the Server command bar, `StudWorkConsole:Invoke("friends coplay server -1")` (Studio
   test players are not real friends).
   Expected: the item leaves Player1's inventory at once and reaches Player2 within a few seconds
   (with Mail on, a gift goes through the crash-safe outbox: one save, then delivery); both HUDs
   update; gifting the same item again does nothing; a second gift within 2 s is ignored; the
   co-play toast "Playing with …" appears for Player1. An item from the Robux egg can't be gifted
   by a paid-random-restricted player (only checkable when the Studio account's PolicyService
   answer is restricted; otherwise skip).

3. **Phone and tablet layout (Device Emulator).**
   Test tab > Device: pick the smallest phone, a large phone and a tablet, each in landscape and
   portrait. Play the loop once per device: touch the block, open the odds screen, open the
   chest, wait for a toast.
   Expected: nothing is clipped or hidden under the top bar or notch; buttons are at least
   thumb-sized; the odds screen draws above the action bar and the HUD; the mailbox badge (when
   shown) doesn't overlap the currency counter; text stays readable.

4. **Listen to every default sound.**
   The sound keys are the `sounds` group of the default theme (`packages/framework/shared/Theme.luau`,
   [theme guide](framework/theme.md)). In Play, trigger each: the rarity stingers (roll items of
   each tier with the block, the chest and `rarity roll`), coin ticks (earn coins), a purchase
   (the Robux egg as a Studio test purchase), rebirth, button click and error (press a button, try
   an unaffordable upgrade), streak (`streak advance`), event start (an event from
   `examples/sandbox/src/shared/Config/Events.luau`).
   Expected: each plays once and fits its moment, rarity stingers get bigger with the tier, and no
   sound is much louder than the others. Swap any id that doesn't fit in the theme (keep the keys).

5. **The real DataStore, on a separate test place.**
   Only on a test place you published for this, never a live game. Enable Studio access to API
   services for it (Game Settings > Security) or play the published place.
   (a) Play, earn coins, leave, rejoin: data kept, and no mock warning in the Output.
   (b) Join a server, leave, and join a second server within a few seconds (a private server or a
   second device): data kept, no kick.
   (c) Buy the CoinPack developer product as a test purchase, then stop the session immediately:
   on the next join the coins are there exactly once.
   (d) Gift an item to an alt account that is offline (server code:
   `StudWork.Inventory.sendGift(player, altUserId, uid)`), then join with the alt in another
   server: it arrives once, or waits in the mailbox (HUD "Mailbox (N)") when the alt's inventory
   is full.
   Expected: as described; the Output has no save load-failure or "refusing to load" warnings.
