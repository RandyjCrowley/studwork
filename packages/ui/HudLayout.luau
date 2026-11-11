--!strict
--[[
	HUD slots and widgets (module-api.md §13), pure.

	Slots: topLeft, topCenter, topRight, left, right, bottom.
	A widget spec: { slot: Slot, order: number?, component: <React component>, module: string? }
	(module = only while that module is enabled). Widget ids are "<Kit or owner>.<name>", e.g.
	"Economy.currency", "Social.mailbox", "Game.nextGoal".

	HudLayout.config(clientHud, load?, isModule?) -> { mode = "default" | "off" | "custom", layout, widgets }
	  clientHud = GameConfig.client.hud: nil | "default" | false | <ModuleScript | component> |
	  { layout = <same>, widgets = { [id] = false | spec } }. load(moduleScript) requires it.
	HudLayout.resolve(defaults, registered, overrides, isEnabled) -> { [Slot]: { {id, spec} } }
	  defaults (framework), then registered (UI.registerWidget), then overrides
	  (client.hud.widgets: false removes, a spec replaces, a bare component replaces only the
	  component of an existing widget, keeping its slot/order/module); sorted by order then id.
]]

local HudLayout = {}

HudLayout.SLOTS = table.freeze({ "topLeft", "topCenter", "topRight", "left", "right", "bottom" })
local SLOT_SET: { [string]: boolean } = {}
for _, s in HudLayout.SLOTS do
	SLOT_SET[s] = true
end

function HudLayout.isSlot(s: any): boolean
	return type(s) == "string" and SLOT_SET[s] == true
end

function HudLayout.checkSpec(id: string, spec: any)
	assert(type(spec) == "table", `HUD widget '{id}': spec must be a table or false`)
	assert(HudLayout.isSlot(spec.slot), `HUD widget '{id}': unknown slot '{tostring(spec.slot)}'`)
	assert(
		type(spec.component) == "function" or type(spec.component) == "table",
		`HUD widget '{id}': component must be a React component`
	)
end

-- A React component given where a widget spec is expected: a function component, a memo /
-- forwardRef object (`$$typeof`) or a class component (a table with a metatable), never a table
-- with `slot` / `component` (that is a spec).
function HudLayout.isBareComponent(v: any): boolean
	if type(v) == "function" then
		return true
	end
	if type(v) ~= "table" or v.slot ~= nil or v.component ~= nil then
		return false
	end
	return v["$$typeof"] ~= nil or getmetatable(v) ~= nil
end

local function isInstance(v: any): boolean
	return typeof(v) == "Instance"
end

local function layoutOf(value: any, load: ((any) -> any)?, isModule: (any) -> boolean): (string, any)
	if isModule(value) then
		assert(load ~= nil, "client.hud: a ModuleScript needs a loader")
		local component = load(value)
		assert(
			type(component) == "function" or type(component) == "table",
			"client.hud: the ModuleScript must return a React component"
		)
		return "custom", component
	elseif value == nil or value == "default" or value == true then
		return "default", nil
	elseif value == false then
		return "off", nil
	elseif
		type(value) == "function" or (type(value) == "table" and value.layout == nil and value.widgets == nil)
	then
		return "custom", value
	end
	error(
		`client.hud: expected "default", false, a ModuleScript or a React component, got {typeof(value)}`,
		0
	)
end

function HudLayout.config(
	clientHud: any,
	load: ((any) -> any)?,
	isModule: ((any) -> boolean)?
): { mode: string, layout: any, widgets: any }
	local moduleTest = isModule or isInstance
	local widgets = {}
	local value = clientHud
	if type(clientHud) == "table" and (clientHud.layout ~= nil or clientHud.widgets ~= nil) then
		value = clientHud.layout
		if clientHud.widgets ~= nil then
			assert(type(clientHud.widgets) == "table", "client.hud.widgets must be a table")
			widgets = clientHud.widgets
		end
	end
	local mode, layout = layoutOf(value, load, moduleTest)
	return { mode = mode, layout = layout, widgets = widgets }
end

export type Placed = { id: string, spec: any }

function HudLayout.resolve(
	defaults: { [string]: any },
	registered: { [string]: any },
	overrides: { [string]: any },
	isEnabled: (name: string) -> boolean
): { [string]: { Placed } }
	local merged: { [string]: any } = table.clone(defaults)
	for id, spec in registered do
		merged[id] = spec
	end
	for id, spec in overrides do
		if spec == false then
			merged[id] = nil
		elseif HudLayout.isBareComponent(spec) then
			-- (added in Phase 2: final review 6) a bare component replaces the widget's component
			-- and keeps its slot, order and module gate
			local base = merged[id]
			assert(
				type(base) == "table",
				`HUD widget '{id}': a bare component can only replace an existing widget; for a new one pass \{ slot, order?, component }`
			)
			local replaced = table.clone(base)
			replaced.component = spec
			merged[id] = replaced
		else
			HudLayout.checkSpec(id, spec)
			merged[id] = spec
		end
	end
	local out: { [string]: { Placed } } = {}
	for _, s in HudLayout.SLOTS do
		out[s] = {}
	end
	for id, spec in merged do
		if spec.module == nil or isEnabled(spec.module) then
			table.insert(out[spec.slot], { id = id, spec = spec })
		end
	end
	for _, list in out do
		table.sort(list, function(a: Placed, b: Placed): boolean
			local oa, ob = a.spec.order or 0, b.spec.order or 0
			if oa ~= ob then
				return oa < ob
			end
			return a.id < b.id
		end)
	end
	return out
end

return HudLayout
