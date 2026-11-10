--!strict
--[[
	Module gate for Core.Client.Actions (pure). An action owned by an optional module
	(Modules.CLIENT_ACTIONS) errors with Modules.notEnabledMessage(module) when that module is not
	in GameConfig.modules; every action errors before Core.start.
]]

local Modules = require(game:GetService("ReplicatedStorage"):WaitForChild("Core"):WaitForChild("Modules"))

local ActionGate = {}

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
	local owner = Modules.CLIENT_ACTIONS[action]
	if owner ~= nil and not gate.enabled[owner] then
		return "[Core] " .. Modules.notEnabledMessage(owner)
	end
	return nil
end

function ActionGate.isEnabled(gate: Gate, name: string): boolean
	return gate.enabled[name] == true or Modules.isFoundation(name)
end

return ActionGate
