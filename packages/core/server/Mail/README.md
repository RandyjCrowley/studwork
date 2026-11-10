# Core.Mail

Owner: agent C (core/v11-c-mail). Logic: `Delivery.luau` (pure, specced); wiring: `init.luau`.

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

Return `false` or error to fail; `nil`/`true` = success.

## API

- `Mail.send(userId, kind, payload, key?) -> boolean` — validates (kind `^[%w_-]{1,32}$`, payload
  JSON-safe table, depth <= 4, <= 1000 encoded bytes; `key` = `Validate.isId`, <= 64 chars) and
  queues `{ id = key or GUID, kind, payload, sentAt }` via `ProfileStore:MessageAsync`. Yields.
  Works for offline users and other servers. Same `key` twice to the same user -> handlers run
  once (dedupe by `PlayerData.mail.seen`, bounded to `Delivery.MAX_SEEN` = 500, oldest pruned, so
  a key is only remembered for the most recent 500 processed messages).
- `Mail.onReceive(kind, handler(player, payload, info))` — `info = { id, kind, sentAt, attempt }`.

## Delivery rules (Delivery.luau)

| case | result |
|---|---|
| id in `mail.seen` | duplicate: consumed, handlers not run |
| same id already in flight | consumed together with the first copy |
| no handler for kind | kept pending (no attempt counted); delivered when one registers |
| all handlers ok | one Data.update: `seen[id]=now`, clear `attempts[id]`, prune -> `processed()` |
| any handler failed | `attempts[id] += 1` (saved); retry after `2 * 2^(n-1)` s (cap 60) |
| `MAX_ATTEMPTS` (5) failures | `mail.dead` += `{id,kind,payload,attempts,error,at}` (max 25), `Analytics.custom(player,"MailDeadLetter",attempts)`, consumed |
| malformed | consumed, one warning per server |
| v1.0 message without id | id `legacy-<kind>-<sentAt>` |
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
