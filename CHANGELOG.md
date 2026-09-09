# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The release workflow folds the `[Unreleased]` section into the tagged
version, so the square brackets are load-bearing -- the action looks for
`[Unreleased]` exactly and fails the build without it.

## [Unreleased]

### Fixed

- The game crashed on launch with `EXCEPTION_ACCESS_VIOLATION` whenever the
  panel was enabled. The panel's screen obstacles were created from
  `on_ready`, which runs while the engine is still inside `InitLua` -- the
  spawn reached a `GroupManager` that had no groups yet. The watcher now
  builds the panel on the first tick that finds a Chronos, which is
  unambiguously in gameplay. Nothing in the load path touches a drawing API
  any more, and a test asserts that.

Stage 3 of 3 (see `CHRONOS_TRAINER_SPEC.md`, one level up, not part of this
repo): milestones and the UNAVAILABLE grid, completing the panel.

- A milestone line: percent-away to the next stage and, when it's not also
  a phase boundary, a second line for the phase after that. Collapses to one
  line at a phase boundary. Percentage only, live from health/max-health,
  never absolute damage (max health differs 20000/16000/26000 by phase).
- Two status lines, shown only while true: shields (`chronos.HitShields`,
  a live integer) and Tempus healing (a live `TimeElemental2` present).
- The UNAVAILABLE grid: one row per currently-ineligible attack, via the
  game's own `IsEnemyWeaponEligible` -- never reimplemented. The reason
  column checks the same five gates the real function does, in the same
  order, so the reported reason is the one that actually fired (`in N
  attacks`, `N of M uses left`, `only when you're closer/farther`, `no line
  of sight`). A gate textpass doesn't yet have wording for shows a visible
  placeholder rather than vanishing from the grid or guessing text.
- Corrected two more research findings while building this: the stage
  ladder's per-transition "what changes" text, traced against the game's own
  `EquipWeapons` diffs (one of seven transitions has no confirmed text and
  is left blank rather than guessed); and `MaxUses` does NOT genus-collapse
  the way `MinAttacksBetweenUse` does, verified against the real gate's own
  code, matters for the grid staying accurate on the Orbit pair.

Stage 2, unchanged:

- A header ("CHRONOS", "Phase N · stage N of 4/2/2") and a NOW block:
  the current attack's label, remaining wind-up as a draining bar, its
  description, and a deterministic "NEXT IN COMBO" line when one applies.
  Text from `CHRONOS_TEXTPASS.md`; an unmapped weapon shows its raw internal
  name rather than a guessed label.
- A live shadow duplicate (Rivals phase 3) gets its own marked line.
- Rendered Jowday-DamageMeter style: every screen component is created once
  and updated in place, never destroyed and recreated. Fades in when a
  tracked Chronos is alive, out when not -- covering phase changes, Chronos
  dying, the player dying, and leaving the room with one check.
- New setting `Panel` (on by default) gates the whole panel; `GroundMarker`
  is declared for a future stage and does nothing yet.
- Corrected two research findings while building this: the stage ladder is
  8 stages (4/2/2), not 9, and `ChronosRush`/`ChronosRush_P3` do not share a
  cooldown genus -- `ChronosCastOrbit`/`ChronosCastOrbit2` do. See
  `CHRONOS_RESEARCH.md` sections 12.1 and 15.

Stage 1, unchanged:

- Wraps `SelectWeapon` to log one line per Chronos attack: the weapon,
  phase, stage, health, wind-up, attack distance, combo state, and the
  eligible/blocked weapon sets from the game's own `IsEnemyWeaponEligible`.
- Logs once at fight start and once per phase transition: health, total
  stage count, and the current weapon pool.
- Scoped to `Chronos` and `Chronos_EMShadow` only. `Chronos_TyphonFight` and
  `NPC_Chronos_01` are untouched, despite all four sharing
  `GenusName = "Chronos"`.
- Writes nothing to the save. One setting, `Enabled`, gates all of it.
