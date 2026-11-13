--!strict
-- Fixture-game balance: each kit module's config (GameConfig.config.<Name>), merged over its
-- defaults and checked against its schema at boot (unknown keys are warnings). The two modules'
-- tables live in their own files so the builders never edit the same lines.
return {
	Carry = require(script.Parent.BalanceCarry),
	Movement = require(script.Parent.BalanceMovement),
}
