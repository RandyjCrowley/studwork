# client/Input

`Types.InputAPI`.

- `device()` - `"KeyboardMouse" | "Touch" | "Gamepad"`. Source: `UserInputService.PreferredInput` (`Enum.PreferredInput`: KeyboardAndMouse, Gamepad, Touch, MicroGamepad - verified against creator-docs 2026-11) observed via `GetPropertyChangedSignal`. If the property can't be read, falls back to capability flags + `LastInputTypeChanged`.
- `deviceChanged` - Signal, fires only on a real change.
- `bind(actionId, binding, handler)` - `ContextActionService:BindAction` with `binding.keys` + `binding.gamepad`; `handler("Began")` / `handler("Ended")` (Cancel also ends a press that began; never an unmatched Ended). Returns `Pass` so default controls still work. `touchButton = true` creates CAS's on-screen button (Roblox shows it on touch devices) with `title`, tinted Palette `accent`, title in Palette `text` + display font, at least `minTouchTarget`. Re-binding the same id replaces it.
- `unbind(actionId)`.

Pure module + spec: `Classify` (enum-name -> device).
