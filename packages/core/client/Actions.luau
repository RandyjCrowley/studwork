--!strict
--[[
	Core.Client.Actions: thin client -> server requests. LEAD-OWNED.
	Never assume success: the server validates and the result arrives through Core.Client.state.
]]

local Generated = require(script.Parent.Net.Generated)

local Actions = {}

function Actions.display(uid: string, slotId: string?)
	Generated.RequestDisplay.Fire(uid, slotId)
end

function Actions.clearDisplay(uid: string)
	Generated.RequestClearDisplay.Fire(uid)
end

function Actions.rebirth()
	Generated.RequestRebirth.Fire()
end

function Actions.upgrade(upgradeId: string)
	Generated.RequestUpgrade.Fire(upgradeId)
end

function Actions.roll(tableId: string)
	Generated.RequestRoll.Fire(tableId)
end

function Actions.gift(toUserId: number, uid: string)
	Generated.RequestGift.Fire(toUserId, uid)
end

function Actions.triggerEvent(eventId: string)
	Generated.AdminTriggerEvent.Fire(eventId)
end

function Actions.funnel(step: string)
	Generated.ClientFunnel.Fire(step)
end

return Actions
