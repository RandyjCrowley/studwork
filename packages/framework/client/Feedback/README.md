# client/Feedback (agent G)

`Types.FeedbackAPI` + `onFeedbackEvent` + `start(ctx)`.

| fn | behaviour |
|---|---|
| `pop(text, position?, rarity?)` | Number pop: squash -> stretch -> settle, float up, fade (`PopAnim`). `UDim2` = screen position, `Vector3` = world pop (BillboardGui on a pooled Attachment under Terrain, AlwaysOnTop, MaxDistance 250), `nil` = upper-centre screen, concurrent pops stack in 6 slots. Colour = rarity colour, else Palette `currency`. Display font + outline stroke. |
| `flash(rarity)` | Full-screen gradient glow in the tier's `glow` colour; peak opacity `0.08 + 0.42 * glowStrength`, fade `0.35 s + 0.25 * glowStrength`. One reused frame. |
| `sound(key)` | `Sounds[key]` (skips id 0). 4 pooled voices per key in `SoundService.CoreFeedbackSounds`. `coin_tick` pitch rises ~1 semitone per tick within 0.35 s, capped at 1.6x (`PitchRamp`). |
| `shake(intensity?)` | Default 1. `BindToRenderStep` at `Camera + 1`, multiplies the CFrame the default camera just wrote (no accumulation, composes with any camera that writes CFrame each frame). Decays over 0.45 s; repeated shakes stack up to 2.5. Unbinds when idle. |
| `onFeedbackEvent(fn(kind, text, rarity?))` | Every Blink `Feedback` message is forwarded (also toasts - the HUD renders those). |

Server messages: `item` -> pop + flash + rarity sound + shake when Legendary+; `pop` -> pop + coin tick (+ shake if a Legendary+ rarity is attached); `toast` -> forwarded only. `Position` (Vector3) makes the pop world-space.

**Reduced motion**: `Players.LocalPlayer:SetAttribute("CoreReducedMotion", true)` (games can wire it to a settings toggle) or Roblox's own `GuiService.ReducedMotionEnabled` -> no shake, pops only fade (no squash/float), flash at half strength.

**Limits**: 12 screen pops, 16 world pops, 4 voices per sound key, 1 flash frame - spam recycles the oldest (`Pool`), never allocates more. The RenderStepped driver only runs while pops are alive.

Pure modules + specs: `Pool`, `PitchRamp`, `Shake`, `PopAnim`.


core-v1.3.0: colours, fonts, stroke, rarity look and sound ids come from the merged theme
(`client/Theme.luau` -> `Framework/shared/Theme`), not `Core.Palette` / `Core.Sounds` /
`Core.RarityTiers`.
