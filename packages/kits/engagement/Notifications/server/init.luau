--!strict
--[[
	Notifications: the server part (docs/framework/kits/notifications.md).

	Experience notifications that bring players back: an opt-in prompt at a good moment (never on
	join), templates in config, sends triggered by game events and a due list for future sends.
	  api: send, schedule, cancel, suggestOptIn, signals Sent / OptInPrompted / LaunchedFrom
	  actions (net.blink): optInShown(requestId, shown), setUtcOffset(hours)
	The sending, due list and ledger are ./Engine.luau (keyed by userId, so offline recipients work),
	the pure rules ./Templates, ./Ledger, ./Quiet, ./Sender, ./OptInRules (all required by the engine except OptInRules). Save section "notifications".

	The module is a factory (`new`) so each server part keeps its own state and a spec can swap the
	generated Blink events (`part.net`, set by the loader) for fakes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Engine = require(script.Engine)
local OptInRules = require(script.OptInRules)
local SignalTable = require(script.SignalTable)
local Templates = require(script.Templates)
local Streak =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Streak"):WaitForChild("module"))

local HOUR = 3600
local DAY = 86400
local STREAK_TEMPLATE = "streakEnding"

local Server = {}

local function serverId(): string
	local ok, id = pcall(function(): any
		return (game :: any).JobId
	end)
	if ok and type(id) == "string" and id ~= "" then
		return id
	end
	return string.format("srv%08x", math.random(1, 0x7fffffff))
end

function Server.new(): any
	local ctx: any = nil
	local engine: any = nil
	local templates: { [string]: Templates.Template } = {}
	local signals: any = SignalTable.new()
	local online: { [number]: any } = {} -- userId -> player, loaded on this server
	local joinedAt: { [any]: number } = {}
	local promptedThisSession: { [any]: boolean } = {}
	local requestCounter = 0
	local part: any = {}

	local function section(player: any): any
		if ctx.data.isLoaded(player) then
			return ctx.data.get(player)
		end
		return nil
	end

	local function offsetOf(userId: number): number?
		local player = online[userId]
		local s = if player then section(player) else nil
		return if s ~= nil and type(s.utcOffset) == "number" then s.utcOffset else nil
	end

	local function analytics(userId: number, name: string, category: string?, reason: string?)
		local player = online[userId]
		if player == nil then
			return -- Analytics needs a player on this server; logs carry the rest
		end
		local fields: { [string]: string } = {}
		if category then
			fields.category = category
		end
		if reason then
			fields.reason = reason
		end
		pcall(ctx.analytics.custom, player, name, 1, fields)
	end

	--------------------------------------------------------------------------
	-- Opt-in
	--------------------------------------------------------------------------
	local function requestPrompt(player: any, viaSuggest: boolean): boolean
		if not engine.enabled() or part.net == nil or part.net.PromptOptIn == nil then
			return false
		end
		local s = section(player)
		local joined = joinedAt[player]
		if s == nil or joined == nil then
			return false
		end
		local now = ctx.now()
		local pending = if type(s.promptRequest) == "table" and type(s.promptRequest.at) == "number"
			then s.promptRequest.at
			else nil
		local allowed = OptInRules.check(ctx.config.optIn, {
			now = now,
			joinedAt = joined,
			sessions = tonumber(s.sessions) or 0,
			prompts = tonumber(s.prompts) or 0,
			lastPromptAt = tonumber(s.lastPromptAt) or 0,
			pendingAt = pending,
			promptedThisSession = promptedThisSession[player] == true,
		}, viaSuggest)
		if not allowed then
			return false
		end
		requestCounter += 1
		local id = string.format("%d-%d", math.floor(now), requestCounter)
		if
			not ctx.data.update(player, function(sec: any)
				sec.promptRequest = { id = id, at = now }
			end)
		then
			return false
		end
		promptedThisSession[player] = true
		ctx.net.fire(player, part.net.PromptOptIn, id)
		return true
	end

	local function onOptInShown(player: any, requestId: any, shown: any)
		if type(requestId) ~= "string" or type(shown) ~= "boolean" or not ctx.data.isLoaded(player) then
			return
		end
		local s = ctx.data.get(player)
		local req = s.promptRequest
		if type(req) ~= "table" or req.id ~= requestId then
			return -- not the request this player was sent: ignored
		end
		local now = ctx.now()
		ctx.data.update(player, function(sec: any)
			sec.promptRequest = nil
			sec.lastPromptAt = now -- also when Roblox didn't show it: the next check waits cooldownDays
			if shown then
				sec.prompts = (tonumber(sec.prompts) or 0) + 1
			end
		end)
		if shown then
			signals.OptInPrompted:Fire(player)
			analytics(player.UserId, "NotificationPrompted", nil, nil)
		end
	end

	local function onSetUtcOffset(player: any, hours: any)
		if type(hours) ~= "number" or hours ~= hours or hours < -14 or hours > 14 then
			return
		end
		local rounded = math.floor(hours * 4 + 0.5) / 4
		ctx.data.update(player, function(sec: any)
			sec.utcOffset = rounded
		end)
	end

	--------------------------------------------------------------------------
	-- Join and leave
	--------------------------------------------------------------------------
	local function readLaunchData(player: any): string?
		local ok, joinData = pcall(function(): any
			return player:GetJoinData()
		end)
		if not ok or type(joinData) ~= "table" then
			return nil
		end
		return Templates.parseLaunchData(joinData.LaunchData, function(key: string): boolean
			return templates[key] ~= nil
		end)
	end

	local function onLoaded(player: any)
		local userId: number = player.UserId
		online[userId] = player
		local now = ctx.now()
		joinedAt[player] = now
		local launched = readLaunchData(player)
		local today = now // DAY
		local countLaunch = false
		ctx.data.update(player, function(sec: any)
			sec.sessions = (tonumber(sec.sessions) or 0) + 1
			if launched ~= nil and (tonumber(sec.lastLaunchDay) or 0) ~= today then
				sec.lastLaunchDay = today
				countLaunch = true
			end
		end)
		if launched ~= nil then
			signals.LaunchedFrom:Fire(player, launched)
			if countLaunch then
				analytics(userId, "NotificationJoin", templates[launched].category, nil)
			end
		end
		if engine.enabled() then
			task.spawn(function()
				engine.cancelWhere(userId, function(key: string): boolean
					local tpl = templates[key]
					return tpl ~= nil and tpl.cancelOnJoin
				end)
			end)
		end
	end

	-- Streak: a reminder shortly before the streak would end. Skipped quietly when it is too late.
	local function scheduleStreakReminder(player: any)
		local tpl = templates[STREAK_TEMPLATE]
		if tpl == nil or not ctx.isEnabled(Streak) then
			return
		end
		local streak = ctx.deps[Streak]
		local ok, state, expiresAt = pcall(function(): (any, any)
			return streak.get(player), streak.expiresAt(player)
		end)
		if not ok or type(state) ~= "table" or type(expiresAt) ~= "number" then
			return
		end
		if (tonumber(state.day) or 0) < tpl.minStreak then
			return
		end
		local at = expiresAt - tpl.hoursBefore * HOUR
		if at <= ctx.now() then
			return -- the reminder time has passed: no false time pressure
		end
		local userId: number = player.UserId
		local offset = offsetOf(userId)
		task.spawn(function()
			engine.schedule(userId, tpl, at, {}, STREAK_TEMPLATE, offset)
		end)
	end

	local function onRemoving(player: any)
		pcall(scheduleStreakReminder, player)
		online[player.UserId] = nil
		joinedAt[player] = nil
		promptedThisSession[player] = nil
	end

	--------------------------------------------------------------------------
	-- API
	--------------------------------------------------------------------------
	local function validUser(userId: any): boolean
		return type(userId) == "number" and userId == userId and userId >= 1 and userId == math.floor(userId)
	end

	local function lookup(
		userId: any,
		templateKey: any,
		params: any
	): (Templates.Template?, { [string]: any }?, string?)
		if not validUser(userId) then
			return nil, nil, "bad_params"
		end
		if next(templates) == nil then
			return nil, nil, "disabled" -- no template configured: the module has nothing to send
		end
		local tpl = if type(templateKey) == "string" then templates[templateKey] else nil
		if tpl == nil then
			return nil, nil, "unknown_template"
		end
		local clean, why = Templates.checkParams(tpl, params)
		if clean == nil then
			return nil, nil, why
		end
		return tpl, clean, nil
	end

	local api: any = {}

	function api.send(userId: number, templateKey: string, params: any?): (boolean, string?)
		local tpl, clean, why = lookup(userId, templateKey, params)
		if tpl == nil or clean == nil then
			return false, why
		end
		return engine.send(userId, tpl, clean, nil)
	end

	function api.schedule(
		userId: number,
		templateKey: string,
		at: number,
		params: any?,
		key: string?
	): (boolean, string?)
		local tpl, clean, why = lookup(userId, templateKey, params)
		if tpl == nil or clean == nil then
			return false, why
		end
		if type(at) ~= "number" or at ~= at then
			return false, "bad_params"
		end
		if key ~= nil and not Templates.validKey(key) then
			return false, "bad_params"
		end
		local ok, reason = engine.schedule(userId, tpl, at, clean, key, nil)
		if ok and tpl.promptOnSchedule and online[userId] ~= nil then
			requestPrompt(online[userId], false)
		end
		return ok, reason
	end

	function api.cancel(userId: number, key: string): boolean
		if not validUser(userId) or not Templates.validKey(key) then
			return false
		end
		return engine.cancel(userId, key)
	end

	function api.suggestOptIn(player: any, _reason: string): boolean
		if type(player) ~= "table" or not ctx.data.isLoaded(player) then
			return false
		end
		return requestPrompt(player, true)
	end

	api.signals = signals

	part.api = api

	part.actions = {
		optInShown = {
			limit = { rate = 1, burst = 2 },
			handler = onOptInShown,
		},
		setUtcOffset = {
			limit = { rate = 0.1, burst = 1 },
			handler = onSetUtcOffset,
		},
	}

	function part.init(context: any)
		ctx = context
		local errors
		templates, errors = Templates.all(ctx.config.templates)
		for _, message in errors do
			ctx.log.warn(message .. ": the template is ignored")
		end
		signals.Sent = ctx.signals.new("Sent")
		signals.OptInPrompted = ctx.signals.new("OptInPrompted")
		signals.LaunchedFrom = ctx.signals.new("LaunchedFrom")
		engine = Engine.new(ctx, templates, {
			jobId = serverId(),
			offsetOf = offsetOf,
			onSent = function(userId: number, templateKey: string)
				signals.Sent:Fire(userId, templateKey)
				analytics(userId, "NotificationSent", templates[templateKey].category, nil)
			end,
			onFailed = function(userId: number, templateKey: string, reason: string)
				local tpl = templates[templateKey]
				ctx.log.info(`send of {templateKey} to {userId} ended: {reason}`)
				analytics(userId, "NotificationFailed", if tpl then tpl.category else nil, reason)
			end,
		})
		ctx.console.register("poll", function(): string
			if not ctx.isStudio then
				return "notifications poll is Studio-only"
			end
			engine.poll()
			return "polled one due shard"
		end, "notifications poll: read one due-list shard now (Studio)")
	end

	function part.start(_context: any)
		local cfg = ctx.config
		if ctx.isStudio and not cfg.sendInStudio then
			ctx.log.info("Studio: notifications are logged (would send <template> to <userId>), not sent")
		end
		-- (a missing secret or allow-list entry is logged once, on the first send or due entry that
		-- needs it: a game that lists the module but isn't set up yet boots without a warning)
		ctx.data.onLoaded(onLoaded)
		ctx.lifecycle.onPlayerRemoving(onRemoving)
		engine.startCursor(math.random(0, cfg.schedule.shards - 1))
		local nextPollAt = ctx.now() + math.random() * engine.pollInterval()
		ctx.lifecycle.onTick(1, function()
			local now = ctx.now()
			if now >= nextPollAt then
				nextPollAt = now + engine.pollInterval()
				task.spawn(engine.poll)
			end
		end)
	end

	return part
end

return Server
