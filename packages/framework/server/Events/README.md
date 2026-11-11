# Core.Events

Public API (`Types.EventsAPI`): `schedule(id, schedule?, handler)`, `trigger(id, by?)`, `isActive(id)`, `onEnded(id, handler)`.

- `Schedule.luau` - pure UTC window math (`lastStart`, `nextStart`, `activeWindow`, `validate`); tests in `Schedule.spec.luau`.
- `init.luau` - 1 s timer loop; every `config.events[id]` with a schedule runs automatically (handler optional).

Windows depend only on `os.time()`, so all servers agree; a server booting mid-window starts the event with the
real `startedAt/endsAt`. Start: `EventStarted`, handler, `EventState.FireAll(id, endsAt)`, replicated
`activeEvents` (id -> endsAt), toast. End: `EventState.FireAll(id, 0)`, replicate, `EventEnded`, onEnded handlers.
`trigger` refuses unknown or already-active ids. `AdminTriggerEvent`: known id string, `ServerConfig.admins` (server-only, `Core.start(Config, ServerConfig)`; deprecated `GameConfig.admins` still honoured with a one-time warning; pure check in `Admins.luau`)
(everyone in Studio).

Console: `event` (list + next start), `event <id>` (trigger now).
