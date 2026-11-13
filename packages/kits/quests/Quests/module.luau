--!strict
--[[
	Quests module definition (kit: quests, v1.8.0). Config-defined quests (daily, weekly, story
	chains, one-time, repeatable, event), progressed only by the server, claimed exactly once inside
	one framework transaction, with a quest board, a HUD tracker and claim toasts.
	Design: docs/framework/kits/quests.md. Server part ../server, client part ../client, shared pure
	rules ../shared (Types, Period, Validate, Deal), net.blink (ClaimQuest, RerollQuest, PinQuest,
	AckQuest).

	Save section "quests" = { day, week, prog, done, waiting, pins, granted }, version 1, not
	replicated (the client gets extra.board / extra.prog / extra.questOdds). `sanitize` is config-free
	shape repair only and never errors (wrong types reset, malformed entries dropped, lists cut at the
	hard maxima: slots 6, objective values 4, waiting 12, pins 5); removed quest ids are pruned in the
	server part's first tx on load. `done` (the claim ledger) is never pruned.

	Both boot with no config at all: no quests, no deal, an empty board.

	config (GameConfig.config.Quests): flag, quests, chains, daily, weekly, poolVersion,
	utcOffsetHours, weekStartsOn, autoClaim, waitingMax, pinMax, foldSeconds, replicateSeconds,
	sourcePollSeconds, rotatePerTick, maxAmount (the page's table; every number is config).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Types = require(script.Parent:WaitForChild("shared"):WaitForChild("Types"))

local function kit(name: string): any
	return require(Modules:WaitForChild(name):WaitForChild("module")) :: any
end

local Economy = kit("Economy")
local Items = kit("Items")
local Inventory = kit("Inventory")
local Rarity = kit("Rarity")
local Rebirth = kit("Rebirth")
local Streak = kit("Streak")
local Leaderboards = kit("Leaderboards")

local MAX_SLOTS = Types.MAX_SLOTS
local MAX_VALUES = Types.MAX_VALUES
local MAX_WAITING = Types.MAX_WAITING
local MAX_PINS = Types.MAX_PINS

local function emptySet(): any
	return { id = -1, slots = {}, seen = {} }
end

local function default(): any
	return { day = emptySet(), week = emptySet(), prog = {}, done = {}, waiting = {}, pins = {}, granted = {} }
end

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- objective values: up to 4 finite numbers >= 0, floored
local function values(raw: any): { number }
	local out: { number } = {}
	if type(raw) ~= "table" then
		return out
	end
	for i = 1, MAX_VALUES do
		local v = raw[i]
		if v == nil then
			break
		end
		table.insert(out, if finite(v) and v > 0 then math.floor(v) else 0)
	end
	return out
end

local function status(v: any): number
	return if v == 1 or v == 2 then v else 0
end

local function slotSet(raw: any): any
	local out = emptySet()
	if type(raw) ~= "table" then
		return out
	end
	if finite(raw.id) then
		out.id = math.floor(raw.id)
	end
	if type(raw.slots) == "table" then
		for _, slot in ipairs(raw.slots) do
			if #out.slots >= MAX_SLOTS then
				break
			end
			if type(slot) == "table" and Types.validId(slot.q) then
				table.insert(out.slots, {
					q = slot.q,
					n = values(slot.n),
					s = status(slot.s),
					r = if finite(slot.r) and slot.r > 0 then math.floor(slot.r) else 0,
				})
			end
		end
	end
	if type(raw.seen) == "table" then
		for id, flag in raw.seen do
			if Types.validId(id) and type(flag) == "boolean" then
				out.seen[id] = flag
			end
		end
	end
	return out
end

-- Config-free shape repair, after migrations on every load. Never errors.
local function sanitize(section: any): any
	if type(section) ~= "table" then
		return default()
	end
	local out = default()
	out.day = slotSet(section.day)
	out.week = slotSet(section.week)
	if type(section.prog) == "table" then
		for id, p in section.prog do
			if Types.validId(id) and type(p) == "table" then
				out.prog[id] = {
					n = values(p.n),
					s = status(p.s),
					p = if finite(p.p) then p.p else nil,
					k = if finite(p.k) and p.k > 0 then math.floor(p.k) else nil,
				}
			end
		end
	end
	if type(section.done) == "table" then
		for id, at in section.done do
			if Types.validId(id) and at ~= nil and at ~= false then
				-- the claim ledger: a malformed timestamp keeps the claim (0), never drops it
				out.done[id] = if finite(at) then at else 0
			end
		end
	end
	if type(section.waiting) == "table" then
		local kept = {}
		for _, w in ipairs(section.waiting) do
			if
				type(w) == "table"
				and Types.validId(w.q)
				and (w.k == "daily" or w.k == "weekly" or w.k == "event")
				and finite(w.p)
			then
				table.insert(kept, { q = w.q, k = w.k, p = w.p })
			end
		end
		-- oldest first: keep the newest MAX_WAITING
		local from = math.max(1, #kept - MAX_WAITING + 1)
		for i = from, #kept do
			table.insert(out.waiting, kept[i])
		end
	end
	if type(section.pins) == "table" then
		local seen: { [string]: boolean } = {}
		for _, id in ipairs(section.pins) do
			if #out.pins >= MAX_PINS then
				break
			end
			if Types.validId(id) and not seen[id] then
				seen[id] = true
				table.insert(out.pins, id)
			end
		end
	end
	if type(section.granted) == "table" then
		for id, flag in section.granted do
			if Types.validId(id) and flag == true then
				out.granted[id] = true
			end
		end
	end
	return out
end

local STRINGS: { [string]: string } = {
	["Quests.title"] = "Quests",
	["Quests.button"] = "Quests",
	["Quests.tab.daily"] = "Daily",
	["Quests.tab.weekly"] = "Weekly",
	["Quests.tab.chain"] = "Story",
	["Quests.tab.event"] = "Event",
	["Quests.tab.waiting"] = "Rewards waiting",
	["Quests.claim"] = "Claim",
	["Quests.claimed"] = "Claimed",
	["Quests.reroll"] = "Reroll",
	["Quests.rerollsLeft"] = "{n} free",
	["Quests.resetsIn"] = "Resets in {time}",
	["Quests.resetsInDays"] = "Resets in {days}d {hours}h",
	["Quests.pin"] = "Track",
	["Quests.unpin"] = "Untrack",
	["Quests.locked"] = "Locked",
	["Quests.capReached"] = "Come back later",
	["Quests.progress"] = "{value}/{target}",
	["Quests.odds"] = "Odds",
	["Quests.empty"] = "No quests right now",
	["Quests.toast.completed"] = "Quest complete: {title}",
	["Quests.toast.claimed"] = "Reward claimed: {title}",
	["Quests.reward.currency"] = "{amount} {currency}",
	["Quests.reward.item"] = "{item}",
	["Quests.reward.roll"] = "Roll: {table}",
	["Quests.reward.custom"] = "Reward",
	["Quests.objective.counter"] = "{key}",
	["Quests.objective.source"] = "{source}",
	["Quests.objective.threshold"] = "Reach {target} {source}",
	["Quests.objective.ack"] = "{key}",
}

return StudWork.defineModule({
	name = "Quests",
	version = "1.0.0",
	framework = "^1.7.0",
	description = "Daily, weekly, story, one-time, repeatable and event quests with exactly-once claims (quests kit)",
	optional = { Economy, Items, Inventory, Rarity, Rebirth, Streak, Leaderboards },
	config = {
		schema = {
			flag = "string?",
			quests = "{[string]: table}",
			chains = "{[string]: {string}}",
			daily = { count = "integer(0..6)", rerollsPerSlot = "integer(0..3)" },
			weekly = { count = "integer(0..6)", rerollsPerSlot = "integer(0..3)" },
			poolVersion = "integer(1..)",
			utcOffsetHours = "number(-14..14)",
			weekStartsOn = '"monday"|"sunday"',
			autoClaim = "boolean",
			waitingMax = "integer(0..12)",
			pinMax = "integer(0..5)",
			foldSeconds = "number(5..120)",
			replicateSeconds = "number(0.25..5)",
			sourcePollSeconds = "number(1..60)",
			rotatePerTick = "integer(1..100)",
			maxAmount = "number(1..)",
		},
		defaults = {
			quests = {},
			chains = {},
			daily = { count = 3, rerollsPerSlot = 1 },
			weekly = { count = 2, rerollsPerSlot = 0 },
			poolVersion = 1,
			utcOffsetHours = 0,
			weekStartsOn = "monday",
			autoClaim = false,
			waitingMax = 6,
			pinMax = 3,
			foldSeconds = 30,
			replicateSeconds = 1,
			sourcePollSeconds = 5,
			rotatePerTick = 10,
			maxAmount = 1000000,
		},
	},
	data = {
		key = "quests",
		version = 1,
		default = default(),
		replicate = false,
		sanitize = sanitize,
	},
	-- English defaults: the static keys, and from config Quests.quest.<id> = the id
	strings = function(config: any): { [string]: string }
		local out = table.clone(STRINGS)
		local quests = if type(config) == "table" then config.quests else nil
		if type(quests) == "table" then
			for id in quests do
				if Types.validId(id) then
					out["Quests.quest." .. id] = id
				end
			end
		end
		return out
	end,
	client = "Quests",
})
