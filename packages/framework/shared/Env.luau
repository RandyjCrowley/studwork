--!strict
--[[
	Environments (module-api.md §23.1, docs/framework/kits/environments.md). Pure, both sides.

	  Env.resolve(environments, info) -> "studio" | "test" | "live"
	  Env.validate(environments, info?) -> (errors, warnings)   shape, test/live overlap, unlisted place
	  Env.build(environments, info, forced?) -> EnvAPI          frozen { name(), placeId(), universeId() }

	info = { isStudio: boolean, placeId: number, universeId: number }. An unlisted place is live, so a
	place nobody listed can never switch on test-only behaviour. Ids are positive integers (the
	generated Environments.luau leaves deploy.json's placeholders out); an id listed under both test
	and live (place ids with place ids, universe ids with universe ids) is a boot error.
]]

local Types = require(script.Parent.Types)

local Env = {}

export type Info = { isStudio: boolean, placeId: number, universeId: number }

local function contains(list: any, id: number): boolean
	if type(list) ~= "table" then
		return false
	end
	for _, v in list do
		if v == id then
			return true
		end
	end
	return false
end

function Env.resolve(environments: any, info: Info): Types.EnvName
	if info.isStudio then
		return "studio"
	end
	local test = if type(environments) == "table" then environments.test else nil
	if type(test) == "table" then
		if contains(test.placeIds, info.placeId) or contains(test.universeIds, info.universeId) then
			return "test"
		end
	end
	return "live"
end

local function checkIds(list: any, where: string, errors: { string })
	if list == nil then
		return
	end
	if type(list) ~= "table" then
		table.insert(errors, `{where} must be a list of numbers`)
		return
	end
	for i, id in list do
		if type(i) ~= "number" or type(id) ~= "number" or id ~= id or id % 1 ~= 0 or id < 1 then
			table.insert(errors, `{where}[{tostring(i)}] must be a positive integer id`)
		end
	end
end

function Env.validate(environments: any, info: Info?): ({ string }, { string })
	local errors: { string } = {}
	local warnings: { string } = {}
	if environments == nil then
		return errors, warnings
	end
	if type(environments) ~= "table" then
		table.insert(errors, "environments must be a table { test = {...}?, live = {...}? }")
		return errors, warnings
	end
	for key in environments do
		if key ~= "test" and key ~= "live" then
			table.insert(warnings, `environments.{tostring(key)}: unknown key (expected test, live)`)
		end
	end
	for _, side in { "test", "live" } do
		local entry = environments[side]
		if entry == nil then
			continue
		end
		if type(entry) ~= "table" then
			table.insert(errors, `environments.{side} must be a table {"{"} placeIds, universeIds {"}"}`)
			continue
		end
		for key in entry do
			if key ~= "placeIds" and key ~= "universeIds" then
				-- a typo (placeId) would silently drop the ids: the place would count as live
				table.insert(
					errors,
					`environments.{side}.{tostring(key)}: unknown key (expected placeIds, universeIds)`
				)
			end
		end
		checkIds(entry.placeIds, `environments.{side}.placeIds`, errors)
		checkIds(entry.universeIds, `environments.{side}.universeIds`, errors)
	end
	local test, live = environments.test, environments.live
	if type(test) == "table" and type(live) == "table" then
		for _, kind in { "placeIds", "universeIds" } do
			if type(test[kind]) == "table" and type(live[kind]) == "table" then
				for _, id in test[kind] do
					if contains(live[kind], id) then
						table.insert(
							errors,
							`environments: {kind} id {tostring(id)} is listed under both test and live`
						)
					end
				end
			end
		end
	end
	if info ~= nil and not info.isStudio and type(live) == "table" then
		local inTest = Env.resolve(environments, info) == "test"
		if
			not inTest
			and not contains(live.placeIds, info.placeId)
			and not contains(live.universeIds, info.universeId)
		then
			table.insert(warnings, `place {info.placeId} isn't in environments; treating it as live`)
		end
	end
	return errors, warnings
end

-- forced: a test or tool picks the name (harness `env = "live"`); production never passes it.
function Env.build(environments: any, info: Info, forced: Types.EnvName?): Types.EnvAPI
	local name = forced or Env.resolve(environments, info)
	return table.freeze({
		name = function(): Types.EnvName
			return name :: any
		end,
		placeId = function(): number
			return info.placeId
		end,
		universeId = function(): number
			return info.universeId
		end,
	})
end

return table.freeze(Env)
