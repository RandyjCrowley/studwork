--!strict
--[[
	Fake Open Cloud transport (StudWork.test.fakes.openCloud, module-api.md §23.7 / §23.10): the
	transport behind ctx.openCloud in the harness. The framework's allow-list sits in front of it
	(server/OpenCloud.luau): a request that gets here was allowed. No key, URL or secret value exists.

	  local fake = StudWork.test.fakes.openCloud({ secrets = { OpenCloudNotifications = true } })
	  harness({ openCloud = fake, secrets = { OpenCloudNotifications = true }, serverConfig = { openCloud = ... } })

	Transport: hasSecret(name) -> boolean (the fake's `secrets` set, plus the harness `secrets` option);
	request({ secret, method, path, body? }) -> (ok, status, body).
	Test surface:
	  requests                      { { secret (the NAME), method, path, body } } in order
	  respond(status, body?)        every later request answers with this (default 200, {})
	  respondNext(status, body?)    only the next request
	  failNext(n, status?)          the next n requests answer `status` (default 503)
	  raiseNext(n)                  the next n requests raise (a network error)
]]

local OpenCloudFake = {}

local function deepCopy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = deepCopy(x)
	end
	return out
end

function OpenCloudFake.new(opts: any?): any
	local o = opts or {}
	local secrets: { [string]: boolean } = {}
	for name, on in (o.secrets or {}) :: any do
		secrets[name] = on == true
	end
	local default = { status = 200, body = {} }
	local nextResponses: { any } = {}
	local fails, failStatus = 0, 503
	local raises = 0
	local fake: any = { requests = {} }

	function fake.hasSecret(name: string): boolean
		return secrets[name] == true
	end

	function fake.setSecret(name: string, on: boolean?)
		secrets[name] = on ~= false
	end

	function fake.respond(status: number, body: any?)
		default = { status = status, body = body or {} }
	end

	function fake.respondNext(status: number, body: any?)
		table.insert(nextResponses, { status = status, body = body or {} })
	end

	function fake.failNext(n: number, status: number?)
		fails += n
		failStatus = status or 503
	end

	function fake.raiseNext(n: number)
		raises += n
	end

	function fake.request(req: any): (boolean, number?, any)
		table.insert(fake.requests, {
			secret = req.secret,
			method = req.method,
			path = req.path,
			body = deepCopy(req.body),
		})
		if raises > 0 then
			raises -= 1
			error("Open Cloud request failed (injected)", 0)
		end
		local response = default
		if fails > 0 then
			fails -= 1
			response = { status = failStatus, body = {} }
		elseif #nextResponses > 0 then
			response = table.remove(nextResponses, 1) :: any
		end
		return response.status >= 200 and response.status < 300, response.status, deepCopy(response.body)
	end

	return fake
end

return OpenCloudFake
