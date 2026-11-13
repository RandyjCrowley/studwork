--!strict
--[[
	The "Report" screen's pure view state (no React, no engine): what the screen shows and what it
	sends. Views.luau renders it; State.spec.luau covers it.

	  State.candidates(inServer, recent, selfUserId) -> { { userId, name, section } }
	      players to pick: this server first (section "inServer"), then recently left ("recent");
	      never the local player, nobody twice, each section sorted by name
	  State.initial(targetUserId?, candidates) -> ViewState
	      step "pick", or "category" when the given target is a candidate
	  State.pick(s, userId, candidates) -> ViewState          step "category"
	  State.choose(s, categoryId, categories) -> ViewState    an unknown id changes nothing
	  State.setNote(s, text, maxLength) -> ViewState          cut to maxLength characters (UTF-8 safe)
	  State.back(s) -> ViewState                              "category" -> "pick"
	  State.args(s, config) -> (targetUserId, category, note?)? what Submit sends (nil until complete;
	                                                          no note when note.enabled is false)
	  State.sent(s) -> ViewState                              step "thanks"
	  State.categories(config) -> { { id, key } }             the buttons (key Reports.category.<id>)
	  State.offerBlock(s, config, inServer) -> boolean        the block prompt after sending
]]

local State = {}

export type Candidate = { userId: number, name: string, section: "inServer" | "recent" }
export type ViewState = {
	step: "pick" | "category" | "thanks",
	target: number?,
	targetName: string?,
	category: string?,
	note: string,
}

local function valid(entry: any): boolean
	return type(entry) == "table" and type(entry.userId) == "number" and type(entry.name) == "string"
end

local function byName(a: Candidate, b: Candidate): boolean
	if a.name == b.name then
		return a.userId < b.userId
	end
	return string.lower(a.name) < string.lower(b.name)
end

function State.candidates(inServer: { any }?, recent: { any }?, selfUserId: number?): { Candidate }
	local seen: { [number]: boolean } = {}
	if selfUserId ~= nil then
		seen[selfUserId] = true
	end
	local here: { Candidate } = {}
	for _, p in (inServer or {}) :: { any } do
		if valid(p) and not seen[p.userId] then
			seen[p.userId] = true
			table.insert(here, { userId = p.userId, name = p.name, section = "inServer" })
		end
	end
	local gone: { Candidate } = {}
	for _, p in (recent or {}) :: { any } do
		if valid(p) and not seen[p.userId] then
			seen[p.userId] = true
			table.insert(gone, { userId = p.userId, name = p.name, section = "recent" })
		end
	end
	table.sort(here, byName)
	table.sort(gone, byName)
	for _, c in gone do
		table.insert(here, c)
	end
	return here
end

local function find(candidates: { Candidate }, userId: any): Candidate?
	for _, c in candidates do
		if c.userId == userId then
			return c
		end
	end
	return nil
end

function State.initial(targetUserId: number?, candidates: { Candidate }): ViewState
	local c = if targetUserId ~= nil then find(candidates, targetUserId) else nil
	if c ~= nil then
		return { step = "category", target = c.userId, targetName = c.name, note = "" }
	end
	return { step = "pick", note = "" }
end

function State.pick(s: ViewState, userId: number, candidates: { Candidate }): ViewState
	local c = find(candidates, userId)
	if c == nil then
		return s
	end
	return { step = "category", target = c.userId, targetName = c.name, category = nil, note = s.note }
end

function State.categories(config: any): { { id: string, key: string } }
	local out = {}
	local list = if type(config) == "table" then config.categories else nil
	for _, id in (if type(list) == "table" then list else {}) :: { any } do
		if type(id) == "string" then
			table.insert(out, { id = id, key = "Reports.category." .. id })
		end
	end
	return out
end

function State.choose(
	s: ViewState,
	categoryId: string,
	categories: { { id: string, key: string } }
): ViewState
	for _, c in categories do
		if c.id == categoryId then
			local new = table.clone(s)
			new.category = categoryId
			return new
		end
	end
	return s
end

-- the first `max` characters (whole UTF-8 sequences; invalid UTF-8 falls back to bytes)
local function cut(text: string, max: number): string
	if max <= 0 then
		return ""
	end
	local n = utf8.len(text)
	if n == nil then
		return string.sub(text, 1, max)
	end
	if n <= max then
		return text
	end
	local stop = utf8.offset(text, max + 1)
	return string.sub(text, 1, (stop or (#text + 1)) - 1)
end

function State.setNote(s: ViewState, text: string, maxLength: number): ViewState
	local new = table.clone(s)
	new.note = cut(if type(text) == "string" then text else "", maxLength)
	return new
end

function State.back(s: ViewState): ViewState
	if s.step == "category" then
		return { step = "pick", note = s.note }
	end
	return s
end

function State.args(s: ViewState, config: any): (number?, string?, string?)
	if s.step ~= "category" or s.target == nil or s.category == nil then
		return nil, nil, nil
	end
	local noteCfg = if type(config) == "table" then config.note else nil
	local enabled = type(noteCfg) == "table" and noteCfg.enabled == true
	local note: string? = nil
	if enabled and s.note ~= "" then
		note = cut(s.note, if type(noteCfg.maxLength) == "number" then noteCfg.maxLength else 0)
		if note == "" then
			note = nil
		end
	end
	return s.target, s.category, note
end

function State.sent(s: ViewState): ViewState
	local new = table.clone(s)
	new.step = "thanks"
	return new
end

function State.offerBlock(s: ViewState, config: any, inServer: { [number]: boolean }): boolean
	return s.step == "thanks"
		and type(config) == "table"
		and config.blockPrompt == true
		and s.target ~= nil
		and inServer[s.target :: number] == true
end

return State
