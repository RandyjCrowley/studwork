--!strict
--[[
	Badges: the server part (docs/framework/kits/badges.md). A part factory: Badges.new() builds a
	fresh part, so two runtimes in one process (specs, the sim) never share state.

	Never awards twice; failures never block gameplay. An award is RECORDED in the player's save
	(section "badges": awarded[key] = { at, sent = false }) the moment its trigger fires, in the
	triggering transaction where there is one, and SENT to Roblox afterwards by this server's send
	queue. A key recorded as sent is never sent again.

	  api.award(player, key) -> boolean     records + queues; true = newly recorded. Doesn't yield.
	  api.has(player, key) -> boolean       recorded (by us or found owned)
	  api.signals.BadgeAwarded(player, key, badgeId)   Roblox confirmed it (or it was found owned)
	  txApi.award(tx, key) / purchaseOps.award(tx, key)  records in the caller's tx; the send
	                                        follows tx.after (product handlers: records only)
	Console: badges list [userId], badges pending [userId], badges reset <key> [userId] (Studio).

	The send queue (one pump per server, never on a caller's thread): per (player, key) entry, in
	userId then key order, within config.budget.perMinute (base + perPlayer x players). Skipped and
	left pending: config.flag off, Studio without awardInStudio (logged "would award"), placeholder
	id 0 (one warning per server per key), a badge disabled on the dashboard (one warning per server
	per id), the player gone. GetBadgeInfoAsync is cached infoCacheSeconds. AwardBadgeAsync:
	  true  -> sent = true, BadgeAwarded, the Awarded client event, a toast when `toast`
	  false -> one CheckUserBadgesAsync (budget.checksPerMinute): owned -> { sent, found }, the
	           signal; not owned -> a failure
	  error -> backoff (config.retry); after `attempts` failures this session it stays pending.
	At join (config.ownershipCheck): configured badges not yet sent (unrecorded AND pending ones)
	are checked in batches of 10; owned ones are recorded { sent = true, found = true } without an
	award call. Then the triggers already satisfied at join fire, and the pending keys are queued.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BadgeRules = require(script.BadgeRules)

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Economy = require(Modules:WaitForChild("Economy"):WaitForChild("module"))
local Inventory = require(Modules:WaitForChild("Inventory"):WaitForChild("module"))
local Leaderboards = require(Modules:WaitForChild("Leaderboards"):WaitForChild("module"))
local Rebirth = require(Modules:WaitForChild("Rebirth"):WaitForChild("module"))
local Streak = require(Modules:WaitForChild("Streak"):WaitForChild("module"))

local CHECK_BATCH = 10 -- CheckUserBadgesAsync takes at most 10 badge ids per call (Roblox)
local MINUTE = 60

local Badges = {}

Badges.Rules = BadgeRules

type Entry = { attempts: number, nextAt: number }

function Badges.new(): any
	local ctx: any = nil
	local created: { [string]: any } = {}
	local signals = setmetatable({}, {
		__index = function(_, key: any): any
			return created[key]
		end,
		__newindex = function()
			error("Badges.signals is read-only", 2)
		end,
	})

	local defs: { [string]: any } = {}
	local keysById: { [number]: { string } } = {}
	local players: { [any]: boolean } = {} -- loaded in this server
	local queue: { [any]: { [string]: Entry } } = {}
	local failures: { [any]: { [string]: number } } = {} -- this session's failed sends
	local studioLogged: { [any]: { [string]: boolean } } = {}
	local infoCache: { [number]: { at: number, enabled: boolean } } = {}
	local warned: { [string]: boolean } = {}
	local window = { minute = -1, awards = 0, checks = 0 }
	local pumping = false

	local part: { [string]: any } = {}

	local function cfg(): any
		return ctx.config
	end

	local function warnOnce(tag: string, message: string)
		if not warned[tag] then
			warned[tag] = true
			ctx.log.warn(message)
		end
	end

	local function isStudio(): boolean
		return ctx.isStudio == true or ctx.env.name() == "studio"
	end

	local function flagOn(): boolean
		local flag = cfg().flag
		return flag == nil or ctx.flags.isOn(flag)
	end

	local function playerCount(): number
		local n = 0
		for _ in players do
			n += 1
		end
		return n
	end

	-- this server's per-minute allowance for "awards" or "checks"; true = one call taken
	local function take(kind: string): boolean
		local minute = math.floor(ctx.now() / MINUTE)
		if minute ~= window.minute then
			window.minute = minute
			window.awards = 0
			window.checks = 0
		end
		local budget = cfg().budget or {}
		local limit = BadgeRules.allowance(
			if kind == "awards" then budget.perMinute else budget.checksPerMinute,
			playerCount()
		)
		local used = (window :: any)[kind]
		if used >= limit then
			return false
		end
		(window :: any)[kind] = used + 1
		return true
	end

	local function service(): any
		return ctx.services.get("BadgeService")
	end

	local function record(player: any, key: string): any
		if not ctx.data.isLoaded(player) then
			return nil
		end
		local section = ctx.data.get(player)
		local awarded = if section and type(section.awarded) == "table" then section.awarded else nil
		return if awarded then awarded[key] else nil
	end

	local function knownKey(fnName: string, key: any): any
		local def = if type(key) == "string" then defs[key] else nil
		if def == nil then
			error(`Badges.{fnName}: unknown badge '{tostring(key)}' (config.Badges.badges)`, 3)
		end
		return def
	end

	local function enqueue(player: any, key: string)
		if not players[player] then
			return
		end
		local rec = record(player, key)
		if rec == nil or rec.sent == true then
			return
		end
		queue[player] = queue[player] or {}
		if queue[player][key] == nil then
			queue[player][key] = { attempts = 0, nextAt = 0 }
		end
	end

	local function dequeue(player: any, key: string)
		local q = queue[player]
		if q then
			q[key] = nil
			if next(q) == nil then
				queue[player] = nil
			end
		end
	end

	-- Confirmed (awarded now, or found already owned): sent = true in the save, then the signal,
	-- the client event and (a fresh award only) the toast.
	local function confirm(player: any, key: string, found: boolean)
		dequeue(player, key)
		local def = defs[key]
		local already = false
		local saved = ctx.data.update(player, function(section: any)
			section.awarded = section.awarded or {}
			local rec = section.awarded[key]
			if rec ~= nil and rec.sent == true then
				already = true
				return
			end
			section.awarded[key] = {
				at = if rec ~= nil and type(rec.at) == "number" then rec.at else ctx.now(),
				sent = true,
				found = if found then true else nil,
			}
		end)
		if not saved or already then
			return
		end
		created.BadgeAwarded:Fire(player, key, def.id)
		local net = part.net
		if type(net) == "table" and net.Awarded ~= nil then
			pcall(ctx.net.fire, player, net.Awarded, key)
		end
		if not found and def.toast ~= false then
			local name = ctx.text.format(player, "Badges.badge." .. key)
			pcall(
				ctx.net.feedback,
				player,
				"toast",
				ctx.text.format(player, "Badges.awarded", { name = name })
			)
		end
	end

	local function failed(player: any, key: string, entry: Entry, why: string)
		local f = failures[player]
		if f == nil then
			dequeue(player, key)
			return
		end
		f[key] = (f[key] or 0) + 1
		entry.attempts = f[key]
		local retry = cfg().retry
		if f[key] >= retry.attempts then
			dequeue(player, key)
			ctx.log.info(
				`{key} for user {player.UserId}: {f[key]} failed sends ({why}); pending until the next session`
			)
			return
		end
		entry.nextAt = ctx.now() + BadgeRules.backoff(retry, f[key])
	end

	-- true = enabled; nil = the lookup failed (counts as a failed send)
	local function badgeEnabled(id: number): boolean?
		local cached = infoCache[id]
		if cached and ctx.now() - cached.at < cfg().infoCacheSeconds then
			return cached.enabled
		end
		local ok, info = pcall(function(): any
			return service():GetBadgeInfoAsync(id)
		end)
		if not ok or type(info) ~= "table" then
			return nil
		end
		local enabled = info.IsEnabled ~= false
		infoCache[id] = { at = ctx.now(), enabled = enabled }
		return enabled
	end

	-- "budget" when this minute's allowance ran out (the pump stops until the next minute)
	local function sendOne(player: any, key: string, entry: Entry): string?
		local def = defs[key]
		local rec = record(player, key)
		if rec == nil or rec.sent == true then
			dequeue(player, key)
			return nil
		end
		if def.id == 0 then
			dequeue(player, key)
			warnOnce(
				"placeholder:" .. key,
				`badge '{key}' has the placeholder id 0: recorded, never sent (set config.Badges.badges.{key}.id)`
			)
			return nil
		end
		if isStudio() and cfg().awardInStudio ~= true then
			dequeue(player, key)
			studioLogged[player] = studioLogged[player] or {}
			if not studioLogged[player][key] then
				studioLogged[player][key] = true
				ctx.log.info(
					`would award {key} ({def.id}) to user {player.UserId} (Studio: awardInStudio is false; stays pending)`
				)
			end
			return nil
		end
		local enabled = badgeEnabled(def.id)
		if enabled == nil then
			failed(player, key, entry, "badge info lookup failed")
			return nil
		end
		if not enabled then
			dequeue(player, key)
			warnOnce(
				"disabled:" .. def.id,
				`badge '{key}' ({def.id}) is disabled on the dashboard: not sent, stays pending`
			)
			return nil
		end
		if not take("awards") then
			return "budget"
		end
		local ok, result = pcall(function(): any
			return service():AwardBadgeAsync(player.UserId, def.id)
		end)
		if not players[player] then
			return nil -- left while the call ran: stays pending for the next session
		end
		if ok and result == true then
			confirm(player, key, false)
			return nil
		end
		if ok and result == false then
			-- Roblox returns false for a badge the player already owns (among other cases)
			if not take("checks") then
				failed(player, key, entry, "award returned false; no check budget")
				return nil
			end
			local okCheck, owned = pcall(function(): any
				return service():CheckUserBadgesAsync(player.UserId, { def.id })
			end)
			if okCheck and type(owned) == "table" and table.find(owned, def.id) ~= nil then
				confirm(player, key, true)
				return nil
			end
			failed(player, key, entry, "award returned false and the badge isn't owned")
			return nil
		end
		failed(player, key, entry, "award call errored")
		return nil
	end

	local function sortedPlayers(): { any }
		local out = {}
		for player in queue do
			table.insert(out, player)
		end
		table.sort(out, function(a: any, b: any): boolean
			return (tonumber(a.UserId) or 0) < (tonumber(b.UserId) or 0)
		end)
		return out
	end

	local function pumpOnce()
		if not flagOn() then
			return
		end
		for _, player in sortedPlayers() do
			local q = queue[player]
			if q == nil then
				continue
			end
			if not players[player] or not ctx.data.isLoaded(player) then
				queue[player] = nil -- left: their pending keys are queued again on the next join
				continue
			end
			for _, key in BadgeRules.sortedKeys(q) do
				local entry = q[key]
				if entry ~= nil and entry.nextAt <= ctx.now() then
					if sendOne(player, key, entry) == "budget" then
						return
					end
				end
			end
		end
	end

	local function pump()
		if pumping then
			return
		end
		pumping = true
		local ok, err = pcall(pumpOnce :: any)
		pumping = false
		if not ok then
			ctx.log.warn(`send queue error: {tostring(err)}`)
		end
	end

	local function kick()
		task.spawn(pump)
	end

	-- records `key` in `section` (a tx section); true when newly recorded
	local function recordIn(section: any, key: string): boolean
		if type(section.awarded) ~= "table" then
			section.awarded = {}
		end
		if section.awarded[key] ~= nil then
			return false
		end
		section.awarded[key] = { at = ctx.now(), sent = false }
		return true
	end

	local function awardTx(tx: any, key: string): boolean
		knownKey("award", key)
		if not recordIn(ctx.section(tx), key) then
			return false
		end
		local player = tx.player
		tx.after(function()
			enqueue(player, key)
			kick()
		end)
		return true
	end

	local api: { [string]: any } = { signals = signals }

	function api.award(player: any, key: string): boolean
		knownKey("award", key)
		if not ctx.data.isLoaded(player) then
			return false
		end
		if record(player, key) ~= nil then
			return false
		end
		local newly = false
		local ok, committed = pcall(ctx.tx, player, function(tx: any)
			newly = recordIn(ctx.section(tx), key)
		end)
		if not ok or committed ~= true or not newly then
			return false
		end
		enqueue(player, key)
		kick()
		return true
	end

	function api.has(player: any, key: string): boolean
		knownKey("has", key)
		return record(player, key) ~= nil
	end

	local function awardSafe(player: any, key: string)
		local ok, err = pcall(api.award, player, key)
		if not ok then
			ctx.log.warn(`trigger for '{key}' failed: {tostring(err)}`)
		end
	end

	-- the keys whose trigger has this kind
	local function keysOfKind(kind: string): { string }
		local out = {}
		for _, key in BadgeRules.sortedKeys(defs) do
			if defs[key].trigger.kind == kind then
				table.insert(out, key)
			end
		end
		return out
	end

	local function currencyOf(trigger: any): string?
		if trigger.currency then
			return trigger.currency
		end
		local ok, id = pcall(function(): any
			return ctx.deps[Economy].primaryCurrency()
		end)
		return if ok then id else nil
	end

	-- the trigger conditions that can be read at join (a streak of 10 for a badge at 7)
	local function satisfiedAtJoin(player: any, key: string): boolean
		local t = defs[key].trigger
		local ok, yes = pcall(function(): boolean
			if t.kind == "join" then
				return ctx.framework.sessions(player) == 1
			elseif t.kind == "streak" then
				return (ctx.deps[Streak].get(player).day or 0) >= t.atLeast
			elseif t.kind == "currency" then
				return ctx.deps[Economy].balance(player, currencyOf(t)) >= t.atLeast
			elseif t.kind == "item" then
				for _, item in ctx.deps[Inventory].list(player) do
					if item.itemId == t.item then
						return true
					end
				end
				return false
			elseif t.kind == "leaderboard" then
				local rank = ctx.deps[Leaderboards].rank(player, t.board)
				return type(rank) == "number" and rank <= t.rank
			elseif t.kind == "rebirths" then
				-- Rebirth.count (v1.7.0): already satisfied at join; Rebirthed handles the rest
				return ctx.deps[Rebirth].count(player) >= t.atLeast
			end
			return false
		end)
		return ok and yes == true
	end

	local function ownershipCheck(player: any)
		local ids: { number } = {}
		local seen: { [number]: boolean } = {}
		for _, key in BadgeRules.sortedKeys(defs) do
			local id = defs[key].id
			local rec = record(player, key)
			if id ~= 0 and (rec == nil or rec.sent ~= true) and not seen[id] then
				seen[id] = true
				table.insert(ids, id)
			end
		end
		for _, batch in BadgeRules.batches(ids, CHECK_BATCH) do
			if not players[player] or not take("checks") then
				return
			end
			local ok, owned = pcall(function(): any
				return service():CheckUserBadgesAsync(player.UserId, batch)
			end)
			if ok and type(owned) == "table" then
				for _, id in owned do
					local keys: { string } = keysById[id] or {}
					for _, key in keys do
						local rec = record(player, key)
						if rec == nil or rec.sent ~= true then
							confirm(player, key, true)
						end
					end
				end
			end
		end
	end

	local function onJoin(player: any)
		if not players[player] then
			return
		end
		if cfg().ownershipCheck and flagOn() then
			ownershipCheck(player)
		end
		if not players[player] then
			return
		end
		for _, key in BadgeRules.sortedKeys(defs) do
			if record(player, key) == nil and satisfiedAtJoin(player, key) then
				awardSafe(player, key)
			end
		end
		for _, key in BadgeRules.sortedKeys(defs) do
			enqueue(player, key)
		end
		pump()
	end

	local function connectTriggers()
		local streakKeys = keysOfKind("streak")
		if #streakKeys > 0 then
			ctx.deps[Streak].onDaily(function(player: any, day: number)
				for _, key in streakKeys do
					if day >= defs[key].trigger.atLeast then
						awardSafe(player, key)
					end
				end
			end)
		end
		local rebirthKeys = keysOfKind("rebirths")
		if #rebirthKeys > 0 then
			ctx.deps[Rebirth].signals.Rebirthed:Connect(function(player: any, count: number)
				for _, key in rebirthKeys do
					if type(count) == "number" and count >= defs[key].trigger.atLeast then
						awardSafe(player, key)
					end
				end
			end)
		end
		local itemKeys = keysOfKind("item")
		if #itemKeys > 0 then
			ctx.deps[Inventory].signals.ItemAdded:Connect(function(player: any, item: any)
				for _, key in itemKeys do
					if type(item) == "table" and item.itemId == defs[key].trigger.item then
						awardSafe(player, key)
					end
				end
			end)
		end
		local currencyKeys = keysOfKind("currency")
		if #currencyKeys > 0 then
			ctx.deps[Economy].signals.CurrencyChanged:Connect(
				function(player: any, currency: string, balance: number)
					for _, key in currencyKeys do
						local t = defs[key].trigger
						if
							currency == currencyOf(t)
							and type(balance) == "number"
							and balance >= t.atLeast
						then
							awardSafe(player, key)
						end
					end
				end
			)
		end
		local boardKeys = keysOfKind("leaderboard")
		if #boardKeys > 0 then
			ctx.deps[Leaderboards].signals.BoardRefreshed:Connect(function(boardId: string)
				for _, key in boardKeys do
					local t = defs[key].trigger
					if t.board == boardId then
						for player in players do
							local ok, rank = pcall(ctx.deps[Leaderboards].rank, player, boardId)
							if ok and type(rank) == "number" and rank <= t.rank then
								awardSafe(player, key)
							end
						end
					end
				end
			end)
		end
	end

	-- console: the player by user id, or the first loaded one
	local function targetPlayer(arg: any): any
		local id = tonumber(arg)
		local first = nil
		for player in players do
			if id ~= nil and player.UserId == id then
				return player
			end
			if first == nil or player.UserId < first.UserId then
				first = player
			end
		end
		return if id == nil then first else nil
	end

	local function listing(player: any, pendingOnly: boolean): string
		local lines = {}
		for _, key in BadgeRules.sortedKeys(defs) do
			local rec = record(player, key)
			if rec ~= nil and (not pendingOnly or rec.sent ~= true) then
				local state = if rec.sent ~= true then "pending" elseif rec.found then "found" else "sent"
				local queued = queue[player] ~= nil and queue[player][key] ~= nil
				table.insert(lines, `{key} ({defs[key].id}): {state}{if queued then ", queued" else ""}`)
			elseif rec == nil and not pendingOnly then
				table.insert(lines, `{key} ({defs[key].id}): not awarded`)
			end
		end
		return if #lines == 0 then "none" else table.concat(lines, "\n")
	end

	function part.init(context: any)
		ctx = context
		created.BadgeAwarded = ctx.signals.new("BadgeAwarded")
		local refs: { [string]: any } = {
			Economy = Economy,
			Inventory = Inventory,
			Leaderboards = Leaderboards,
			Rebirth = Rebirth,
			Streak = Streak,
		}
		local errors = BadgeRules.validate(ctx.config.badges, function(moduleName: string): boolean
			local ref = refs[moduleName]
			return ref ~= nil and ctx.isEnabled(ref)
		end)
		local flag = ctx.config.flag
		if flag ~= nil and not pcall(ctx.flags.isOn, flag) then
			table.insert(errors, `config.Badges.flag '{tostring(flag)}' is not declared in GameConfig.flags`)
		end
		if #errors > 0 then
			error("invalid Badges config:\n  - " .. table.concat(errors, "\n  - "), 0)
		end
		for key, def in ctx.config.badges do
			defs[key] = def
			keysById[def.id] = keysById[def.id] or {}
			table.insert(keysById[def.id], key)
		end
		-- placeholders are allowed (recorded, never sent), but named once at boot so none ships by
		-- mistake (a log line, not a warning: a game in development boots clean)
		local placeholders: { string } = {}
		for _, key in BadgeRules.sortedKeys(defs) do
			if defs[key].id == 0 then
				table.insert(placeholders, key)
			end
		end
		if #placeholders > 0 then
			ctx.log.info(
				`placeholder badges (id 0): {table.concat(placeholders, ", ")}: recorded, never sent; set each config.Badges.badges.<key>.id (Creator Dashboard) before publishing`
			)
		end

		ctx.console.register("list", function(_player: any, userId: any): string
			local player = targetPlayer(userId)
			return if player then listing(player, false) else "no loaded player"
		end, "badges list [userId]: every configured badge and its state")
		ctx.console.register("pending", function(_player: any, userId: any): string
			local player = targetPlayer(userId)
			return if player then listing(player, true) else "no loaded player"
		end, "badges pending [userId]: recorded badges not yet confirmed by Roblox")
		ctx.console.register("reset", function(_player: any, key: any, userId: any): string
			if not isStudio() then
				return "badges reset is Studio-only"
			end
			if type(key) ~= "string" or defs[key] == nil then
				return `unknown badge '{tostring(key)}'`
			end
			local player = targetPlayer(userId)
			if player == nil then
				return "no loaded player"
			end
			dequeue(player, key)
			ctx.data.update(player, function(section: any)
				if type(section.awarded) == "table" then
					section.awarded[key] = nil
				end
			end)
			return `cleared our record of {key} (nothing is removed from Roblox)`
		end, "badges reset <key> [userId]: clear our record of a badge (Studio)")
	end

	function part.start(_context: any)
		-- after every module's own load handlers (balances, streaks and lists are readable by then)
		ctx.lifecycle.onPlayerLoaded(function(player: any)
			players[player] = true
			failures[player] = {}
			task.spawn(onJoin, player)
		end)
		ctx.lifecycle.onPlayerRemoving(function(player: any)
			players[player] = nil
			queue[player] = nil
			failures[player] = nil
			studioLogged[player] = nil
		end)
		ctx.lifecycle.onTick(1, function()
			if next(queue) ~= nil then
				pump()
			end
		end)
		local flag = ctx.config.flag
		if flag ~= nil then
			ctx.flags.onChanged(flag, function(on: boolean)
				if on then
					kick()
				end
			end)
		end
		connectTriggers()
	end

	part.api = api
	part.txApi = { award = awardTx }
	-- product handlers (tx.use(Badges).award): records only; the send follows the commit
	part.purchaseOps = { award = awardTx }

	return part
end

return Badges
