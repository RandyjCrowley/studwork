--!strict
--[[
	Pure shape check for StateSync payloads (charm-sync SyncPayload list). Zero dependencies.
	check(payloads, key) -> (ok, reason?)
	  * payloads must be a non-empty array of { type = "init" | "patch", data = table }
	  * every data table may only contain `key` (our own state key); anything else is refused
	  * an "init" for our key must carry a table with a boolean `loaded`
]]

local PayloadCheck = {}

function PayloadCheck.check(payloads: any, key: string): (boolean, string?)
	if type(payloads) ~= "table" or #payloads == 0 then
		return false, "not a payload list"
	end
	for index, payload in payloads do
		if type(index) ~= "number" or type(payload) ~= "table" then
			return false, "bad entry"
		end
		local kind = payload.type
		if kind ~= "init" and kind ~= "patch" then
			return false, "bad type"
		end
		local data = payload.data
		if type(data) ~= "table" then
			return false, "bad data"
		end
		for dataKey, value in data do
			if dataKey ~= key then
				return false, "foreign key"
			end
			if kind == "init" and (type(value) ~= "table" or type(value.loaded) ~= "boolean") then
				return false, "bad init state"
			end
		end
	end
	return true, nil
end

return PayloadCheck
