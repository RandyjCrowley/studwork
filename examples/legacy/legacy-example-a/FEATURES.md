# legacy-example-a: what the game does

A small Studio-only game (one place file, no Rojo, no StudWork), used to test adopting StudWork.

1. **Coins** are saved per player and shown on the leaderboard (`leaderstats.Coins`).
2. **Coin pad:** standing on the yellow pad gives 5 coins, at most once every 2 seconds.
3. **Daily reward:** 100 coins once every 24 hours (the Daily button).
4. **Shop:** buy a Sword (100), a Shield (250) or a Party Hat (50) with coins; each item once;
   owned items are saved.
5. **Coin pack (Robux):** developer product 1234567 gives 1000 coins. Granted receipts are recorded
   in the `PurchaseHistory` DataStore (`<userId>_<purchaseId>`).
6. **Music:** background music; M toggles it, and the choice is saved (`settings.music`).
7. **Saves:** DataStore `PlayerSave_v3`, key `Player_<userId>`, autosave every 60 s, on leave and
   on shutdown. `settings.sfx` is saved but nothing uses it yet.
