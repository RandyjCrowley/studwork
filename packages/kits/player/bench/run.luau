--!nocheck
-- Reuse the exact reference measurement loops without changing the shared variant list.
-- Run from the repository root: lune run packages/kits/player/bench/run [runs]
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local Harness = require("../../../../tools/lune/testkit/harness")
local PathUtil = require("../../../../tools/lune/testkit/pathutil")
local Config = require("./Config")
local source = fs.readFile(PathUtil.join(process.cwd, "tools/lune/bench/replication.luau"))
local function replaceOnce(before, after)
	local startAt, endAt = string.find(source, before, 1, true)
	assert(startAt ~= nil, "reference benchmark contract changed")
	assert(string.find(source, before, endAt + 1, true) == nil, "ambiguous reference benchmark anchor")
	source = string.sub(source, 1, startAt - 1) .. after .. string.sub(source, endAt + 1)
end
replaceOnce(
	"local function bootKits(players: { FakePlayer }, all: boolean)",
	"local function bootKits(players: { FakePlayer }, all: boolean, player: boolean?)"
)
replaceOnce(
	"\tlocal h = StudWork.test.harness({",
	[[
	if player then
		for _, name in PlayerBenchConfig.modules do table.insert(modules, kit("Player", name)) end
		for name, value in PlayerBenchConfig.config do config[name] = value end
		for key, value in PlayerBenchConfig.strings do extra.strings[key] = value end
	end
	local h = StudWork.test.harness({]]
)
replaceOnce(
	'local ORDER = { "BEFORE", "AFTER", "AFTER-STUB", "MERGED", "MERGED-V13", "KITS", "KITS-ALL" }',
	[[
variants["PLAYER-ALL"] = function(players) return bootKits(players, true, true) end
tickFns["PLAYER-ALL"] = tickFns["KITS-ALL"]
local ORDER = { "KITS-ALL", "PLAYER-ALL" }]]
)
local environment = {}
local imports = {
	["@lune/fs"] = fs,
	["@lune/luau"] = luau,
	["@lune/process"] = process,
	["../testkit/harness"] = Harness,
}
environment.require = function(name)
	assert(imports[name] ~= nil, "unexpected benchmark import")
	return imports[name]
end
environment.PlayerBenchConfig = Config
luau.load(source, { debugName = "player benchmark", environment = environment })()
