--!nocheck
--[[
	Quests server spec helpers (Lune only; packages/kits/quests/tests/, not synced by Rojo).

	  K.boot(opts?) -> (h, p, q)       a harness with Quests (+ opts.modules) and one loaded player
	      opts = { quests = config.Quests (default F.questsConfig()), config = { other sections },
	               modules = { refs }, probes, events (default F.events()), items, store,
	               startTime, isStudio, flags, userId (default 1), data, analytics }
	  K.harness(opts?) -> h            the same harness without a player
	  K.saveWith(section, opts?) -> save   a stored save whose `quests` section is `section`
	      (booted once with opts.modules so every other section is well-formed)
	  K.ids(q, p, kind?) -> { questId }    the active ids (of one kind), board order
	  K.slots(h, p, kind) -> { questId }   the saved slot ids ("day" / "week")
	  K.section(h, p) -> the stored quests section (after a save)
	  K.count(list, fn) -> number
	  K.ref(name) -> a kit module's definition
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Modules = ReplicatedStorage:WaitForChild("Modules")
local F = require("packages/kits/quests/tests/Fixtures.luau")

local K = {}
K.F = F
K.Quests = F.Quests

function K.ref(name: string)
	return require(Modules:WaitForChild(name):WaitForChild("module"))
end

function K.harness(opts)
	local o = opts or {}
	local modules = { F.Quests }
	for _, ref in o.modules or {} do
		table.insert(modules, ref)
	end
	local config = table.clone(o.config or {})
	config.Quests = o.quests or F.questsConfig()
	return F.harness({
		modules = modules,
		probes = o.probes,
		config = config,
		events = if o.events == false then nil else (o.events or F.events()),
		items = o.items,
		store = o.store,
		startTime = o.startTime,
		isStudio = o.isStudio,
		flags = o.flags,
		analytics = o.analytics,
		compliance = o.compliance,
		services = o.services,
		env = o.env,
	})
end

function K.boot(opts)
	local o = opts or {}
	local h = K.harness(o)
	local p = h:addPlayer({ userId = o.userId or 1, data = o.data })
	return h, p, h:use(F.Quests)
end

function K.saveWith(section, opts)
	local o = table.clone(opts or {})
	o.store = StudWork.test.memoryStore()
	local h = K.harness(o)
	local p = h:addPlayer({ userId = o.userId or 1 })
	h:removePlayer(p)
	local save = h:saved(p)
	save.quests = section
	return save
end

function K.ids(q, p, kind)
	local out = {}
	for _, v in q.active(p) do
		if kind == nil or v.kind == kind then
			table.insert(out, v.id)
		end
	end
	return out
end

function K.slotIds(set)
	local out = {}
	for _, slot in set.slots do
		table.insert(out, slot.q)
	end
	return out
end

function K.section(h, p)
	return h:saved(p).quests
end

function K.count(list, fn)
	local n = 0
	for _, v in list do
		if fn == nil or fn(v) then
			n += 1
		end
	end
	return n
end

-- the first active slot quest of a kind and its counter key (from the config)
function K.slotQuest(q, p, kind, slot)
	for _, v in q.active(p) do
		if v.kind == kind and v.slot == (slot or 1) and not v.waiting then
			return v.id, q.def(v.id).objectives[1].key, q.def(v.id).objectives[1].target
		end
	end
	return nil
end

return K
