# ov-c: override case (c)

Override example (v1.3.0 case (c), ported to the v1.3.1 layout in the v1.4.0 split): replace a piece: the whole HUD replaced (`client.hud = { layout = Game.MyHud, widgets = { ["Social.mailbox"] = false } }`, `src/shared/MyHud.luau`) and a custom screen (`src/client/QuestsScreen.luau`, `UI.registerScreen("Quests", ...)`, opened from a "Quests" action-bar button).

`src/server/Override.spec.luau` boots this game's real project in the multi-server sim (`StudWork.test.sim`) and checks the case; `src/server/Boot.spec.luau` checks the module list. Generated with `tools/new-game ov-c --into examples/overrides`, then edited (edits are marked `override (c)`). See `docs/framework/override-levels.md`.

- Modules: template default (all)
- Dev: `tools/dev ov-c` (rojo serve on port 34876)
- deploy.json ids are placeholders (0): an example, never published.
