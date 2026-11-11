# ov-d: override case (d)

Override example (v1.3.0 case (d), ported to the v1.3.1 layout in the v1.4.0 split): switch kits off: Collection without Economy (`tools/new-game ov-d --modules Items,Rarity,Inventory`); items have no `economy` field.

`src/server/Override.spec.luau` boots this game's real project in the multi-server sim (`StudWork.test.sim`) and checks the case; `src/server/Boot.spec.luau` checks the module list. Generated with `tools/new-game ov-d --into examples/overrides`, then edited (edits are marked `override (d)`). See `docs/framework/override-levels.md`.

- Modules: Items, Rarity, Inventory
- Dev: `tools/dev ov-d` (rojo serve on port 34877)
- deploy.json ids are placeholders (0): an example, never published.
