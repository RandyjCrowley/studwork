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

	STUB (foundation): `services.get` is the plain engine lookup; the Open Cloud transport reports no
	secret and raises on `request`. The live HTTP and secrets-store adapters are the environments/
	flags/services builder's (B2). `translatorFor` is `LocalizationService:GetTranslatorForPlayerAsync`
	(it raises when the fetch fails; server/Text.luau retries at 5, 30 and 120 s).
]]

local PlatformServices = {}

function PlatformServices.live(): any
	return {
		services = {
			get = function(name: string): any
				return game:GetService(name)
			end,
		},
		openCloud = {
			hasSecret = function(_name: string): boolean
				return false -- STUB (B2)
			end,
			request = function(_req: any): (boolean, number?, any)
				error("not implemented: PlatformServices.openCloud.request", 0)
			end,
		},
		localization = {
			translatorFor = function(player: any): any
				return game:GetService("LocalizationService"):GetTranslatorForPlayerAsync(player)
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
