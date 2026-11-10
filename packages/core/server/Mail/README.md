# Core.Mail

Logic: `Delivery.luau` (delivery + mailbox), `Outbox.luau` (sendInto flush), `MailValidate.luau`
(all pure, specced); wiring: `init.luau`. End-to-end gifting property test:
`../Inventory/Gift.spec.luau`.

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
  once (dedupe by `PlayerData.mail.seen`, bounded to `Delivery.MAX_SEEN` = 500, oldest pruned, so
  a key is only remembered for the most recent 500 processed messages).
- `Mail.onReceive(kind, handler(player, payload, info))` — `info = { id, kind, sentAt, attempt }`.
- `Mail.pending(player) -> { MailboxEntry }` — the mailbox (copies), oldest `heldAt` first (tie: id).
  Replicated as `ReplicatedState.mailbox`; pushed after every hold, claim and on load.
- `Mail.claim(player, id) -> (ok, reason?)` — re-runs the kind's handlers for a held message
  (`info.attempt` = 1 + earlier claim errors). Reasons: `busy` (a claim for that id is running),
  `not_loaded`, `not_found`, `no_handler`, `still_held` (a handler returned false again), `error`
  (a handler threw: warned, stays in the box, attempts counted but a held message is **never**
  dead-lettered). Success = one update removes `box[id]` and writes `seen[id]`. Client:
  `Actions.claimMail(id)` -> Blink `RequestMailClaim` (validated id; rate-limited by Net).
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

Console (Studio): `mailbox [userId]` (box + dead letters), `mailclaim <userId> <id>`,
`mailreplay <userId> <id>` (moves a dead letter back into the mailbox so it can be claimed).

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

- Dedupe memory is bounded: `seen` keeps the last `MAX_SEEN` (500) ids. A re-send of a message
  older than that would run again, which is why handlers must be idempotent on their own too
  (`core_gift` is: a uid already in the inventory is a success).
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
| `maxAttempts` (10) errors | `mail.dead` += `{id,kind,payload,attempts,error,at}` (max 25), `Analytics.custom(player,"MailDeadLetter",attempts)`, consumed |
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
