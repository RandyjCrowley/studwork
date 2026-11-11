# StudWork docs

StudWork is an opinionated Roblox game framework: a module API (`packages/framework`), eleven
built-in kit modules in five kits (`packages/kits`), a UI kit (`packages/ui`), generators and
offline tests. Start with the philosophy, then follow the framework pages in order.

## Start here

1. [Philosophy](philosophy.md): defaults first, every default overridable, nothing in core is
   special, guardrails you can't turn off.
2. [Framework index](framework/README.md): the map of the framework docs.

## Framework, in reading order

| Page | What's in it |
|---|---|
| [Getting started](framework/getting-started.md) | From `tools/new-game` to a game that boots, then your first module |
| [Concepts](framework/concepts.md) | Modules, refs, `ctx`, save sections, the game's own module, boot |
| [The five override levels](framework/override-levels.md) | Defaults, config, replace a piece, switch a kit off, write a module |
| [Module API reference](framework/module-reference.md) | `defineModule`, server and client parts, every `ctx` field, transactions, purchases, testing |
| [Kit contract](framework/kit-contract.md) | What each kit module offers other modules |
| [Generators](framework/generators.md) | `tools/new-game`, `tools/make-module`, `tools/make-migration`, `tools/make-screen`, `templates/` |
| [Theme guide](framework/theme.md) | Theme tree, presets, rarity look, HUD slots and widgets, screens |
| [Guardrails](framework/guardrails.md) | What you can't turn off, why, and where enforcement stops |
| [Games repo](framework/games-repo.md) | Using StudWork as a submodule of your own games repo |
| [Publishing](framework/publishing.md) | Publishing a game from your games repo to Roblox: Open Cloud key, test and live experiences, launch checklist |
| [FAQ](framework/faq.md) | Short answers to common questions |
| [Module API design](framework/module-api.md) | The design behind the module API, with the reasoning for each rule |

## Kits

| Kit | Modules |
|---|---|
| [Collection](framework/kits/collection.md) | Items, Rarity, Inventory |
| [Economy](framework/kits/economy.md) | Economy, Upgrades, Rebirth, Offline |
| [Base](framework/kits/base.md) | Plot |
| [Social](framework/kits/social.md) | Friends, Mail |
| [Engagement](framework/kits/engagement.md) | Streak |

## Project

| Page | What's in it |
|---|---|
| [Manual QA](manual-qa.md) | The Studio checklist for what offline tests can't cover, and how to start the sandbox |
| [Decisions](decisions.md) | Design decisions and their reasons |
| [Known issues](known-issues.md) | Known limits and open issues |
| [Changelog](../CHANGELOG.md) | Release notes |
| [Contributing](../CONTRIBUTING.md) | How to set up, test and send changes |
| [Security](../SECURITY.md) | How to report a vulnerability |
