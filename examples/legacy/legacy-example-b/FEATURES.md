# legacy-example-b: what the game does

A Rojo game (no StudWork) that saves with ProfileService, used to test adopting StudWork.

1. **Coins and gems**, saved per player; coins on the leaderboard (`leaderstats.Coins`).
2. **Coin piles:** six piles around the spawn; touching one gives 10 coins (20 with VIP); a pile
   comes back after 10 seconds.
3. **Pets:** hatch an egg for 50 gems: Puppy, Kitten (Common), Fox, Owl (Rare), Dragon
   (Legendary), weights 40/40/9/9/2. Up to 10 pets (20 with the ExtraSlots pass). Equip up to 3.
4. **Pet income:** every equipped pet earns its coins per second (doubled with VIP).
5. **VIP gamepass** (2222): double coins. **ExtraSlots gamepass** (3333): 20 pet slots.
6. **Gem pack** (developer product 4444, Robux): 100 gems. Granted purchase ids are kept in the
   profile (`Purchases[purchaseId] = true`).
7. **Stats:** eggs hatched, coins collected (saved).
8. **Custom UI:** coins/gems labels, the pet list with equip toggles, the hatch / VIP / slots /
   gem pack buttons.
9. **Saves:** ProfileService (`lib/ProfileService.luau`), profile store `PlayerData`, key
   `Player_<userId>`, session-locked, autosaved, released on leave.
