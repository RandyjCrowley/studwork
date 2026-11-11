# ov-b: override case (b)

Override example (v1.3.0 case (b), ported to the v1.3.1 layout in the v1.4.0 split): config + theme only: a custom 4-tier rarity preset in `config.Rarity.tiers` (Bronze, Silver, Gold, Diamond; items, luckMinTier and pity remapped) and a custom `theme` (accent, display font, corner radius, per-tier sounds).

`src/server/Override.spec.luau` boots this game's real project in the multi-server sim (`StudWork.test.sim`) and checks the case; `src/server/Boot.spec.luau` checks the module list. Generated with `tools/new-game ov-b --into examples/overrides`, then edited (edits are marked `override (b)`). See `docs/framework/override-levels.md`.

- Modules: template default (all)
- Dev: `tools/dev ov-b` (rojo serve on port 34875)
- deploy.json ids are placeholders (0): an example, never published.
