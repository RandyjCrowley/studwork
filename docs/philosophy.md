# StudWork philosophy

**StudWork** is an **opinionated Roblox game framework**. (In construction, studwork is the timber framework inside a wall; studs are Roblox's unit of measure.) It makes good decisions for you, so a new game is
playable within minutes. Every one of those decisions can be overridden, so the framework never
becomes something you have to work around.

Design decisions and their reasons are recorded in [decisions.md](decisions.md); the framework
docs start at [framework/README.md](framework/README.md).

---

## 1. Opinionated defaults

A game that sets only its name and items gets all of the following:

| Area | Default opinion | Why |
|---|---|---|
| Rarity | 7 tiers: Common, Uncommon, Rare, Epic, Legendary, Mythic, Secret, each with its own colour, glow and sound | Players already recognise this ladder |
| Look | The `framework-default` theme: deep navy panels, warm orange accent, teal secondary, gold currency, warm sun with cool shadows | Reads well on phones, looks good both light and dark |
| Type | Fredoka One for display text and numbers, Builder Sans for body text | Built into Roblox, friendly, legible at small sizes |
| Layout | 12px corners, 12px padding, 2px outlines, 44px minimum touch target | Mobile first. Most players are on phones |
| Feel | A number pops, a rarity flash, rising coin ticks, a stinger per rarity, camera shake on big rewards | Feedback is what makes simple loops feel good |
| HUD | Currency, earnings per second, a next-goal arrow, a mailbox badge | The collect-and-earn loop, visible at a glance |
| Economy | Items earn per tick (1 s by default), multipliers stack by multiplying | Progress you can see every second |
| Luck | Weighted rolls, a guaranteed tier after a run of bad rolls, mutations, all odds disclosed | Fair, exciting and compliant |
| Rebirth | Reset for a permanent multiplier. Robux-bought items are kept and items bought with Coins are wiped | Long-term goal without punishing paying players or allowing exploits |
| Return | Daily streaks (UTC days by default) with a grace window, capped offline earnings | Return days are what Roblox ranks |
| Social | Co-play detection: friends in the server, invite joins, private servers | Co-play is a ranking signal |

## 2. Five levels of override

Each level is a supported path, documented with an example. Go only as deep as you need.

| Level | You do | Example |
|---|---|---|
| **1. Use the defaults** | Nothing | listing the Collection and Economy modules in `modules` gives a working game |
| **2. Change config** | Set values in your game's Config | `Economy = { income = { tickSeconds = 5, ... } }`, `Streak = { streak = { utcOffsetHours = -5, graceHours = 36 } }` |
| **3. Replace a piece** | Supply your own preset, theme, screen or widget | A 4-tier "Bronze/Silver/Gold/Diamond" rarity preset, your own theme, your own HUD |
| **4. Switch a kit off** | Leave it out of `modules` | No Economy kit: items become cards, cosmetics or quest items with no income |
| **5. Write your own module** | `tools/make-module`, using the public module API | A leaderboard, a quest system, a pet-follow system |

## 3. Nothing in core is special

The built-in kits (Collection, Economy, Base, Social, Engagement) are built **only** on the public
module API, the same one available to a third-party module.

- If a built-in kit can do something, your module can too.
- Built-in kits get no private hooks or back doors. A lint rule enforces this.
- If a kit needs something the API doesn't offer, **the API gets extended for everyone**.

## 4. Guardrails you can't turn off by accident

Some opinions protect players, your revenue and your standing with Roblox, so they are not overridable.

| Guardrail | What it guarantees |
|---|---|
| **The server is authoritative** | Clients only send requests. Every request is validated and rate-limited before it reaches a module |
| **Purchases are safe to retry** | A Robux purchase is granted exactly once: the grant and the receipt record commit together, and `PurchaseGranted` is returned only after the save |
| **Paid-random compliance** | Any random outcome bought with Robux, or with a currency bought with Robux, has its full odds disclosed and is policy-checked per player. Luck that wasn't disclosed is refused. This is enforced by the framework, so third-party modules get it too |
| **Saves can't be overwritten** | A save that fails to load or migrate never gets defaults written over it. The player gets a friendly kick and their data is kept |
| **Modules stay in their own data** | A module can read and write only its own save section. Everything else goes through other modules' public APIs |

## 5. Fixed technology choices

These are part of what the framework *is*. They're documented, not configurable.

| Choice | Role |
|---|---|
| Luau (strict) | Language |
| Rojo + Wally + Rokit | Project sync, packages, toolchain |
| ProfileStore | Player data, with session locking |
| Blink | Typed networking (framework internals and module messages) |
| Charm + charm-sync | State and its replication |
| React-lua | UI |
| Lune | Tests and tooling scripts |

## 6. Principles for contributors

1. **Defaults first.** A new feature has to work with zero config.
2. **Every default is overridable** at the lowest level that makes sense: config before replacement, replacement before writing code.
3. **Add, don't break.** After v1.3.0 the public API follows semantic versioning, and changes are additive within a major version.
4. **Balance numbers live in Config,** never in code.
5. **Test it.** Every module ships tests that run in Lune without Studio.
6. **Document the default.** Every config key lists its default value and the reason behind it.
