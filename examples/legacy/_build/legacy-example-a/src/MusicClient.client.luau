-- MusicClient: background music with an on/off key (M); the choice is saved on the server.
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local music = Instance.new("Sound")
music.Name = "Music"
music.Looped = true
music.Volume = 0.3
music.Parent = workspace
local on = true

UserInputService.InputBegan:Connect(function(input, processed)
	if processed or input.KeyCode ~= Enum.KeyCode.M then
		return
	end
	on = not on
	if on then
		music:Resume()
	else
		music:Pause()
	end
	Remotes.ToggleMusic:FireServer(on)
end)
