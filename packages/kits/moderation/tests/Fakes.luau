--!nocheck
--[[
	Engine fakes for the moderation kit's specs (Lune; not synced by Rojo). Nothing here talks to
	Roblox; every fake records its calls. Pass them through the harness:
	  StudWork.test.harness({ services = { Players = Fakes.players(), GroupService = Fakes.groupService(),
	                                       TextChatService = Fakes.textChatService() }, ... })
	MessagingService is NOT faked: cross-server delivery goes through ctx.data.messages (the harness
	memory store / the sim).
	From a game's specs (docs/framework/kits/moderation.md "Tests (mocked)"): require
	  (require :: any)("studwork/packages/kits/moderation/tests/Fakes.luau")   -- single-game project
	and pass GroupService to a Boot.spec as
	  StudWork.test.sim.bootGame("default.project.json", { services = { GroupService = Fakes.groupService() } })

	Fakes.players(opts?)  ctx.services.get("Players")
	  opts = { bans = { [userId] = { Duration, DisplayReason, PrivateReason, StartTime } }?,
	           history = { [userId] = { entry } }?, banningEnabled = true?, pageSize = 2? }
	  engine:  BanAsync(config), UnbanAsync(config), GetBanHistoryAsync(userId) -> pages
	           (GetCurrentPage, IsFinished, AdvanceToNextPageAsync), BanningEnabled,
	           GetPlayers(), GetPlayerByUserId(id) (from fake.online, a { [userId] = player })
	  test:    calls { { method, args } }, count(method), failNext(n, message?) (the next n
	           Ban/Unban/GetBanHistory calls raise; default message is Roblox's transient form
	           "HTTP failure for UserId <id>: Timedout"), recover() (drops the queued failures),
	           bans (current bans by userId), history, setOnline(players)
	  opts.online = fn(userId) -> player? (sims: one fake shared by several sim servers; a ban
	           kicks the player wherever they are online)
	  BanAsync validates like Roblox: UserIds 1..50 numbers, Duration an integer > 0 or -1,
	  DisplayReason <= 400 and PrivateReason <= 1000 characters (raises a non-transient error).

	Fakes.groupService(opts?)  ctx.services.get("GroupService")
	  opts = { roles = { [groupId] = { [userId] = { { Id, Name, Rank } } } }? }
	  engine:  GetRolesInGroupAsync(userId, groupId) -> { IsMember, Roles } (highest first)
	  test:    calls, lookups(), failNext(n, message?), setRoles(groupId, userId, roles)

	Fakes.textChatService(opts?)  ctx.services.get("TextChatService")
	  engine:  TextChannels (FindFirstChild, GetChildren, GetDescendants), DescendantAdded:Connect(fn),
	           ChatVersion
	  test:    addChannel(name) -> channel; channel:AddUserAsync(userId) -> textSource
	           (UserId, CanSend = true, fires DescendantAdded); source(userId, channel?) -> textSource;
	           sources(userId) -> { textSource }; connections()

	Fakes.giveGui(player) -> gui   a fake PlayerGui on a harness mock player:
	  player:FindFirstChild("PlayerGui") returns it; gui:FindFirstChild(name), gui:GetChildren(),
	  gui.add(child) (records a delivered child: { Name, ... }), gui.children, gui.lookups (how often
	  FindFirstChild("PlayerGui") was called on the player).
]]

local Fakes = {}

local MAX_IDS = 50
local MAX_DISPLAY = 400
local MAX_PRIVATE = 1000

local function signal(): any
	local s = { handlers = {} }
	function s.Connect(_self: any, fn: any): any
		table.insert(s.handlers, fn)
		local conn = { Connected = true }
		function conn.Disconnect(c: any)
			c.Connected = false
			local i = table.find(s.handlers, fn)
			if i then
				table.remove(s.handlers, i)
			end
		end
		return conn
	end
	function s.Fire(...)
		for _, fn in table.clone(s.handlers) do
			fn(...)
		end
	end
	return s
end

local function failer(defaultMessage: (any) -> string): any
	local f = { queue = {} }
	function f.add(n: number, message: string?)
		for _ = 1, n do
			table.insert(f.queue, message or false)
		end
	end
	function f.take(arg: any)
		if #f.queue > 0 then
			local message = table.remove(f.queue, 1)
			error(if message then message else defaultMessage(arg), 0)
		end
	end
	return f
end

--------------------------------------------------------------------------------
-- Players
--------------------------------------------------------------------------------

function Fakes.players(opts: any?): any
	local o = opts or {}
	local fake: any = {
		calls = {},
		bans = table.clone(o.bans or {}),
		history = {},
		BanningEnabled = if o.banningEnabled == nil then true else o.banningEnabled,
		online = {},
		pageSize = o.pageSize or 2,
	}
	for userId, entries in o.history or {} do
		fake.history[userId] = table.clone(entries)
	end
	local fail = failer(function(config: any): string
		local id = if type(config) == "table" and type(config.UserIds) == "table"
			then config.UserIds[1]
			else config
		return `HTTP failure for UserId {tostring(id)}: Timedout`
	end)

	function fake.failNext(n: number, message: string?)
		fail.add(n, message)
	end

	-- the outage ends: every queued failure is dropped
	function fake.recover()
		table.clear(fail.queue)
	end

	function fake.count(method: string): number
		local n = 0
		for _, c in fake.calls do
			if c.method == method then
				n += 1
			end
		end
		return n
	end

	function fake.setOnline(list: { any })
		fake.online = {}
		for _, p in list do
			fake.online[p.UserId] = p
		end
	end

	-- (sims) opts.online(userId) -> player?: who is online anywhere in the universe (several sim
	-- servers share one fake: a ban kicks the player wherever they are, like Roblox's BanAsync)
	if type(o.online) == "function" then
		local lookup = o.online
		fake.online = setmetatable({}, {
			__index = function(_, userId: any): any
				return lookup(userId)
			end,
		})
	end

	local function record(method: string, args: any)
		table.insert(fake.calls, { method = method, args = args })
	end

	local function checkIds(method: string, config: any)
		if type(config) ~= "table" or type(config.UserIds) ~= "table" then
			error(`Players:{method}: config.UserIds is required`, 0)
		end
		if #config.UserIds < 1 or #config.UserIds > MAX_IDS then
			error(`Players:{method}: UserIds must hold 1..{MAX_IDS} ids`, 0)
		end
		for _, id in config.UserIds do
			if type(id) ~= "number" then
				error(`Players:{method}: every UserId must be a number`, 0)
			end
		end
	end

	local function addHistory(userId: number, entry: any)
		fake.history[userId] = fake.history[userId] or {}
		table.insert(fake.history[userId], 1, entry) -- newest first
	end

	function fake.BanAsync(_self: any, config: any)
		record("BanAsync", if type(config) == "table" then table.clone(config) else config)
		fail.take(config)
		checkIds("BanAsync", config)
		local d = config.Duration
		if type(d) ~= "number" or d % 1 ~= 0 or (d <= 0 and d ~= -1) then
			error("Players:BanAsync: Duration must be an integer > 0 or -1", 0)
		end
		if
			type(config.DisplayReason) ~= "string"
			or utf8.len(config.DisplayReason) == nil
			or utf8.len(config.DisplayReason) > MAX_DISPLAY
		then
			error(`Players:BanAsync: DisplayReason must be a string of at most {MAX_DISPLAY} characters`, 0)
		end
		if
			type(config.PrivateReason) ~= "string"
			or utf8.len(config.PrivateReason) == nil
			or utf8.len(config.PrivateReason) > MAX_PRIVATE
		then
			error(`Players:BanAsync: PrivateReason must be a string of at most {MAX_PRIVATE} characters`, 0)
		end
		for _, id in config.UserIds do
			local entry = {
				Ban = true,
				Duration = d,
				DisplayReason = config.DisplayReason,
				PrivateReason = config.PrivateReason,
				StartTime = "2023-11-14T22:13:20Z",
				PlaceId = if config.ApplyToUniverse == false then 1 else -1,
				ExcludeAltAccounts = config.ExcludeAltAccounts,
				ApplyDeviceBlock = config.ApplyDeviceBlock,
			}
			fake.bans[id] = entry
			addHistory(id, entry)
			local p = fake.online[id]
			if p ~= nil and type(p.Kick) == "function" then
				p:Kick(config.DisplayReason)
			end
		end
	end

	function fake.UnbanAsync(_self: any, config: any)
		record("UnbanAsync", if type(config) == "table" then table.clone(config) else config)
		fail.take(config)
		checkIds("UnbanAsync", config)
		for _, id in config.UserIds do
			fake.bans[id] = nil
			addHistory(id, {
				Ban = false,
				Duration = 0,
				DisplayReason = "",
				PrivateReason = "",
				StartTime = "2023-11-14T22:13:20Z",
				PlaceId = if config.ApplyToUniverse == false then 1 else -1,
			})
		end
	end

	function fake.GetBanHistoryAsync(_self: any, userId: number): any
		record("GetBanHistoryAsync", { userId })
		fail.take(userId)
		local all = table.clone(fake.history[userId] or {})
		local size = fake.pageSize
		local pages: any = { page = 1 }
		local function slice(): { any }
			local out = {}
			for i = (pages.page - 1) * size + 1, math.min(pages.page * size, #all) do
				table.insert(out, table.clone(all[i]))
			end
			return out
		end
		pages.IsFinished = pages.page * size >= #all
		function pages.GetCurrentPage(_p: any): { any }
			return slice()
		end
		function pages.AdvanceToNextPageAsync(p: any)
			record("AdvanceToNextPageAsync", { userId })
			if p.IsFinished then
				error("Pages:AdvanceToNextPageAsync: no more pages", 0)
			end
			p.page += 1
			p.IsFinished = p.page * size >= #all
		end
		return pages
	end

	function fake.GetPlayers(_self: any): { any }
		local out = {}
		for _, p in fake.online do
			table.insert(out, p)
		end
		table.sort(out, function(a, b)
			return a.UserId < b.UserId
		end)
		return out
	end

	function fake.GetPlayerByUserId(_self: any, userId: number): any
		return fake.online[userId]
	end

	return fake
end

--------------------------------------------------------------------------------
-- GroupService
--------------------------------------------------------------------------------

function Fakes.groupService(opts: any?): any
	local o = opts or {}
	local roles: { [number]: { [number]: { any } } } = {}
	for groupId, users in o.roles or {} do
		roles[groupId] = {}
		for userId, list in users do
			roles[groupId][userId] = table.clone(list)
		end
	end
	local fake: any = { calls = {} }
	local fail = failer(function(): string
		return "GroupService:GetRolesInGroupAsync: HTTP 503 (Service Unavailable)"
	end)

	function fake.failNext(n: number, message: string?)
		fail.add(n, message)
	end

	function fake.lookups(): number
		return #fake.calls
	end

	function fake.setRoles(groupId: number, userId: number, list: { any }?)
		roles[groupId] = roles[groupId] or {}
		roles[groupId][userId] = if list then table.clone(list) else nil
	end

	function fake.GetRolesInGroupAsync(_self: any, userId: number, groupId: number): any
		table.insert(fake.calls, { method = "GetRolesInGroupAsync", userId = userId, groupId = groupId })
		fail.take(nil)
		local list = roles[groupId] and roles[groupId][userId]
		if list == nil or #list == 0 then
			return { IsMember = false, Roles = {} }
		end
		local sorted = {}
		for _, r in list do
			table.insert(sorted, { Id = r.Id, Name = r.Name, Rank = r.Rank })
		end
		table.sort(sorted, function(a, b)
			return a.Rank > b.Rank
		end)
		return { IsMember = true, Roles = sorted }
	end

	return fake
end

--------------------------------------------------------------------------------
-- TextChatService
--------------------------------------------------------------------------------

local function container(name: string, className: string): any
	local c: any = { Name = name, ClassName = className, children = {} }
	function c.FindFirstChild(self: any, childName: string): any
		for _, child in self.children do
			if child.Name == childName then
				return child
			end
		end
		return nil
	end
	function c.GetChildren(self: any): { any }
		return table.clone(self.children)
	end
	function c.GetDescendants(self: any): { any }
		local out = {}
		for _, child in self.children do
			table.insert(out, child)
			if type(child.GetDescendants) == "function" then
				for _, d in child:GetDescendants() do
					table.insert(out, d)
				end
			end
		end
		return out
	end
	function c.IsA(self: any, cls: string): boolean
		return self.ClassName == cls or cls == "Instance"
	end
	return c
end

function Fakes.textChatService(opts: any?): any
	local o = opts or {}
	local fake: any = container("TextChatService", "TextChatService")
	fake.ChatVersion = o.chatVersion or "TextChatService"
	fake.DescendantAdded = signal()
	local channels = container("TextChannels", "Folder")
	fake.TextChannels = channels
	table.insert(fake.children, channels)

	function fake.addChannel(name: string): any
		local channel = container(name, "TextChannel")
		function channel.AddUserAsync(self: any, userId: number): (any, boolean)
			for _, s in self.children do
				if s.UserId == userId then
					return s, true
				end
			end
			local source = container(tostring(userId), "TextSource")
			source.UserId = userId
			source.CanSend = true
			table.insert(self.children, source)
			fake.DescendantAdded.Fire(source)
			return source, true
		end
		table.insert(channels.children, channel)
		fake.DescendantAdded.Fire(channel)
		return channel
	end

	function fake.source(userId: number, channelName: string?): any
		for _, channel in channels.children do
			if channelName == nil or channel.Name == channelName then
				for _, s in channel.children do
					if s.UserId == userId then
						return s
					end
				end
			end
		end
		return nil
	end

	function fake.sources(userId: number): { any }
		local out = {}
		for _, channel in channels.children do
			for _, s in channel.children do
				if s.UserId == userId then
					table.insert(out, s)
				end
			end
		end
		return out
	end

	function fake.connections(): number
		return #fake.DescendantAdded.handlers
	end

	return fake
end

--------------------------------------------------------------------------------
-- PlayerGui on a harness mock player
--------------------------------------------------------------------------------

function Fakes.giveGui(player: any): any
	local gui = container("PlayerGui", "PlayerGui")
	gui.lookups = 0
	function gui.add(child: any): any
		table.insert(gui.children, child)
		return child
	end
	player.PlayerGui = gui
	player.FindFirstChild = function(_self: any, name: string): any
		if name == "PlayerGui" then
			gui.lookups += 1
			return gui
		end
		return nil
	end
	return gui
end

return Fakes
