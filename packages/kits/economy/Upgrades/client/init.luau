--!strict
--[[
	Upgrades client part (module-api.md §9; v1.3.1 R19: one folder per module, found by the client
	runtime as ReplicatedStorage.Modules.Upgrades.client). Client action:
	  StudWork.use(Upgrades).actions.upgrade(...)
	fires this module's own Blink event `Upgrade` (./net.blink -> generated ./Net.luau, bound by the
	runtime as the part's `net`).
]]

return {
	actions = {
		upgrade = true, -- the event `Upgrade` in ./Net.luau (generated from ../net.blink)
	},
}
