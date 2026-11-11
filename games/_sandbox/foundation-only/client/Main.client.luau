--!strict
-- Foundation-only client: starts StudWork, mounts the HUD (no currency/goal without Economy/Rebirth)
-- and shows that a module's client action errors clearly when the module is off.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Config = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))
local Rebirth =
	require(ReplicatedStorage:WaitForChild("Kits"):WaitForChild("Economy"):WaitForChild("Rebirth"))

StudWork.start(Config)
StudWork.Client.Hud.mount()

local result = table.pack(pcall(function()
	StudWork.use(Rebirth).actions.rebirth()
end))
print(`[foundation-only] client Rebirth.actions.rebirth -> ok={result[1]} {tostring(result[2])}`)
