--!strict
--[[
	Core.Client.Actions: thin client -> server requests. LEAD-OWNED.
	Never assume success: the server validates and the result arrives through Core.Client.state.
	Every action errors before Core.start. core-v1.3.1 (R19): only the framework's own actions
	(triggerEvent, funnel); a module's actions are StudWork.use(<ModuleRef>).actions.<name>.
]]

local ActionGate = require(script.Parent.ActionGate)
local Generated = require(script.Parent.Net.Generated)

local Actions = {}

local gate = ActionGate.new()

local function check(action: string)
	local problem = ActionGate.check(gate, action)
	if problem then
		error(problem, 3)
	end
end

-- Called once by the client bootstrap (not part of Core.Client.Actions).
function Actions.start(moduleOrder: { string })
	ActionGate.start(gate, moduleOrder)
end

function Actions.isEnabled(name: string): boolean
	return ActionGate.isEnabled(gate, name)
end

function Actions.triggerEvent(eventId: string)
	check("triggerEvent")
	Generated.AdminTriggerEvent.Fire(eventId)
end

function Actions.funnel(step: string)
	check("funnel")
	Generated.ClientFunnel.Fire(step)
end

return Actions
