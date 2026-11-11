# StudWork framework docs

StudWork is the opinionated Roblox game framework in `packages/framework` plus five built-in kits
in `packages/kits`. Read [philosophy](../philosophy.md) first: defaults first, every default
overridable, nothing in core is special, guardrails you can't turn off.

| Page | What's in it |
|---|---|
| [Getting started](getting-started.md) | From `tools/new-game` to a game that boots, step by step |
| [Concepts](concepts.md) | Modules, refs, `ctx`, save sections, the game's own module, boot |
| [The five override levels](override-levels.md) | Defaults, config, replace a piece, switch a kit off, write a module; one example each |
| [Module API reference](module-reference.md) | `defineModule`, the server and client parts, every `ctx` field, transactions, purchases, replication, testing |
| [Generators](generators.md) | `tools/new-game --modules`, `tools/make-module`, `tools/make-migration`, `tools/make-screen`, the `templates/` folder |
| [Single-game projects](single-game-project.md) | `tools/new-project`: one repo per game, the root is the game, StudWork at `studwork/` (detection, commands, framework pin, bumping, publish, fresh clone) |
| [Adopting StudWork](adopting.md) | Moving an existing game to StudWork (design): `tools/adopt`, `ctx.data.importLegacy`, the purchase bridge, `studwork-legacy.json`, the cutover. Agents follow the [playbook](../agents/adopt-existing-game.md); [AGENTS.md](../../AGENTS.md) routes any coding agent |
| [Games repo](games-repo.md) | Using StudWork from a separate games repo (`roblox-core/` submodule): layout, wrappers, commands, bumping the framework, publish |
| [Publishing](publishing.md) | One-time Roblox setup (Group, test/live experiences, Open Cloud key), `tools/publish`, launch checklist |
| [Kit contract](kit-contract.md) | What each kit module offers other modules: api, txApi, purchase ops, extensions, signals, replicated keys |
| Kits: [Collection](kits/collection.md), [Economy](kits/economy.md), [Base](kits/base.md), [Social](kits/social.md), [Engagement](kits/engagement.md) | Config keys with defaults, API, extensions, signals, replicated state, save data |
| [Theme guide](theme.md) | The theme tree, presets, rarity look, HUD slots and widgets, screens |
| [Guardrails](guardrails.md) | What you can't turn off, why, and what can only be guided |
| [FAQ](faq.md) | Short answers to common questions |
| [Example module](../../examples/modules/session-leaderboard/README.md) | `SessionLeaderboard`, a third-party module built on the public API only |
| Example games | [`examples/sandbox`](../../examples/sandbox/README.md) (every kit; `foundation-only.project.json` = the framework alone) and [`examples/overrides/ov-a` … `ov-f`](../../examples/overrides/) (one per override case, each with an `Override.spec.luau`) |

The design behind the module API, with the reasoning for each rule, is
[module-api.md](module-api.md). The surface the kits offer each other is in
[kit-contract.md](kit-contract.md). These pages describe the code as it is; where the code and the
design differ, the reference pages follow the code and say so. All docs:
[docs/README.md](../README.md).
