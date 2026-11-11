# Single-game project skeleton (StudWork v1.5.0)

`tools/new-project <path>` (run from a StudWork checkout) creates a complete single-game project
from this folder plus `templates/new-game` (`docs/framework/single-game-project.md` has the details):

```sh
studwork/tools/new-project ../my-game --modules Items,Rarity,Inventory,Economy
```

| File | What |
|---|---|
| `studwork.json` | the layout marker (`{"layout": "single-game"}`): the tools treat the root as the game |
| `tools/_studwork` | runs `studwork/tools/<tool>` with `STUDWORK_PROJECT_ROOT` = the project |
| `tools/*` | one-line wrappers: dev, lint, typecheck, test, build, publish, install, doctor, framework-status, net, sync-projects, make-module, make-screen, make-migration (and new-game, which refuses) |
| `.githooks/pre-commit` | `tools/lint` + `tools/test` (enabled by `tools/install`) |
| `gitignore` -> `.gitignore` | build output, caches, `.env` |
| `env.example` -> `.env.example` | the Open Cloud key name for `tools/publish` |
| `FRAMEWORK_REQUESTS.md` | what the game needs from StudWork |
| `README.md.tmpl` -> `README.md` | the project's README (`{{name}}`, `{{tag}}`, `{{port}}`, `{{modules}}`) |
| `CLAUDE.md.tmpl` -> `CLAUDE.md` | rules for game agents working in the project |

This README is not copied. The game itself (`default.project.json`, `deploy.json`, `src/`,
`modules/<name>/`, `docs/design.md`) comes from `templates/new-game`, scaffolded at the root with
`$path`s into `studwork/`.
