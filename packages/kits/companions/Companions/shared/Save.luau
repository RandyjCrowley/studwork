--!strict
local Save = {}
function Save.sanitize(old: any): any
	local clean: { string } = {}
	local seen: { [string]: boolean } = {}
	if type(old) == "table" and type(old.equipped) == "table" then
		-- Only a contiguous array is meaningful; never iterate attacker-controlled sparse indices.
		for _, uid in ipairs(old.equipped) do
			if type(uid) == "string" and #uid > 0 and #uid <= 64 and not seen[uid] and #clean < 12 then
				seen[uid] = true
				table.insert(clean, uid)
			end
		end
	end
	return { equipped = clean, manual = type(old) == "table" and old.manual == true }
end
Save.migrate1 = Save.sanitize
return Save
