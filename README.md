# ChronosAssist

A training panel for the Chronos fight in Hades II: what he is doing, what he
can do next, and how far the fight has to go.

**Status: stage 3 of 3 (see `CHRONOS_TRAINER_SPEC.md`) -- feature-complete,
not yet playtested.** A top-left box shows:

- the header (phase and stage)
- the current attack: its name, a draining wind-up bar, what it does, and
  (inside a combo) what comes next
- a milestone line: how far to the next stage, and to the phase after that
- status lines while a shield or a healer is active
- the UNAVAILABLE grid: which attacks he can't currently use, and why

Stage 1's log (`LogOutput.log`, every line prefixed `[ChronosAssist]`) is
unchanged and still runs underneath it.

Writes nothing to your save. Two settings: `Enabled` (master switch) and
`Panel` (the on-screen box). A third, `GroundMarker`, is declared for a later
stage and does nothing yet.

## Installing for a playtest (not yet on Thunderstore)

1. Close Hades II.
2. Junction this repo's `src/` folder into your r2modman profile's plugins
   folder:

   ```powershell
   New-Item -ItemType Junction -Path "$env:APPDATA\r2modmanPlus-local\HadesII\profiles\Default\ReturnOfModding\plugins\Adicon-ChronosAssist" -Target "C:\path\to\Adicon-ChronosAssist\src"
   ```
3. Launch the game and fight Chronos. Every log line is prefixed
   `[ChronosAssist]` in `LogOutput.log`; the panel sits top-left, since
   Jowday's Damage Meter already occupies bottom-right and many players run
   both.

The panel's position, size and colors are first-guess starting values --
nobody has seen them on screen yet. Playtest first, then tell me what to
adjust; every one of those numbers is a single named constant.

## Credits

- **Supergiant Games**, for Chronos and the fight this panel is built around.
  The icon is a cropped in-game portrait of Chronos.
- The **Hades Wiki**'s Chronos/Combat pages, for the attack inventory and
  the observation that the rift attack "deals damage in the full arc between
  Chronos and itself" despite its shape -- the premise this whole panel acts on.
- **Mobalytics**' "How to Beat Chronos" guide, for the player-facing attack
  names this panel uses and its own statement of the same premise: "you
  always have time to react."
- **Jowday's Damage Meter**, whose on-screen box is the direct template for
  how this one is drawn -- `CreateScreenObstacle` plus a screen-anchor
  registry, updated in place rather than destroyed and recreated. It sits
  bottom-right; this panel goes top-left so the two run together.

Built on [ReturnOfModding / Hell2Modding](https://github.com/SGG-Modding). This
mod cannot load without `LuaENVY-ENVY`, `SGG_Modding-ModUtil` and
`SGG_Modding-ReLoad` — the environment isolation, the function wrapping and the
hot reload are all theirs.

Thank you to the Hades Modding community. Your work is astounding.

Built by Adicon, with Claude.
