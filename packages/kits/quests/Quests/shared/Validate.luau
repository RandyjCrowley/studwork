--!strict
--[[
	Quests: config validation and defaults (pure; docs/framework/kits/quests.md, "Config validation").

	  Validate.SOURCES                      the built-in sources: { [name] = { mode, needs, param? } }
	  Validate.resolve(id, raw, cfg) -> Quest
	      one config entry with its defaults filled in (never errors; garbage fields keep defaults)
	  Validate.defs(cfg) -> { [questId]: Quest }
	      every entry with a valid id, resolved and deep-frozen (what `Quests.def(id)` returns)
	  Validate.check(cfg, env) -> { string }
	      every problem, each naming the quest, chain or key, sorted; {} = valid. The server part
	      runs it in `start` (after every module's init, so the extensions are in) and throws them
	      together. env (all optional):
	        enabled: { [moduleName]: boolean }      modules enabled in this game
	        sources: { [name]: any }                registered value sources (registerSource)
	        rewards: { [handler]: any }             registered reward handlers (registerReward)
	        itemKnown: (itemId) -> boolean          Items.get(id) ~= nil (called only with Items on)
	        oddsDetail: (tableId) -> any?           Rarity.getOddsDetail(tableId, nil, 1) (Rarity on)
	        events: { [eventId]: any }              ctx.gameConfig.events

	With no config at all (every default) `check` returns {}: an empty pool deals nothing, so
	`count` is compared only with a non-empty pool.
]]

local Types = require(script.Parent.Types)

local Validate = {}

export type Env = {
	enabled: { [string]: boolean }?,
	sources: { [string]: any }?,
	rewards: { [string]: any }?,
	itemKnown: ((string) -> boolean)?,
	oddsDetail: ((string) -> any?)?,
	events: { [string]: any }?,
}

export type SourceInfo = { mode: "add" | "value", needs: { string }, param: string? }

local SOURCES: { [string]: SourceInfo } = {
	currencyEarned = { mode = "add", needs = { "Economy" } },
	itemCollected = { mode = "add", needs = { "Inventory" } },
	rebirthDone = { mode = "add", needs = { "Rebirth" } },
	currency = { mode = "value", needs = { "Economy" } },
	rebirths = { mode = "value", needs = { "Rebirth" } },
	streakDay = { mode = "value", needs = { "Streak" } },
	itemOwned = { mode = "value", needs = { "Inventory" }, param = "item" },
	leaderboardRank = { mode = "value", needs = { "Leaderboards" }, param = "board" },
}
for _, info in SOURCES do
	table.freeze(info.needs)
	table.freeze(info)
end
Validate.SOURCES = table.freeze(SOURCES)

local REWARD_NEEDS: { [string]: { string } } = {
	currency = { "Economy" },
	item = { "Inventory" },
	roll = { "Rarity", "Inventory" },
	custom = {},
}

local TARGET_MAX = 1e9
local ID_RULE = "^[%w_]{1,32}$"

local function isInt(v: any, lo: number, hi: number): boolean
	return type(v) == "number" and v == v and v == math.floor(v) and v >= lo and v <= hi
end

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function sortedKeys(t: any): { string }
	local out: { string } = {}
	if type(t) == "table" then
		for k in t do
			if type(k) == "string" then
				table.insert(out, k)
			end
		end
	end
	table.sort(out)
	return out
end

local function isList(t: any): boolean
	if type(t) ~= "table" then
		return false
	end
	local n = 0
	for _ in t do
		n += 1
	end
	return n == #t
end

local function deepFreeze(v: any): any
	if type(v) ~= "table" or table.isfrozen(v) then
		return v
	end
	for _, child in v do
		deepFreeze(child)
	end
	return table.freeze(v)
end

local function deepCopy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, child in v do
		out[k] = deepCopy(child)
	end
	return out
end

local function hasAck(objectives: any): boolean
	if type(objectives) ~= "table" then
		return false
	end
	for _, o in objectives do
		if type(o) == "table" and o.kind == "ack" then
			return true
		end
	end
	return false
end

-- One config entry with defaults filled in (a fresh, unfrozen table).
function Validate.resolve(id: string, raw: any, cfg: any): Types.Quest
	local q = if type(raw) == "table" then raw else {}
	local globalAuto = type(cfg) == "table" and cfg.autoClaim == true
	local objectives = if type(q.objectives) == "table" then deepCopy(q.objectives) else {}
	local auto: boolean
	if type(q.autoClaim) == "boolean" then
		auto = q.autoClaim
	else
		auto = globalAuto and not hasAck(objectives) -- quests with an ack objective are never auto-claimed
	end
	return {
		id = id,
		kind = q.kind,
		objectives = objectives,
		reward = if type(q.reward) == "table" then deepCopy(q.reward) else {},
		title = if type(q.title) == "string" then q.title else "Quests.quest." .. id,
		text = if type(q.text) == "string" then q.text else nil,
		weight = if q.weight ~= nil then q.weight else 1,
		requires = if type(q.requires) == "table" then deepCopy(q.requires) else nil,
		cap = if q.cap ~= nil then q.cap else 1,
		period = if q.period ~= nil then q.period else "daily",
		event = q.event,
		offer = if q.offer ~= nil then q.offer else "auto",
		autoClaim = auto,
		retired = q.retired == true,
		funnel = if type(q.funnel) == "string" then q.funnel else nil,
	} :: any
end

function Validate.defs(cfg: any): { [string]: Types.Quest }
	local out: { [string]: Types.Quest } = {}
	local quests = if type(cfg) == "table" then cfg.quests else nil
	for _, id in sortedKeys(quests) do
		if Types.validId(id) then
			out[id] = deepFreeze(Validate.resolve(id, quests[id], cfg))
		end
	end
	return table.freeze(out)
end

--------------------------------------------------------------------------------
-- check
--------------------------------------------------------------------------------

local function checkObjective(
	where: string,
	o: any,
	env: Env,
	enabled: { [string]: boolean },
	add: (string) -> ()
)
	if type(o) ~= "table" then
		add(`{where}: must be a table`)
		return
	end
	local kind = o.kind
	if table.find(Types.OBJECTIVE_KINDS, kind) == nil then
		add(`{where}: unknown kind '{tostring(kind)}' (counter, source, threshold, ack)`)
		return
	end
	if o.label ~= nil and type(o.label) ~= "string" then
		add(`{where}: label must be a string key`)
	end
	if kind == "counter" or kind == "ack" then
		if not Types.validId(o.key) then
			add(`{where}: key '{tostring(o.key)}' must match {ID_RULE}`)
		end
	end
	if kind ~= "ack" and not isInt(o.target, 1, TARGET_MAX) then
		add(`{where}: target must be an integer 1..1e9`)
	end
	if kind == "source" or kind == "threshold" then
		local name = o.source
		if type(name) ~= "string" then
			add(`{where}: source must be a string`)
			return
		end
		if o.params ~= nil and type(o.params) ~= "table" then
			add(`{where}: params must be a table`)
		end
		local params = if type(o.params) == "table" then o.params else {}
		local builtin = Validate.SOURCES[name]
		local registered = env.sources ~= nil and env.sources[name] ~= nil
		local mode: string
		if builtin then
			mode = builtin.mode
			for _, need in builtin.needs do
				if not enabled[need] then
					add(`{where}: source '{name}' needs {need} (add it to GameConfig.modules)`)
				end
			end
			if name == "itemCollected" and params.rarity ~= nil and not enabled.Items then
				add(
					`{where}: source 'itemCollected' with params.rarity needs Items (add it to GameConfig.modules)`
				)
			end
			if builtin.param ~= nil and type(params[builtin.param]) ~= "string" then
				add(`{where}: source '{name}' needs params.{builtin.param}`)
			end
		elseif registered then
			mode = "value" -- registerSource adds value sources only
		else
			add(`{where}: unknown source '{name}' (neither built in nor registered with registerSource)`)
			return
		end
		if kind == "threshold" and mode == "add" then
			add(
				`{where}: a threshold objective needs a value source; '{name}' is an add source (use kind = "source")`
			)
		elseif kind == "source" and mode == "value" then
			add(
				`{where}: a source objective needs an add source; '{name}' is a value source (use kind = "threshold")`
			)
		end
	end
end

local function checkReward(
	where: string,
	r: any,
	env: Env,
	enabled: { [string]: boolean },
	add: (string) -> ()
)
	if type(r) ~= "table" then
		add(`{where}: must be a table`)
		return
	end
	local kind = r.kind
	local needs = REWARD_NEEDS[kind]
	if needs == nil then
		add(`{where}: unknown kind '{tostring(kind)}' (currency, item, roll, custom)`)
		return
	end
	local missing = false
	for _, need in needs do
		if not enabled[need] then
			missing = true
			add(`{where}: a {kind} reward needs {need} (add it to GameConfig.modules)`)
		end
	end
	if kind == "currency" then
		if not isInt(r.amount, 1, math.huge) then
			add(`{where}: amount must be an integer >= 1`)
		end
		if r.currency ~= nil and type(r.currency) ~= "string" then
			add(`{where}: currency must be a string`)
		end
	elseif kind == "item" then
		if type(r.item) ~= "string" then
			add(`{where}: item must be an item id`)
		elseif not missing and env.itemKnown ~= nil and not env.itemKnown(r.item) then
			add(`{where}: unknown item '{r.item}' (not in GameConfig.items)`)
		end
		if r.count ~= nil and not isInt(r.count, 1, 10) then
			add(`{where}: count must be an integer 1..10`)
		end
	elseif kind == "roll" then
		if type(r.table) ~= "string" then
			add(`{where}: table must be a Rarity table id`)
		elseif not missing and env.oddsDetail ~= nil then
			local ok, detail = pcall(env.oddsDetail, r.table)
			if not ok or detail == nil then
				add(`{where}: unknown roll table '{r.table}' (Rarity.getOddsDetail returned nil)`)
			elseif type(detail) == "table" and detail.paid == true then
				add(
					`{where}: roll table '{r.table}' is paid; quest rolls must come from a free table (no paid = true, no cost in a paid currency)`
				)
			end
		end
	elseif kind == "custom" then
		if type(r.handler) ~= "string" then
			add(`{where}: handler must be a string`)
		elseif env.rewards == nil or env.rewards[r.handler] == nil then
			add(`{where}: reward handler '{r.handler}' is not registered (registerReward during init)`)
		end
		if r.params ~= nil and type(r.params) ~= "table" then
			add(`{where}: params must be a table`)
		end
	end
end

function Validate.check(cfg: any, env: Env?): { string }
	local e: Env = env or {}
	local enabled: { [string]: boolean } = e.enabled or {}
	local events = e.events or {}
	local errors: { string } = {}
	local function add(message: string)
		table.insert(errors, message)
	end
	if type(cfg) ~= "table" then
		return { "config.Quests must be a table" }
	end
	local quests = if type(cfg.quests) == "table" then cfg.quests else {}
	local chains = if type(cfg.chains) == "table" then cfg.chains else {}

	-- quests
	for _, id in sortedKeys(quests) do
		local raw = quests[id]
		local where = `quest '{id}'`
		if not Types.validId(id) then
			add(`{where}: bad id (must match {ID_RULE})`)
			continue
		end
		if type(raw) ~= "table" then
			add(`{where}: must be a table`)
			continue
		end
		local kind = raw.kind
		if table.find(Types.QUEST_KINDS, kind) == nil then
			add(`{where}: unknown kind '{tostring(kind)}' (daily, weekly, chain, oneTime, repeatable, event)`)
		end
		-- objectives
		local objectives = raw.objectives
		if not isList(objectives) or #objectives == 0 or #objectives > Types.MAX_OBJECTIVES then
			add(`{where}: needs 1..4 objectives`)
		else
			local acks = 0
			for i, o in objectives do
				checkObjective(`{where} objective {i}`, o, e, enabled, add)
				if type(o) == "table" and o.kind == "ack" then
					acks += 1
				end
			end
			if acks == #objectives then
				add(`{where}: every objective is an ack (an acknowledge can't complete a quest on its own)`)
			end
			if acks > 0 and raw.autoClaim == true then
				add(`{where}: autoClaim = true on a quest with an ack objective (never auto-claimed)`)
			end
		end
		-- rewards
		if raw.reward ~= nil then
			if not isList(raw.reward) or #raw.reward > Types.MAX_REWARDS then
				add(`{where}: reward must be a list of 0..4 rewards`)
			else
				for i, r in raw.reward do
					checkReward(`{where} reward {i}`, r, e, enabled, add)
				end
			end
		end
		-- fields
		if raw.title ~= nil and type(raw.title) ~= "string" then
			add(`{where}: title must be a string key`)
		end
		if raw.text ~= nil and type(raw.text) ~= "string" then
			add(`{where}: text must be a string key`)
		end
		if raw.funnel ~= nil and type(raw.funnel) ~= "string" then
			add(`{where}: funnel must be a string`)
		end
		if raw.retired ~= nil and type(raw.retired) ~= "boolean" then
			add(`{where}: retired must be a boolean`)
		end
		if raw.autoClaim ~= nil and type(raw.autoClaim) ~= "boolean" then
			add(`{where}: autoClaim must be a boolean`)
		end
		if raw.weight ~= nil and (not finite(raw.weight) or raw.weight <= 0) then
			add(`{where}: weight must be a finite number > 0`)
		end
		if raw.cap ~= nil and not isInt(raw.cap, 1, 100) then
			add(`{where}: cap must be an integer 1..100`)
		end
		if raw.period ~= nil and raw.period ~= "daily" and raw.period ~= "weekly" then
			add(`{where}: period must be "daily" or "weekly"`)
		end
		if raw.offer ~= nil and raw.offer ~= "auto" and raw.offer ~= "grant" then
			add(`{where}: offer must be "auto" or "grant"`)
		end
		if kind == "event" then
			if type(raw.event) ~= "string" then
				add(`{where}: an event quest needs event = <an id in GameConfig.events>`)
			elseif events[raw.event] == nil then
				add(`{where}: event '{raw.event}' is not in GameConfig.events`)
			end
		end
		-- requires
		local req = raw.requires
		if req ~= nil then
			if type(req) ~= "table" then
				add(`{where}: requires must be a table`)
			else
				if req.quests ~= nil then
					if not isList(req.quests) then
						add(`{where}: requires.quests must be a list of quest ids`)
					else
						for _, other in req.quests do
							if other == id then
								add(`{where}: requires itself`)
							elseif type(other) ~= "string" or type(quests[other]) ~= "table" then
								add(`{where}: requires unknown quest '{tostring(other)}'`)
							end
						end
					end
				end
				if req.rebirths ~= nil then
					if not finite(req.rebirths) then
						add(`{where}: requires.rebirths must be a number`)
					elseif not enabled.Rebirth then
						add(`{where}: requires.rebirths needs Rebirth (add it to GameConfig.modules)`)
					end
				end
				if req.items ~= nil then
					if not isList(req.items) then
						add(`{where}: requires.items must be a list of item ids`)
					elseif not enabled.Inventory then
						add(`{where}: requires.items needs Inventory (add it to GameConfig.modules)`)
					else
						for _, item in req.items do
							if type(item) ~= "string" or (e.itemKnown ~= nil and not e.itemKnown(item)) then
								add(`{where}: requires unknown item '{tostring(item)}'`)
							end
						end
					end
				end
			end
		end
	end

	-- requirement cycles (quests -> requires.quests), reported once per cycle start
	local state: { [string]: number } = {} -- 1 visiting, 2 done
	local reported: { [string]: boolean } = {}
	local function visit(id: string, path: { string })
		state[id] = 1
		table.insert(path, id)
		local raw = quests[id]
		local req = if type(raw) == "table" and type(raw.requires) == "table"
			then raw.requires.quests
			else nil
		if isList(req) then
			for _, other in req do
				if type(other) == "string" and other ~= id and type(quests[other]) == "table" then
					if state[other] == 1 then
						local at = table.find(path, other) or 1
						local cycle = table.move(path, at, #path, 1, {})
						table.insert(cycle, other)
						local key = table.concat(cycle, ">")
						if not reported[key] then
							reported[key] = true
							add(`quest '{other}': requirement cycle {table.concat(cycle, " -> ")}`)
						end
					elseif state[other] == nil then
						visit(other, path)
					end
				end
			end
		end
		table.remove(path)
		state[id] = 2
	end
	for _, id in sortedKeys(quests) do
		if state[id] == nil then
			visit(id, {})
		end
	end

	-- chains
	local inChain: { [string]: { string } } = {}
	for _, chainId in sortedKeys(chains) do
		local steps = chains[chainId]
		local where = `chain '{chainId}'`
		if not Types.validId(chainId) then
			add(`{where}: bad id (must match {ID_RULE})`)
		end
		if not isList(steps) or #steps == 0 then
			add(`{where}: is empty (needs at least one step)`)
			continue
		end
		local seen: { [string]: boolean } = {}
		for i, step in steps do
			if type(step) ~= "string" or type(quests[step]) ~= "table" then
				add(`{where} step {i}: '{tostring(step)}' is not a quest`)
				continue
			end
			if seen[step] then
				add(`{where}: step '{step}' is listed twice`)
				continue
			end
			seen[step] = true
			if quests[step].kind ~= "chain" then
				add(`{where} step {i}: quest '{step}' has kind '{tostring(quests[step].kind)}', not "chain"`)
			end
			inChain[step] = inChain[step] or {}
			table.insert(inChain[step], chainId)
		end
	end
	for _, id in sortedKeys(quests) do
		local raw = quests[id]
		if type(raw) == "table" and raw.kind == "chain" then
			local list = inChain[id]
			if list == nil then
				add(`quest '{id}': a chain quest in no chain (list it in config.chains)`)
			elseif #list > 1 then
				add(`quest '{id}': a chain quest in two chains ({table.concat(list, ", ")})`)
			end
		end
	end

	-- counts against non-empty pools
	for _, kind in { "daily", "weekly" } do
		local pool = 0
		for _, raw in quests do
			if type(raw) == "table" and raw.kind == kind and raw.retired ~= true then
				pool += 1
			end
		end
		local section = cfg[kind]
		local count = if type(section) == "table" then section.count else nil
		if pool > 0 and type(count) == "number" and count > pool then
			add(`{kind}.count {count} is larger than the {kind} pool ({pool} non-retired quests)`)
		end
	end

	table.sort(errors)
	return errors
end

return Validate
