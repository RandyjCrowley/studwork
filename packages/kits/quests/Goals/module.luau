--!strict
--[[
	Goals module definition (kit: quests, v1.8.0). The first-session goal chain and the next-goal
	pointer ("no tutorial wall, one arrow to the next goal"): a HUD pill, one world beam and an
	off-screen edge arrow toward the current goal, a game-supplied "what's next" after the chain, and
	one analytics funnel step per goal. Design: docs/framework/kits/quests.md ("Goals"). Server part
	../server, client part ../client (pill, pointer), shared ../shared (Types, Validate), net.blink
	(SkipGoals, AckGoal).

	Save section "goals" = { done = { [goalId] = true }, fin, hide, v }, version 1, not replicated
	(the client gets extra.goal). v = 0: never loaded with Goals; then the chainVersion it was last
	checked against. `sanitize` is config-free shape repair only (types; done cut at 20 entries;
	never errors); removed goal ids are dropped in the server part's onPlayerLoaded tx.

	Boots with no config at all: an empty chain, nothing shown.
	theme: colors.goalPointer (the beam colour, default #FFB547).

	config (GameConfig.config.Goals): flag, chain, chainVersion, skippable, nextSeconds,
	sourcePollSeconds, pointer (the page's table).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Types = require(script.Parent:WaitForChild("shared"):WaitForChild("Types"))

local function kit(name: string): any
	return require(Modules:WaitForChild(name):WaitForChild("module")) :: any
end

local Quests = kit("Quests")
local Economy = kit("Economy")
local Inventory = kit("Inventory")
local Rebirth = kit("Rebirth")
local Streak = kit("Streak")

local function default(): any
	return { done = {}, fin = false, hide = false, v = 0 }
end

-- Config-free shape repair, after migrations on every load. Never errors.
local function sanitize(section: any): any
	if type(section) ~= "table" then
		return default()
	end
	local out = default()
	if type(section.done) == "table" then
		local ids: { string } = {}
		for id, flag in section.done do
			if Types.validId(id) and flag == true then
				table.insert(ids, id)
			end
		end
		table.sort(ids)
		for i = 1, math.min(#ids, Types.MAX_GOALS) do
			out.done[ids[i]] = true
		end
	end
	out.fin = section.fin == true
	out.hide = section.hide == true
	local v = section.v
	if type(v) == "number" and v == v and v >= 0 and v ~= math.huge then
		out.v = math.floor(v)
	end
	return out
end

return StudWork.defineModule({
	name = "Goals",
	version = "1.0.0",
	framework = "^1.7.0",
	description = "First-session goal chain and the next-goal pointer: HUD pill, one beam, edge arrow (quests kit)",
	optional = { Quests, Economy, Inventory, Rebirth, Streak },
	config = {
		schema = {
			flag = "string?",
			chain = "{table}",
			chainVersion = "integer(1..)",
			skippable = "boolean",
			nextSeconds = "number(1..60)",
			sourcePollSeconds = "number(1..60)",
			pointer = {
				beam = "boolean",
				edgeArrow = "boolean",
				updateSeconds = "number(0.05..1)",
				nearStuds = "number(0..)",
				maxStuds = "number(0..)",
			},
		},
		defaults = {
			chain = {},
			chainVersion = 1,
			skippable = true,
			nextSeconds = 5,
			sourcePollSeconds = 5,
			pointer = { beam = true, edgeArrow = true, updateSeconds = 0.1, nearStuds = 8, maxStuds = 2000 },
		},
	},
	data = {
		key = "goals",
		version = 1,
		default = default(),
		replicate = false,
		sanitize = sanitize,
	},
	theme = {
		colors = { goalPointer = "#FFB547" },
	},
	-- English defaults: hide/show, and from config Goals.goal.<id> = the id
	strings = function(config: any): { [string]: string }
		local out: { [string]: string } = { ["Goals.hide"] = "Hide goals", ["Goals.show"] = "Show goals" }
		local chain = if type(config) == "table" then config.chain else nil
		if type(chain) == "table" then
			for _, goal in chain do
				if type(goal) == "table" and Types.validId(goal.id) then
					out["Goals.goal." .. goal.id] = goal.id
				end
			end
		end
		return out
	end,
	client = "Goals",
})
