--!nocheck
--[[
	A fake replicated client state for the Quests client specs (Lune only), without Charm (the
	real package can't load under Lune; FakeState.luau needs it). Same shape and recording as
	FakeState: a plain state table, `fs:board(board)` / `fs:prog(prog)` / `fs:odds(odds)` replace the
	slice (a new table each time), `fs:start(opts?)` boots the client runtime with it and `fs.fired`
	records every action. After a change call `fs:check()` (the part's watcher; with Charm the
	subscription does it).

	  local fs = Kit.new({ board = <extra.board>, prog = {...} })
	  fs:start({ config = { Quests = ... }, gameConfig = { ... } })
	  fs:stop()   (afterEach)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Boot = require(ReplicatedStorage:WaitForChild("FrameworkClient"):WaitForChild("Boot"))
local Runtime = require(ReplicatedStorage:WaitForChild("FrameworkClient"):WaitForChild("Runtime"))
local Modules = ReplicatedStorage:WaitForChild("Modules")
local Quests = require(Modules:WaitForChild("Quests"):WaitForChild("module"))

local Kit = {}
Kit.__index = Kit

local function pascal(name: string): string
	return string.upper(string.sub(name, 1, 1)) .. string.sub(name, 2)
end

function Kit.new(extra: { [string]: any }?)
	local self = setmetatable({ fired = {}, state = nil, part = nil }, Kit)
	self.state = {
		loaded = true,
		framework = { activeEvents = {}, flags = {} },
		modules = { Quests = { data = {}, extra = extra or {} } },
	}
	return self
end

function Kit.set(self, key: string, value)
	local state = table.clone(self.state)
	state.modules = table.clone(state.modules)
	local slice = table.clone(state.modules.Quests)
	slice.extra = table.clone(slice.extra)
	slice.extra[key] = value
	state.modules.Quests = slice
	self.state = state
end

function Kit.board(self, board)
	self:set("board", board)
end

function Kit.prog(self, prog)
	self:set("prog", prog)
end

function Kit.odds(self, odds)
	self:set("questOdds", odds)
end

function Kit.check(self)
	if self.part and self.part.check then
		self.part.check()
	end
end

function Kit.start(self, opts: { [string]: any }?)
	local o = opts or {}
	Boot.attach(nil)
	local fired = self.fired
	local selfRef = self
	local rt = Runtime.start(
		{
			gameId = "questsclient",
			modules = { Quests },
			config = o.config or {},
			items = {},
			events = {},
		},
		nil,
		{
			state = function()
				return selfRef.state
			end,
			ui = function()
				return {
					state = function()
						return selfRef.state
					end,
				}
			end,
			loadClient = function(_ref)
				-- the part itself; its generated Blink Net module can't load under Lune, so `net` is fake
				local part = require(Modules:WaitForChild("Quests"):WaitForChild("client"))
				local out = table.clone(part)
				local net = {}
				for key, spec in part.actions or {} do
					local name = if type(key) == "number" then spec else key
					local event = pascal(name)
					net[event] = {
						Fire = function(...)
							table.insert(fired, { event = event, args = { ... } })
						end,
					}
				end
				out.net = net
				selfRef.part = part
				return out
			end,
		}
	)
	return rt
end

function Kit.stop(_self)
	Boot.attach(nil)
end

return Kit
