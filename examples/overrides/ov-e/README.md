# ov-e: override case (e)

Override example (v1.3.0 case (e), ported to the v1.3.1 layout in the v1.4.0 split): foundation only (`tools/new-game ov-e --modules ,`): the framework and the game's own module, nothing else.

`src/server/Override.spec.luau` boots this game's real project in the multi-server sim (`StudWork.test.sim`) and checks the case; `src/server/Boot.spec.luau` checks the module list. Generated with `tools/new-game ov-e --into examples/overrides`, then edited (edits are marked `override (e)`). See `docs/framework/override-levels.md`.

- Modules: foundation only
- Dev: `tools/dev ov-e` (rojo serve on port 34878)
- deploy.json ids are placeholders (0): an example, never published.
