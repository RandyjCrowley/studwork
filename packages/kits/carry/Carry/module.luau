--!strict
--[[
	Carry module definition (kit: carry, v1.8.0). Pick up, carry, hand off, throw, drop and deliver an
	object, alone or with other players. The server drives every carried object (anchored, CFrame
	written on the shared Heartbeat ticker, rate-clamped); a client only sends requests (ids).
	Design: docs/framework/kits/carry.md. Server part ../server, client part ../client, net.blink
	(carryPickUp, carryDrop, carryHandOff), pure helpers ../shared.

	No save section (live, server-only state). Replicated extra: one key per object,
	"carry:<objectId>", set on state changes only.

	config (GameConfig.config.Carry): the tables in carry.md "Config": flag, sampleSeconds, motionHz,
	carriables, dropRules, delivery*, pickUpRadius, agree, handOffRange, throwRange, throwSpeed,
	catchRadius, catchWindowSeconds, maxObjects, holdOffset, massClasses, applyWalkSpeed, clamp,
	killMarginStuds, killHitchSeconds, settle, dropNoCollideSeconds, collisionGroup, wobble, bindings.

	optional = { Movement }: Carry reads Movement's accepted positions only after
	ctx.isEnabled(Movement) and works without it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))
local Movement =
	require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Movement"):WaitForChild("module"))

return StudWork.defineModule({
	name = "Carry",
	version = "1.0.0",
	framework = "^1.7.0",
	description = "Carry, hand off, throw, drop and deliver objects alone or together (carry kit)",
	optional = { Movement },
	config = {
		schema = {
			flag = "string?",
			sampleSeconds = "number(0.02..1)",
			motionHz = "number(1..120)",
			carriables = "{[string]: table}",
			-- every rule is optional: nil / false = that rule never drops the object
			dropRules = {
				belowMin = "boolean?",
				tiltDegrees = "any?", -- number, or nil / false for never
				stretchStuds = "any?",
				hardLandingSpeed = "any?",
				hardLandingMarginStuds = "number(0..)?", -- the minimum fall above the carriers' jump apex
				carrierDied = "boolean?",
				carrierLeft = '"drop"|"returnToSpawn"?',
				carrierDisqualified = '"off"|"runDisqualified"|"strike"?',
				untrustedCarrier = "boolean?",
				hazard = "boolean?",
			},
			deliveryTag = "string",
			deliveryContainment = '"full"|"center"',
			deliveryReachStuds = "number(0..)",
			pickUpRadius = "number(0..)",
			agree = {
				baseStuds = "number(0..)",
				sampleAgeSeconds = "number(0..)",
				lagSeconds = "number(0..)",
			},
			handOffRange = "number(0..)",
			throwRange = "number(0..)",
			throwSpeed = "number(0..)",
			catchRadius = "number(0..)",
			catchWindowSeconds = "number(0..)",
			maxObjects = "integer(1..)",
			holdOffset = "{number}",
			massClasses = "{[string]: table}",
			applyWalkSpeed = "boolean",
			clamp = {
				speedSlack = "number(1..)",
				maxDtSeconds = "number(0..)",
				gripBreakStuds = "number(0..)",
				maxFallSpeed = "number(0..)",
				riseSlack = "number(1..)",
			},
			killMarginStuds = "number(0..)",
			killHitchSeconds = "number(0..)",
			settle = {
				speedStuds = "number(0..)",
				seconds = "number(0..)",
			},
			dropNoCollideSeconds = "number(0..)?", -- opt-in escape hatch only; nil (the default) = collision group only
			collisionGroup = "string?",
			wobble = {
				enabled = "boolean",
				maxDegrees = "number(0..)",
				hz = "number(0..)",
				damping = "number(0..)",
			},
			bindings = {
				interact = { keys = "{string}", gamepad = "{string}" },
				pass = { keys = "{string}", gamepad = "{string}" },
			},
		},
		defaults = {
			sampleSeconds = 0.1,
			motionHz = 30,
			carriables = {},
			dropRules = {
				belowMin = true,
				tiltDegrees = 50,
				stretchStuds = 8,
				-- hardLandingSpeed: off by default (opt-in, e.g. 55). The rule is a heuristic with known limits
				-- (carry.md "dropRules"); a game that turns it on accepts them.
				hardLandingMarginStuds = 4,
				carrierDied = true,
				carrierLeft = "drop",
				carrierDisqualified = "runDisqualified",
				untrustedCarrier = true,
				hazard = false,
			},
			deliveryTag = "CarryDelivery",
			deliveryContainment = "full",
			deliveryReachStuds = 6,
			pickUpRadius = 6,
			agree = { baseStuds = 2, sampleAgeSeconds = 0.1, lagSeconds = 0.6 },
			handOffRange = 8,
			throwRange = 40,
			throwSpeed = 40,
			catchRadius = 5,
			catchWindowSeconds = 1.2,
			maxObjects = 20,
			holdOffset = { 0, 0.5, -2.5 },
			massClasses = {
				light = { speedFactor = 1, throwable = true },
				medium = { speedFactor = 0.85, throwable = true },
				heavy = { speedFactor = 0.7, throwable = false },
			},
			applyWalkSpeed = true,
			clamp = {
				speedSlack = 1.35,
				maxDtSeconds = 0.5,
				gripBreakStuds = 12,
				maxFallSpeed = 200,
				riseSlack = 1.15,
			},
			killMarginStuds = 50,
			killHitchSeconds = 0.5,
			settle = { speedStuds = 0.5, seconds = 1 },
			wobble = { enabled = true, maxDegrees = 9, hz = 2.2, damping = 0.6 },
			bindings = {
				interact = { keys = { "E" }, gamepad = { "ButtonX" } },
				pass = { keys = { "F" }, gamepad = { "ButtonY" } },
			},
		},
	},
	strings = {
		["Carry.pickUp"] = "Pick up",
		["Carry.join"] = "Help carry",
		["Carry.drop"] = "Drop",
		["Carry.pass"] = "Pass",
		["Carry.carrying"] = "Carrying {name}",
		["Carry.needMore"] = "Needs {count} more",
		["Carry.slots"] = "{count}/{max}",
		["Carry.full"] = "Full",
		["Carry.tooFar"] = "Too far",
		["Carry.delivered"] = "Delivered!",
	},
	client = "Carry",
})
