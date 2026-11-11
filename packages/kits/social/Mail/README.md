# Mail (social kit, v1.3.0 module)

Layout (v1.3.1, one folder per module, module-api.md §1): `module.luau` (definition), `server/` (server part; the code files named below live there), `client/` (client part). Rojo: `ReplicatedStorage.Modules.Mail` (module, client, shared), `ServerScriptService.Modules.Mail` (server).

Definition: `module.luau`. Logic: `Delivery.luau` (delivery + mailbox), `Outbox.luau`
(the crash-safe outbox), `Escrow.luau` + `Gifts.luau` (R1 gift cap and return to sender),
`MailValidate.luau` (all pure, specced; `GiftSoak.spec.luau` is the 2000+ gift soak); wiring:
`init.luau` (ctx only: `ctx.data` section `mail`, `ctx.data.messages` for the cross-server queue,
`ctx.replicate` extra `mailbox`). End-to-end gifting property test: `../../collection/Inventory/server/Gift.spec.luau`.

## Kit contract surfaces (docs/framework/kit-contract.md)

- `api`: `send`, `onReceive`, `pending`, `claim` (v1.2 names; `send`/`onReceive` refuse `core_` kinds).
- `txApi.send(tx, toUserId, kind, payload, key?) -> boolean`: the outbox write (v1.2 `sendInto`).
- `extensions.registerKind(kind, claimFn(tx, player, payload, info) -> boolean?)`: claimFn runs in a
  `ctx.tx` of the receiver; `false` holds (the tx is discarded), an error retries / dead-letters.
  `core_` kinds are allowed here.

## Gifts to players who never return (R1)

Kinds in `config.Mail.mail.returnKinds` (default `{ "core_gift" }`) sent through `txApi.send` are
**escrowed** when the framework offers `ctx.data.shared` (a shared, durable, atomic
`update(key, fn)` store, added to the framework in v1.3.0). One record per
recipient holds every escrowed gift until the recipient's server consumed it:

- **cap** (`giftCap`, default 100): checked atomically before the message is sent; over the cap the
  gift is refused and comes straight back to the sender (their mailbox, claimed at once, so the item
  is back in the inventory when there is room). A recipient known to be full refuses new gifts
  before the item even leaves (60 s cache). The cap keeps escrowed gifts far below ProfileStore's
  1000-message queue, so its drop-oldest rule never fires for them.
- **return** (`returnAfterDays`, default 14): the sender's server reclaims gifts nobody took
  (on load and every `sweepSeconds`, default 3600). Exactly one side wins each gift (pending ->
  claimed by the recipient, or pending -> returned to the sender); a copy that reaches the recipient
  after it was returned is dropped unopened.
- A gift the recipient took and **held** (inventory full) stays in their mailbox with no time limit.

Without `ctx.data.shared` Mail logs it once at boot and gifts work as in v1.2 (no cap, no return).

## HANDLERS MUST BE SAFE TO RUN TWICE

Delivery is **at-least-once**. A handler can run again for the same message when: another handler
for the same kind failed (all handlers re-run on retry), the server crashed/shut down after your
handler ran but before Mail recorded the id, or the player left mid-delivery. Make the grant
idempotent by keying it on `info.id`, inside one `Data.update` (never nest Data.update):

```lua
Core.Mail.onReceive("bottle", function(player, payload, info)
	return Core.Data.update(player, function(data)
		local got = data.game.bottlesReceived -- your game table: { [id]: true } (bound it yourself)
		if got[info.id] then
			return -- already granted: success, nothing to do
		end
		got[info.id] = true
		table.insert(data.game.bottles, payload)
	end)
end)
```

`nil`/`true` = delivered. `false` = "can't accept it now" (e.g. inventory full): the message is
**held in the player's mailbox** (see below), never counted as a failure. **Error** = failure:
retried with backoff, dead-lettered after `maxAttempts` errors.

## API

- `Mail.send(userId, kind, payload, key?) -> boolean` — validates (kind `^[%w_-]{1,32}$`, payload
  JSON-safe table, depth <= 4, <= 1000 encoded bytes; `key` = `Validate.isId`, <= 64 chars) and
  queues `{ id = key or GUID, kind, payload, sentAt }` via `ProfileStore:MessageAsync`. Yields.
  Works for offline users and other servers. Same `key` twice to the same user -> handlers run
  once (dedupe by `PlayerData.mail.seen`: every id younger than `SEEN_TTL` (60 days) up to
  `MAX_SEEN` = 2000, and always the newest `QUEUE_LIMIT` = 1000, ProfileStore's queue size; R7).
- `Mail.onReceive(kind, handler(player, payload, info))` — `info = { id, kind, sentAt, attempt }`.
- `Mail.pending(player) -> { MailboxEntry }` — the mailbox (copies), oldest `heldAt` first (tie: id).
  Replicated as `ReplicatedState.mailbox`; pushed after every hold, claim and on load.
- `Mail.claim(player, id) -> (ok, reason?)` — re-runs the kind's handlers for a held message
  (`info.attempt` = 1 + earlier claim errors). Reasons: `busy` (a claim for that id is running),
  `not_loaded`, `not_found`, `no_handler`, `still_held` (a handler returned false again), `error`
  (a handler threw: warned, stays in the box, attempts counted but a held message is **never**
  dead-lettered). Success = one update removes `box[id]` and writes `seen[id]`. Client:
  `StudWork.use(Mail).actions.claimMail(id)` -> the module's own Blink event `ClaimMail`
  (`Mail/net.blink`, RemoteScope `STUDWORK_MAIL`, `Data: Id` = `string(1..64)`; v1.3.1, was
  the framework's `RequestMailClaim`). Server action `claimMail`, limit 2/s burst 5; the handler
  re-validates the id (`MailValidate.key`) and toasts on `still_held` / `error`.
- ctx-only `Mail.sendInto(tx, toUserId, kind, payload, key) -> boolean` — the outbox (below).

## Reserved kinds

Kinds starting with `core_` belong to core (`core_gift`). The public facade (`Core.Mail.send` /
`Core.Mail.onReceive`, via the `Mail.facade` override) refuses them: `send` warns and returns
false, `onReceive` errors. Core services use `ctx.services.Mail` and may use them.

## Config (`GameConfig.mail`, all optional, reliability rails)

| key | default | meaning |
|---|---|---|
| `maxAttempts` | 10 | handler ERRORS before dead-lettering (counted across sessions) |
| `backoff = { base, factor, max }` | `{ 30, 2, 900 }` | wait before retry n: `min(max, base * factor^(n-1))` s |
| `mailboxCap` | 500 | held messages per player; beyond it a message stays queued in ProfileStore, whose queue keeps at most 1000 messages and drops the oldest (review R1) |

## Mailbox (N1)

A handler returning `false` holds the message: ONE update writes
`mail.box[id] = { id, kind, payload, sentAt, heldAt }` and clears `attempts[id]`, then
`processed()` (core owns the message now). The player gets a toast "Mailbox: N item(s) waiting".
When the box already holds `mailboxCap` entries nothing is written and `processed()` is NOT
called: ProfileStore keeps it and offers it again next session (one warning per server).
An id in `box` is a duplicate for `deliver` (like `seen`).

Console (live servers too, R6; admins = `ServerConfig.Mail.admins`, plus the server console and
Studio): `mail dead <userId>` (held mail, dead letters, unsent outbox), `mail redeliver <userId> <id>`
(moves a dead letter back into the mailbox and delivers it), `mail claim <userId> <id>`.
Dead letters kept per player: `MAX_DEAD` = 100 (was 25).

## Outbox (`sendInto`, used by `Inventory.sendGift`)

`sendInto` validates like `send` (+ a required key) and writes
`tx.data.mail.outbox[key] = { toUserId, kind, payload, key, at }` in the caller's transaction, so
the cause (the item leaving) and the message are one atomic write. After commit (`tx.after`)
`Outbox.flush(sender)`:
1. `Data.saveAsync(sender)` first, if an entry was written this session and isn't known saved: the
   message must not leave before its cause is durable (else a crash restores the item AND
   delivers it).
2. `MessageAsync` with `id = key` for each entry, oldest first; on success the entry is removed
   in a `Data.update`.
3. Any failure: retry with the config backoff while the sender is online. On the sender's next
   load (`Data.onLoaded`) leftovers are flushed (no extra save: they came from the store).

A crash after the send but before the removal is saved re-sends with the **same key**; the
receiver's `seen`/`box` turns it into a duplicate.

## At-least-once notes

- Dedupe memory: `seen` keeps the newest 1000 ids (the most ProfileStore can re-deliver) and every
  id younger than 60 days, up to 2000 (R7). Handlers must still be idempotent on their own
  (`core_gift` is: a uid already in the inventory is a success).
- R3: when the sender leaves, outbox entries already saved are sent once more (best effort; a
  later resend is a duplicate). Entries not yet saved wait for the sender's next session; a
  cross-server sweeper would need a shared queue the framework doesn't offer (see the report).
- A message held while the box is full is offered again next session, not this one.

## Delivery rules (Delivery.luau)

| case | result |
|---|---|
| id in `mail.seen` | duplicate: consumed, handlers not run |
| same id already in flight | consumed together with the first copy |
| no handler for kind | kept pending (no attempt counted); delivered when one registers |
| all handlers ok | one Data.update: `seen[id]=now`, clear `attempts[id]`, prune -> `processed()` |
| id in `mail.box` | duplicate: consumed, handlers not run |
| a handler returned `false` | held in the mailbox (above), consumed; no attempt counted |
| a handler threw | `attempts[id] += 1` (saved); retry after the config backoff |
| `maxAttempts` (10) errors | `mail.dead` += `{id,kind,payload,attempts,error,at}` (max 100), `Analytics.custom(player,"MailDeadLetter",attempts)`, consumed |
| malformed | consumed, one warning per server |
| v1.0 message without id | id `legacy-<kind>-<sentAt>-<fnv1a(payload)>` |
| player left / server shutting down | stop; never `processed()` -> re-delivered next session, attempts keep counting |

## ProfileStore 1.0.3 behaviour (read from deps/.../ProfileStore.luau)

- The MessageHandler callback is started with `task.spawn` (both for queued messages in
  `Profile:MessageHandler` and for new ones found on save), so it **may yield**; `processed` can
  be called any time later.
- `processed()` only sets `locked_global_updates[index] = true` in memory; the message is removed
  from the stored queue on the profile's **next save** (auto-save or `Profile:Save()`).
- A message whose callback never calls `processed()` stays in `profile.global_updates`. Within the
  same session it is **not** handed out again (ProfileStore remembers it as received) — hence
  Mail's own in-session retry loop. On the next session load it is delivered again.
- If the session ends before the save that drops it, it is re-delivered next session; Mail's
  `seen` (saved in the same profile) turns that into a duplicate, if the success write made it
  into the final save.
- Queue cap: 1000 messages per profile (`MAX_MESSAGE_QUEUE`); `MessageAsync` fails beyond that.
- Delivery timing: queued messages arrive right after load; new ones on the owner's next save
  (other servers are pinged over MessagingService; in this server Mail nudges a save).
