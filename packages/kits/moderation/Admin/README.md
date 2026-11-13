# Admin (moderation kit, v1.0.0 module)

Staff roles with ranks and permissions (`ServerConfig.Admin` users and group rules through
`GroupService:GetRolesInGroupAsync`), per-staff limits, and the staff panel the other moderation
modules register into. Depends on nothing; optional Economy (the grant action) and TextFilter
(free panel text).

Layout (one folder per module, module-api.md §1): `module.luau` (the definition: config schema and
defaults, strings, exported types), `server/` (server part), `client/` (tiny: `isStaff`,
`permissions`, `role`, `panel`), `net.blink` (RemoteScope `STUDWORK_ADMIN`). Rojo:
`ReplicatedStorage.Modules.Admin`, `ServerScriptService.Modules.Admin`.

Design and API: [docs/framework/kits/moderation.md](../../../../docs/framework/kits/moderation.md#admin).

Two surfaces: the API (`ctx.deps[Admin]`, `StudWork.use(Admin)`: `can`, `allow`, the rank calls,
`limitsOf`, ...) and the extensions (`ctx.depsExt[Admin]`, from a module's `init`: `registerAction`,
`registerTab`, `onStaffMove`, ...); the kit page lists which is which.

Files: `server/init.luau` (the part: roles, `can`/`allow`/`rankOfUserId`/`rankOfChecked`/`limitsOf`,
extensions, the `run`/`fetch`/`panelOpen` actions, built-in actions, replication, panel delivery, console),
`server/Check.luau` (config, ActionDef and TabDef checks), `server/Panel/init.luau` (the React
panel, cloned into staff PlayerGuis only) and `server/Panel/State.luau` (its pure view state),
`client/init.luau`. Specs: `packages/kits/moderation/tests/Admin*.spec.luau`.
