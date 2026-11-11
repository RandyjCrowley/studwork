--!strict
--[[
	Module gate for Core.Client.Actions (pure). An action owned by a kit module
	(ActionGate.CLIENT_ACTIONS) errors with Resolve.notEnabledMessage(module) when that module is
	not in GameConfig.modules; every action errors before Core.start.
	core-v1.3.0 Phase 2: the action -> module table and the framework-service names moved here from
	the deleted v1.2 module manifest; the message is the framework's.
]]

local Resolve =
	require(game:GetService("ReplicatedStorage"):WaitForChild("Framework"):WaitForChild("Resolve"))

local ActionGate = {}

-- Client Actions that belong to a kit module (calling them with the module off errors).
ActionGate.CLIENT_ACTIONS = table.freeze({
	display = "Plot",
	clearDisplay = "Plot",
	rebirth = "Rebirth",
	upgrade = "Upgrades",
	roll = "Rarity",
	gift = "Inventory",
	claimMail = "Mail",
} :: { [string]: string })

-- Framework services: always on.
ActionGate.FOUNDATION = table.freeze({ "Data", "Policy", "Analytics", "Events", "Shop", "Net" })

export type Gate = {
	started: boolean,
	enabled: { [string]: boolean },
}

function ActionGate.new(): Gate
	return { started = false, enabled = {} }
end

function ActionGate.start(gate: Gate, moduleOrder: { string })
	gate.started = true
	for _, name in moduleOrder do
		gate.enabled[name] = true
	end
end

-- Returns nil when the action may run, else the error message.
function ActionGate.check(gate: Gate, action: string): string?
	if not gate.started then
		return `[Core] Core.Client.Actions.{action} called before Core.start`
	end
	local owner = ActionGate.CLIENT_ACTIONS[action]
	if owner ~= nil and not gate.enabled[owner] then
		return "[Core] " .. Resolve.notEnabledMessage(owner)
	end
	return nil
end

function ActionGate.isEnabled(gate: Gate, name: string): boolean
	return gate.enabled[name] == true or table.find(ActionGate.FOUNDATION, name) ~= nil
end

return ActionGate
