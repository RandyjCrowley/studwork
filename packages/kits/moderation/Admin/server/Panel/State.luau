--!strict
--[[
	Admin panel: the pure view state (no Roblox, no React). The panel component (./init.luau)
	renders what this returns and turns taps into `reduce` events and `request` calls; the spec
	(packages/kits/moderation/tests/AdminPanelState.spec.luau) covers it under Lune.

	`staff` is the replicated extra.staff value the server sets for a staff player only:
	{ role, label?, rank, permissions, actions = { { id, labelKey, target, presets?, durations?,
	freeText?, permission, amount? } }, tabs = { { id, labelKey, permission, rowActions } },
	playerListMax }.

	  State.tabs(staff) -> { { id, labelKey, kind } }   Players, registered tabs, Announce, Data
	  State.has(staff, permission) -> boolean
	  State.playerActions(staff) -> { action }          actions on a player (quick actions)
	  State.action(staff, id) -> action?
	  State.durationLabel(seconds) -> (key, args)        Admin.duration.* (-1 = permanent)
	  State.decodeRows(payload) -> { columns, rows, target? }   a Rows payload, cells checked
	  State.cellText(value, kind?, resolve) -> string    a cell for display (strings are keys)
	  State.cycle(list, current) -> value?               the next choice of a picker
	  State.new(staff) -> state                          the initial state (Players tab)
	  State.reduce(state, event) -> state                a new state (the old one is untouched)
	  State.request(state, staff) -> (run args?, reason key?)   what to send for the chosen action
	  State.rowRequest(tabId, rowActionId, rowId, preset?, note?) -> run args (choices ride in
	                                                     `text`: "<preset>" or "<preset>|<note>")
	  State.rowRun(state, staff) -> (run args?, reason key?)   the picked row action + choices
	  State.announceRequest(state) -> (run args?, reason key?)
	  State.decodeAnnounce(payload) -> (kind "key" | "text" | nil, value)
]]

local State = {}

State.ANNOUNCE_KEY = "k|"
State.ANNOUNCE_TEXT = "t|"

local MINUTE = 60
local HOUR = 3600
local DAY = 86400

export type Tab = { id: string, labelKey: string, kind: "players" | "rows" | "announce" | "data" }

-- a Run request: the five wire arguments
export type Run = {
	actionId: string,
	targetUserId: number?,
	preset: string?,
	duration: number?,
	text: string?,
}

local function list(v: any): { any }
	return if type(v) == "table" then v else {}
end

function State.has(staff: any, permission: string): boolean
	if type(staff) ~= "table" then
		return false
	end
	return table.find(list(staff.permissions), permission) ~= nil
end

function State.tabs(staff: any): { Tab }
	local out: { Tab } = {}
	if type(staff) ~= "table" then
		return out
	end
	table.insert(out, { id = "players", labelKey = "Admin.tab.players", kind = "players" })
	for _, t in list(staff.tabs) do
		if type(t) == "table" and type(t.id) == "string" and type(t.labelKey) == "string" then
			table.insert(out, { id = t.id, labelKey = t.labelKey, kind = "rows" })
		end
	end
	if State.action(staff, "announce") ~= nil then
		table.insert(out, { id = "announce", labelKey = "Admin.tab.announce", kind = "announce" })
	end
	if State.action(staff, "dataView") ~= nil then
		table.insert(out, { id = "data", labelKey = "Admin.tab.data", kind = "data" })
	end
	return out
end

function State.action(staff: any, id: string): any
	if type(staff) ~= "table" then
		return nil
	end
	for _, a in list(staff.actions) do
		if type(a) == "table" and a.id == id then
			return a
		end
	end
	return nil
end

function State.playerActions(staff: any): { any }
	local out = {}
	if type(staff) ~= "table" then
		return out
	end
	for _, a in list(staff.actions) do
		if type(a) == "table" and (a.target == "player" or a.target == "userId") then
			table.insert(out, a)
		end
	end
	return out
end

function State.tabDef(staff: any, id: string): any
	if type(staff) ~= "table" then
		return nil
	end
	for _, t in list(staff.tabs) do
		if type(t) == "table" and t.id == id then
			return t
		end
	end
	return nil
end

function State.durationLabel(seconds: number): (string, { [string]: any })
	if seconds < 0 then
		return "Admin.duration.permanent", {}
	elseif seconds >= DAY and seconds % DAY == 0 then
		return "Admin.duration.days", { n = seconds // DAY }
	elseif seconds >= HOUR and seconds % HOUR == 0 then
		return "Admin.duration.hours", { n = seconds // HOUR }
	end
	return "Admin.duration.minutes", { n = math.max(1, math.floor(seconds / MINUTE + 0.5)) }
end

local function cellValue(v: any): any
	if type(v) == "boolean" or type(v) == "string" then
		return v
	elseif type(v) == "number" and v == v and v > -math.huge and v < math.huge then
		return v
	end
	return nil
end

function State.decodeRows(payload: any): { columns: { string }, rows: { { [string]: any } }, target: number? }
	local columns: { string } = {}
	local rows: { { [string]: any } } = {}
	if type(payload) ~= "table" then
		return { columns = columns, rows = rows }
	end
	for _, c in list(payload.columns) do
		if type(c) == "string" then
			table.insert(columns, c)
		end
	end
	for _, r in list(payload.rows) do
		if type(r) == "table" then
			local row: { [string]: any } = {}
			for k, v in r do
				if type(k) == "string" then
					row[k] = cellValue(v)
				end
			end
			table.insert(rows, row)
		end
	end
	local target = if type(payload.target) == "number" then payload.target else nil
	return { columns = columns, rows = rows, target = target }
end

-- strings in rows are strings keys or names the server already checked: resolve() returns the
-- text for a key (and anything that isn't a key unchanged)
function State.cellText(value: any, kind: string?, resolve: (string) -> string): string
	if value == nil then
		return ""
	elseif type(value) == "boolean" then
		return resolve(if value then "Admin.value.yes" else "Admin.value.no")
	elseif type(value) == "number" then
		if kind == "time" then
			return os.date("!%Y-%m-%d %H:%M", math.floor(value)) :: string
		end
		if value % 1 == 0 then
			return string.format("%d", value)
		end
		return string.format("%.2f", value)
	end
	return resolve(tostring(value))
end

function State.cycle(choices: { any }?, current: any): any
	if choices == nil or #choices == 0 then
		return nil
	end
	local i = table.find(choices, current)
	if i == nil or i >= #choices then
		return choices[1]
	end
	return choices[i + 1]
end

export type PanelState = {
	tab: string,
	page: number,
	selected: number?,
	actionId: string?,
	preset: string?,
	duration: number?,
	amount: number?,
	text: string,
	rows: { [string]: any },
	resultOk: boolean?,
	resultKey: string?,
	confirming: boolean,
	rowAction: { tabId: string, id: string, rowId: string }?,
	note: string?,
}

function State.new(_staff: any): PanelState
	return {
		tab = "players",
		page = 1,
		selected = nil,
		actionId = nil,
		preset = nil,
		duration = nil,
		amount = nil,
		text = "",
		rows = {},
		resultOk = nil,
		resultKey = nil,
		confirming = false,
		rowAction = nil,
		note = nil,
	}
end

local function copy(s: PanelState): PanelState
	local c = table.clone(s :: any)
	c.rows = table.clone(s.rows)
	return c :: PanelState
end

local function clearChoice(s: PanelState)
	s.preset = nil
	s.duration = nil
	s.amount = nil
	s.text = ""
	s.note = nil
	s.confirming = false
end

function State.reduce(state: PanelState, event: any): PanelState
	local s = copy(state)
	local kind = if type(event) == "table" then event.type else nil
	if kind == "tab" then
		if s.tab ~= event.id then
			s.tab = event.id
			s.page = 1
			s.actionId = nil
			s.rowAction = nil
			clearChoice(s)
		end
	elseif kind == "select" then
		s.selected = event.userId
		s.confirming = false
	elseif kind == "action" then
		s.actionId = event.id
		clearChoice(s)
	elseif kind == "rowAction" then
		s.rowAction = if event.id ~= nil
			then { tabId = event.tabId, id = event.id, rowId = event.rowId }
			else nil
		clearChoice(s)
	elseif kind == "note" then
		s.note = event.value
		s.confirming = false
	elseif kind == "preset" then
		s.preset = event.value
		s.confirming = false
	elseif kind == "duration" then
		s.duration = event.value
		s.confirming = false
	elseif kind == "amount" then
		local n = tonumber(event.value)
		s.amount = if n ~= nil and n == n then math.floor(n) else nil
		s.confirming = false
	elseif kind == "text" then
		s.text = if type(event.value) == "string" then event.value else ""
		s.confirming = false
	elseif kind == "page" then
		s.page = math.clamp(s.page + (event.delta or 0), 1, 65535)
	elseif kind == "rows" then
		s.rows[event.tabId] = { page = event.page, data = State.decodeRows(event.data) }
	elseif kind == "result" then
		s.resultOk = event.ok == true
		s.resultKey = event.key
		s.confirming = false
	elseif kind == "confirm" then
		s.confirming = event.value == true
	end
	return s
end

-- the Run for the chosen quick action on the selected player (checked here so the panel can tell
-- the staff member what's missing; the server checks everything again)
function State.request(state: PanelState, staff: any): (Run?, string?)
	local a = if state.actionId ~= nil then State.action(staff, state.actionId) else nil
	if a == nil then
		return nil, "Admin.panel.pickAction"
	end
	local target: number? = nil
	if a.target ~= "none" then
		if state.selected == nil then
			return nil, "Admin.panel.pickPlayer"
		end
		target = state.selected
	end
	local text = if a.freeText == true and string.match(state.text, "%S") ~= nil then state.text else nil
	local presets = list(a.presets)
	if #presets > 0 and state.preset == nil and text == nil then
		return nil, "Admin.panel.pickReason"
	end
	if state.preset ~= nil and table.find(presets, state.preset) == nil then
		return nil, "Admin.panel.pickReason"
	end
	local duration: number? = nil
	if type(a.amount) == "table" then
		local n = state.amount
		if n == nil or n < (a.amount.min or 1) or n > (a.amount.max or 0) then
			return nil, "Admin.panel.pickAmount"
		end
		duration = n
	elseif #list(a.durations) > 0 then
		if state.duration == nil or table.find(a.durations, state.duration) == nil then
			return nil, "Admin.panel.pickDuration"
		end
		duration = state.duration
	end
	return {
		actionId = a.id,
		targetUserId = target,
		preset = state.preset,
		duration = duration,
		text = text,
	},
		nil
end

function State.announceRequest(state: PanelState, staff: any): (Run?, string?)
	local s = copy(state)
	s.actionId = "announce"
	local run, why = State.request(s, staff)
	if run ~= nil and run.preset ~= nil and run.text ~= nil then
		-- one or the other: typed text wins over a picked preset
		run.preset = nil
	end
	return run, why
end

function State.rowRequest(
	tabId: string,
	rowActionId: string,
	rowId: string,
	preset: string?,
	note: string?
): Run
	local text: string? = nil
	if preset ~= nil then
		text = if note ~= nil then `{preset}|{note}` else preset
	end
	return { actionId = `{tabId}/{rowActionId}`, preset = rowId, text = text }
end

-- the row action the staff member picked on a row, with its preset (required when it offers
-- any) and optional note
function State.rowRun(state: PanelState, staff: any): (Run?, string?)
	local chosen = state.rowAction
	if chosen == nil then
		return nil, "Admin.panel.pickAction"
	end
	local tab = State.tabDef(staff, chosen.tabId)
	local ra = nil
	for _, candidate in list(if tab ~= nil then tab.rowActions else nil) do
		if type(candidate) == "table" and candidate.id == chosen.id then
			ra = candidate
		end
	end
	if ra == nil then
		return nil, "Admin.panel.pickAction"
	end
	local presets = list(ra.presets)
	if #presets > 0 and (state.preset == nil or table.find(presets, state.preset) == nil) then
		return nil, "Admin.panel.pickReason"
	end
	if #presets == 0 and state.preset ~= nil then
		return nil, "Admin.panel.pickReason"
	end
	if state.note ~= nil and table.find(list(ra.notes), state.note) == nil then
		return nil, "Admin.panel.pickNote"
	end
	return State.rowRequest(chosen.tabId, chosen.id, chosen.rowId, state.preset, state.note), nil
end

function State.decodeAnnounce(payload: any): (string?, string?)
	if type(payload) ~= "string" then
		return nil, nil
	end
	local prefix, rest = string.sub(payload, 1, 2), string.sub(payload, 3)
	if rest == "" then
		return nil, nil
	end
	if prefix == State.ANNOUNCE_KEY then
		return "key", rest
	elseif prefix == State.ANNOUNCE_TEXT then
		return "text", rest
	end
	return nil, nil
end

return State
