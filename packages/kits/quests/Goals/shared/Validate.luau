--!strict
--[[
	Goals: chain validation (pure; docs/framework/kits/quests.md, Goals "Validation at boot").

	  Validate.SOURCES                          built-in value sources: { [name] = { needs, param? } }
	  Validate.check(chain, env) -> { string }  every problem, each naming the goal; {} = valid
	      env (all optional):
	        enabled: { [moduleName]: boolean }  modules enabled in this game
	        sources: { [name]: any }            registered value sources (registerSource)
	        questDef: (questId) -> Quest?       Quests.def (only called while Quests is enabled)
	  Validate.position(v) -> boolean           a position: { x, y, z } (array) or { x = , y = , z = } (named),
	                                            three finite numbers either way
	  Validate.toArray(v) -> { number }?        the array form of a valid position (nil when invalid); the
	                                            server puts this on the wire and the client's resolver reads it
	  Validate.warnings(chain, funnel) -> { string }
	                                            non-fatal problems: a goal whose `funnel` step is not in the
	                                            game's analytics funnel list (nil list = unknown: no warnings)

	The server part runs `check` in `start` (and in `setChain`) and throws the problems together.
	An empty chain is valid (Goals is idle).
]]

local Types = require(script.Parent.Types)

local Validate = {}

export type Env = {
	enabled: { [string]: boolean }?,
	sources: { [string]: any }?,
	questDef: ((string) -> any?)?,
}

local SOURCES: { [string]: { needs: string, param: string? } } = {
	currency = { needs = "Economy" },
	rebirths = { needs = "Rebirth" },
	streakDay = { needs = "Streak" },
	itemOwned = { needs = "Inventory", param = "item" },
}
for _, info in SOURCES do
	table.freeze(info)
end
Validate.SOURCES = table.freeze(SOURCES)

local ID_RULE = "^[%w_]{1,32}$"
local CHECK_FORMS = { "quest", "source", "call", "ack" }
local TARGET_FORMS = { "tag", "path", "position", "picker" }

local function finite(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function isArrayPosition(v: any): boolean
	return type(v) == "table" and finite(v[1]) and finite(v[2]) and finite(v[3])
end

local function isNamedPosition(v: any): boolean
	return type(v) == "table" and finite(v.x) and finite(v.y) and finite(v.z)
end

function Validate.position(v: any): boolean
	return isArrayPosition(v) or isNamedPosition(v)
end

function Validate.toArray(v: any): { number }?
	if isArrayPosition(v) then
		return { v[1], v[2], v[3] }
	elseif isNamedPosition(v) then
		return { v.x, v.y, v.z }
	end
	return nil
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

local function checkTarget(where: string, t: any, add: (string) -> ())
	if type(t) ~= "table" then
		add(`{where}: target must be a table (tag, path, position or picker)`)
		return
	end
	local forms = 0
	for _, f in TARGET_FORMS do
		if t[f] ~= nil then
			forms += 1
		end
	end
	if forms ~= 1 then
		add(`{where}: target must have exactly one of tag, path, position, picker`)
		return
	end
	if t.tag ~= nil and (type(t.tag) ~= "string" or t.tag == "") then
		add(`{where}: target.tag must be a CollectionService tag`)
	elseif t.path ~= nil and (type(t.path) ~= "string" or t.path == "") then
		add(`{where}: target.path must be a path like "Workspace.Map.Shop"`)
	elseif t.picker ~= nil and (type(t.picker) ~= "string" or t.picker == "") then
		add(`{where}: target.picker must be a picker name`)
	elseif t.position ~= nil and not Validate.position(t.position) then
		add(`{where}: target.position must be three numbers (x, y, z as an array or as named x, y, z)`)
	end
end

local function checkCheck(
	where: string,
	c: any,
	env: Env,
	enabled: { [string]: boolean },
	add: (string) -> ()
)
	if type(c) ~= "table" then
		add(`{where}: check must be a table`)
		return
	end
	local forms = 0
	for _, f in CHECK_FORMS do
		if c[f] ~= nil then
			forms += 1
		end
	end
	if forms ~= 1 then
		add(`{where}: check must be exactly one of quest, source, call, ack`)
		return
	end
	if c.quest ~= nil then
		if type(c.quest) ~= "string" then
			add(`{where}: check.quest must be a quest id`)
			return
		end
		if c.on ~= nil and c.objective ~= nil then
			add(`{where}: check has both on and objective (use one)`)
		end
		if c.on ~= nil and c.on ~= "complete" and c.on ~= "claimed" then
			add(`{where}: check.on must be "complete" or "claimed"`)
		end
		if not enabled.Quests then
			add(`{where}: a quest check needs Quests (add it to GameConfig.modules)`)
			return
		end
		local def = if env.questDef ~= nil then env.questDef(c.quest) else nil
		if def == nil then
			add(`{where}: Quests has no quest '{c.quest}'`)
			return
		end
		if c.objective ~= nil then
			local count = if type(def.objectives) == "table" then #def.objectives else 0
			if
				type(c.objective) ~= "number"
				or c.objective ~= math.floor(c.objective)
				or c.objective < 1
				or c.objective > count
			then
				add(`{where}: quest '{c.quest}' has no objective {tostring(c.objective)} (it has {count})`)
			end
		end
	elseif c.source ~= nil then
		local name = c.source
		if type(name) ~= "string" then
			add(`{where}: check.source must be a source name`)
			return
		end
		if not finite(c.atLeast) then
			add(`{where}: check.atLeast must be a finite number`)
		end
		if c.params ~= nil and type(c.params) ~= "table" then
			add(`{where}: check.params must be a table`)
		end
		local builtin = Validate.SOURCES[name]
		if builtin then
			if not enabled[builtin.needs] then
				add(`{where}: source '{name}' needs {builtin.needs} (add it to GameConfig.modules)`)
			end
			local params = if type(c.params) == "table" then c.params else {}
			if builtin.param ~= nil and type(params[builtin.param]) ~= "string" then
				add(`{where}: source '{name}' needs params.{builtin.param}`)
			end
		elseif env.sources == nil or env.sources[name] == nil then
			add(`{where}: unknown source '{name}' (neither built in nor registered with registerSource)`)
		end
	elseif c.call ~= nil then
		if c.call ~= true then
			add(`{where}: check.call must be true`)
		end
	elseif c.ack ~= nil then
		if c.ack ~= true then
			add(`{where}: check.ack must be true`)
		end
	end
end

function Validate.check(chain: any, env: Env?): { string }
	local e: Env = env or {}
	local enabled: { [string]: boolean } = e.enabled or {}
	local errors: { string } = {}
	local function add(message: string)
		table.insert(errors, message)
	end
	if chain == nil then
		return errors
	end
	if not isList(chain) then
		return { "chain must be a list of goals" }
	end
	if #chain > Types.MAX_GOALS then
		add(`chain has {#chain} goals (at most {Types.MAX_GOALS})`)
	end
	local seen: { [string]: boolean } = {}
	for i, g in chain do
		if type(g) ~= "table" then
			add(`goal {i}: must be a table`)
			continue
		end
		local where = if type(g.id) == "string" then `goal '{g.id}'` else `goal {i}`
		if not Types.validId(g.id) then
			add(`{where}: bad id (must match {ID_RULE})`)
		elseif seen[g.id] then
			add(`{where}: duplicate id`)
		else
			seen[g.id] = true
		end
		checkCheck(where, g.check, e, enabled, add)
		if g.target ~= nil then
			checkTarget(where, g.target, add)
		end
		if g.fallback ~= nil and not Validate.position(g.fallback) then
			add(`{where}: fallback must be three numbers (x, y, z as an array or as named x, y, z)`)
		end
		if g.text ~= nil and type(g.text) ~= "string" then
			add(`{where}: text must be a string key`)
		end
		if g.widget ~= nil and type(g.widget) ~= "string" then
			add(`{where}: widget must be a HUD widget id`)
		end
		if g.funnel ~= nil and type(g.funnel) ~= "string" then
			add(`{where}: funnel must be a string`)
		end
	end
	return errors
end

-- Non-fatal findings for a valid chain. `funnel` is GameConfig.analytics.funnel (nil when the caller
-- can't read it). The framework logs a funnel step only when it is in that list, so a goal naming
-- a step that isn't there would silently never log it.
function Validate.warnings(chain: any, funnel: { string }?): { string }
	local out: { string } = {}
	if funnel == nil or type(chain) ~= "table" then
		return out
	end
	local listed: { [string]: boolean } = {}
	for _, step in funnel do
		if type(step) == "string" then
			listed[step] = true
		end
	end
	for i, g in chain do
		if type(g) == "table" and type(g.funnel) == "string" and not listed[g.funnel] then
			local where = if type(g.id) == "string" then `goal '{g.id}'` else `goal {i}`
			table.insert(
				out,
				`{where}: funnel step '{g.funnel}' is not in GameConfig.analytics.funnel (it will never be logged)`
			)
		end
	end
	return out
end

return Validate
