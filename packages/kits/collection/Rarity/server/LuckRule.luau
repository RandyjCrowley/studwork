--!strict
--[[
	Pure paid-roll luck rule (CLAUDE.md hard rule 11, v1.2 N4). Zero requires.

	check(input) -> (ok, reason?). Checked in this order:
		1. not paid                      -> ok (free rolls may use any luck)
		2. luck == 1                     -> ok
		3. table not luckDisclosed       -> false, LuckRule.NOT_DISCLOSED
		4. no odds of this table sent    -> false, LuckRule.NOT_SENT
		5. sent odds not luckDisclosed or sent.luck ~= luck
		                                 -> false, LuckRule.LUCK_MISMATCH
		otherwise ok.
	input.luck must already be sanitised (RollMath.sanitizeLuck), exactly like the luck the
	server put into the disclosed odds, so the comparison is exact.
	message(tableId, luck, reason) -> the error text Rarity.rollInto raises.
]]

export type Input = {
	paid: boolean,
	luck: number,
	luckDisclosed: boolean, -- RarityTableConfig.luckDisclosed == true
	sent: any, -- ctx.sentReplicated(player, "odds")[tableId] (an OddsDetail) or nil
}

local LuckRule = {}

LuckRule.NOT_DISCLOSED = "luck_not_disclosed"
LuckRule.NOT_SENT = "odds_not_sent"
LuckRule.LUCK_MISMATCH = "sent_luck_mismatch"

function LuckRule.check(input: Input): (boolean, string?)
	if input.paid ~= true then
		return true, nil
	end
	if input.luck == 1 then
		return true, nil
	end
	if input.luckDisclosed ~= true then
		return false, LuckRule.NOT_DISCLOSED
	end
	local sent = input.sent
	if type(sent) ~= "table" then
		return false, LuckRule.NOT_SENT
	end
	if sent.luckDisclosed ~= true or sent.luck ~= input.luck then
		return false, LuckRule.LUCK_MISMATCH
	end
	return true, nil
end

function LuckRule.message(tableId: string, luck: number, reason: string): string
	local why = if reason == LuckRule.NOT_DISCLOSED
		then "the table does not set luckDisclosed = true"
		elseif reason == LuckRule.NOT_SENT then "the player's client has not received this table's odds yet"
		else "the odds sent to the player's client do not include this luck (use Rarity.setLuck)"
	return string.format(
		"[Core.Rarity] paid roll on table '%s' with luck %s refused (hard rule 11): %s",
		tableId,
		tostring(luck),
		why
	)
end

return LuckRule
