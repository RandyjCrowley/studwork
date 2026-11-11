--!strict
--[[
	Screen registry (module-api.md §13), pure. UI.registerScreen / UI.open / UI.close use one
	shared registry (UI.screens); Screens.new() makes an isolated one (tests).

	reg:register(name, component)  add or REPLACE a screen (a game replaces a default screen by
	                               registering the same name); component = React component
	reg:get(name) -> component?    reg:names() -> sorted names
	reg:open(name, props?)         show it (props are passed through, plus onClose); opening an
	                               open screen replaces its props; errors on an unknown name
	reg:close(name)                reg:isOpen(name)
	reg:openList() -> { { name, component, props } } in open order (later = on top)
	reg:subscribe(fn) -> unsubscribe   fn() after every register / open / close
]]

local Screens = {}
Screens.__index = Screens

export type Entry = { name: string, component: any, props: { [string]: any } }

function Screens.new(): any
	return setmetatable({ _screens = {}, _open = {}, _listeners = {} }, Screens)
end

local function isComponent(c: any): boolean
	return type(c) == "function" or type(c) == "table"
end

function Screens.notify(self: any)
	for fn in self._listeners do
		fn()
	end
end

function Screens.register(self: any, name: string, component: any)
	assert(type(name) == "string" and name ~= "", "UI.registerScreen: name must be a non-empty string")
	assert(isComponent(component), `UI.registerScreen('{name}'): component must be a React component`)
	self._screens[name] = component
	self:notify()
end

function Screens.get(self: any, name: string): any
	return self._screens[name]
end

function Screens.names(self: any): { string }
	local out = {}
	for name in self._screens do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

function Screens.open(self: any, name: string, props: { [string]: any }?)
	if self._screens[name] == nil then
		error(`UI.open: no screen '{tostring(name)}' (UI.registerScreen it first)`, 2)
	end
	for i, entry in self._open do
		if entry.name == name then
			table.remove(self._open, i)
			break
		end
	end
	table.insert(self._open, { name = name, props = props or {} })
	self:notify()
end

function Screens.close(self: any, name: string)
	for i, entry in self._open do
		if entry.name == name then
			table.remove(self._open, i)
			self:notify()
			return
		end
	end
end

function Screens.isOpen(self: any, name: string): boolean
	for _, entry in self._open do
		if entry.name == name then
			return true
		end
	end
	return false
end

-- Resolved at read time, so a screen replaced while open renders the new component.
function Screens.openList(self: any): { Entry }
	local out: { Entry } = {}
	for _, entry in self._open do
		local component = self._screens[entry.name]
		if component ~= nil then
			table.insert(out, { name = entry.name, component = component, props = entry.props })
		end
	end
	return out
end

function Screens.subscribe(self: any, fn: () -> ()): () -> ()
	self._listeners[fn] = true
	return function()
		self._listeners[fn] = nil
	end
end

return Screens
