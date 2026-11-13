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
<server|invite|private> [userId]`, `sandbox giftme [itemId] [userId]`, `sandbox fill [userId]`, `sandbox free [userId]`.
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

In Studio, connect the sandbox, start Play, switch the command bar to **Client**, and paste
`tools/studio/ui-text-fit.luau` (or run it through Studio MCP `execute_luau` with
`datamodel_type = "Client"`). It mounts every UI kit component and the default Odds (restricted,
long names), Inventory and Mailbox screens, one at a time, in surfaces of 1280×720 (desktop),
667×375 (small phone), 926×428 (large phone) and 1024×768 (tablet), under the responsive UIScale
`UI.ScaledRoot` applies at that size, and returns JSON keyed by size:

- `clipped`: text whose box is smaller than `TextService:GetTextBoundsAsync` at its real inner
  width, or whose rendered size is below `Theme.metrics.minTextSize`. Never `TextFits`, which stays
  true for the v1.6.1 notice that showed one of its lines. `TextScaled` sizes are emulated in real
  pixels, because the engine applies `UITextSizeConstraint` after every UIScale.
- `blocked`: a button inside a Modal (on screen, not scrolled out) whose centre's top hit isn't the
  button.
- `offscreen`: a Modal panel or close button outside the screen.
- `overflow`: a fixed-size container whose list content is bigger than it (spills onto neighbours).
- `truncated`: intentional two-line ellipses (odds names, item cards), for information.

Pass = `clipped`, `blocked`, `offscreen` and `overflow` empty at every size. Against v1.6.1 it reports the cut-off
region notice, odds text under 11 px and every Modal button blocked. For screenshots set
`KEEP = "<size>"`, `KEEP_CASE = "<case>"` (and `ONLY` to run one case); stop Play to clear them.

The surfaces don't cover a game's own ScreenGui. Also open one odds window through the real game
(`policy restrict true` in the server console, then the game's button): v1.6.2 found a blank odds
window there that every surface check passed, caused by a game ScreenGui left at
`ZIndexBehavior.Global`.

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

## New in v1.7.0

Everything below needs Studio or a published test place. Nothing in the automated tests calls a real
Roblox service. Use a **test** place, never a live game; Open Cloud and badge checks need real ids
and a key from the game owner (`docs/framework/kits/notifications.md`, "Setup").

6. **Two players: TextFilter and the friends context (Local Server, 2 players).**
   In the sandbox, `sandbox petname Sprout` in Player1's context shows what other players see.
   Expected: a `public` name comes back filtered (try a name Roblox filters); a `friends` text is
   shown to a real friend and hidden from a non-friend (Studio test players are not real friends:
   use two real accounts on a test place); a restricted account (`IsContentSharingAllowed` false)
   is refused with `policy`; nothing readable appears in the Output logs.

7. **Leaderboards across servers (two servers, 1-2 players each).**
   Touch the sandbox block in server A until `sandbox top dailyTouches` shows rows, wait
   `writeSeconds` (120 s) plus `refreshSeconds` (60 s), then run `sandbox top dailyTouches` in a
   second server.
   Expected: the second server shows the first server's rows and your own rank; only one server
   reads the shared top at a time (check the Output for read warnings or `budget` answers);
   `UI.open("Leaderboards")` highlights your row, pins it under the list when outside the top N, and
   reads well on phone and tablet (run `tools/studio/ui-text-fit.luau` with long player names).

8. **Notifications (test place, a real key).**
   Create the Open Cloud key and secret as the page says, put a real template id in `Balance.luau`,
   then `sandbox egg 30` on a server with one real player who has opted in.
   Expected: the prompt appears only after `minSessionSeconds`, not on join; the notification arrives
   once, after about 30 s, also when you leave the server first (a second server must still be
   running); tapping its button joins with launch data and fires `LaunchedFrom` once. Check the real
   response and error shapes against the request on the page.

9. **Badges (test place, a test badge).**
   Put a real test badge id in `Balance.luau`, `sandbox badge firstCollect`.
   Expected: Roblox's own notification and the in-game toast appear once; awarding again does
   nothing; with `awardInStudio = false` in Studio the Output says `would award` and nothing is sent.

10. **Environments, flags and ConfigService.**
    On the test place, paste its ids into `deploy.json`, run `tools/sync-projects`, publish, and
    check `StudWork.env.name()` reads `"test"` there and `"live"` on the live place. Stage a boolean
    experience config `flag_newShop` and wait `refreshSeconds`: `StudWork.flags.isOn("newShop")`
    follows it, and a `testOnly` flag cannot be switched on in live.

11. **Languages.**
    In Studio, change the player's language (Player Emulator): `UI.useText` labels re-render, and
    the server's `ctx.text.format` follows after the translator refetch. Confirm a Rojo-built
    `LocalizationTable` under `LocalizationService` is picked up, that automatic text capture of
    kit labels works, and that text still fits in a long language.

12. **Store limits under load.**
    With several servers running, watch the Output for `budget`, `throttled` and `memory_budget`
    answers from the ordered and MemoryStore calls; confirm the census reading (`servers`, `players`)
    matches the dashboard and that player saves are never delayed. At scale (hundreds of servers),
    watch the MemoryStore observability dashboard for `DataUpdateConflict` and
    `PartitionRequestsOverLimit` on `SW/_/census` and its shard maps `SW/_/census/<k>` (past 500
    servers the census bucket is split, module-api §23.5) and on the usage items `u/<Module>`,
    which are not split.

## New in v1.8.0

Everything below needs Studio or a published test place; the automated tests use fakes for every
Roblox service and a fake world. Use a **test** place, never a live game. Each kit page names what it
assumes; open problems are in [known-issues.md](known-issues.md) (O14 to O45).

13. **Quests and Goals (`examples/quests-demo`, Device Emulator, a StreamingEnabled place).**
    - [ ] Quest board on a phone (Device Emulator 667x375 and a real device): tabs, rows, Claim,
          Reroll, Odds, "Resets in"; text readable; nothing clipped; touch only.
    - [ ] Gamepad: open the board from the HUD button, first Claim selected, B closes; the pill,
          tracker and edge arrow never take focus.
    - [ ] Goal pill and beam in the first session: they help without nagging; no modal, no camera
          move; reduce motion on: no pulse.
    - [ ] StreamingEnabled place: a goal target far away (streamed out) still gets an edge arrow (last
          known or fallback); walking toward it streams it in and the beam snaps to it.
    - [ ] Reset time: a daily set changes at the configured local midnight for players in your main
          time zone; the set is the same after rejoining and after joining another server.
    - [ ] Save size after weeks: `data dump <userId>` for a regular player: the `quests` section stays
          a few KB (no per-day growth).
    - [ ] A claim with full inventory shows the refusal toast and keeps the quest claimable.
    - [ ] A roll reward's Odds button shows the table's odds at luck 1, also while the player has a
          luck boost.
    - [ ] At 667x375 the Goals pill, the currency widget, the mailbox and `Game.nextGoal` (if used)
          don't overlap in `topCenter`.

14. **Carry and Movement (`examples/carry`, Local Server with 2 players, network simulator).**
    - [ ] Two real players on a Local Server pick up a 2-carrier object together and walk it into a
          delivery zone. `Delivered` fires once, listing both carriers. Picking it up again is
          refused until `Carry.reset`.
    - [ ] A throw between two real players, caught, and then a missed catch. A missed throw becomes a
          plain drop that anyone can pick up, and it settles and re-anchors.
    - [ ] Touch controls on a phone or the Device Emulator at 667x375 and 926x428: the interact
          button ("Pick up" / "Help carry" / "Drop"), the pass button and its target highlight, and
          the bottom status chip.
    - [ ] A real player on Studio's network simulator at 300 ms with jitter completes a normal run
          (walk, jump, fall off a ledge, ride a tagged moving platform, sit in a seat, respawn) with
          zero Movement strikes.
    - [ ] A carried object looks smooth (no 10 Hz stepping) to a second client at 300 ms. A dropped
          object pushed off the map comes back to its spawn.
    - [ ] A carriable **Model** (with a `PrimaryPart` at one end) does not jump on pick-up, reset or
          delivery once its pivot is at its box centre; note the jump if it isn't (known issue O31).
    - [ ] With `wallSweep = "strike"`, carrying an object past walls, through a checkpoint and past a
          just-dropped object gives zero strikes; a client-side teleport still strikes.
    - [ ] On a deployed (not Studio) server with real latency, `Player:GetNetworkPing()` is non-zero
          and a normal run at about 300 ms draws no strike (known issue O32).
    - [ ] After a cold server start, a dropped object doesn't collide with players
          (`CarryDropped` × `CarryCharacters`) but does collide with the floor.
    - [ ] A crate held still for 10 s: its server CFrame changes 0 times (the idle-write skip holds
          against a live character's replicated wobble).
    - [ ] Changing a character root's `CollisionGroup` in the client's command bar doesn't change
          what the server reads.
    - [ ] A respawned player's new body is never hit by another player's wall sweep (no `wallSweep`
          strikes when walking through a just-respawned player).
    - [ ] With hard landing turned on (`hardLandingSpeed` set): walk a crate off a 15-stud ledge, down
          a staircase with a jump, and onto a lift; only the ledge fall drops it (known issue O31).

15. **Companions (Local Server with 2 players, a low-end phone).**
    - [ ] Equip three copies: walker, hopper and flyer; follow on flat ground, stairs and a moving
          platform.
    - [ ] Respawn and teleport; each clone snaps back without crossing the world by smoothing.
    - [ ] Enable a variant hook on server and client; confirm follower, Plot and custom thumbnail
          agree.
    - [ ] Check the equip screen at desktop and 667x375, including paging, empty state and full
          slots.
    - [ ] Toggle reduced motion and low detail; decorative motion and tracks stop, following remains.
    - [ ] Toggle the kit's flag off/on; actions, bonus and visuals follow it while saved selections
          remain.
    - [ ] In a real two-player local server, both clients see the other's companions.
    - [ ] Profile a low-end phone and a busy streamed scene; capture triangles, effects and frame cost
          (known issue O34).

16. **Codes and Settings (a published test experience).**
    - [ ] Real ConfigService propagation: stage a live promotion definition and confirm servers pick it
          up after `refreshSeconds` (the guide gives roughly 15 seconds to one minute).
    - [ ] Shared-store throttling under production load: a capped code redeemed from several servers
          never exceeds its cap.
    - [ ] Device accessibility preferences (reduced motion, preferred text size, UI scale) are applied
          by the Settings screens on a real device.
    - [ ] Audible group mixing: changing the effects volume in Settings changes the framework's
          feedback sounds and nothing else.

17. **Moderation kit (a published test place, a real group, two servers).**
    - [ ] A real `BanAsync`: the ban modal on join, alt-account propagation and device blocking.
    - [ ] Which real `BanAsync` errors are transient (a transient one leaves the ban `"pending"` and
          retried).
    - [ ] Real cross-server latency of `ctx.data.messages` (a kick or mute to a player on another
          server).
    - [ ] Staff ranks from a real group (`ServerConfig.Admin.groups`).
    - [ ] Voice mute through `AudioDeviceInput` access lists.
    - [ ] Text mute: `TextSource.CanSend` under platform-integrated chat.
    - [ ] The staff panel and the report screen on a phone.
