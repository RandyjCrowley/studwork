# Local companion fixture

Build from the repository root with `rojo build packages/kits/companions/Companions/test/studio/default.project.json -o build/companions-fixture.rbxl`. Open the result locally in Studio and Play. The fixture uses three primitive models, three starter copies, a Golden look registered on each side, ground, stairs and a moving platform. The equip screen opens after three seconds. Scripts refuse to run outside Studio. No asset ids or uploads are needed. Framework storage uses its normal local Studio behavior; do not enable API access.

In the client command bar:

```lua
local fixture = game.Players.LocalPlayer.PlayerScripts.CompanionsFixture
print(fixture:Invoke("stats"))
print(fixture:Invoke("transforms"))
fixture:Invoke("open")
fixture:Invoke("lowDetail", true)
fixture:Invoke("reducedMotion", true)
```

This fixture supplies one real owner. Other-owner visibility needs a Studio multi-client playtest; the offline simulation checks multiple owners, but does not substitute for that engine check. Plot is not enabled. The fixture is separate from normal game builds.
