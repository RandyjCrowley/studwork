--!strict
--[[
	The live engine-service adapters (framework internal), the counterpart of PlatformStores for
	everything else a module or the framework reaches through a service table.

	  PlatformServices.live() -> {
	    services     = { get(name) -> service }               ctx.services / Services.internal (GetService)
	    openCloud    = { hasSecret(name) -> boolean,           ctx.openCloud transport
	                     request({ secret, method, path, body? }) -> (ok, status?, body?) }
	    localization = { translatorFor(player) -> translator? } ctx.text (the player's translator; yields)
	  }
	  PlatformServices.inert() -> the same shape, nothing available

	Open Cloud (module-api.md §23.7): the key is only ever read with HttpService:GetSecret(name)
	(Roblox's secrets store) and only ever placed in the `x-api-key` header; the Secret object is
	cached per name and never converted to text, logged or returned. A request is
	HttpService:RequestAsync to OPEN_CLOUD_BASE .. path with the two headers Roblox allows for Open
	Cloud from a game server (`x-api-key`, `content-type: application/json`), the body JSON-encoded
	(not on GET). Answers: (Success, StatusCode, the decoded JSON body or nil). Errors raise to
	server/OpenCloud, which reports `failed` without their text. `hasSecret` is false when HTTP
	requests are off (when the engine lets the server read that) or GetSecret errors (no such
	secret, a local playtest without a local secret).

	translatorFor: LocalizationService:GetTranslatorForPlayerAsync(player) in pcall, nil on failure
	(server/Text keeps English and owns the retry schedule).
]]

local PlatformServices = {}

PlatformServices.OPEN_CLOUD_BASE = "https://apis.roblox.com/cloud/v2/"

local function liveOpenCloud(): any
	local http: any = nil
	local function HttpServiceGet(): any
		http = http or game:GetService("HttpService")
		return http
	end
	local secrets: { [string]: any } = {} -- name -> Secret, or false when GetSecret failed

	local function secretFor(name: string): any
		local s = secrets[name]
		if s == nil then
			local ok, value = pcall(function(): any
				return HttpServiceGet():GetSecret(name)
			end)
			s = if ok and value ~= nil then value else false
			secrets[name] = s
		end
		return if s == false then nil else s
	end

	local function httpEnabled(): boolean
		local ok, on = pcall(function(): any
			return HttpServiceGet().HttpEnabled
		end)
		-- unreadable from this context: assume on (a request then fails and reports `failed`)
		return not ok or on ~= false
	end

	return {
		hasSecret = function(name: string): boolean
			return httpEnabled() and secretFor(name) ~= nil
		end,
		request = function(req: any): (boolean, number?, any)
			local HttpService = HttpServiceGet()
			local secret = secretFor(req.secret)
			if secret == nil then
				error("open cloud: secret unavailable", 0)
			end
			local headers: any = {
				["x-api-key"] = secret,
				["content-type"] = "application/json",
			}
			local options: any = {
				Url = PlatformServices.OPEN_CLOUD_BASE .. req.path,
				Method = req.method,
				Headers = headers,
			}
			if req.body ~= nil and req.method ~= "GET" then
				options.Body = HttpService:JSONEncode(req.body)
			end
			local response: any = HttpService:RequestAsync(options)
			local decoded: any = nil
			if type(response.Body) == "string" and response.Body ~= "" then
				local ok, value = pcall(function(): any
					return HttpService:JSONDecode(response.Body)
				end)
				if ok then
					decoded = value
				end
			end
			return response.Success == true, response.StatusCode, decoded
		end,
	}
end

function PlatformServices.live(): any
	local localizationService: any = nil
	return {
		services = {
			get = function(name: string): any
				return game:GetService(name :: any)
			end,
		},
		openCloud = liveOpenCloud(),
		localization = {
			translatorFor = function(player: any): any
				local ok, translator = pcall(function(): any
					localizationService = localizationService or game:GetService("LocalizationService")
					return localizationService:GetTranslatorForPlayerAsync(player)
				end)
				return if ok then translator else nil
			end,
		},
	}
end

function PlatformServices.inert(): any
	return {
		services = {
			get = function(name: string): any
				error(`no engine service '{name}' on this platform`, 0)
			end,
		},
		openCloud = {
			hasSecret = function(_name: string): boolean
				return false
			end,
			request = function(_req: any): (boolean, number?, any)
				error("no Open Cloud transport on this platform", 0)
			end,
		},
		localization = {
			translatorFor = function(_player: any): any
				return nil
			end,
		},
	}
end

return PlatformServices
