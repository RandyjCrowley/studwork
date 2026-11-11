# ov-a: override case (a)

Override example (v1.3.0 case (a), ported to the v1.3.1 layout in the v1.4.0 split): defaults only: the full template, every kit module, the default look (EggRoll product id set to 9001 so the sim can deliver a receipt).

`src/server/Override.spec.luau` boots this game's real project in the multi-server sim (`StudWork.test.sim`) and checks the case; `src/server/Boot.spec.luau` checks the module list. Generated with `tools/new-game ov-a --into examples/overrides`, then edited (edits are marked `override (a)`). See `docs/framework/override-levels.md`.

- Modules: template default (all)
- Dev: `tools/dev ov-a` (rojo serve on port 34874)
- deploy.json ids are placeholders (0): an example, never published.
