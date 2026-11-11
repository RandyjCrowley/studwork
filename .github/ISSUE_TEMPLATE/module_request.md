---
name: Module request
about: Propose a new kit module (or a change to a kit's public API)
title: "Module: "
labels: module
---

**Game need**
What kind of game needs this, and what does the player experience?

**Module**
- Name and kit (collection, economy, base, social, engagement, or a new one):
- Dependencies (`dependsOn` / `optional`):
- Save section (key, what it stores, migrations):
- Config keys and their opinionated defaults:

**Public API**
Functions on `StudWork.use(<Module>)`, `depsTx` functions, actions (with argument validation and
rate limits), replicated state, HUD widgets / screens.

**Purchases and randomness**
Does it sell anything or roll anything? How does it use `ctx.shop` / `ctx.compliance`?

**Could it live in a games repo instead?**
Kits get nothing a third-party module doesn't, so a module in your own games repo may be enough.
Why should it ship with StudWork?
