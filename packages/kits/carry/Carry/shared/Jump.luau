--!strict
--[[
	Jump: a character's jump, as Carry reads it (pure; the live World adapter and the Lune FakeWorld both use it,
	so the specs exercise the same formula the server does).

	  Jump.velocity(useJumpPower, jumpPower, jumpHeight, gravity) -> studs/s
	      Humanoid.UseJumpPower ? JumpPower : sqrt(2 x gravity x JumpHeight)
	  Jump.apex(velocity, gravity) -> studs       v^2 / 2g, the height of a standing jump
]]

local Jump = {}

function Jump.velocity(useJumpPower: boolean, jumpPower: number, jumpHeight: number, gravity: number): number
	if useJumpPower then
		return jumpPower
	end
	return math.sqrt(2 * gravity * math.max(jumpHeight, 0))
end

function Jump.apex(velocity: number, gravity: number): number
	return velocity * velocity / (2 * gravity)
end

return Jump
