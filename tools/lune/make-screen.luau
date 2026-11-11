--!nocheck
--[[
	tools/make-screen <game> <ScreenName>
	A React screen at games/<game>/src/client/Screens/<ScreenName>.luau, registered with
	UI.registerScreen by src/client/Screens/init.luau (created once), which Main.client.luau calls
	right after StudWork.start(Config) (module-api.md §13). Open it with UI.open("<ScreenName>").
	Pure parts: MakeGen.luau (self-test: MakeGen.spec.luau).
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local MakeGen = require("./MakeGen")

local args = process.args
if #args ~= 2 then
	print("usage: tools/make-screen <game> <ScreenName>")
	process.exit(1)
end
local gameDir = require("./Roots").findGame(fs, args[1])
if gameDir == nil then
	print("error: no such game: " .. args[1])
	process.exit(1)
end
local written, err = MakeGen.writeScreen(fs, gameDir, args[2])
if written == nil then
	print("error: " .. tostring(err))
	process.exit(1)
end
pcall(
	process.exec,
	"stylua",
	{ "--config-path", require("./Roots").core("stylua.toml"), gameDir .. "/src/client" }
)
for _, path in written do
	print("wrote " .. path)
end
print(`next: open it on the client with UI.open("{args[2]}"); tools/lint`)
