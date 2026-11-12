# sandbox (example game)

Minimal playable reference game that exercises every kit module: touch the glowing block -> get an item -> it goes on your plot -> it earns per second -> upgrade -> rebirth -> leave and come back to an offline payout.

- Rojo: `rojo serve examples/sandbox/default.project.json` (port 34872)
- Config: `src/shared/Config` (shared, replicated). Server-only settings (admins) live in
  `src/server/ServerConfig.luau`, passed as `StudWork.start(Config, ServerConfig)`. Game code: `modules/sandbox`
  (the game's own module). Boot test: `src/server/Boot.spec.luau`.
- Foundation-only check: `rojo serve examples/sandbox/foundation-only.project.json` (port 34873)
  boots StudWork with `modules = {}` (src in `foundation-only/`) and prints `[foundation-only] boot ok`
  plus the "Rebirth is not enabled in GameConfig.modules" error. Offline smoke test:
  `foundation-only/shared/Config.spec.luau`. `tools/typecheck` covers `src/`, `modules/` and `foundation-only/`.
- v1.7.0 demos (all in `modules/sandbox/server/Demo*.luau`; each does nothing when its module is left out of `GameConfig.modules`; Studio console commands are prefixed `sandbox`):
  - Leaderboards: block touches feed the `dailyTouches` board (a daily `sum` board); the `coins` board (all-time) reads Economy by itself. `sandbox top [board]` prints the cached rows and your own rank. **In the HUD** the "Leaderboards" button (top right, under Rebirth; flag `leaderboardButton`) opens the Leaderboards screen on `dailyTouches`, with a tab for `coins` and your own row highlighted.
  - Badges: `firstCollect` is awarded on the first item added (its `id = 0` is a placeholder: recorded and logged, never sent; `streakThree` fires from Streak). `sandbox badge [key] [userId]` awards one. In Studio the player sees a toast marked "(Studio preview, not sent)" and the client `Awarded` event fires, once per badge per session (`studioFeedback`, badges.md); Roblox is never called. Put a real badge id in `Balance.luau` to send it (live shows the plain toast).
  - Notifications opt-in: **demo values in `Balance.luau`**: `optIn = { minSessionSeconds = 30, minSessions = 0 }` (defaults: 180 and 1, so a first-session player is never asked). The 30 s loop requests the prompt once the session is 30 s old (never on join); `sandbox optin` asks now if allowed and says why not otherwise.
  - Notifications: `sandbox egg [seconds]` schedules an `eggReady` notification for you and offers the opt-in prompt; a 30 s loop also offers it. The template's `messageId` is a placeholder, so nothing is sent; the secret `OpenCloudNotifications` and its allow-list are in `src/server/ServerConfig.luau`.
  - TextFilter: `sandbox petname <name>` stores a public pet name and prints what other players would see (or the refusal reason); `sandbox petname-clear` releases it.
  - Environments, flags and strings (framework features): `src/shared/Config/Environments.luau` (generated from `deploy.json`), a hidden flag in `ServerConfig.luau` (the `flags` console command lists them), and `strings` that reword `ui.close` and add `game.welcome`, `game.leaderboards` and `game.debug`.
  - **Flags gate visible HUD elements** (`src/shared/HudRules.luau`, `src/client/Main.client.luau`): `leaderboardButton` (default on) shows the Leaderboards button: `flags set leaderboardButton false` in the Studio console hides it live, `flags set leaderboardButton clear` brings it back, no restart. `debugPanel` (testOnly: on in Studio and test, never in live) shows a "debug: studio" label under the buttons. `newShop` gates nothing visible.
  - **Localization**: `src/shared/Localization/game.csv` is mapped as `LocalizationService` (`tools/sync-projects` wrote the mapping in `default.project.json` and `foundation-only.project.json`; Rojo builds a `LocalizationTable` named `game`). It has English and `es` rows for `game.leaderboards` ("Clasificaciones") and `game.welcome`; the English defaults live in `GameConfig.strings`. With the player's locale set to `es` the HUD button reads "Clasificaciones" (not yet checked in Studio).
- `templates/new-game` is a copy of this folder.
