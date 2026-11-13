--!strict
--[[
	Arc: the jump/fall envelope (carry.md, Movement "Worked numbers"). Pure.

	  launch speed  vJ' = max(jumpVelocity, walkSpeed) x launchSlack + max(0, platform vertical speed)   55 studs/s
	  gravity       g'  = Gravity x (1 - gravitySlack)                                                    166.77 studs/s^2
	  maxY = y0 + H(tau') + heightSlackStuds, tau' = max(0, airborneFor - lag - graceSeconds)
	  H = vJ'^2 / 2g' while tau' <= vJ'/g' (apex allowance 10.57 studs above takeoff), else vJ' tau' - 1/2 g' tau'^2
	Descending at gravity is legal for any duration (maxY only falls with it).
]]

local Arc = {}

function Arc.launchSpeed(
	jumpVelocity: number,
	walkSpeed: number,
	launchSlack: number,
	platformUpSpeed: number
): number
	return math.max(jumpVelocity, walkSpeed) * launchSlack + math.max(0, platformUpSpeed)
end

function Arc.gravity(gravity: number, gravitySlack: number): number
	return gravity * (1 - gravitySlack)
end

-- The highest legal Y, `airborneFor` seconds after the first airborne sample that took off from y0.
function Arc.maxY(
	y0: number,
	airborneFor: number,
	lag: number,
	graceSeconds: number,
	launch: number,
	g: number,
	heightSlackStuds: number
): number
	local tau = math.max(0, airborneFor - lag - graceSeconds)
	local h
	if tau <= launch / g then
		h = launch * launch / (2 * g)
	else
		h = launch * tau - 0.5 * g * tau * tau
	end
	return y0 + h + heightSlackStuds
end

return Arc
