--!nocheck
--[[
	A fake engine environment for the Goals client part under Lune (Builder C's helper; Lune only).
	Pass `env` to `require(<Goals client>)._setEnv(env)` before FakeState:start().

	  local E = GoalsClientEnv.new(opts?)
	      opts.viewport = { X, Y } (default 667 x 375, the smallest phone the kit is checked at)
	  E.env                         the environment (UI, collection, root, now, character, project,
	                                heartbeat, buildBeam, buildArrow, reducedMotion)
	  E.clock                       env.now() (seconds); E:advance(dt) moves it and runs Heartbeat once
	  E.charPos                     the character's position (Vector3 stub); set it to move
	  E:part(name, x, y, z, tags?)  a fake BasePart (Parent = a fake world); E:tag(inst, tag) adds a
	                                tag (fires the Added signal), E:streamOut(inst) parents it to nil
	                                and fires Removed
	  E.ui                          the fake UI kit: registered = { [id] = spec }, opened = { name },
	                                texts = { key }
	  E.camera                      a read-only fake camera: writes land in E.cameraWrites
	  E.gui                         a fake GuiService: writes land in E.guiWrites (SelectedObject)
	  E.beams / E.arrows            what buildBeam / buildArrow built (one each at most)
	  E.beamMoves                   how many times the beam's start attachment was moved
	  E.collectionCalls             GetTagged calls per tag
	  E:goal(wire)                  state.modules.Goals.extra.goal = wire (a new state table;
	                                env.subscribe listeners run, like a Charm subscription)
	  E:start(opts?) -> rt          boots the client runtime (Runtime.start) on this state, with
	                                the Goals client's env injected: opts.modules (default
	                                { Quests, Goals }), opts.config. Each client part gets a fake
	                                `net` recording into E.fired ({ event, args }). E:stop() detaches.

	Why not FakeState: under Lune its Charm require can't load (the Wally Charm package has no
	init.luau at the path the testkit maps) and Runtime.defaultLoadClient binds the generated Blink
	Net (needs RunService); this helper keeps the state in a plain table and loads parts without Net.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Boot = require(ReplicatedStorage:WaitForChild("FrameworkClient"):WaitForChild("Boot"))
local Runtime = require(ReplicatedStorage:WaitForChild("FrameworkClient"):WaitForChild("Runtime"))
local Modules = ReplicatedStorage:WaitForChild("Modules")

local GoalsClientEnv = {}
GoalsClientEnv.__index = GoalsClientEnv

local function signal()
	local handlers = {}
	return {
		Connect = function(_self, fn)
			table.insert(handlers, fn)
			return {
				Disconnect = function()
					local i = table.find(handlers, fn)
					if i then
						table.remove(handlers, i)
					end
				end,
			}
		end,
		Fire = function(_self, ...)
			for _, fn in table.clone(handlers) do
				fn(...)
			end
		end,
	}
end

local function recorder(name, writes, reads)
	return setmetatable({}, {
		__index = function(_, key)
			return reads[key]
		end,
		__newindex = function(_, key, value)
			table.insert(writes, { target = name, key = key, value = value })
		end,
	})
end

local function fakeInstance(className, props)
	local inst = props or {}
	inst.ClassName = className
	inst.Enabled = inst.Enabled
	function inst.IsA(self, c)
		return self.ClassName == c
			or (c == "BasePart" and self.ClassName == "Part")
			or (c == "GuiObject" and self.ClassName == "ImageLabel")
	end
	function inst.FindFirstChild(self, name)
		return self.children and self.children[name] or nil
	end
	function inst.Destroy(self)
		self.Parent = nil
		self.destroyed = true
	end
	return inst
end

function GoalsClientEnv.new(opts)
	local o = opts or {}
	local self = setmetatable({}, GoalsClientEnv)
	self.clock = 0
	self.charPos = Vector3.new(0, 3, 0)
	self.viewport = o.viewport or { X = 667, Y = 375 }
	self.beams = {}
	self.beamMoves = 0
	self.arrows = {}
	self.cameraWrites = {}
	self.guiWrites = {}
	self.collectionCalls = {}
	self.tags = {}
	self.added = {}
	self.removed = {}
	self.heartbeats = {}
	self.world = fakeInstance("Folder", { Name = "World", children = {} })
	self.root = fakeInstance("DataModel", { children = { Workspace = self.world } })
	self.world.Parent = self.root

	self.camera = recorder("Camera", self.cameraWrites, {
		WorldToViewportPoint = function(_cam, pos)
			-- a simple projection: x maps to the screen, z < 0 behind the camera
			local vx = self.viewport.X / 2 + pos.X * 10
			local vy = self.viewport.Y / 2 - (pos.Y - 3) * 10
			return Vector3.new(vx, vy, pos.Z), true
		end,
	})
	self.gui = recorder("GuiService", self.guiWrites, { SelectedObject = nil, ReducedMotionEnabled = false })

	local ui = { registered = {}, opened = {}, texts = {} }
	self.ui = ui
	ui.registerWidget = function(id, spec)
		ui.registered[id] = spec
	end
	ui.widgets = function()
		local specs, removals = {}, {}
		for id, spec in ui.registered do
			if spec == false then
				removals[id] = false
			else
				specs[id] = spec
			end
		end
		return specs, removals
	end
	ui.open = function(name)
		table.insert(ui.opened, name)
	end
	ui.text = function(key)
		table.insert(ui.texts, key)
		return key
	end

	local collection = {
		GetTagged = function(_c, tag)
			self.collectionCalls[tag] = (self.collectionCalls[tag] or 0) + 1
			local out = {}
			for inst in self.tags[tag] or {} do
				table.insert(out, inst)
			end
			return out
		end,
		GetInstanceAddedSignal = function(_c, tag)
			self.added[tag] = self.added[tag] or signal()
			return self.added[tag]
		end,
		GetInstanceRemovedSignal = function(_c, tag)
			self.removed[tag] = self.removed[tag] or signal()
			return self.removed[tag]
		end,
	}

	self.fired = {}
	self.listeners = {}
	self.state = {
		loaded = true,
		framework = { activeEvents = {}, paidRandomRestricted = true, flags = {} },
		modules = {
			Quests = {
				data = {},
				extra = { board = { list = {}, waiting = {}, pins = {} }, prog = {}, questOdds = {} },
			},
			Goals = { data = {}, extra = {} },
		},
	}

	self.env = {
		UI = ui,
		state = function()
			return self.state
		end,
		subscribe = function(selector, cb)
			local entry = { selector = selector, cb = cb }
			table.insert(self.listeners, entry)
			return function()
				local i = table.find(self.listeners, entry)
				if i then
					table.remove(self.listeners, i)
				end
			end
		end,
		collection = collection,
		root = self.root,
		now = function()
			return self.clock
		end,
		reducedMotion = function()
			return self.reduced == true
		end,
		heartbeat = function(fn)
			table.insert(self.heartbeats, fn)
			return function()
				local i = table.find(self.heartbeats, fn)
				if i then
					table.remove(self.heartbeats, i)
				end
			end
		end,
		character = function()
			return self.charPos, { Name = "Character" }
		end,
		project = function(pos)
			local p = self.camera:WorldToViewportPoint(pos)
			return p, self.viewport
		end,
		buildBeam = function()
			local parts = {
				beam = fakeInstance("Beam", { Enabled = false, Parent = "Terrain" }),
				from = setmetatable({}, {
					__index = fakeInstance("Attachment", { Parent = "Terrain" }),
					__newindex = function(t, key, value)
						if key == "WorldPosition" then
							self.beamMoves += 1
						end
						rawset(getmetatable(t).__index, key, value)
					end,
				}),
				to = fakeInstance("Attachment", { Parent = "Terrain" }),
			}
			table.insert(self.beams, parts)
			return parts
		end,
		buildArrow = function()
			local label = fakeInstance("ImageLabel", { Visible = false })
			table.insert(self.arrows, label)
			return label
		end,
	}
	return self
end

function GoalsClientEnv.goal(self, wire)
	local out = table.clone(self.state)
	out.modules = table.clone(self.state.modules)
	local slice = table.clone(out.modules.Goals)
	slice.extra = table.clone(slice.extra)
	slice.extra.goal = wire
	out.modules.Goals = slice
	self.state = out
	for _, entry in table.clone(self.listeners) do
		entry.cb(entry.selector())
	end
end

local function pascal(name)
	return string.upper(string.sub(name, 1, 1)) .. string.sub(name, 2)
end

function GoalsClientEnv.start(self, opts)
	local o = opts or {}
	local GoalsClient = require(Modules:WaitForChild("Goals"):WaitForChild("client"))
	GoalsClient._setEnv(self.env)
	Boot.attach(nil)
	local fired = self.fired
	local stateFn = self.env.state
	self.rt = Runtime.start(
		{
			gameId = "goalsfake",
			modules = o.modules or {
				require(Modules:WaitForChild("Quests"):WaitForChild("module")),
				require(Modules:WaitForChild("Goals"):WaitForChild("module")),
			},
			config = o.config or {},
			items = {},
			events = {},
		},
		nil,
		{
			state = stateFn,
			ui = function()
				return { state = stateFn }
			end,
			loadClient = function(ref)
				-- the client part itself, without its generated Blink Net (Blink needs RunService)
				local holder = ref.client and Modules:FindFirstChild(ref.client)
				local clientScript = holder and holder:FindFirstChild("client")
				local part = if clientScript then require(clientScript) else nil
				if type(part) ~= "table" then
					return part
				end
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
				return out
			end,
		}
	)
	return self.rt
end

function GoalsClientEnv.stop(_self)
	local GoalsClient = require(Modules:WaitForChild("Goals"):WaitForChild("client"))
	GoalsClient._setEnv(nil)
	Boot.attach(nil)
end

function GoalsClientEnv.advance(self, dt)
	self.clock += dt
	for _, fn in table.clone(self.heartbeats) do
		fn()
	end
end

function GoalsClientEnv.part(self, name, x, y, z, tags)
	local inst = fakeInstance("Part", { Name = name, Position = Vector3.new(x, y, z), Parent = self.world })
	self.world.children[name] = inst
	for _, tag in tags or {} do
		self:tag(inst, tag)
	end
	return inst
end

function GoalsClientEnv.tag(self, inst, tag)
	self.tags[tag] = self.tags[tag] or {}
	self.tags[tag][inst] = true
	if self.added[tag] then
		self.added[tag]:Fire(inst)
	end
end

function GoalsClientEnv.streamOut(self, inst)
	inst.Parent = nil
	if self.world.children[inst.Name] == inst then
		self.world.children[inst.Name] = nil
	end
	for tag, set in self.tags do
		if set[inst] then
			set[inst] = nil
			if self.removed[tag] then
				self.removed[tag]:Fire(inst)
			end
		end
	end
end

return GoalsClientEnv
