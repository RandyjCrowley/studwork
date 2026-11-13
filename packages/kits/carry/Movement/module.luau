--!strict
--[[
	Movement module definition (kit: carry, v1.8.0). A server-side movement validator for player
	characters: sliding-window speed, per-sample teleport cap, analytic volume sweep, ground cast with
	a jump/fall envelope, wall sweep and rise cap, with platform/seat-relative motion, server-move
	anchors and a respawn window. Carry uses it, and so can any game code.
	Design: docs/framework/kits/carry.md ("Movement"). Server part ../server only (no client part, no
	net.blink). No save section: strikes and samples are in memory.

	Replicated extra: key "movement" (owner only), "<strikeCount>|<lastReason>", set on a strike only.

	config (GameConfig.config.Movement): the table in carry.md "Movement > Config": flag, sampleHz,
	staggerBuckets, minSampleFraction, speedCap, speedSlack, speedWindowSeconds, lag, teleport, rise, arc,
	groundCast, wallSweep, platform, climb, volumes, anchor, respawn, trustAfterCleanSamples, response,
	responses, maxStrikesBeforeKick, strikeDecaySeconds, exemptDefaultSeconds, samplesKept.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StudWork = require(ReplicatedStorage:WaitForChild("Framework"))

return StudWork.defineModule({
	name = "Movement",
	version = "1.0.0",
	framework = "^1.7.0",
	description = "Server-side movement validator: speed, teleport, volume sweep, ground, wall (carry kit)",
	config = {
		schema = {
			flag = "string?",
			sampleHz = "number(1..60)",
			staggerBuckets = "integer(1..60)",
			minSampleFraction = "number(0..1)",
			speedCap = "number(0..)",
			speedSlack = "number(1..)",
			speedWindowSeconds = "number(0.5..)",
			lag = {
				pingFactor = "number(0..)",
				jitterMarginSeconds = "number(0..)",
				minSeconds = "number(0..)",
				maxSeconds = "number(0..)",
				pingRefreshSeconds = "number(0..)",
			},
			teleport = {
				minLagSeconds = "number(0..)",
				slackStuds = "number(0..)",
				capStuds = "number?", -- nil: the formula; a number replaces it
			},
			rise = {
				speedCap = "number?", -- nil: derived from the server's jump velocity
				slackStuds = "number(0..)",
			},
			arc = {
				launchSlack = "number(1..)",
				gravitySlack = "number(0..1)",
				heightSlackStuds = "number(0..)",
				graceSeconds = "number(0..)",
			},
			groundCast = {
				lengthStuds = "number(0..)",
				footprintStuds = "number(0..)",
				groundedSlackStuds = "number(0..)",
				skipStuds = "number(0..)",
			},
			wallSweep = {
				enabled = "boolean",
				minStuds = "number(0..)",
				minPenetrationStuds = "number(0..)",
				edgeMarginStuds = "number(0..)",
				everySamples = "integer(1..)",
			},
			platform = {
				graceSeconds = "number(0..)",
				ancestorDepth = "integer(0..)",
			},
			climb = { reachStuds = "number(0..)" },
			volumes = '{[string]: "hazard"|"noEntry"|"checkpoint"|"platform"|"climbable"}',
			anchor = {
				reachStuds = "number(0..)",
				timeoutSeconds = "number(0..)",
				retries = "integer(0..)",
			},
			respawn = {
				settleSamples = "integer(1..)",
				settleStuds = "number(0..)",
				maxSettleSeconds = "number(0..)",
			},
			trustAfterCleanSamples = "integer(1..)",
			response = '"log"|"strike"|"resetPosition"|"disqualifyRun"',
			-- { [CheckName]: response }, the config form of setResponse
			responses = '{[string]: "log"|"strike"|"resetPosition"|"disqualifyRun"}',
			maxStrikesBeforeKick = "integer(0..)",
			strikeDecaySeconds = "number(0..)",
			exemptDefaultSeconds = "number(0..)",
			samplesKept = "integer(1..)",
		},
		defaults = {
			sampleHz = 10,
			staggerBuckets = 6,
			minSampleFraction = 0.5,
			speedCap = 16,
			speedSlack = 1.15,
			speedWindowSeconds = 4,
			lag = {
				pingFactor = 1,
				jitterMarginSeconds = 0.15,
				minSeconds = 0.25,
				maxSeconds = 0.75,
				pingRefreshSeconds = 1,
			},
			teleport = { minLagSeconds = 0.6, slackStuds = 1 },
			rise = { slackStuds = 1 },
			arc = { launchSlack = 1.1, gravitySlack = 0.15, heightSlackStuds = 1.5, graceSeconds = 0.2 },
			groundCast = { lengthStuds = 12, footprintStuds = 2, groundedSlackStuds = 1.5, skipStuds = 4 },
			wallSweep = {
				enabled = true,
				minStuds = 0.5,
				minPenetrationStuds = 0.2,
				edgeMarginStuds = 1,
				everySamples = 2,
			},
			platform = { graceSeconds = 1, ancestorDepth = 3 },
			climb = { reachStuds = 3 },
			volumes = {},
			anchor = { reachStuds = 6, timeoutSeconds = 2, retries = 2 },
			respawn = { settleSamples = 2, settleStuds = 0.5, maxSettleSeconds = 3 },
			trustAfterCleanSamples = 3,
			response = "log",
			responses = {},
			maxStrikesBeforeKick = 0,
			strikeDecaySeconds = 60,
			exemptDefaultSeconds = 2,
			samplesKept = 20,
		},
	},
	strings = {
		["Movement.kicked"] = "Removed for unusual movement",
	},
})
