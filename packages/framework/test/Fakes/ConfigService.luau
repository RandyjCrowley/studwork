--!strict
--[[
	Fake experience config service (StudWork.test.fakes.configService, module-api.md §23.10): what the
	framework's flag override reads (harness `services = { ConfigService = fake }`). Never talks to Roblox.

	  local fake = StudWork.test.fakes.configService({ values = { flag_newShop = true }, failNext = n })

	Engine surface (like Roblox's snapshot: values change only on Refresh):
	  GetConfigAsync() -> snapshot            raises while failNext is pending
	  snapshot:GetValue(key) -> any?          nil for a missing key
	  snapshot.UpdateAvailable                a signal (:Connect) fired by fake.publish()
	  snapshot.Outdated                       true after a publish, until Refresh
	  snapshot:Refresh()                      takes the published values
	Test surface: set(key, value | nil) stages a value; publish() makes the staged values available
	(fires UpdateAvailable, Outdated = true); calls; failNext(n).
]]

local Signal = (require :: any)(script.Parent.Parent.Parent.shared.Signal)

local ConfigFake = {}

local function copy(t: any): any
	return table.clone(t)
end

function ConfigFake.new(opts: any?): any
	local o = opts or {}
	local live: { [string]: any } = copy(o.values or {}) -- what snapshots see
	local staged: { [string]: any } = copy(live) -- what set() changed
	local published: { [string]: any }? = nil
	local failures = if type(o.failNext) == "number" then o.failNext else 0
	local fake: any = { calls = {} }
	local snapshot: any = { Outdated = false, UpdateAvailable = Signal.new("ConfigFake.UpdateAvailable") }

	function snapshot.GetValue(_self: any, key: string): any
		table.insert(fake.calls, { method = "GetValue", key = key })
		return live[key]
	end

	function snapshot.Refresh(_self: any)
		table.insert(fake.calls, { method = "Refresh" })
		if published ~= nil then
			live = published
			published = nil
		end
		snapshot.Outdated = false
	end

	function fake.GetConfigAsync(_self: any): any
		table.insert(fake.calls, { method = "GetConfigAsync" })
		if failures > 0 then
			failures -= 1
			error("ConfigService:GetConfigAsync failed (injected)", 0)
		end
		return snapshot
	end

	function fake.failNext(n: number)
		failures += n
	end

	function fake.set(key: string, value: any)
		staged[key] = value
	end

	function fake.publish()
		published = copy(staged)
		snapshot.Outdated = true
		snapshot.UpdateAvailable:Fire()
	end

	return fake
end

return ConfigFake
