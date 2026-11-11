# Social kit: Friends, Mail

Co-play detection and cross-server, offline-safe messages with a mailbox. Code:
`packages/kits/social/<Module>/` (one folder per module: `module.luau`, `server/`, `client/`; Rojo `ReplicatedStorage.Modules.<Module>`, `ServerScriptService.Modules.<Module>`). Entries marked
**(contract)** are part of the cross-module surface listed in [kit-contract.md](../kit-contract.md).

```lua
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Friends = require(Modules:WaitForChild("Friends"):WaitForChild("module"))
local Mail = require(Modules:WaitForChild("Mail"):WaitForChild("module"))
```

## Friends

**Config (`config.Friends`):**

| Key | Default | Meaning |
|---|---|---|
| `friends.checkIntervalSec` | `30` | how often in-server friend detection re-runs |
| `friends.coPlayMultiplier` | none | income multiplier while at least one friend is in the server; needs Economy |

- **API:** `onCoPlay(fn(player, friends, kind)) -> Connection` (`kind` = `"invite"` when a friend
  referred the join, `"private"` in a private server, else `"server"`), `friendsInServer(player)`
  (the last detected list; doesn't yield), signal `CoPlay(player, friends, kind)`.
- Uses `Economy.addMultiplier/removeMultiplier` (optional Economy).
- **Save data:** none.

## Mail

Delivery is **at-least-once**: a handler can run again for the same message, so make grants
idempotent (key them on the message id). Messages reach offline players and other servers.

**Config (`config.Mail`, all optional reliability rails):**

| Key | Default | Meaning |
|---|---|---|
| `mail.maxAttempts` | `10` | handler errors before a message is dead-lettered (counted across sessions) |
| `mail.backoff` | `{ base = 30, factor = 2, max = 900 }` | wait before retry n: `min(max, base * factor^(n-1))` seconds |
| `mail.mailboxCap` | `500` | held messages per player |
| `mail.giftCap` | `100` | undelivered gifts (`returnKinds`) one recipient can have waiting; over it a gift goes straight back to the sender |
| `mail.returnAfterDays` | `14` | an uncollected gift goes back to the sender's mailbox after this many days |
| `mail.returnKinds` | `{ "core_gift" }` | kinds sent through `txApi.send` that are escrowed, capped and returned |

- **API:** `send(userId, kind, payload, key?) -> boolean` (yields; `kind` matches
  `^[%w_-]{1,32}$`, payload JSON-safe, depth <= 4, <= 1000 bytes; the same `key` twice runs
  handlers once), `onReceive(kind, fn(player, payload, info) -> boolean?)`, `pending(player) -> {
  MailboxEntry }`, `claim(player, id) -> (ok, reason?)`. A handler returning `false` holds the
  message in the player's mailbox (for example a full inventory); an error retries with backoff.
  Kinds starting with `core_` are reserved.
- **txApi (contract):** `send(tx, toUserId, kind, payload, key?) -> boolean`: the crash-safe outbox.
  The message is written in your transaction and leaves only after it is saved, so the cause (an
  item leaving) and the message can't be separated.
- **Extensions (contract):** `registerKind(kind, claimFn(tx, player, payload, info) -> boolean?)`:
  the module that owns a kind decides what claiming it does (Inventory owns `core_gift`). `false`
  holds it in the mailbox; an error retries and then dead-letters.
- **Client action:** `claimMail(id)`: wire = Mail's own `net.blink` event `ClaimMail`
  (`Data: Id`, RemoteScope `STUDWORK_MAIL`; the framework event `RequestMailClaim` before v1.3.1),
  limit 2/s burst 5 (the server part's `actions.claimMail.limit`). Friends has no client actions
  and no `net.blink`.
- **Replicated `extra`:** `mailbox` (contract): `{ { id, kind, payload, sentAt, heldAt } }`.
- **Widget and screen:** the mailbox badge and the `Mailbox` screen (theme guide).
- **Save data:** section `mail`: `{ mail = { seen, attempts, dead, box?, outbox? } }`, not
  replicated (the mailbox goes out as `extra.mailbox`).

**Client part (`Mail/client/`):** `StudWork.use(Mail).actions.claimMail(messageId)`;
`StudWork.use(Mail).onMailbox(fn(count)) -> Connection` (was `StudWork.Client.onMailbox`); the HUD
badge widget `"Social.mailbox"` (topCenter, order 3, while messages wait; tapping calls
`HudOptions.onMailbox` or opens the `"Mailbox"` screen), registered with `UI.registerWidget` at
start, so `client.hud.widgets["Social.mailbox"] = false` still removes it.

## Example: a gift kind your module owns

```lua
-- optional = { Mail }
function M.init(ctx)
	if ctx.isEnabled(Mail) then
		ctx.depsExt[Mail].registerKind("bottle", function(tx, player, payload, info)
			local mine = ctx.section(tx)
			if mine.received[info.id] then
				return true -- already granted by an earlier run of this message
			end
			mine.received[info.id] = true
			table.insert(mine.bottles, payload.text)
			return true
		end)
	end
end
```
