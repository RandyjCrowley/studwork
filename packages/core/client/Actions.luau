--!strict
--[[
	Core.Client.Actions: thin client -> server requests. LEAD-OWNED.
	Never assume success: the server validates and the result arrives through Core.Client.state.
	Actions of a module that is not in GameConfig.modules error with
	"<Name> is not enabled in GameConfig.modules" (ActionGate, Modules.CLIENT_ACTIONS); every
	action errors before Core.start.
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

function Actions.display(uid: string, slotId: string?)
	check("display")
	Generated.RequestDisplay.Fire(uid, slotId)
end

function Actions.clearDisplay(uid: string)
	check("clearDisplay")
	Generated.RequestClearDisplay.Fire(uid)
end

function Actions.rebirth()
	check("rebirth")
	Generated.RequestRebirth.Fire()
end

function Actions.upgrade(upgradeId: string)
	check("upgrade")
	Generated.RequestUpgrade.Fire(upgradeId)
end

function Actions.roll(tableId: string)
	check("roll")
	Generated.RequestRoll.Fire(tableId)
end

function Actions.gift(toUserId: number, uid: string)
	check("gift")
	Generated.RequestGift.Fire(toUserId, uid)
end

function Actions.triggerEvent(eventId: string)
	check("triggerEvent")
	Generated.AdminTriggerEvent.Fire(eventId)
end

function Actions.claimMail(messageId: string)
	check("claimMail")
	Generated.RequestMailClaim.Fire(messageId)
end

function Actions.funnel(step: string)
	check("funnel")
	Generated.ClientFunnel.Fire(step)
end

return Actions
