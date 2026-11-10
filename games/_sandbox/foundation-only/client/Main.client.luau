--!strict
-- Foundation-only client: starts Core, mounts the HUD (no currency/goal without Economy/Rebirth)
-- and shows that module actions error clearly.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Core = require(ReplicatedStorage:WaitForChild("Core"))
local Config = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))

Core.start(Config)
Core.Client.Hud.mount()

local result = table.pack(pcall(Core.Client.Actions.rebirth))
print(`[foundation-only] client Actions.rebirth -> ok={result[1]} {tostring(result[2])}`)
