--!strict
--[[
	Leaderboards: the server part (docs/framework/kits/leaderboards.md).

	Values come only from the server: a built-in source (Economy balance, Rebirth count, Streak
	day), a registered source function, or server code calling `submit`. Nothing here is reachable
	from a client (no action, no net.blink). The player's save (section "leaderboards") holds the
	authoritative value; every store write sends that value and is idempotent (`update` with the
	better of old and new, or `set`), never `increment`.

	  all-time boards   ctx.data.ordered(boardId), key = user id
	  daily / weekly    ctx.data.sortedMap(boardId/periodId/shard), key = user id, sort key = value,
	                    item { v, n }; a new period is a new map (the clock moving, no reset job)
	  shared top N      ctx.data.sortedMap("top/" .. boardId), one item per period (key periodId, or
	                    "all"): { rows = { { u, n, v } }, at, cut?, lease = { by, untilAt }? }

	One elected reader per board: a server that finds the item older than refreshSeconds with no live
	lease takes the lease (30 s) with an atomic update, reads the source and writes the item back;
	every other server just reads the item. A server's interval is
	max(refreshSeconds, 60 x servers / topReadsPerMinute), `servers` from ctx.data.census().

	Replicated: extra.boards (setAll) and extra.mine (per player). The `title` in a board entry is a
	string key; the client resolves it in the player's language.

	api: submit, top, rank, refresh, signals.BoardRefreshed. txApi: submit. extensions:
	registerSource. Console: `leaderboards refresh <boardId>`,
	`leaderboards submit <boardId> <value> [userId]`.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Merge = require(script.Merge)
local Period = require(script.Period)
local Economy =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Economy"):WaitForChild("module"))
local Rebirth =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Rebirth"):WaitForChild("module"))
local Streak =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Streak"):WaitForChild("module"))

local LEASE_SECONDS = 30 -- the reader lease (the page's number; not a game balance value)
local TICK_SECONDS = 1 -- the shared ticker's step; every cadence below is config
local START_JITTER = 0.1 -- each board's first read is staggered by up to this share of refreshSeconds
-- submitted values wait in memory at most this long before they join the save (staggered per
-- player; also before each store write, on leave and on shutdown). Durability, not balance: the
-- framework's autosave decides when the save itself is written.
local FOLD_SECONDS = 30
local MAX_CATCH_UP_SECONDS = 600 -- a longer clock jump visits every player once instead
local MAX_ID_LENGTH = 24

local idCounter = 0 -- distinguishes servers (parts) created in one process

local LeaderboardsModule = {}

-- One part per server (module state lives inside, so two servers in one process stay apart).
function LeaderboardsModule.new(): any
	local Leaderboards: any = {}

	local ctx: any = nil
	local cfg: any = nil
	local boards: { [string]: any } = {}
	local boardIds: { string } = {}
	local sources: { [string]: (any) -> number? } = {}
	local signals: any = {}
	local cache: { [string]: any } = {}
	local players: { [any]: any } = {}
	local nameCache: { [number]: { name: string, at: number } } = {}
	local rebirths: { [any]: number } = {}
	local maps: { [string]: any } = {}
	local stores: { [string]: any } = {}
	local warned: { [string]: boolean } = {}
	local flagOffPublished = false
	local myId = ""

	--------------------------------------------------------------------------------
	-- Helpers
	--------------------------------------------------------------------------------

	local function warnOnce(key: string, message: string)
		if not warned[key] then
			warned[key] = true
			ctx.log.warn(message)
		end
	end

	local function isOn(): boolean
		if cfg.flag == nil then
			return true
		end
		local ok, on = pcall(ctx.flags.isOn, cfg.flag)
		return ok and on == true
	end

	local function mapFor(name: string): any
		local map = maps[name]
		if map == nil then
			map = ctx.data.sortedMap(name)
			maps[name] = map
		end
		return map
	end

	local function storeFor(boardId: string): any
		local store = stores[boardId]
		if store == nil then
			store = ctx.data.ordered(boardId)
			stores[boardId] = store
		end
		return store
	end

	local function periodNow(b: any): Period.Info?
		return Period.of(b.period, ctx.now(), cfg.utcOffsetHours, cfg.weekStartsOn)
	end

	local function playerName(player: any): string
		local name = player.DisplayName
		if type(name) ~= "string" or name == "" then
			name = player.Name
		end
		return if type(name) == "string" and name ~= "" then name else tostring(player.UserId)
	end

	local function copyRows(rows: any): { Merge.Row }
		local out: { Merge.Row } = {}
		if type(rows) ~= "table" then
			return out
		end
		for _, row in rows do
			if type(row) == "table" and type(row.u) == "number" and type(row.v) == "number" then
				local name = if type(row.n) == "string" then row.n else tostring(row.u)
				table.insert(out, { u = row.u, n = name, v = row.v })
			end
		end
		return out
	end

	local function publicRows(rows: { Merge.Row }): any
		local out = {}
		for i, row in rows do
			out[i] = table.freeze({ rank = i, userId = row.u, name = row.n, value = row.v })
		end
		return table.freeze(out)
	end

	--------------------------------------------------------------------------------
	-- Config resolution (a bad board is a boot error naming the board)
	--------------------------------------------------------------------------------

	local SOURCE_KINDS = { submit = true, registered = true, currency = true, rebirths = true, streak = true }

	local function resolveBoard(boardId: any, raw: any): any
		if
			type(boardId) ~= "string"
			or #boardId > MAX_ID_LENGTH
			or string.match(boardId, "^[%w_]+$") == nil
		then
			error(
				`[Leaderboards] board id '{tostring(boardId)}' must be 1..{MAX_ID_LENGTH} letters, digits or _`,
				0
			)
		end
		if type(raw) ~= "table" then
			error(`[Leaderboards] board '{boardId}' must be a table`, 0)
		end
		local b: any = {
			id = boardId,
			period = raw.period or "allTime",
			mode = raw.mode or "max",
			order = raw.order or "desc",
			topN = if raw.topN == nil then 50 else raw.topN,
			minValue = if raw.minValue == nil then 1 else raw.minValue,
			shards = if raw.shards == nil then 1 else raw.shards,
			title = if raw.title == nil then `Leaderboards.board.{boardId}` else raw.title,
		}
		local source = raw.source or { kind = "submit" }
		if type(source) ~= "table" or SOURCE_KINDS[source.kind] ~= true then
			error(
				`[Leaderboards] board '{boardId}': source.kind must be submit, registered, currency, rebirths or streak`,
				0
			)
		end
		b.source = source
		if b.period ~= "allTime" and b.period ~= "daily" and b.period ~= "weekly" then
			error(`[Leaderboards] board '{boardId}': period must be allTime, daily or weekly`, 0)
		end
		if b.mode ~= "max" and b.mode ~= "set" and b.mode ~= "sum" then
			error(`[Leaderboards] board '{boardId}': mode must be max, set or sum`, 0)
		end
		if b.mode == "sum" and source.kind ~= "submit" then
			error(
				`[Leaderboards] board '{boardId}': mode sum needs a submit source (a source reports a total)`,
				0
			)
		end
		if b.order ~= "desc" and b.order ~= "asc" then
			error(`[Leaderboards] board '{boardId}': order must be desc or asc`, 0)
		end
		if type(b.topN) ~= "number" or b.topN % 1 ~= 0 or b.topN < 1 or b.topN > 100 then
			error(`[Leaderboards] board '{boardId}': topN must be a whole number in 1..100`, 0)
		end
		if type(b.minValue) ~= "number" or b.minValue ~= b.minValue then
			error(`[Leaderboards] board '{boardId}': minValue must be a number`, 0)
		end
		if type(b.shards) ~= "number" or b.shards % 1 ~= 0 or b.shards < 1 or b.shards > 16 then
			error(`[Leaderboards] board '{boardId}': shards must be a whole number in 1..16`, 0)
		end
		if b.period == "allTime" and b.shards ~= 1 then
			error(`[Leaderboards] board '{boardId}': shards apply to daily and weekly boards only`, 0)
		end
		if type(b.title) ~= "string" or b.title == "" then
			error(`[Leaderboards] board '{boardId}': title must be a string key`, 0)
		end
		local needs = { currency = Economy, rebirths = Rebirth, streak = Streak }
		local module = needs[source.kind]
		if module ~= nil and not ctx.isEnabled(module) then
			error(
				`[Leaderboards] board '{boardId}' uses a {source.kind} source: add the {module.name} module to GameConfig.modules`,
				0
			)
		end
		return b
	end

	--------------------------------------------------------------------------------
	-- The player's section: values, periods, dirty
	--------------------------------------------------------------------------------

	local function sectionTable(section: any, key: string): any
		if type(section[key]) ~= "table" then
			section[key] = {}
		end
		return section[key]
	end

	-- Combines `value` into the player's saved value for board `b` at time `now`. Returns
	-- (changed, rolled): `rolled` is a dirty entry of an earlier period that this call replaced.
	local function applyValue(section: any, b: any, value: number, now: number): (boolean, any?)
		local dirty = sectionTable(section, "dirty")
		if b.period == "allTime" then
			local values = sectionTable(section, "values")
			local old = values[b.id]
			local nextValue = Merge.combine(b.mode, b.order, old, value)
			if nextValue == old then
				return false, nil
			end
			values[b.id] = nextValue
			if nextValue >= b.minValue then
				dirty[b.id] = true
			end
			return true, nil
		end
		local info = Period.of(b.period, now, cfg.utcOffsetHours, cfg.weekStartsOn) :: Period.Info
		local periods = sectionTable(section, "periods")
		local entry = periods[b.id]
		local rolled: any = nil
		if type(entry) ~= "table" or entry.id ~= info.id then
			if type(entry) == "table" and dirty[b.id] == true and type(entry.value) == "number" then
				rolled = { id = entry.id, value = entry.value }
			end
			entry = { id = info.id }
			periods[b.id] = entry
			dirty[b.id] = nil
		end
		local old = entry.value
		local nextValue = Merge.combine(b.mode, b.order, old, value)
		if nextValue == old then
			return false, rolled
		end
		entry.value = nextValue
		if nextValue >= b.minValue then
			dirty[b.id] = true
		end
		return true, rolled
	end

	-- The player's current value on a board from a (read-only) section view.
	local function savedValue(section: any, b: any, now: number): number?
		if type(section) ~= "table" then
			return nil
		end
		if b.period == "allTime" then
			local values = section.values
			return if type(values) == "table" then values[b.id] else nil
		end
		local periods = section.periods
		local entry = if type(periods) == "table" then periods[b.id] else nil
		if type(entry) ~= "table" then
			return nil
		end
		local info = Period.of(b.period, now, cfg.utcOffsetHours, cfg.weekStartsOn) :: Period.Info
		if entry.id ~= info.id then
			return nil
		end
		return entry.value
	end

	--------------------------------------------------------------------------------
	-- Pending submits: `submit` on a `max` or `sum` board combines the value into
	-- players[player].pending[boardId] = { value, at, id?, startsAt?, endsAt? } (no transaction);
	-- foldPending applies it to the save in one ctx.data.update. Both modes commute, so a txApi
	-- submit in between needs no ordering; `set` boards are written straight into the save.
	--------------------------------------------------------------------------------

	local function inPeriod(entry: any, now: number): boolean
		return entry.startsAt == nil or (now >= entry.startsAt and now < entry.endsAt)
	end

	-- The player's value including what is still pending.
	local function currentValue(player: any, b: any, section: any, now: number): number?
		local value = savedValue(section, b, now)
		local ps = players[player]
		local entry = if ps ~= nil then ps.pending[b.id] else nil
		if entry ~= nil and inPeriod(entry, now) then
			value = Merge.combine(b.mode, b.order, value, entry.value)
		end
		return value
	end

	local spawnRolled: (player: any, b: any, rolled: any) -> ()

	-- True when the save already holds a later period than a pending entry's: a txApi submit
	-- rolled it past, taking that entry's value with it (see txApi.submit).
	local function savedPast(section: any, boardId: string, entry: any): boolean
		local periods = if type(section) == "table" then section.periods else nil
		local saved = if type(periods) == "table" then periods[boardId] else nil
		local savedId = if type(saved) == "table" then tonumber(saved.id) else nil
		return savedId ~= nil and savedId > (tonumber(entry.id) :: number)
	end

	-- Applies every pending value to the save. Returns false when the save could not be updated
	-- (the values stay pending).
	local function foldPending(player: any, ps: any): boolean
		local taken = ps.pending
		if next(taken) == nil then
			return true
		end
		if not ctx.data.isLoaded(player) then
			return false
		end
		local rolledList: { [string]: any }? = nil
		local ran = ctx.data.update(player, function(section: any)
			for id, entry in taken do
				local b = boards[id]
				if entry.id ~= nil and savedPast(section, id, entry) then
					continue
				end
				local _, r = applyValue(section, b, entry.value, entry.at)
				if r ~= nil then
					local list = rolledList or {}
					list[id] = r
					rolledList = list
				end
			end
		end)
		if not ran then
			return false
		end
		if ps.pending == taken then
			ps.pending = {}
		end
		if rolledList ~= nil then
			for id, r in rolledList do
				spawnRolled(player, boards[id], r)
			end
		end
		return true
	end

	--------------------------------------------------------------------------------
	-- Replication
	--------------------------------------------------------------------------------

	local function publishBoards()
		local out: { [string]: any } = {}
		if isOn() then
			flagOffPublished = false
			for _, id in boardIds do
				local b, c = boards[id], cache[id]
				local entry: any = {
					period = b.period,
					periodId = c.periodId,
					endsAt = c.endsAt,
					title = b.title,
					rows = publicRows(c.rows),
					updatedAt = c.updatedAt,
				}
				if b.period ~= "allTime" and cfg.previousPeriod and c.previous ~= nil then
					entry.previous = { periodId = c.previous.periodId, rows = publicRows(c.previous.rows) }
				end
				out[id] = entry
			end
		else
			flagOffPublished = true
		end
		ctx.replicate.setAll("boards", out)
	end

	local function mineOf(player: any): any
		local out: { [string]: any } = {}
		if not ctx.data.isLoaded(player) or not isOn() then
			return out
		end
		local section = ctx.data.get(player)
		local now = ctx.now()
		for _, id in boardIds do
			local value = currentValue(player, boards[id], section, now)
			if value ~= nil then
				out[id] = { value = value, rank = Merge.indexOf(cache[id].rows, player.UserId) }
			end
		end
		return out
	end

	local function publishMine(player: any)
		if players[player] ~= nil then
			ctx.replicate.set(player, "mine", mineOf(player))
		end
	end

	local function publishAllMine()
		for player in players do
			publishMine(player)
		end
	end

	--------------------------------------------------------------------------------
	-- Sources
	--------------------------------------------------------------------------------

	local function readSource(player: any, b: any): number?
		local kind = b.source.kind
		local ok, value = true, nil :: any
		if kind == "registered" then
			local fn = sources[b.id]
			if fn == nil then
				return nil
			end
			ok, value = pcall(fn, player)
		elseif kind == "currency" then
			ok, value = pcall(function(): any
				return ctx.deps[Economy].balance(player, b.source.currency)
			end)
		elseif kind == "rebirths" then
			ok, value = pcall(function(): any
				local api = ctx.deps[Rebirth]
				if type(api.count) == "function" then
					return api.count(player)
				end
				return rebirths[player]
			end)
		elseif kind == "streak" then
			ok, value = pcall(function(): any
				return ctx.deps[Streak].get(player).day
			end)
		else
			return nil
		end
		if not ok then
			warnOnce(`source:{b.id}`, `board '{b.id}': the {kind} source failed: {tostring(value)}`)
			return nil
		end
		local normalized = Merge.normalize(value)
		if normalized == nil and value ~= nil then
			warnOnce(
				`sourcevalue:{b.id}`,
				`board '{b.id}': the {kind} source returned a value that is not a finite number`
			)
		end
		return normalized
	end

	-- Reads a source board's value into the player's section (dirty when it changed). Returns a
	-- dirty entry of an earlier period that the read replaced, if any.
	local function pollSource(player: any, b: any): any?
		local value = readSource(player, b)
		if value == nil then
			return nil
		end
		local now = ctx.now()
		local rolled: any = nil
		ctx.data.update(player, function(section: any)
			local _, r = applyValue(section, b, value, now)
			rolled = r
		end)
		return rolled
	end

	--------------------------------------------------------------------------------
	-- Writing a player's value to the stores
	--------------------------------------------------------------------------------

	-- A snapshot of what to write: { userId, name, board, periodId?, endsAt?, value }
	local function jobFor(player: any, b: any, section: any): any?
		if type(section) ~= "table" then
			return nil
		end
		local dirty = section.dirty
		if type(dirty) ~= "table" or dirty[b.id] ~= true then
			return nil
		end
		local job: any = { userId = player.UserId, name = playerName(player), board = b }
		if b.period == "allTime" then
			local values = section.values
			local value = if type(values) == "table" then values[b.id] else nil
			if type(value) ~= "number" then
				return nil
			end
			job.value = value
			return job
		end
		local periods = section.periods
		local entry = if type(periods) == "table" then periods[b.id] else nil
		if type(entry) ~= "table" or type(entry.value) ~= "number" then
			return nil
		end
		local info = Period.fromId(b.period, entry.id, cfg.utcOffsetHours)
		if info == nil then
			return nil
		end
		job.value = entry.value
		job.periodId = info.id
		job.endsAt = info.endsAt
		return job
	end

	-- Does this value fall below a full board's cut (periodic max/sum boards only, cutToTop)?
	local function belowCut(b: any, job: any): boolean
		if not cfg.cutToTop or b.period == "allTime" or b.mode == "set" then
			return false
		end
		local c = cache[b.id]
		if c.periodId ~= job.periodId or c.cut == nil then
			return false
		end
		return not Merge.beatsCut(b.order, job.value, c.cut)
	end

	-- Yields. Returns true when the stores hold the value (or it was cut), false to retry later.
	local function runJob(job: any): boolean
		local b = job.board
		local key = string.format("%d", job.userId)
		if b.period == "allTime" then
			local store = storeFor(b.id)
			local ok
			if b.mode == "set" then
				ok = store.set(key, job.value)
			else
				ok = store.update(key, function(old: number?): number?
					local nextValue = Merge.stored(b.mode, b.order, old, job.value)
					return if nextValue == old then nil else nextValue
				end)
			end
			return ok == true
		end
		local now = ctx.now()
		if now >= job.endsAt + cfg.periodGraceHours * 3600 then
			return true -- the period's maps are gone; nothing to write
		end
		if belowCut(b, job) then
			return true
		end
		local map = mapFor(`{b.id}/{job.periodId}/{job.userId % b.shards}`)
		local ok = map.update(key, function(old: any, _oldSort: any): (any?, number?)
			local oldValue = if type(old) == "table" and type(old.v) == "number" then old.v else nil
			local nextValue = Merge.stored(b.mode, b.order, oldValue, job.value)
			if oldValue == nextValue and type(old) == "table" and old.n == job.name then
				return nil, nil
			end
			return { v = nextValue, n = job.name }, nextValue
		end, Period.expirySeconds(job.endsAt, cfg.periodGraceHours, now))
		return ok == true
	end

	-- Runs a job and, when it landed and the player is still here with the same value, clears dirty.
	local function finishJob(player: any, job: any): boolean
		local ok = runJob(job)
		if not ok or players[player] == nil then
			return ok
		end
		local b = job.board
		ctx.data.update(player, function(section: any)
			local dirty = sectionTable(section, "dirty")
			local current: any
			if b.period == "allTime" then
				current = sectionTable(section, "values")[b.id]
			else
				local entry = sectionTable(section, "periods")[b.id]
				current = if type(entry) == "table" and entry.id == job.periodId then entry.value else nil
			end
			if current == job.value then
				dirty[b.id] = nil
			end
		end)
		return true
	end

	function spawnRolled(player: any, b: any, rolled: any)
		if rolled == nil then
			return
		end
		local info = Period.fromId(b.period, rolled.id, cfg.utcOffsetHours)
		if info == nil then
			return
		end
		local job = {
			userId = player.UserId,
			name = playerName(player),
			board = b,
			value = rolled.value,
			periodId = info.id,
			endsAt = info.endsAt,
		}
		task.spawn(function()
			runJob(job)
		end)
	end

	--------------------------------------------------------------------------------
	-- The shared top N
	--------------------------------------------------------------------------------

	local function itemExpiry(info: Period.Info?, now: number): number
		if info ~= nil then
			return Period.expirySeconds(info.endsAt, cfg.periodGraceHours, now)
		end
		return math.max(10 * cfg.refreshSeconds, 3600)
	end

	local function newCache(): any
		return { rows = {}, at = 0, updatedAt = 0, failures = 0, nextAt = 0, busy = false }
	end

	-- Notes a period change: the rows shown move to `previous` and the new period starts empty.
	-- Returns true when something changed.
	local function syncPeriod(b: any): boolean
		local c = cache[b.id]
		if c.startsAt ~= nil then
			local now = ctx.now()
			if now >= c.startsAt and now < c.endsAt then
				return false -- still the same period (no allocation on the tick)
			end
		end
		local info = periodNow(b)
		if info == nil or c.periodId == info.id then
			return false
		end
		if c.periodId ~= nil then
			local prev = Period.previous(b.period, info, cfg.utcOffsetHours, cfg.weekStartsOn)
			if prev ~= nil and c.periodId == prev.id and #c.rows > 0 then
				c.previous = { periodId = c.periodId, rows = c.rows }
			end
		end
		c.periodId = info.id
		c.startsAt = info.startsAt
		c.endsAt = info.endsAt
		c.rows = {}
		c.cut = nil
		c.at = 0
		c.updatedAt = 0
		c.nextAt = 0
		return true
	end

	local function adopt(c: any, item: any): boolean
		local at = if type(item.at) == "number" then item.at else 0
		local changed = at ~= c.at
		c.rows = copyRows(item.rows)
		c.cut = if type(item.cut) == "number" then item.cut else nil
		c.at = at
		c.updatedAt = at
		return changed
	end

	local function nameOf(userId: number, now: number): string?
		local hit = nameCache[userId]
		if hit ~= nil and now - hit.at < cfg.names.cacheSeconds then
			return hit.name
		end
		return nil
	end

	-- All-time: the store's top list plus one batched name lookup. Returns rows or nil.
	local function readAllTime(b: any, now: number): { Merge.Row }?
		local ok, list = storeFor(b.id).top(b.topN, b.order, b.minValue)
		if not ok or type(list) ~= "table" then
			return nil
		end
		local rows: { Merge.Row } = {}
		local missing: { number } = {}
		for _, entry in list do
			local userId = tonumber(entry.key)
			if userId ~= nil and type(entry.value) == "number" then
				local name = nameOf(userId, now)
				table.insert(rows, { u = userId, n = name or tostring(userId), v = entry.value })
				if name == nil then
					table.insert(missing, userId)
				end
			end
		end
		if #missing > 0 then
			local called, infos = pcall(function(): any
				local service = ctx.services.get("UserService")
				return service:GetUserInfosByUserIdsAsync(missing)
			end)
			if called and type(infos) == "table" then
				local byId: { [number]: string } = {}
				for _, info in infos do
					local name = info.DisplayName
					if type(name) ~= "string" or name == "" then
						name = info.Username
					end
					if type(info.Id) == "number" and type(name) == "string" then
						byId[info.Id] = name
						nameCache[info.Id] = { name = name, at = now }
					end
				end
				for _, row in rows do
					row.n = byId[row.u] or row.n
				end
			else
				warnOnce(
					`names:{b.id}`,
					`board '{b.id}': the name lookup failed; showing user ids until the next read`
				)
			end
		end
		return rows
	end

	-- Daily/weekly: the best topN of every shard, merged. Returns rows or nil (a failed shard aborts).
	local function readPeriodic(b: any, info: Period.Info): { Merge.Row }?
		local lists: { { Merge.Row } } = {}
		local direction = if b.order == "asc" then "asc" else "desc"
		for shard = 0, b.shards - 1 do
			local ok, entries = mapFor(`{b.id}/{info.id}/{shard}`).range(direction, b.topN)
			if not ok or type(entries) ~= "table" then
				return nil
			end
			local list: { Merge.Row } = {}
			for _, entry in entries do
				local userId = tonumber(entry.key)
				local v = entry.value
				if userId ~= nil and type(v) == "table" and type(v.v) == "number" then
					local name = if type(v.n) == "string" then v.n else tostring(userId)
					table.insert(list, { u = userId, n = name, v = v.v })
				end
			end
			table.insert(lists, list)
		end
		return Merge.mergeRows(b.order, b.topN, lists)
	end

	local function failRead(c: any): boolean
		c.failures += 1
		return false
	end

	-- Seconds until this server reads a board's shared top N again.
	local function interval(c: any): number
		local census = ctx.data.census()
		local base = cfg.refreshSeconds
		if census ~= nil and type(census.servers) == "number" then
			base = math.max(base, 60 * census.servers / cfg.topReadsPerMinute)
		end
		if c.failures > 0 then
			local backoff =
				math.min(cfg.backoff.max, cfg.backoff.base * cfg.backoff.factor ^ (c.failures - 1))
			base = math.max(base, backoff)
		end
		return base
	end

	-- Yields. One refresh of a board's shared top N; true when the rows are current.
	local function readBoard(b: any): boolean
		local c = cache[b.id]
		syncPeriod(b)
		local now = ctx.now()
		local info = periodNow(b)
		local key = if info then info.id else "all"
		local top = mapFor(`top/{b.id}`)
		local ok, item = top.get(key)
		if not ok then
			return failRead(c)
		end
		local changed = false
		if type(item) == "table" then
			changed = adopt(c, item)
		end
		-- the previous period's rows, once per period per server
		if info ~= nil and cfg.previousPeriod then
			local prev = Period.previous(b.period, info, cfg.utcOffsetHours, cfg.weekStartsOn)
			if prev ~= nil and c.previousTried ~= prev.id then
				local okPrev, prevItem = top.get(prev.id)
				if okPrev then
					c.previousTried = prev.id
					if type(prevItem) == "table" and type(prevItem.rows) == "table" then
						c.previous = { periodId = prev.id, rows = copyRows(prevItem.rows) }
						changed = true
					end
				end
			end
		end
		local stale = type(item) ~= "table" or now - (tonumber(item.at) or 0) >= cfg.refreshSeconds
		local lease = if type(item) == "table" then item.lease else nil
		local leased = type(lease) == "table" and (tonumber(lease.untilAt) or 0) > now
		if stale and not leased then
			local claimed = false
			local okLease = top.update(key, function(old: any): (any?, number?)
				claimed = false
				if type(old) == "table" then
					if ctx.now() - (tonumber(old.at) or 0) < cfg.refreshSeconds then
						return nil, nil -- another server refreshed meanwhile
					end
					if type(old.lease) == "table" and (tonumber(old.lease.untilAt) or 0) > ctx.now() then
						return nil, nil -- another server got the lease first
					end
				end
				claimed = true
				local nextItem: any = if type(old) == "table" then table.clone(old) else { rows = {}, at = 0 }
				nextItem.lease = { by = myId, untilAt = ctx.now() + LEASE_SECONDS }
				return nextItem, 0
			end, itemExpiry(info, now))
			if not okLease then
				return failRead(c)
			end
			if claimed then
				local rows = if b.period == "allTime"
					then readAllTime(b, now)
					else readPeriodic(b, info :: Period.Info)
				if rows == nil then
					return failRead(c) -- the lease runs out on its own
				end
				local cut = if #rows >= b.topN then rows[b.topN].v else nil
				local writeAt = ctx.now()
				local okWrite = top.update(key, function(old: any): (any?, number?)
					if
						type(old) == "table"
						and type(old.lease) == "table"
						and old.lease.by ~= myId
						and (tonumber(old.lease.untilAt) or 0) > ctx.now()
					then
						return nil, nil -- another server took over after our lease ran out
					end
					return { rows = rows, at = writeAt, cut = cut }, 0
				end, itemExpiry(info, writeAt))
				if not okWrite then
					return failRead(c)
				end
				c.rows = rows
				c.cut = cut
				c.at = writeAt
				c.updatedAt = writeAt
				changed = true
			end
		end
		c.failures = 0
		if changed then
			publishBoards()
			publishAllMine()
			signals.BoardRefreshed:Fire(b.id)
		end
		return true
	end

	-- Yields. Reads the board, then schedules the next read (a failed read backs off).
	local function refreshBoard(b: any): boolean
		local ok, result = pcall(readBoard, b)
		local c = cache[b.id]
		if not ok then
			c.failures += 1
		end
		c.nextAt = ctx.now() + interval(c)
		if not ok then
			error(result, 0)
		end
		return result
	end

	--------------------------------------------------------------------------------
	-- The ticker: refresh cadence, write cadence
	--------------------------------------------------------------------------------

	local function stepBoards(now: number)
		local periodChanged = false
		for _, id in boardIds do
			local b, c = boards[id], cache[id]
			if syncPeriod(b) then
				periodChanged = true
			end
			if now >= c.nextAt and not c.busy then
				c.busy = true
				c.nextAt = now + interval(c)
				task.spawn(function()
					local ok, result = pcall(refreshBoard, b)
					c.busy = false
					if not ok then
						ctx.log.warn(`refresh of '{id}' failed: {tostring(result)}`)
					end
				end)
			end
		end
		if periodChanged then
			publishBoards()
			publishAllMine()
		end
	end

	-- Per-player work runs from a timer wheel (one bucket per whole second): a player is visited
	-- only when one of their writes, source reads or folds is due, so a tick where nothing is due
	-- costs nothing per player. Anything that makes work due calls `schedule`.
	local wheel: { [number]: { [any]: boolean } } = {}
	local wheelAt = 0 -- the last whole second whose bucket ran (set in start)

	local function schedule(player: any, ps: any, at: number)
		local key = math.max(math.ceil(at), wheelAt + 1)
		local current = ps.wakeKey
		if current ~= nil and current > wheelAt and current <= key then
			return -- already woken at or before then
		end
		ps.wakeKey = key
		local bucket = wheel[key]
		if bucket == nil then
			bucket = {}
			wheel[key] = bucket
		end
		bucket[player] = true
	end

	-- The first fold time after `now` on the player's own (staggered) phase.
	local function advanceFold(ps: any, now: number)
		if ps.foldAt <= now then
			ps.foldAt += (math.floor((now - ps.foldAt) / FOLD_SECONDS) + 1) * FOLD_SECONDS
		end
	end

	local function visit(player: any, ps: any, now: number)
		if players[player] ~= ps or not ctx.data.isLoaded(player) then
			return -- left, or the save is gone; a new load schedules again
		end
		if next(ps.pending) ~= nil then
			local foldDue = now >= ps.foldAt
			if not foldDue then
				for id in ps.pending do
					if now >= ps.nextAt[id] and not ps.inflight[id] then
						foldDue = true -- a store write is due: it sends the folded value
						break
					end
				end
			end
			if foldDue then
				foldPending(player, ps)
				advanceFold(ps, now)
			end
		end
		for _, id in boardIds do
			local b = boards[id]
			if now < ps.nextAt[id] or ps.inflight[id] then
				continue
			end
			if b.source.kind ~= "submit" then
				ps.nextAt[id] = now + cfg.writeSeconds
				spawnRolled(player, b, pollSource(player, b))
			end
			local job = jobFor(player, b, ctx.data.get(player))
			if job ~= nil then
				ps.nextAt[id] = now + cfg.writeSeconds
				ps.inflight[id] = true
				task.spawn(function()
					local ok, err = pcall(finishJob, player, job)
					ps.inflight[id] = nil
					if not ok then
						ctx.log.warn(`write to '{id}' failed: {tostring(err)}`)
					end
					publishMine(player)
					if players[player] == ps then
						schedule(player, ps, ps.nextAt[id]) -- still dirty (failed or changed): retry then
					end
				end)
			end
		end
		-- the next time anything is due: a source read, a write after the cadence, a fold
		local wake = math.huge
		for _, id in boardIds do
			if not ps.inflight[id] and (boards[id].source.kind ~= "submit" or ps.nextAt[id] > now) then
				wake = math.min(wake, ps.nextAt[id])
			end
		end
		if next(ps.pending) ~= nil then
			wake = math.min(wake, ps.foldAt)
			for id in ps.pending do
				if not ps.inflight[id] then
					wake = math.min(wake, ps.nextAt[id])
				end
			end
		end
		if wake < math.huge then
			schedule(player, ps, wake)
		end
	end

	local function stepPlayers(now: number)
		local second = math.floor(now)
		if second < wheelAt or second - wheelAt > MAX_CATCH_UP_SECONDS then
			-- the clock jumped (or the flag was off a long time): visit everyone once
			wheel = {}
			wheelAt = second
			for player, ps in players do
				ps.wakeKey = nil
				visit(player, ps, now)
			end
			return
		end
		while wheelAt < second do
			wheelAt += 1
			local bucket = wheel[wheelAt]
			if bucket ~= nil then
				wheel[wheelAt] = nil
				for player in bucket do
					local ps = players[player]
					if ps ~= nil and ps.wakeKey == wheelAt then
						ps.wakeKey = nil
						visit(player, ps, now)
					end
				end
			end
		end
	end

	local function step()
		if not isOn() then
			if not flagOffPublished then
				publishBoards()
				for player in players do
					publishMine(player)
				end
			end
			return
		end
		if flagOffPublished then
			publishBoards()
			publishAllMine()
		end
		local now = ctx.now()
		stepBoards(now)
		stepPlayers(now)
	end

	-- Jobs for every dirty board of a player (sources read first). Used on leave and on shutdown.
	local function pendingJobs(player: any): { any }
		local out: { any } = {}
		if not ctx.data.isLoaded(player) then
			return out
		end
		for _, id in boardIds do
			local b = boards[id]
			if b.source.kind ~= "submit" then
				spawnRolled(player, b, pollSource(player, b))
			end
			local job = jobFor(player, b, ctx.data.get(player))
			if job ~= nil then
				table.insert(out, job)
			end
		end
		return out
	end

	--------------------------------------------------------------------------------
	-- Submit, init and start
	--------------------------------------------------------------------------------

	local function submitCommon(section: any, b: any, value: any): (boolean, any?)
		local normalized = Merge.normalize(value)
		if normalized == nil then
			warnOnce(`badvalue:{b.id}`, `board '{b.id}': submit refused a value that is not a finite number`)
			return false, nil
		end
		local _, rolled = applyValue(section, b, normalized, ctx.now())
		return true, rolled
	end

	local function submitFor(player: any, boardId: string, value: any): boolean
		local b = boards[boardId]
		if b == nil or b.source.kind ~= "submit" or not isOn() or not ctx.data.isLoaded(player) then
			return false
		end
		local ps = players[player]
		if ps ~= nil and b.mode ~= "set" then
			local normalized = Merge.normalize(value)
			if normalized == nil then
				warnOnce(
					`badvalue:{b.id}`,
					`board '{b.id}': submit refused a value that is not a finite number`
				)
				return false
			end
			local now = ctx.now()
			local entry = ps.pending[boardId]
			if entry ~= nil and not inPeriod(entry, now) then
				-- an earlier period's value joins the save first
				if not foldPending(player, ps) then
					return false
				end
				entry = ps.pending[boardId]
			end
			if entry == nil then
				if b.mode == "max" then
					local saved = savedValue(ctx.data.get(player), b, now)
					if saved ~= nil and Merge.combine(b.mode, b.order, saved, normalized) == saved then
						return true -- doesn't beat the saved best: nothing to write
					end
				end
				entry = { value = normalized, at = now }
				if b.period ~= "allTime" then
					local info = Period.of(b.period, now, cfg.utcOffsetHours, cfg.weekStartsOn) :: Period.Info
					entry.id = info.id
					entry.startsAt = info.startsAt
					entry.endsAt = info.endsAt
				end
				ps.pending[boardId] = entry
				advanceFold(ps, now)
				schedule(
					player,
					ps,
					if ps.inflight[boardId] then ps.foldAt else math.min(ps.foldAt, ps.nextAt[boardId])
				)
			else
				entry.value = Merge.combine(b.mode, b.order, entry.value, normalized)
			end
			return true
		end
		local accepted = false
		local rolled: any = nil
		local ran = ctx.data.update(player, function(section: any)
			accepted, rolled = submitCommon(section, b, value)
		end)
		if ran and accepted then
			spawnRolled(player, b, rolled)
			if ps ~= nil then
				schedule(player, ps, ps.nextAt[boardId]) -- the save holds a dirty value
			end
			return true
		end
		return false
	end

	local function isAdmin(player: any): boolean
		if player == nil or ctx.isStudio then
			return true
		end
		local admins = ctx.serverConfig and ctx.serverConfig.admins
		return type(admins) == "table" and table.find(admins, player.UserId) ~= nil
	end

	function Leaderboards.init(context: any)
		ctx = context
		cfg = ctx.config
		signals.BoardRefreshed = ctx.signals.new("BoardRefreshed")
		idCounter += 1
		myId = string.format("%x-%x-%x", math.random(0, 0x7fffffff), math.floor(os.clock() * 1000), idCounter)

		if cfg.flag ~= nil then
			local ok, err = pcall(ctx.flags.isOn, cfg.flag)
			if not ok then
				error(`[Leaderboards] config.flag: {tostring(err)}`, 0)
			end
		end
		for id, raw in cfg.boards do
			boards[id] = resolveBoard(id, raw)
			table.insert(boardIds, id)
		end
		table.sort(boardIds)

		ctx.console.register("refresh", function(_player: any, boardId: any): string
			local b = boards[tostring(boardId)]
			if b == nil then
				return `unknown board '{tostring(boardId)}'`
			end
			return if Leaderboards.api.refresh(b.id)
				then `{b.id}: refreshed`
				else `{b.id}: refresh failed (budget or store)`
		end, "leaderboards refresh <boardId>: re-read a board's shared top N now")
		ctx.console.register("submit", function(player: any, boardId: any, value: any, userId: any): string
			if not isAdmin(player) then
				return "leaderboards submit is for Studio or admins"
			end
			local b = boards[tostring(boardId)]
			if b == nil then
				return `unknown board '{tostring(boardId)}'`
			end
			local target = nil
			local id = tonumber(userId)
			for p in players do
				if id == nil or p.UserId == id then
					target = p
					break
				end
			end
			if target == nil then
				return "no loaded player"
			end
			return if submitFor(target, b.id, tonumber(value)) then `{b.id}: submitted` else `{b.id}: refused`
		end, "leaderboards submit <boardId> <value> [userId]: add a value for a player (Studio or admins)")
	end

	function Leaderboards.start(_context: any)
		local now = ctx.now()
		wheelAt = math.floor(now) - 1
		for _, id in boardIds do
			local c = newCache()
			c.nextAt = now + math.random() * cfg.refreshSeconds * START_JITTER
			cache[id] = c
			syncPeriod(boards[id])
		end
		if ctx.isEnabled(Rebirth) then
			local api = ctx.deps[Rebirth]
			for _, id in boardIds do
				if boards[id].source.kind == "rebirths" then
					api.signals.Rebirthed:Connect(function(player: any, count: number)
						rebirths[player] = count
					end)
					break
				end
			end
		end
		publishBoards()
		if cfg.flag ~= nil then
			ctx.flags.onChanged(cfg.flag, function()
				publishBoards()
				publishAllMine()
			end)
		end

		ctx.data.onLoaded(function(player: any)
			local now = ctx.now()
			local ps =
				{ nextAt = {}, inflight = {}, pending = {}, foldAt = now + math.random() * FOLD_SECONDS }
			for _, id in boardIds do
				ps.nextAt[id] = 0
			end
			players[player] = ps
			schedule(player, ps, now) -- a dirty value from an earlier session is written now
			nameCache[player.UserId] = { name = playerName(player), at = ctx.now() }
			publishMine(player)
		end)
		ctx.lifecycle.onPlayerRemoving(function(player: any)
			local ps = players[player]
			if ps == nil then
				return
			end
			foldPending(player, ps) -- values accepted while the flag was on are kept either way
			local jobs: { any } = if isOn() then pendingJobs(player) else {}
			players[player] = nil
			rebirths[player] = nil
			for _, job in jobs do
				task.spawn(function()
					local ok, err = pcall(runJob, job)
					if not ok then
						ctx.log.warn(`write to '{job.board.id}' on leave failed: {tostring(err)}`)
					end
				end)
			end
		end)
		ctx.lifecycle.onTick(TICK_SECONDS, function()
			task.spawn(step)
		end)
		ctx.lifecycle.onShutdown(function()
			for player, ps in table.clone(players) do
				foldPending(player, ps)
			end
			if not isOn() then
				return
			end
			for player in table.clone(players) do
				for _, job in pendingJobs(player) do
					local ok, err = pcall(runJob, job)
					if not ok then
						ctx.log.warn(`shutdown write to '{job.board.id}' failed: {tostring(err)}`)
					end
				end
			end
		end)
	end

	--------------------------------------------------------------------------------
	-- Public API
	--------------------------------------------------------------------------------

	local EMPTY = table.freeze({ rows = table.freeze({}), updatedAt = 0 })

	Leaderboards.api = {
		submit = function(player: any, boardId: string, value: number): boolean
			return submitFor(player, boardId, value)
		end,
		top = function(boardId: string, previous: boolean?): any
			local b, c = boards[boardId], cache[boardId]
			if b == nil or c == nil or not isOn() then
				return EMPTY
			end
			if previous == true then
				local prev = c.previous
				if b.period == "allTime" or prev == nil then
					return EMPTY
				end
				local info = Period.fromId(b.period, prev.periodId, cfg.utcOffsetHours)
				return table.freeze({
					rows = publicRows(prev.rows),
					periodId = prev.periodId,
					endsAt = if info then info.endsAt else nil,
					updatedAt = c.updatedAt,
				})
			end
			return table.freeze({
				rows = publicRows(c.rows),
				periodId = c.periodId,
				endsAt = c.endsAt,
				updatedAt = c.updatedAt,
			})
		end,
		rank = function(player: any, boardId: string): (number?, number)
			local b, c = boards[boardId], cache[boardId]
			if b == nil or c == nil or not ctx.data.isLoaded(player) then
				return nil, 0
			end
			local value = currentValue(player, b, ctx.data.get(player), ctx.now())
			if value == nil then
				return nil, 0
			end
			return Merge.indexOf(c.rows, player.UserId), value
		end,
		refresh = function(boardId: string): boolean
			local b = boards[boardId]
			if b == nil or not isOn() then
				return false
			end
			local ok, result = pcall(refreshBoard, b)
			if not ok then
				ctx.log.warn(`refresh of '{boardId}' failed: {tostring(result)}`)
				return false
			end
			return result
		end,
		signals = signals,
	}

	Leaderboards.txApi = {
		submit = function(tx: any, boardId: string, value: any): boolean
			local b = boards[boardId]
			if b == nil or b.source.kind ~= "submit" or not isOn() then
				return false
			end
			local section = ctx.section(tx)
			local ps = players[tx.player]
			local entry = if ps ~= nil then ps.pending[boardId] else nil
			if entry ~= nil and not inPeriod(entry, ctx.now()) and not savedPast(section, boardId, entry) then
				-- this submit rolls the save into a new period: the earlier period's pending value
				-- goes into the rolled total first (a later fold, or a second txApi submit in this
				-- tx, skips it: the save is past it)
				local _, earlier = applyValue(section, b, entry.value, entry.at)
				if earlier ~= nil then
					tx.after(function()
						spawnRolled(tx.player, b, earlier)
					end)
				end
				tx.after(function()
					if ps.pending[boardId] == entry then
						ps.pending[boardId] = nil
					end
				end)
			end
			local accepted, rolled = submitCommon(section, b, value)
			if accepted and ps ~= nil then
				tx.after(function()
					if players[tx.player] == ps then
						schedule(tx.player, ps, ps.nextAt[boardId]) -- the save holds a dirty value
					end
				end)
			end
			if accepted and rolled ~= nil then
				tx.after(function()
					spawnRolled(tx.player, b, rolled)
				end)
			end
			return accepted
		end,
	}

	Leaderboards.extensions = {
		registerSource = function(boardId: string, fn: (player: any) -> number?)
			assert(type(fn) == "function", "Leaderboards.registerSource(boardId, fn): fn must be a function")
			local b = boards[boardId]
			if b == nil then
				error(`Leaderboards.registerSource: unknown board '{tostring(boardId)}'`, 2)
			end
			if b.source.kind ~= "registered" then
				error(`Leaderboards.registerSource: board '{boardId}' has source.kind '{b.source.kind}'`, 2)
			end
			if sources[boardId] ~= nil then
				error(`Leaderboards.registerSource: board '{boardId}' already has a source`, 2)
			end
			sources[boardId] = fn
		end,
	}

	return Leaderboards
end

return LeaderboardsModule
