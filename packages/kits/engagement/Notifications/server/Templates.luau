--!strict
--[[
	Notification templates (docs/framework/kits/notifications.md, "Config" and "Template"). Pure.

	  Templates.normalize(key, def) -> (Template?, error?)       one config entry, with its defaults
	  Templates.all(defs) -> ({ [key]: Template }, { string })   every valid entry + one message per bad one
	  Templates.checkParams(tpl, params) -> (clean?, reason?)    "bad_params" unless every declared name is
	                                                             present, nothing extra, strings <= 100 chars
	  Templates.body(tpl, params, universeId) -> table           the Open Cloud request body
	  Templates.launchData(key) / Templates.parseLaunchData(text, isTemplate) -> key?
	      LaunchData is `sw1:<templateKey>`, at most 200 bytes; anything else is nil (it is untrusted)
]]

local Templates = {}

export type Template = {
	key: string,
	messageId: string,
	placeholder: boolean,
	params: { [string]: string }, -- name -> "string" | "userId"
	paramNames: { string }, -- sorted
	category: string,
	launch: boolean,
	cooldownHours: number,
	cancelOnJoin: boolean,
	promptOnSchedule: boolean,
	hoursBefore: number,
	minStreak: number,
}

Templates.KEY_PATTERN = "^[%w_]{1,32}$"
Templates.MAX_PARAM_LENGTH = 100
Templates.MAX_LAUNCH_BYTES = 200
Templates.LAUNCH_PREFIX = "sw1:"

local PARAM_KINDS: { [string]: boolean } = { string = true, userId = true }

function Templates.validKey(key: any): boolean
	return type(key) == "string" and string.match(key, "^[%w_]+$") ~= nil and #key >= 1 and #key <= 32
end

local function positive(v: any, default: number): number
	return if type(v) == "number" and v == v and v >= 0 then v else default
end

-- "" (a placeholder) or what the Creator Dashboard shows: letters, digits and dashes, at most 64
local function validMessageId(id: string): boolean
	return id == "" or (#id <= 64 and string.match(id, "^[%w%-]+$") ~= nil)
end

function Templates.normalize(key: any, def: any): (Template?, string?)
	if not Templates.validKey(key) then
		return nil, `template key '{tostring(key)}' must match {Templates.KEY_PATTERN}`
	end
	if type(def) ~= "table" then
		return nil, `template '{key}' must be a table`
	end
	local messageId = def.messageId
	if type(messageId) == "number" then
		messageId = string.format("%d", messageId)
	end
	if type(messageId) ~= "string" then
		return nil, `template '{key}': messageId is required (a string; "" is a placeholder)`
	end
	if not validMessageId(messageId) then
		return nil,
			`template '{key}': messageId '{string.sub(messageId, 1, 64)}' is not a notification string id (letters, digits and dashes, as the Creator Dashboard shows it; "" is a placeholder)`
	end
	local params: { [string]: string } = {}
	local names: { string } = {}
	local declared = def.params
	if declared ~= nil and type(declared) ~= "table" then
		return nil, `template '{key}': params must be a table of name = "string" | "userId"`
	end
	for k, v in (declared or {}) :: { [any]: any } do
		local name, kind = k, v
		if type(k) == "number" then -- a list of names: every one a string
			name, kind = v, "string"
		end
		if type(name) ~= "string" or string.match(name, "^[%w_]+$") == nil or #name > 32 then
			return nil, `template '{key}': parameter names are words of at most 32 characters`
		end
		if PARAM_KINDS[kind] ~= true then
			return nil, `template '{key}': parameter '{name}' must be "string" or "userId"`
		end
		params[name] = kind
		table.insert(names, name)
	end
	table.sort(names)
	local category = if type(def.category) == "string" and def.category ~= "" then def.category else key
	return {
		key = key,
		messageId = messageId,
		placeholder = messageId == "",
		params = params,
		paramNames = names,
		category = category,
		launch = def.launch ~= false,
		cooldownHours = positive(def.cooldownHours, 24),
		cancelOnJoin = def.cancelOnJoin ~= false,
		promptOnSchedule = def.promptOnSchedule == true,
		hoursBefore = positive(def.hoursBefore, 4),
		minStreak = if type(def.minStreak) == "number" and def.minStreak >= 0 then def.minStreak else 3,
	},
		nil
end

function Templates.all(defs: any): ({ [string]: Template }, { string })
	local out: { [string]: Template } = {}
	local errors: { string } = {}
	if type(defs) ~= "table" then
		return out, errors
	end
	local keys: { any } = {}
	for k in defs do
		table.insert(keys, k)
	end
	table.sort(keys, function(a: any, b: any): boolean
		return tostring(a) < tostring(b)
	end)
	for _, k in keys do
		local tpl, err = Templates.normalize(k, defs[k])
		if tpl then
			out[tpl.key] = tpl
		else
			table.insert(errors, err or "invalid template")
		end
	end
	return out, errors
end

-- params must name exactly the template's parameters; strings are at most 100 characters, userId
-- parameters are positive whole numbers.
function Templates.checkParams(tpl: Template, params: any): ({ [string]: any }?, string?)
	if params ~= nil and type(params) ~= "table" then
		return nil, "bad_params"
	end
	local given: { [string]: any } = (params or {}) :: any
	local clean: { [string]: any } = {}
	for name, kind in tpl.params do
		local v = given[name]
		if kind == "userId" then
			if type(v) ~= "number" or v ~= v or v < 1 or v ~= math.floor(v) then
				return nil, "bad_params"
			end
		elseif type(v) ~= "string" or #v > Templates.MAX_PARAM_LENGTH then
			return nil, "bad_params"
		end
		clean[name] = v
	end
	for name in given do
		if tpl.params[name :: any] == nil then
			return nil, "bad_params"
		end
	end
	return clean, nil
end

function Templates.launchData(key: string): string
	return Templates.LAUNCH_PREFIX .. key
end

function Templates.parseLaunchData(text: any, isTemplate: (string) -> boolean): string?
	if type(text) ~= "string" or #text > Templates.MAX_LAUNCH_BYTES then
		return nil
	end
	local key = string.match(text, "^sw1:([%w_]+)$")
	if key == nil or #key > 32 or not isTemplate(key) then
		return nil
	end
	return key
end

-- The request body of POST users/{userId}/notifications. Field names follow the Open Cloud reference
-- (checked live, see the page's live checklist); the values here come only from the template and params.
function Templates.body(tpl: Template, params: { [string]: any }, universeId: number): { [string]: any }
	local parameters: { [string]: any } = {}
	for name, kind in tpl.params do
		local v = params[name]
		parameters[name] = if kind == "userId"
			then { int64Value = string.format("%d", v) }
			else { stringValue = v }
	end
	local payload: { [string]: any } = {
		type = "MOMENT",
		messageId = tpl.messageId,
		analyticsData = { category = tpl.category },
	}
	if next(parameters) ~= nil then
		payload.parameters = parameters
	end
	if tpl.launch then
		payload.joinExperience = { launchData = Templates.launchData(tpl.key) }
	end
	return {
		source = { universe = string.format("universes/%d", universeId) },
		payload = payload,
	}
end

return Templates
