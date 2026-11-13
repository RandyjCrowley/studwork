--!strict
--[[
	Rules: carriable definitions and drop rules (pure). carry.md "Config" / "CarriableDef" / "dropRules".

	  Rules.normalize(tag, def, cfg, who) -> def   validates like boot config and fills defaults; errors
	                                               name `who` (the caller)
	  Rules.merge(...) -> rules                    later tables win per field (false and nil-by-omission kept)
]]

local Rules = {}

local function fail(who: string, tag: string, message: string)
	error(`{who}: carriable '{tag}': {message}`, 3)
end

function Rules.normalize(tag: string, def: any, cfg: any, who: string): any
	if type(tag) ~= "string" or tag == "" then
		error(`{who}: tag must be a non-empty string`, 2)
	end
	if string.find(tag, "[|,]") then
		fail(who, tag, 'the tag may not contain "|" or ","')
	end
	if type(def) ~= "table" then
		fail(who, tag, "definition must be a table")
	end
	local massClass = def.massClass or "medium"
	if cfg.massClasses[massClass] == nil then
		fail(who, tag, `massClass '{tostring(massClass)}' is not a key of config.massClasses`)
	end
	local carriers = def.carriers or { min = 1, max = 1 }
	local min, max = carriers.min, carriers.max
	if
		type(min) ~= "number"
		or type(max) ~= "number"
		or min % 1 ~= 0
		or max % 1 ~= 0
		or min < 1
		or max < min
		or max > 8
	then
		fail(who, tag, "carriers must be integers with 1 <= min <= max <= 8")
	end
	local gripPoints = def.gripPoints or { { 0, 0, 0 } }
	if type(gripPoints) ~= "table" or #gripPoints ~= max then
		fail(who, tag, `gripPoints needs exactly carriers.max ({max}) entries`)
	end
	for _, g in gripPoints do
		if
			type(g) ~= "table"
			or type(g[1]) ~= "number"
			or type(g[2]) ~= "number"
			or type(g[3]) ~= "number"
		then
			fail(who, tag, "every grip point is { x, y, z }")
		end
	end
	local speedPenalty = def.speedPenalty or 0
	if type(speedPenalty) ~= "number" or speedPenalty < 0 or speedPenalty > 1 then
		fail(who, tag, "speedPenalty must be 0..1")
	end
	local fragility = def.fragility or 1
	if type(fragility) ~= "number" or fragility < 0 or fragility > 1 then
		fail(who, tag, "fragility must be 0..1")
	end
	return {
		model = def.model,
		massClass = massClass,
		carriers = { min = min, max = max },
		gripPoints = gripPoints,
		speedPenalty = speedPenalty,
		fragility = fragility,
		pickUpRadius = def.pickUpRadius,
		killY = def.killY,
		dropRules = def.dropRules,
	}
end

function Rules.merge(...: any): any
	local out: { [string]: any } = {}
	for i = 1, select("#", ...) do
		local layer = select(i, ...)
		if type(layer) == "table" then
			for k, v in layer do
				out[k] = v
			end
		end
	end
	return out
end

return Rules
