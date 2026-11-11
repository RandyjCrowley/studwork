# legacy-example-c: what the game does

A messy Rojo game (no StudWork) that saves with DataStore2, used to test adopting StudWork.

1. **Coins, xp, level, rebirths** on the leaderboard (`leaderstats.Coins`, `Level`, `Rebirths`).
   Level = floor(sqrt(xp / 50)) + 1.
2. **Passive income:** every second, coins += level x (1 + rebirths), doubled while a boost is
   active; xp += 1.
3. **XP orbs:** 8 orbs on the map; touching one gives 25 xp; it moves and comes back after 15 s.
4. **Rebirth:** costs 10000 x (1 + rebirths) coins; resets coins and xp, +1 rebirth.
5. **2x boost:** 500 coins for 10 minutes of double coins (stacks in time); boosts bought are
   counted in the inventory (`inventory.boostsBought`).
6. **Robux products:** 5555 = 500 coins; 5556 = +1 rebirth. No purchase history is kept.
7. **Saves:** DataStore2 with `Combine("DATA", "coins", "xp", "rebirths", "inventory",
   "boostUntil")`, ordered-backups layout (`lib/DataStore2.lua`). A second script also saves
   every player's coins to the DataStore `CoinsBackup` (key `<userId>`) and restores them at join
   when the backup is higher.
