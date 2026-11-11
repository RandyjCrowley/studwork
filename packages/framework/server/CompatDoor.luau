--!strict
--[[
	COMPAT-ONLY DOOR. DELETED IN PHASE 2 (core-v1.3.0, step 4b-IIa; listed on the Phase 2 delete list).

	The v1.2 kit services still run unchanged behind their defineModule wrappers through the compat
	bridge (packages/kits/compat/Bridge.luau). They read and write ONE flat v1.2 PlayerData, which
	spans every kit module's save section, so the bridge needs cross-section access that no module
	may ever have. This door is that access, and the only one:

	  CompatDoor.runtime() -> rt     the running server runtime of THIS server (framework Data,
	                                 Net, Replication, Compliance, Policy, Shop, console table, ...)

	Rules:
	  - Only packages/kits/compat requires this file. It is NOT reachable through ctx, StudWork,
	    StudWork.use or any module API, and no kit/game/third-party module may require it.
	  - Server.start attaches the runtime before resolving modules (so wrapper server parts can
	    capture it while they are loaded) and nothing else ever writes it.
	When Phase 1 kit agents replace the wrappers with real modules, nothing requires this door any
	more and Phase 2 deletes it together with packages/kits/compat.
]]

local CompatDoor = {}

local current: any = nil

-- Server.start only.
function CompatDoor.attach(rt: any)
	current = rt
end

-- packages/kits/compat only.
function CompatDoor.runtime(): any
	if current == nil then
		error("[StudWork] CompatDoor.runtime() before StudWork.start (compat bridge only)", 2)
	end
	return current
end

return CompatDoor
