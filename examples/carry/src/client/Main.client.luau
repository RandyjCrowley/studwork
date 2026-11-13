--!strict
--[[
	The carry fixture game's client: StudWork.start(Config) and the framework HUD. The Carry client
	part (interact / pass bindings, the status chip, wobble) mounts itself through the module runtime.

	Studio only: the scripted teleport cheat (Tuning.movement.cheatCommand, "/cheat" in chat). It writes
	the local character's own root CFrame ON THE CLIENT, the way an exploited client would: the move
	reaches the server as the character's replicated physics, so Movement sees an unexplained jump and
	strikes it (`teleport`; watch Movement.signals.Strike or the console command
	`movement samples <userId>`). A SERVER-side write would not do: Movement treats a server-authored
	move as legitimate (it auto-anchors to it), so it can never produce a strike.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Config = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"))
local Tuning = require(ReplicatedStorage:WaitForChild("Game"):WaitForChild("Config"):WaitForChild("Tuning"))

StudWork.start(Config)

StudWork.Client.Hud.mount({})

if RunService:IsStudio() and Tuning.movement.cheatCommand ~= nil then
	local T = Tuning.movement
	local lastCheatAt = -math.huge
	local function cheat(message: string)
		-- both chat paths below can report the same message: one jump per message
		if message ~= T.cheatCommand or os.clock() - lastCheatAt < 0.5 then
			return
		end
		lastCheatAt = os.clock()
		local character = Players.LocalPlayer.Character
		local root: any = character and character:FindFirstChild("HumanoidRootPart")
		if root ~= nil then
			root.CFrame = root.CFrame + Vector3.new(T.cheatDistance, 0, 0)
		end
	end
	TextChatService.SendingMessage:Connect(function(textChatMessage: TextChatMessage)
		cheat(textChatMessage.Text)
	end)
	Players.LocalPlayer.Chatted:Connect(cheat) -- the legacy chat
end
