---
name: Feature request
about: A change to the framework, a kit, the UI kit or the tools
title: ""
labels: enhancement
---

**The problem**
What are you trying to do in your game, and what gets in the way?

**Proposal**
The API or behaviour you have in mind. Module API changes are additive only (new optional fields,
new functions; nothing renamed or removed).

**Override level**
Could this be done today with config, a replaced piece, or your own module
(docs/framework/override-levels.md)? Why isn't that enough?

**Rules check**
- [ ] Server-authoritative (clients only send requests that the server validates)
- [ ] Balance numbers in config
- [ ] Compliance rules for paid random items unaffected, or explained below
- [ ] Usable by a third-party module the same way (nothing is special)

**Alternatives considered**
