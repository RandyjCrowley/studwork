--!strict
--[[
	TextFilter: the server part (docs/framework/kits/textfilter.md). A part factory:
	TextFilter.new() builds a fresh part (specs and the sim run several runtimes in one process).

	Unfiltered player text is never shown to another player, and never handed to a caller in a form
	it could replicate. Every call that filters YIELDS (Roblox): call from an action handler or a
	spawned thread, never inside ctx.tx.

	  filter(author, text, context) -> (ok, Filtered | reason)   a submission: one fresh
	      FilterStringAsync, never from the cache. Filtered = { context, author (user id),
	      public? (the broadcast string, "public" only), forViewer(viewer) -> string? }
	  textFor(viewer, author, text, context) -> string?          re-display, through the cache (a
	      miss counts against perPlayerPerMinute: over it, nil)
	  store(author, text, context) -> (ok, Stored | reason)      a kept submission: the original goes
	      in THIS module's section (originals[id] = { t, c, at }, never replicated); Stored =
	      { id, author, context, at, shown? } holds no original text
	  shown(stored, viewer?) -> string?                          re-filtered from the original while
	      the author is in this server; else stored.shown ("public", younger than shownMaxDays)
	  release(author, stored)                                    drops the original
	Reasons: empty, too_long, rate_limited, policy, author_offline, filter_failed.

	Contexts: "public" -> PublicChat + GetNonChatStringForBroadcastAsync (everyone);
	"friends" -> PrivateChat + GetNonChatStringForUserAsync(viewer) for the author and the author's
	friends (player:IsFriendsWithAsync, cached per pair for the session); "private" -> the same for
	the author only. A viewer who isn't in this server gets nil.

	Privacy: player text (original or filtered) is never logged or sent to analytics; warnings
	carry the author id, the context and the reason only.
]]

local TextFilter = {}

local CONTEXTS = table.freeze({ public = true, friends = true, private = true })
local DAY = 86400
local MINUTE = 60

-- Enum.TextFilterContext.<name> (nil where there is no Enum, e.g. under Lune)
local function filterContext(name: string): any
	local ok, value = pcall(function(): any
		return (Enum :: any).TextFilterContext[name]
	end)
	return if ok then value else nil
end

-- Pure: the text as filtered and stored: control characters stripped, then (trim) leading and
-- trailing whitespace removed and runs of spaces collapsed. -> (text?, reason?)
function TextFilter.clean(text: any, maxLength: number, trim: boolean): (string?, string?)
	if type(text) ~= "string" then
		return nil, "empty"
	end
	local s = string.gsub(text, "%c", "")
	if trim then
		s = string.gsub(s, "^%s+", "")
		s = string.gsub(s, "%s+$", "")
		s = string.gsub(s, " +", " ")
	end
	if s == "" then
		return nil, "empty"
	end
	local length = utf8.len(s) or #s
	if length > maxLength then
		return nil, "too_long"
	end
	return s, nil
end

TextFilter.CONTEXTS = CONTEXTS

type CacheEntry = {
	at: number,
	used: number,
	result: any,
	public: string?,
	viewers: { [number]: string | false },
}

function TextFilter.new(): any
	local ctx: any = nil
	local online: { [number]: any } = {} -- userId -> player loaded in this server
	local rate: { [any]: { minute: number, count: number } } = {}
	local friends: { [string]: boolean } = {}
	local cache: { [string]: CacheEntry } = {}
	local cacheSize = 0
	local useCounter = 0

	local part: { [string]: any } = {}

	local function cfg(): any
		return ctx.config
	end

	local function service(): any
		return ctx.services.get("TextService")
	end

	local function present(player: any): boolean
		local ok, id = pcall(function(): any
			return player.UserId
		end)
		return ok and type(id) == "number" and online[id] == player and ctx.data.isLoaded(player)
	end

	local function checkContext(fnName: string, context: any)
		if type(context) ~= "string" or not CONTEXTS[context] then
			error(`TextFilter.{fnName}: context must be "public", "friends" or "private"`, 3)
		end
	end

	local function policyAllows(author: any, context: string): boolean
		if context == "private" or not cfg().respectContentSharing then
			return true
		end
		return ctx.policy.allows(author, "IsContentSharingAllowed")
	end

	local function takeRate(author: any): boolean
		local minute = math.floor(ctx.now() / MINUTE)
		local r = rate[author]
		if r == nil or r.minute ~= minute then
			r = { minute = minute, count = 0 }
			rate[author] = r
		end
		if r.count >= cfg().perPlayerPerMinute then
			return false
		end
		r.count += 1
		return true
	end

	local function areFriends(a: any, b: any): boolean
		if a == b then
			return true
		end
		local x, y = a.UserId, b.UserId
		local key = if x < y then `{x}:{y}` else `{y}:{x}`
		local cached = friends[key]
		if cached ~= nil then
			return cached
		end
		local ok, yes = pcall(function(): any
			return a:IsFriendsWithAsync(y)
		end)
		if not ok then
			return false -- unknown: not shown (not cached, so a later call can ask again)
		end
		friends[key] = yes == true
		return yes == true
	end

	-- may `viewer` see text `author` wrote in `context`? (both must be in this server)
	local function mayView(viewer: any, author: any, context: string): boolean
		if not present(viewer) then
			return false
		end
		if context == "public" then
			return true
		end
		if viewer == author then
			return true
		end
		return context == "friends" and areFriends(author, viewer)
	end

	-- one FilterStringAsync (+ the broadcast string for "public"); nil = Roblox failed
	local function runFilter(author: any, text: string, context: string): (any, string?)
		local ok, result = pcall(function(): any
			local enum = filterContext(if context == "public" then "PublicChat" else "PrivateChat")
			return service():FilterStringAsync(text, author.UserId, enum)
		end)
		if not ok or result == nil then
			ctx.log.warn(`filter failed for author {author.UserId} ({context}): filter_failed`)
			return nil, nil
		end
		local broadcast: string? = nil
		if context == "public" then
			local okB, s = pcall(function(): any
				return result:GetNonChatStringForBroadcastAsync()
			end)
			if not okB or type(s) ~= "string" then
				ctx.log.warn(`broadcast string failed for author {author.UserId} (public): filter_failed`)
				return nil, nil
			end
			broadcast = s
		end
		return result, broadcast
	end

	local function stringForViewer(entry: any, viewer: any, author: any, context: string): string?
		if not mayView(viewer, author, context) then
			return nil
		end
		if context == "public" then
			return entry.public
		end
		local cached = entry.viewers[viewer.UserId]
		if cached ~= nil then
			return if cached == false then nil else cached
		end
		local ok, s = pcall(function(): any
			return entry.result:GetNonChatStringForUserAsync(viewer.UserId)
		end)
		if not ok or type(s) ~= "string" then
			entry.viewers[viewer.UserId] = false
			return nil
		end
		entry.viewers[viewer.UserId] = s
		return s
	end

	local function cacheKey(author: any, text: string, context: string): string
		return `{author.UserId}\0{context}\0{text}`
	end

	local function cachePut(key: string, entry: CacheEntry)
		if cache[key] == nil then
			cacheSize += 1
		end
		cache[key] = entry
		local max = cfg().cache.maxEntries
		while cacheSize > max do
			local oldestKey, oldestUse = nil, math.huge
			for k, e in cache do
				if e.used < oldestUse then
					oldestKey, oldestUse = k, e.used
				end
			end
			if oldestKey == nil then
				break
			end
			cache[oldestKey] = nil
			cacheSize -= 1
		end
	end

	local function newEntry(result: any, broadcast: string?): CacheEntry
		useCounter += 1
		return { at = ctx.now(), used = useCounter, result = result, public = broadcast, viewers = {} }
	end

	-- the re-display path: a cached result younger than cache.seconds, or one fresh filter, which
	-- counts against the author's perPlayerPerMinute like a submission (so text that was never
	-- submitted can't reach FilterStringAsync without a bound)
	local function redisplay(author: any, text: string, context: string): CacheEntry?
		local key = cacheKey(author, text, context)
		local entry = cache[key]
		if entry ~= nil and ctx.now() - entry.at < cfg().cache.seconds then
			useCounter += 1
			entry.used = useCounter
			return entry
		end
		if not takeRate(author) then
			return nil
		end
		local result, broadcast = runFilter(author, text, context)
		if result == nil then
			return nil
		end
		local fresh = newEntry(result, broadcast)
		cachePut(key, fresh)
		return fresh
	end

	-- a submission: validation, author present, policy, rate, then ONE fresh filter
	local function submit(author: any, text: any, context: string): (CacheEntry?, string?, string?)
		local c = cfg()
		local clean, why = TextFilter.clean(text, c.maxLength, c.trim)
		if clean == nil then
			return nil, why, nil
		end
		if not present(author) then
			return nil, "author_offline", nil
		end
		if not policyAllows(author, context) then
			return nil, "policy", nil
		end
		if not takeRate(author) then
			return nil, "rate_limited", nil
		end
		local result, broadcast = runFilter(author, clean, context)
		if result == nil then
			return nil, "filter_failed", nil
		end
		local entry = newEntry(result, broadcast)
		-- a later re-display of this exact text reuses this result (a submission never reads it)
		cachePut(cacheKey(author, clean, context), entry)
		return entry, nil, clean
	end

	local function handle(entry: CacheEntry, author: any, context: string): any
		return table.freeze({
			context = context,
			author = author.UserId,
			public = entry.public,
			forViewer = function(viewer: any): string?
				return stringForViewer(entry, viewer, author, context)
			end,
		})
	end

	local api: { [string]: any } = {}

	function api.filter(author: any, text: string, context: string): (boolean, any)
		checkContext("filter", context)
		local entry, why = submit(author, text, context)
		if entry == nil then
			return false, why
		end
		return true, handle(entry, author, context)
	end

	function api.textFor(viewer: any, author: any, text: string, context: string): string?
		checkContext("textFor", context)
		local c = cfg()
		local clean = TextFilter.clean(text, c.maxLength, c.trim)
		if clean == nil or not present(author) or not policyAllows(author, context) then
			return nil
		end
		if not mayView(viewer, author, context) then
			return nil
		end
		local entry = redisplay(author, clean, context)
		if entry == nil then
			return nil
		end
		return stringForViewer(entry, viewer, author, context)
	end

	function api.store(author: any, text: string, context: string): (boolean, any)
		checkContext("store", context)
		local entry, why, clean = submit(author, text, context)
		if entry == nil then
			return false, why
		end
		local now = ctx.now()
		local id: number? = nil
		local saved = ctx.data.update(author, function(section: any)
			section.originals = section.originals or {}
			local n = tonumber(section.nextId) or 1
			section.originals[tostring(n)] = { t = clean, c = context, at = now }
			section.nextId = n + 1
			id = n
			-- keep at most originals.max: drop the oldest (the lowest id) first
			local ids = {}
			for k in section.originals do
				local v = tonumber(k)
				if v then
					table.insert(ids, v)
				end
			end
			table.sort(ids)
			for i = 1, #ids - cfg().originals.max do
				section.originals[tostring(ids[i])] = nil
			end
		end)
		if not saved or id == nil then
			return false, "author_offline"
		end
		return true,
			table.freeze({
				id = id,
				author = author.UserId,
				context = context,
				at = now,
				shown = if context == "public" then entry.public else nil,
			})
	end

	local function validStored(stored: any): boolean
		return type(stored) == "table"
			and type(stored.id) == "number"
			and type(stored.author) == "number"
			and type(stored.context) == "string"
			and CONTEXTS[stored.context] == true
	end

	local function away(stored: any): string?
		if stored.context ~= "public" or type(stored.shown) ~= "string" or type(stored.at) ~= "number" then
			return nil
		end
		if ctx.now() - stored.at > cfg().shownMaxDays * DAY then
			return nil
		end
		return stored.shown
	end

	function api.shown(stored: any, viewer: any?): string?
		if not validStored(stored) then
			return nil
		end
		local author = online[stored.author]
		if author == nil or not present(author) then
			return away(stored)
		end
		local section = ctx.data.get(author)
		local originals = if section and type(section.originals) == "table" then section.originals else nil
		local original = if originals then originals[tostring(stored.id)] else nil
		if type(original) ~= "table" or type(original.t) ~= "string" or original.c ~= stored.context then
			return away(stored) -- dropped (released or over originals.max): as if the author were away
		end
		if not policyAllows(author, stored.context) then
			return nil
		end
		if viewer ~= nil and not mayView(viewer, author, stored.context) then
			return nil
		end
		if viewer == nil and stored.context ~= "public" then
			return nil
		end
		local entry = redisplay(author, original.t, stored.context)
		if entry == nil then
			return away(stored)
		end
		if viewer == nil then
			return entry.public
		end
		return stringForViewer(entry, viewer, author, stored.context)
	end

	function api.release(author: any, stored: any)
		if not validStored(stored) or not present(author) or author.UserId ~= stored.author then
			return
		end
		ctx.data.update(author, function(section: any)
			if type(section.originals) == "table" then
				section.originals[tostring(stored.id)] = nil
			end
		end)
	end

	function part.init(context: any)
		ctx = context
	end

	function part.start(_context: any)
		ctx.data.onLoaded(function(player: any)
			online[player.UserId] = player
		end)
		ctx.lifecycle.onPlayerRemoving(function(player: any)
			if online[player.UserId] == player then
				online[player.UserId] = nil
			end
			rate[player] = nil
			local id = tostring(player.UserId)
			for key in friends do
				local a, b = string.match(key, "^(%d+):(%d+)$")
				if a == id or b == id then
					friends[key] = nil
				end
			end
		end)
	end

	part.api = api
	return part
end

return TextFilter
