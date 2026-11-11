--!strict
--[[
	Mail client state readers (pure; v1.3.1 R19: moved from the framework HUD's Slices, which
	now names no module). Read this module's per-module client slice of the replicated state
	(module-api.md §10: state.modules.Mail.data / .extra), or a v1.2 flat state's fields.
	State.mailbox(state) -> { entry }   extra.mailbox ({} when absent)
	State.count(state) -> number        held mailbox messages (0 when absent or malformed)
	State.shown(isEnabled) -> boolean   the mailbox badge slot: only with this module (v1.2, N1)
]]

local State = {}

local NAME = "Mail"

-- state.modules.Mail (a v1.3 state) or the state itself (a v1.2 flat state); nil fields read as nil
local function slice(state: any): any
	if type(state) ~= "table" then
		return nil
	end
	if type(state.modules) ~= "table" then
		return state
	end
	local m = state.modules[NAME]
	return if type(m) == "table" then m else {}
end

local function field(t: any, key: string): any
	return if type(t) == "table" then t[key] else nil
end

local function isModular(state: any): boolean
	return type(state) == "table" and type(state.modules) == "table"
end

-- extra.<key> of this module's slice (v1.2 flat: state.<key>)
local function extra(state: any, key: string): any
	local s = slice(state)
	if isModular(state) then
		return field(field(s, "extra"), key)
	end
	return field(s, key)
end

function State.mailbox(state: any): { any }
	local box = extra(state, "mailbox")
	return if type(box) == "table" then box else {}
end

function State.count(state: any): number
	local box = extra(state, "mailbox")
	if type(box) ~= "table" then
		return 0
	end
	local n = 0
	for _ in box do
		n += 1
	end
	return n
end

function State.shown(isEnabled: (name: string) -> boolean): boolean
	return isEnabled(NAME)
end

return State
