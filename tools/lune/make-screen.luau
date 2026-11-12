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

local args = table.clone(process.args)
-- (v1.5.0) single-game project: the root game is the default (tools/make-screen <ScreenName>)
if require("./Roots").single and #args == 1 then
	table.insert(args, 1, ".")
end
local USAGE =
	"usage: tools/make-screen <game> <ScreenName>   (single-game project: tools/make-screen <ScreenName>)"
for _, a in args do
	if a == "--help" or a == "-h" then
		print(USAGE)
		process.exit(0)
	end
end
if #args ~= 2 then
	print(USAGE)
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
pcall(process.exec, "stylua", {
	"--config-path",
	require("./Roots").core("stylua.toml"),
	if gameDir == "." then "src/client" else gameDir .. "/src/client",
})
for _, path in written do
	print("wrote " .. path)
end
print(`next: open it on the client with UI.open("{args[2]}"); tools/lint`)
