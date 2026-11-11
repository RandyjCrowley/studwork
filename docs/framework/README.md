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
| [Generators](generators.md) | `tools/new-game --modules`, `tools/make-module`, `tools/make-migration`, `tools/make-screen` |
| Kits: [Collection](kits/collection.md), [Economy](kits/economy.md), [Base](kits/base.md), [Social](kits/social.md), [Engagement](kits/engagement.md) | Config keys with defaults, API, extensions, signals, replicated state, save data |
| [Theme guide](theme.md) | The theme tree, presets, rarity look, HUD slots and widgets, screens |
| [Guardrails](guardrails.md) | What you can't turn off, why, and what can only be guided |
| [FAQ](faq.md) | Short answers to common questions |
| [Example module](../../examples/modules/session-leaderboard/README.md) | `SessionLeaderboard`, a third-party module built on the public API only |

The frozen design is [module-api.md](module-api.md) (tag `core-contract-v1.3`). The cross-kit
contract for core v1.3.0 is pinned in
[PHASE1-CONTRACT.md]((internal build report, not public)). These pages describe the code
as it is; where they describe something still being built in core v1.3.0 Phase 1, they say so and
point at the contract.
