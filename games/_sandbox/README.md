# _sandbox

Minimal playable reference game that exercises every kit module: touch the glowing block -> get an item -> it goes on your plot -> it earns per second -> upgrade -> rebirth -> leave and come back to an offline payout.

- Rojo: `rojo serve games/_sandbox/default.project.json` (port 34872)
- Config: `src/shared/Config` (shared, replicated). Server-only settings (admins) live in
  `src/server/ServerConfig.luau`, passed as `StudWork.start(Config, ServerConfig)`. Game code: `modules/sandbox`
  (the game's own module). Boot test: `src/server/Boot.spec.luau`.
- Foundation-only check: `rojo serve games/_sandbox/foundation-only.project.json` (port 34873)
  boots StudWork with `modules = {}` (src in `foundation-only/`) and prints `[foundation-only] boot ok`
  plus the "Rebirth is not enabled in GameConfig.modules" error. Offline smoke test:
  `foundation-only/shared/Config.spec.luau`. `tools/typecheck` covers `src/`, `modules/` and `foundation-only/`.
- `templates/new-game` is a copy of this folder.
