--!strict
--[[
	Start gate for StudWork.Client's framework actions (pure): every action errors before
	StudWork.start. core-v1.3.1 (R19): the framework knows no module's actions any more (the v1.2
	action -> kit module table is gone); a module's client actions are
	StudWork.use(<ModuleRef>).actions.<name>, whose not-enabled error is the client runtime's
	erroring proxy (Resolve.notEnabledMessage).
]]

local ActionGate = {}

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
	return nil
end

function ActionGate.isEnabled(gate: Gate, name: string): boolean
	return gate.enabled[name] == true or table.find(ActionGate.FOUNDATION, name) ~= nil
end

return ActionGate
