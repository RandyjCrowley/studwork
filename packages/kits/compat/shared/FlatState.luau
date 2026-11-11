--!strict
--[[
	COMPAT (deleted in Phase 2). Client-side selector: the v1.2 flat ReplicatedState the v1.2
	framework client UI (Hud, Visibility, the mailbox badge, Core.Client.onMailbox) still reads,
	derived from the v1.3 replicated state (module-api.md §10):

	  { loaded, framework = { paidRandomRestricted, activeEvents, odds }, modules = { <Name> = { data, extra } } }
	  -> { loaded, data = <every module's data merged; the game module's as data.game[gameId]>,
	       ratePerSec, multiplier (Economy extra), paidRandomRestricted, activeEvents (framework),
	       plotName (Plot extra), odds (Rarity extra: the v1.2 disclosure map), mailbox (Mail extra) }

	A state that is already v1.2-shaped (no `modules`: a scaffold still booting through the v1.2
	Core facade until step 4b-IIb) passes through with the v1.2 defaults filled in.
	Game UI should read module slices instead (StudWork.use(Economy).state()); this exists only so
	the v1.2 HUD keeps working until Phase 1 (agent D) moves it onto module slices.

	FlatState.flatten(raw, gameModuleName?, gameId?) -> v1.2 ReplicatedState
]]

local FlatState = {}

local function withDefaults(s: { [string]: any }): { [string]: any }
	if s.ratePerSec == nil then
		s.ratePerSec = 0
	end
	if s.multiplier == nil then
		s.multiplier = 1
	end
	if s.paidRandomRestricted == nil then
		s.paidRandomRestricted = true
	end
	if s.activeEvents == nil then
		s.activeEvents = {}
	end
	s.loaded = s.loaded == true
	return s
end

-- v1.2 PlayerData fields the client can see, with their v1.2 defaults (a disabled module's field)
local DATA_DEFAULTS: { [string]: () -> any } = {
	currency = function()
		return {}
	end,
	inventory = function()
		return {}
	end,
	displayed = function()
		return {}
	end,
	upgrades = function()
		return {}
	end,
	rebirths = function()
		return 0
	end,
	multipliers = function()
		return {}
	end,
	streak = function()
		return { day = 0, lastDay = 0 }
	end,
}

function FlatState.flatten(raw: any, gameModuleName: string?, gameId: string?): any
	if type(raw) ~= "table" then
		return withDefaults({})
	end
	local modules = raw.modules
	if type(modules) ~= "table" then
		return withDefaults(table.clone(raw))
	end
	local fw = if type(raw.framework) == "table" then raw.framework else {}
	local function extra(name: string, key: string): any
		local m = modules[name]
		local e = if type(m) == "table" then m.extra else nil
		return if type(e) == "table" then e[key] else nil
	end
	local data: { [string]: any }? = nil
	if raw.loaded == true then
		local d: { [string]: any } = {}
		for name, m in modules do
			if type(m) == "table" and type(m.data) == "table" then
				if name == gameModuleName and gameId ~= nil then
					d.game = { [gameId] = m.data }
				else
					for k, v in m.data do
						d[k] = v
					end
				end
			end
		end
		for field, make in DATA_DEFAULTS do
			if d[field] == nil then
				d[field] = make()
			end
		end
		data = d
	end
	return withDefaults({
		loaded = raw.loaded == true,
		data = data,
		ratePerSec = extra("Economy", "ratePerSec"),
		multiplier = extra("Economy", "multiplier"),
		paidRandomRestricted = fw.paidRandomRestricted,
		activeEvents = fw.activeEvents,
		plotName = extra("Plot", "plotName"),
		odds = extra("Rarity", "odds"),
		mailbox = extra("Mail", "mailbox"),
	})
end

return FlatState
