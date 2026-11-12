--!nocheck
--[[
	Simulated Instances for game code that builds a small tree under a player (v1.6.0 dogfood:
	the playbook's leaderstats recipe, docs/agents/adopt-existing-game.md step 8). typeof() of
	any of them (and of a sim player) is "Instance" (Server.luau simTypeof), and they behave like
	the real thing for what that code uses, so game code needs NO "is this the sim?" guard:

	  Instance.new(className, parent?)   Folder, Configuration, Model and the value classes
	                                     (IntValue, NumberValue, StringValue, BoolValue,
	                                     ObjectValue); any other class errors (not simulated)
	  .Name (default = ClassName), .ClassName, .Parent (re-parenting moves it; nil removes it)
	  .Value (value classes: 0 / "" / false / nil by default; IntValue rounds like Roblox)
	  .Changed (value classes: fires with the new value), :GetPropertyChangedSignal(prop)
	  child by name (`player.leaderstats.Coins`), :FindFirstChild(name, recursive?),
	  :WaitForChild(name, timeout?)       (a server thread waits, sim time; returns nil after
	                                      the timeout; on a spec's own thread it never yields:
	                                      nil, or an error without a timeout)
	  :FindFirstChildOfClass, :FindFirstChildWhichIsA, :GetChildren, :GetDescendants,
	  :IsA, :IsDescendantOf, :Destroy, :ClearAllChildren, :GetAttribute / :SetAttribute

	A sim player gets the same tree methods through Instances.attach (Server:join). Reading a
	member that doesn't exist returns nil (Roblox would error); that never hides a crash in
	code that works in Roblox.
]]

local Signal = require(script.Parent.Signal)

local Instances = {}

Instances.CLASSES = {
	Folder = true,
	Configuration = true,
	Model = true,
	IntValue = 0,
	NumberValue = 0,
	StringValue = "",
	BoolValue = false,
	ObjectValue = "nil",
}

local SUPER = { Configuration = "Instance", Folder = "Instance", Model = "PVInstance" }

local function isValueClass(className: string): boolean
	return string.sub(className, -5) == "Value"
end

-- Every node (and each attached player) keeps its tree state here, never in its own fields.
local state: { [any]: any } = setmetatable({}, { __mode = "k" })

local function children(node: any): { any }
	local s = state[node]
	return if s then s.children else {}
end

local function setParent(node: any, parent: any)
	local s = state[node]
	local old = s.parent
	if old == parent then
		return
	end
	if parent ~= nil then
		assert(
			state[parent] ~= nil,
			"sim: Parent must be a simulated Instance (Instance.new or a sim player)"
		)
		local p = parent
		while p ~= nil do
			if p == node then
				error(
					"sim: attempt to set parent of " .. tostring(s.props.Name) .. " to a descendant of itself",
					3
				)
			end
			p = state[p] and state[p].parent
		end
	end
	if old ~= nil then
		local list = children(old)
		local index = table.find(list, node)
		if index then
			table.remove(list, index)
		end
	end
	s.parent = parent
	if parent ~= nil then
		table.insert(state[parent].children, node)
	end
end

local function findChild(node: any, name: string, recursive: boolean?): any
	for _, child in children(node) do
		if state[child].props.Name == name then
			return child
		end
	end
	if recursive then
		for _, child in children(node) do
			local found = findChild(child, name, true)
			if found ~= nil then
				return found
			end
		end
	end
	return nil
end

local function className(node: any): string
	local s = state[node]
	return if s.props then s.props.ClassName else rawget(node, "ClassName")
end

local function isA(node: any, name: string): boolean
	local cls = className(node)
	if name == cls or name == "Instance" then
		return true
	end
	if cls == "Player" then
		return false
	end
	if isValueClass(cls) then
		return name == "ValueBase"
	end
	return SUPER[cls] == name
end

-- The tree methods shared by simulated Instances and sim players. `server` gives WaitForChild its
-- scheduler.
local function methods(server: any): { [string]: any }
	local m = {}
	function m.FindFirstChild(self, name: string, recursive: boolean?)
		return findChild(self, name, recursive)
	end
	function m.WaitForChild(self, name: string, timeout: number?)
		local found = findChild(self, name)
		if found ~= nil then
			return found
		end
		local scheduler = server.scheduler
		local thread = coroutine.running()
		if not coroutine.isyieldable() or thread == scheduler.specThread then
			if timeout ~= nil then
				return nil
			end
			error(
				"sim: WaitForChild('"
					.. tostring(name)
					.. "') would wait forever on the spec's own thread; give a timeout or run it in server:spawn",
				2
			)
		end
		local waited = 0
		local warned = false
		while true do
			waited += scheduler:wait(0.1)
			found = findChild(self, name)
			if found ~= nil then
				return found
			end
			if timeout ~= nil and waited >= timeout then
				return nil
			end
			if timeout == nil and not warned and waited >= 5 then
				warned = true
				server.globals.warn(
					"Infinite yield possible on '"
						.. tostring(self)
						.. ':WaitForChild("'
						.. tostring(name)
						.. "\")'"
				)
			end
		end
	end
	function m.FindFirstChildOfClass(self, cls: string)
		for _, child in children(self) do
			if className(child) == cls then
				return child
			end
		end
		return nil
	end
	function m.FindFirstChildWhichIsA(self, cls: string)
		for _, child in children(self) do
			if isA(child, cls) then
				return child
			end
		end
		return nil
	end
	function m.GetChildren(self)
		return table.clone(children(self))
	end
	function m.GetDescendants(self)
		local out = {}
		local function walk(n)
			for _, child in children(n) do
				table.insert(out, child)
				walk(child)
			end
		end
		walk(self)
		return out
	end
	function m.ClearAllChildren(self)
		for _, child in table.clone(children(self)) do
			child:Destroy()
		end
	end
	function m.IsDescendantOf(self, ancestor: any)
		local p = state[self] and state[self].parent
		while p ~= nil do
			if p == ancestor then
				return true
			end
			p = state[p] and state[p].parent
		end
		return false
	end
	function m.GetAttribute(self, name: string)
		return state[self].attributes[name]
	end
	function m.SetAttribute(self, name: string, value: any)
		state[self].attributes[name] = value
	end
	function m.GetAttributes(self)
		return table.clone(state[self].attributes)
	end
	return m
end

-- Gives a sim player (a plain table with raw fields) the tree methods and child-by-name lookup.
function Instances.attach(server: any, player: any)
	state[player] = { children = {}, attributes = {} }
	for name, fn in methods(server) do
		player[name] = fn
	end
	function player.IsA(p, cls: string)
		return isA(p, cls)
	end
	local mt = getmetatable(player) or {}
	mt.__index = function(p, key)
		return findChild(p, key)
	end
	setmetatable(player, mt)
end

-- The sim's `Instance` global for game code: Instance.new(className, parent?).
function Instances.library(server: any, extra: ((string) -> any)?): any
	local shared = methods(server)
	local function new(cls: string, parent: any?)
		local default = Instances.CLASSES[cls]
		if default == nil then
			if extra then
				local made = extra(cls)
				if made ~= nil then
					return made
				end
			end
			error("sim: Instance.new('" .. tostring(cls) .. "') is not simulated", 2)
		end
		local props = { ClassName = cls, Name = cls }
		if isValueClass(cls) then
			props.Value = if default == "nil" then nil else default
		end
		local node = { __simInstance = true }
		local s = { props = props, children = {}, attributes = {}, parent = nil, signals = {} }
		state[node] = s
		local function signalFor(prop: string)
			s.signals[prop] = s.signals[prop] or Signal.new(server.scheduler, server, cls .. "." .. prop)
			return s.signals[prop]
		end
		local own = {}
		function own.IsA(_self, name: string)
			return isA(node, name)
		end
		function own.Destroy(_self)
			for _, child in table.clone(s.children) do
				child:Destroy()
			end
			setParent(node, nil)
		end
		function own.GetPropertyChangedSignal(_self, prop: string)
			return signalFor("prop:" .. prop)
		end
		function own.GetFullName(_self)
			local parts = { props.Name }
			local p = s.parent
			while p ~= nil do
				table.insert(
					parts,
					1,
					tostring(rawget(p, "Name") or (state[p].props and state[p].props.Name))
				)
				p = state[p].parent
			end
			return table.concat(parts, ".")
		end
		setmetatable(node, {
			__index = function(_, key)
				if key == "Parent" then
					return s.parent
				elseif key == "Changed" and isValueClass(cls) then
					return signalFor("Changed")
				end
				local v = props[key]
				if v ~= nil then
					return v
				end
				v = own[key] or shared[key]
				if v ~= nil then
					return v
				end
				return findChild(node, key)
			end,
			__newindex = function(_, key, value)
				if key == "Parent" then
					setParent(node, value)
					return
				elseif key == "ClassName" then
					error("sim: ClassName is read-only", 2)
				elseif key == "Name" then
					props.Name = tostring(value)
				elseif key == "Value" and isValueClass(cls) then
					if cls == "IntValue" then
						assert(type(value) == "number", "sim: IntValue.Value expects a number")
						value = math.floor(value + 0.5)
					elseif cls == "NumberValue" then
						assert(type(value) == "number", "sim: NumberValue.Value expects a number")
					elseif cls == "StringValue" then
						value = tostring(value)
					elseif cls == "BoolValue" then
						value = value == true
					end
					local changed = props.Value ~= value
					props.Value = value
					if changed then
						if s.signals.Changed then
							s.signals.Changed:Fire(value)
						end
						if s.signals["prop:Value"] then
							s.signals["prop:Value"]:Fire()
						end
					end
					return
				else
					props[key] = value
				end
				if s.signals["prop:" .. key] then
					s.signals["prop:" .. key]:Fire()
				end
			end,
			__tostring = function()
				return props.Name
			end,
		})
		if parent ~= nil then
			setParent(node, parent)
		end
		return node
	end
	return { new = new }
end

return Instances
