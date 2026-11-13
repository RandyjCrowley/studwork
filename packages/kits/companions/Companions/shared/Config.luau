--!strict
local Config = {}
Config.defaults = {
	slots = 3,
	autoEquipBest = true,
	assetsFolderName = "GameAssets",
	maxDrawn = 30,
	drawDistance = 160,
	nearDistance = 50,
	nearHz = 30,
	farHz = 10,
	selectionHz = 4,
	lowDetailHz = 10,
	spacing = 3,
	behind = 4,
	followSpeed = 10,
	teleportDistance = 60,
	hoverHeight = 3,
	groundProbeUp = 8,
	groundProbeDown = 24,
	bobHeight = 0.25,
	bobHz = 1.5,
	hopHeight = 0.75,
	idleSpeed = 0.5,
	incomeBonusEnabled = false,
	bonusCap = 3,
}
Config.schema = {
	flag = "string?",
	slots = "integer(1..12)",
	autoEquipBest = "boolean",
	assetsFolderName = "string",
	maxDrawn = "integer(0..100)",
	drawDistance = "number(0..10000)",
	nearDistance = "number(0..10000)",
	nearHz = "number(1..60)",
	farHz = "number(1..60)",
	selectionHz = "number(1..60)",
	lowDetailHz = "number(1..60)",
	spacing = "number(0..1000)",
	behind = "number(0..1000)",
	followSpeed = "number(0..100)",
	teleportDistance = "number(0..10000)",
	hoverHeight = "number(0..1000)",
	groundProbeUp = "number(0..1000)",
	groundProbeDown = "number(0..1000)",
	bobHeight = "number(0..100)",
	bobHz = "number(0..60)",
	hopHeight = "number(0..100)",
	idleSpeed = "number(0..100)",
	incomeBonusEnabled = "boolean",
	bonusCap = "number(1..100)",
}
Config.itemSchema = {
	companions = {
		movement = "enum(walk,hop,fly,hover)?",
		hoverHeight = "number(0..1000)?",
		score = "number(0..1000000000000)?",
		incomeBonus = "number(0..100)?",
		look = "string?",
		idleAnimation = "string?",
		moveAnimation = "string?",
		triangles = "integer(0..1000000000)?",
	},
}
local function bounded(v: any, lo: number, hi: number, exclusive: boolean?): boolean
	return type(v) == "number" and v == v and v >= lo and v <= hi and (not exclusive or v > lo)
end
local function text(v: any, max: number): boolean
	return type(v) == "string" and #v > 0 and #v <= max
end
function Config.validate(config: any, gameConfig: any, flagsApi: any?)
	assert(type(config) == "table", "Companions config must be a table")
	assert(bounded(config.nearHz, 1, 60, false), "Companions.nearHz out of range")
	assert(bounded(config.farHz, 1, 60, false), "Companions.farHz out of range")
	assert(bounded(config.selectionHz, 1, 60, false), "Companions.selectionHz out of range")
	assert(bounded(config.lowDetailHz, 1, 60, false), "Companions.lowDetailHz out of range")
	assert(bounded(config.drawDistance, 0, 10000, true), "Companions.drawDistance out of range")
	assert(bounded(config.nearDistance, 0, 10000, true), "Companions.nearDistance out of range")
	assert(bounded(config.teleportDistance, 0, 10000, true), "Companions.teleportDistance out of range")
	assert(bounded(config.spacing, 0, 1000, true), "Companions.spacing out of range")
	assert(bounded(config.behind, 0, 1000, true), "Companions.behind out of range")
	assert(bounded(config.hoverHeight, 0, 1000, true), "Companions.hoverHeight out of range")
	assert(bounded(config.groundProbeUp, 0, 1000, true), "Companions.groundProbeUp out of range")
	assert(bounded(config.groundProbeDown, 0, 1000, true), "Companions.groundProbeDown out of range")
	assert(bounded(config.slots, 1, 12, false) and config.slots % 1 == 0, "Companions.slots out of range")
	assert(
		bounded(config.maxDrawn, 0, 100, false) and config.maxDrawn % 1 == 0,
		"Companions.maxDrawn out of range"
	)
	assert(bounded(config.followSpeed, 0, 100, true), "Companions.followSpeed out of range")
	assert(bounded(config.bobHeight, 0, 100, false), "Companions.bobHeight out of range")
	assert(bounded(config.bobHz, 0, 60, true), "Companions.bobHz out of range")
	assert(bounded(config.hopHeight, 0, 100, false), "Companions.hopHeight out of range")
	assert(bounded(config.idleSpeed, 0, 100, false), "Companions.idleSpeed out of range")
	assert(bounded(config.bonusCap, 1, 100, false), "Companions.bonusCap out of range")
	assert(
		type(config.autoEquipBest) == "boolean" and type(config.incomeBonusEnabled) == "boolean",
		"Companions boolean config invalid"
	)
	assert(text(config.assetsFolderName, 100), "Companions.assetsFolderName invalid")
	assert(config.nearDistance <= config.drawDistance, "Companions nearDistance exceeds drawDistance")
	if config.flag ~= nil then
		assert(text(config.flag, 64), "Companions.flag invalid")
		local flags = gameConfig.flags
		if type(flags) == "table" then
			local flag = flags[config.flag]
			assert(
				type(flag) == "table" and flag.serverOnly ~= true,
				"Companions.flag must be declared and replicated"
			)
		else
			-- Server contexts expose flag state through the public API, not declaration metadata.
			assert(
				type(flagsApi) == "table" and type(flagsApi.isOn) == "function",
				"Companions.flag requires the public flags API"
			)
			local ok, value = pcall(flagsApi.isOn, config.flag)
			assert(ok and type(value) == "boolean", "Companions.flag must be declared")
		end
	end
	for _, item in gameConfig.items or {} do
		if item.companions ~= nil then
			assert(text(item.id, 64), "Companions item id invalid")
			Config.validateItem(item.companions)
		end
	end
end
function Config.validateItem(fields: any)
	assert(type(fields) == "table", "Companions item namespace must be a table")
	assert(
		fields.movement == nil or table.find({ "walk", "hop", "fly", "hover" }, fields.movement) ~= nil,
		"Companions movement invalid"
	)
	local limits: { [string]: number } =
		{ hoverHeight = 1000, score = 1e12, incomeBonus = 100, triangles = 1e9 }
	for key, limit in limits do
		local value = fields[key]
		assert(value == nil or bounded(value, 0, limit), `Companions item {key} invalid`)
	end
	assert(fields.triangles == nil or fields.triangles % 1 == 0, "Companions triangles must be integer")
	for _, key in { "look", "idleAnimation", "moveAnimation" } do
		assert(fields[key] == nil or text(fields[key], 64), `Companions item {key} invalid`)
	end
end
return Config
