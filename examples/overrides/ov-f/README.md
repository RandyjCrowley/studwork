# ov-f: override case (f)

Override example (core-v1.3.0 P2-C case (f), ported to the v1.3.1 layout in the v1.4.0 split): a third-party module next to the built-in kits: `examples/modules/session-leaderboard` mapped in `default.project.json` (README wiring; tools/sync-projects keeps the entries canonical once mapped), listed in `GameConfig.modules`, configured in `Balance.luau`; with Items, Rarity, Inventory, Economy.

`src/server/Override.spec.luau` boots this game's real project in the multi-server sim (`StudWork.test.sim`) and checks the case; `src/server/Boot.spec.luau` checks the module list. Generated with `tools/new-game ov-f --into examples/overrides`, then edited (edits are marked `override (f)`). See `docs/framework/override-levels.md`.

- Modules: Items, Rarity, Inventory, Economy
- Dev: `tools/dev ov-f` (rojo serve on port 34879)
- deploy.json ids are placeholders (0): an example, never published.
