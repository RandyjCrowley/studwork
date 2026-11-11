--!strict
--[[
	COMPAT ADAPTER for the Engagement kit (Streak). Owned by Phase 1 agent C; DELETED IN PHASE 2 with
	the rest of packages/kits/compat.

	Once a module of this kit is REAL (its ModuleServers.loadServer returns a real server part,
	not Bridge.serverPart), the compat bridge calls this function to build the v1.2-shaped
	`services.<Module>` that the still-bridged v1.2 services (ctx.services.<Module> inside the
	bridge) and the multi-server sim (Bridge.compatServices(rt)) use:

	  adapter(name, rt, api, txApi, extensions) -> { [v1.2 function name]: fn }?

	  name        the module name (one of: Streak)
	  rt          the framework runtime (rt.data.runTx(player, fn(tx)) opens a tx)
	  api         the real module's api as other modules see it (Extensions.wrapApi: no calls
	              during init)
	  txApi       its txApi (first argument must be an open tx)
	  extensions  its extensions

	Return the v1.2 functions siblings and the sim call (plain v1.2 names such as grant,
	balance or get over `api`; the *Into ones take a v1.2 tx { player, data, after }, see the
	guide). Return nil for a module with no v1.2 callers left.
	Any v1.2 name not returned errors on use, naming this file. See the "Phase 1 kit agent
	guide" in (internal build report, not public)
]]

return function(_name: string, _rt: any, _api: any, _txApi: any, _extensions: any): any
	return nil -- no entries yet
end
