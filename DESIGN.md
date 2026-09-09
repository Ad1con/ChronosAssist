# Design notes -- stage 1

Repo-only. Rationale for decisions in `src/main.lua` that would otherwise bloat
its header comment. See `CHRONOS_TRAINER_SPEC.md` and `CHRONOS_RESEARCH.md`
(both one level up, not part of this repo) for the underlying research this
stage is validating.

## Why SelectWeapon needs a re-entrancy guard and UnitSplit (RealHecate) did not

`SelectWeapon` (`EnemyAILogic.lua:1232`) calls itself recursively in four
places:

- `:1254` -- a `ChainedWeapon` whose `ChainChance` roll fails
- `:1263` -- a chained weapon that turns out to be `WeaponComboOnly`
- `:1287`, `:1294` -- an active combo step whose `WeaponOptions` all filter out
  as ineligible, or whose `GameStateRequirements` fail
- `:1360` -- a freshly-selected weapon that turns out to be `WeaponComboOnly`

Every one of these is `return SelectWeapon(enemy)` -- a bare global reference,
resolved at call time against whatever the global environment's `SelectWeapon`
currently is. `ModUtil.Path.Wrap("SelectWeapon", wrapper)` replaces that global
slot with the wrapper. So after wrapping, the ORIGINAL function's own internal
recursive calls re-enter the wrapper too, not the original body directly.

Without a guard, one logical attack decision (one call from the AI system)
could produce two, three, even four log lines, most of them showing a
transitional state -- a `nil` weapon, a combo index that has not settled yet.
The fix is the same shape as RealHecate's generation guard on `watchClones`,
but for a different hazard: a boolean flag on the enemy table
(`enemy.ChronosAssist_InSelectWeapon`), set before calling `base`, cleared
after, checked at the top of the wrapper. Only the outermost call -- the one
the AI system actually made -- ever reaches the logging code; every recursive
call takes the early exit straight to `base`.

`UnitSplit` (`EnemyAILogic.lua:5139`), which RealHecate wraps, does not
recurse into itself anywhere in its body, so that mod never needed this. It is
a property of the specific function being wrapped, not something to assume
generalizes.

## Why phase-begin logging reads CurrentPhase drift instead of hooking ChronosPhaseTransition

The obvious approach is to wrap `ChronosPhaseTransition`
(`PresentationBiomeI.lua:704`) directly, the same way the per-attack hook
wraps `SelectWeapon`. Tracing `StagedAI`'s loop (`EnemyAILogic.lua:5601`)
against that function shows why it gives the wrong snapshot for
`weaponpool=`:

1. `StagedAI` iterates `enemy.AIStages`. For each stage `k`, it applies that
   stage's own `AIData` -- including `WeaponOptions` -- via
   `OverwriteTableKeys(enemy, aiStage.AIData)` at `:5633`, near the TOP of the
   iteration.
2. Only after that does it call `aiStage.TransitionFunction`, at `:5755`, near
   the BOTTOM of the same iteration.

So when stage 5 (the last stage of phase 1) runs, `ChronosPhaseTransition`
fires with `enemy.WeaponOptions` still holding stage 5's OWN pool -- the
phase-1 pool that is about to be retired -- because stage 6's `AIData` is not
applied until the loop advances to the NEXT iteration. A post-hoc wrap of the
transition function itself would log the outgoing pool under the incoming
phase's `begin` line, which is backwards from what the line is supposed to
show.

Reading `enemy.CurrentPhase` at actual attack-selection time sidesteps the
question entirely: by the time any `SelectWeapon` call happens in the new
phase, `StagedAI` has long since applied that phase's first stage's `AIData`.
Detecting the phase change by diffing against the last value seen
(`enemy.ChronosAssist_LastPhase`) is one field read, needs no second hook, and
is guaranteed to see settled data.

Cost: the phase-begin line fires on the FIRST ATTACK of the new phase, not the
instant the transition animation plays. Given the phase transition itself
locks player input and takes several seconds (`SetPlayerInvulnerable`,
`AddInputBlock` in `ChronosPhaseTransition`), this lag is invisible in
practice -- there is no attack to log until the transition has finished
anyway.

## Why `stages=<N>` is the fight-wide total, not "N in this phase"

The header (built in stage 2) reads as "stage `N` of 4" -- a count scoped to
the CURRENT phase (4 in phase 1, 2 in phase 2, 2 in phase 3, per
`CHRONOS_TEXTPASS.md` section 1). Stage 1's log line uses `#enemy.AIStages`
instead -- the fight-wide total, **8** -- because segmenting `AIStages` by
phase requires walking the array looking for `TransitionFunction ==
"ChronosPhaseTransition"` boundaries, which is exactly the kind of derived
structure the per-phase header needed to get right with tests behind it.
Doing that early, un-tested, to serve one log field would have been solving
stage 2's problem inside stage 1. The fight-wide total is trivially correct
and was enough to confirm the stage ladder in `CHRONOS_RESEARCH.md` section 15
fires at the right thresholds, which was stage 1's actual job.

(The "9" this section originally said was wrong -- see the correction below.
Stage 1's own log line and test were fixed alongside it; nothing about this
section's REASONING changed, only the number.)

## `CONFIG.phaseStageCounts`'s own off-by-one, caught before it shipped

Building the header's per-phase numbering required the segmentation this
section above deferred. The first version got it wrong in exactly the way
the correction below describes: it treated a `TransitionFunction ==
"ChronosPhaseTransition"` entry as the LAST stage of the phase ending, when
`StagedAI`'s loop (`EnemyAILogic.lua:5601-5755`) actually runs that
transition as part of entering the stage it's attached to -- so it's the
FIRST stage of the new phase. Tracing `EnemyData_Chronos.lua:344-622`
directly (not reasoning about it) is what caught this: the array has eight
entries, not nine, split 4/2/2, matching `CHRONOS_TEXTPASS.md` exactly where
an earlier reading did not.

The fix moves one line: close the previous phase's count BEFORE incrementing
for an entry that starts a new one, rather than after. `CONFIG
.phaseStageCounts`'s own comment in `main.lua` carries the full trace.
Sabotage-verified (test suite section 11): reverting to the old order turns
all seven per-stage header assertions red at once, which is the right blast
radius for an off-by-one in a shared counting function.

## Why "blocked" reasons are candidate gates, not a single diagnosed reason

`IsEnemyWeaponEligible` (`EnemyAILogic.lua:1370`) is roughly 300 lines and
checks several dozen distinct requirement keys -- health percentages, combo
partners, required equipment, line of sight, and more, on top of the handful
`CHRONOS_RESEARCH.md` section 4.2 documents as load-bearing for Chronos.
Reimplementing all of it a second time, just to report WHICH single check
failed, would be exactly the mistake `MODDING_HADES2.md` section 3 rule 5
warns about: a second copy that can drift from, or simply misunderstand, the
first.

The boolean itself is never in question here -- it always comes from calling
the game's own function. `candidateGates` only lists which of a blocked
weapon's own requirement keys are non-nil, from a fixed whitelist of the gates
research found in practice. For a weapon with exactly one such gate, that IS
the reason. For a weapon with two or more, the log names both without
claiming to know which one actually fired -- accurate as a hint, not
authoritative. A single confirmed reason per weapon, matching
`CHRONOS_TEXTPASS.md` section 8's exact wording, is stage 3's job, once the
grid needs the harness treatment (a real copy of `IsEnemyWeaponEligible`,
`NumAttacksSinceWeapon` and `NumConsecutiveUses`) that spec section 8
describes.

## What the test harness does and does not reproduce

`test/harness.lua` fakes `IsEnemyWeaponEligible` covering only
`MinAttacksBetweenUse`, `MaxUses`, `PreviousWeaponNot`, `MinPlayerDistance`
and `MaxPlayerDistance` -- the gates most relevant to Chronos and the ones the
spec explicitly warns are easy to get backwards (section 5.2: `MinPlayerDistance`
blocks when the player IS within range, not when they are outside it). This is
not the mistake rule 5 warns about, because the shipped mod never reimplements
eligibility -- `scanEligibility` only loops and calls the real function
(`CONFIG.scanEligibility` in `main.lua`). The harness fake exists so the suite
has a realistic function to call FROM while testing the mod's own scanning and
formatting code, not as a stand-in the mod's logic is measured against. A
fuller copy, matching the real function line for line, is stage 3's
responsibility once the grid's correctness actually depends on it.

## A correction to research section 12.1, found while writing this stage

`CHRONOS_RESEARCH.md` claimed `ChronosRush` and `ChronosRush_P3` share a
cooldown via `GenusName`. Grepping `WeaponData_Chronos.lua` turned up exactly
three `GenusName` occurrences across all 105 weapons, and neither Rush weapon
has one -- `ChronosRush_P3` uses `InheritFrom`, which does not fabricate a
field the parent never declared (`RunData.lua:1363-1420`). The real pair is
`ChronosCastOrbit` / `ChronosCastOrbit2`. Corrected in the research doc
2026-09-05, along with the test fixture here that had copied the wrong claim
uncritically (see MODDING_HADES2.md section 1: read the source, don't recall
it).

That fixture fix surfaced a second, more interesting bug in the TEST rather
than the mod: the first version of the corrected 5.1 asserted
`ChronosCastOrbit2` alone in `WeaponOptions`, picked it, and checked the
resulting log line. It passed. It ALSO passed after sabotaging the genus link
away -- a vacuous test wearing a passing test's clothes, exactly the failure
mode `MODDING_HADES2.md` section 3 rule 3's "partial sabotage" refinement
warns about. The cause: `scanEligibility` runs AFTER `base()` has already
appended the just-picked weapon to `enemy.WeaponHistory`, so any weapon with
`MinAttacksBetweenUse` that gets picked shows itself blocked on the very next
scan regardless of genus -- correct behavior (its own cooldown just started),
but it swamped the thing the test meant to check (whether OLDER history
collapses via genus). The fix -- give the fake a second, gate-free option and
force the pick onto that instead, leaving the weapon under test un-picked --
is the same shape as 5.2's comment already documented. Both tests are
sabotage-verified for real now (flip the genus, watch it fail, revert), not
just asserted to be.

## Stage 2 -- rendering decisions

### Why the background rectangle fades by SetColor alpha, not ModifyTextBox FadeTarget

Every `FadeTarget` usage found in the shipped scripts (`grep -rn FadeTarget
Content\Scripts`, about twenty hits) is a `ModifyTextBox` call on something
that also had `CreateTextBox` called on it. The panel's background is a bare
`rectangle01` obstacle with no text box attached -- Jowday's own equivalent
(`createDpsOverlayBackground`, `JowdayDPS.Main.lua:527-544`) never calls
`CreateTextBox` on it either, and hides it by `game.Destroy` instead, which
this mod deliberately does not copy (see the file header: anchors are never
destroyed). Untested whether `ModifyTextBox({Id=<rect>, FadeTarget=...})`
would silently no-op, error, or actually work on a non-text obstacle --
rather than guess, the background's visibility is `SetColor`'s alpha channel,
which is unambiguously documented to work on this exact obstacle type
(`SetColor({Id=..., Color=readBackgroundcolor()})`, same file, :543). The
practical cost: the background snaps instead of smoothly fading, while the
text above it eases in over `FADE_DURATION`. Worth revisiting once the maintainer
confirms whether `FadeTarget` on a plain obstacle works at all.

### Why the panel is built by the watcher and not at load

The first two launches with the panel enabled crashed the game outright:

```
[0]  sgg::GroupManager::GetIndex        GroupManager.h:22
[1]  sgg::GroupManager::Add             GroupManager.cpp:191
[2]  sgg::ScriptAction::SpawnScreenObstacle  ScriptAction.cpp:7340
...
[33] sgg::ScriptManager::InitLua        ScriptManager.cpp:891
```

`ensurePanel` ran from `on_ready`, which fires on `modutil.once_loaded.game`.
That callback means the game's Lua tables exist -- not that the game is
running. The engine was still inside `InitLua` when `CreateScreenObstacle`
asked it to spawn into a `GroupManager` that had no groups yet.

Two things about this are worth keeping in mind:

* **The `pcall` around `ensurePanel` was useless.** The fault is native, not a
  Lua error, so it never becomes a catchable value. The mod died before
  reaching its own `logAlways`, which is why the log contained zero
  `Adicon-ChronosAssist:` lines and the previous mod alphabetically
  (AlwaysChaosGates) looked like the culprit.
* **Copying DamageMeter's call was not enough.** Its `CreateScreenObstacle`
  arguments were right; *where it calls them from* was the part that mattered,
  and that lives in its in-run code paths, not its entry point.

So `ensurePanel` now starts the watcher and nothing else. `watchFight` builds
the anchors on the first tick that finds a Chronos, which is unambiguously
gameplay. `setPanelVisible` returns early while `Panel.created` is false --
without recording `Panel.visible`, so the first call after construction still
writes rather than matching a stale "no change".

Test 16.3 in `test/run_tests.lua` asserts boot creates zero obstacles. It
exists purely so this cannot come back.

### Why one persistent watcher thread, not one per fight (unlike RealHecate)

RealHecate's `watchClones` starts a fresh watcher at every split and retires
it with a generation guard once that split's clones are gone -- appropriate
because a NEW split's marker state must not be clobbered by a STALE watcher
from the previous one still judging by old clone ids.

Nothing here has that shape. There is only ever one panel, and "is a tracked
Chronos alive" is a question that stays valid across any number of fights in
one session -- unlike RealHecate's clone ids, nothing about a NEW fight
invalidates how a watcher should judge an OLD one, because the check never
references fight-specific state at all. So `ensurePanel` starts exactly one
`watchFight` thread, ever (guarded by `Panel.watcherStarted`), and it runs for
the rest of the session, fading the SAME anchors in and out as fights start
and end. This is also what makes all four teardown paths in spec section 4.4
-- phase change, Chronos dying, player dying, leaving the room -- collapse to
one check (`findPrimary` returning nil) instead of four: none of them change
what "alive" means, they just all eventually make it false.

### Why the shadow-duplicate line is simpler than research's own mockup

`CHRONOS_RESEARCH.md` section 18 state 12 mockups a duplicate's entry with
its own two lines (name+timer, then description) and no bar. This ships with
one line only (`CONFIG.duplicateLine`: the marker glyph plus the resolved
label, no description, no timer). Reasons: it is Rivals-phase-3-only content,
so it is the least-tested path in a build nobody has played yet; research
section 13.2 already establishes a duplicate is never the one-shot, which is
the highest-value fact to convey in one glance; and `CONFIG.findShadow` shows
only the first live shadow found, untested against more than one at once
(possible per research's "past duplicates" plural). Revisit once a Rivals
playtest shows whether the compact version reads as under-informative.

### Layout constants are unverified starting guesses

`LAYOUT` in `main.lua` -- position, panel size, bar size, colors -- was
chosen from the nearest confirmed data point (`HUDData.lua`'s
`ObjectiveStartX/Y`) and Jowday's own empirical `rectangle01` scale
calibration, not from seeing the panel rendered. `MODDING_HADES2.md`
section 5 is explicit that this project cannot see the screen and every
visual default in a sibling mod (RealHecate's `GroundFxScale`, its color
presets) needed a playtest pass to land. Treat every number in `LAYOUT` the
same way -- it is a single named constant specifically so that pass is a
one-line edit and a hot reload, not a rewrite.

## Stage 3 -- milestones and the grid

### Deriving WHAT_CHANGES, and the one transition it leaves unconfirmed

`CHRONOS_TEXTPASS.md` section 6 gives exactly six phrases for "what
changes", and the stage ladder (corrected above) has seven transitions
between its eight stages that could each show one. The six were matched to
transitions by triangulating three sources:

1. `EnemyData_Chronos.lua`'s own `EquipWeapons` diffs between consecutive
   stages -- what actually gets added.
2. Research section 19.1's add-spawn triggers (satyrs at 75%, elites at
   25%), which happen to land on the same health fractions as two stage
   boundaries.
3. Research section 18's own worked walkthrough, which states four of the
   seven pairings AS WRITTEN, in context: state 1 (1->2: "6 satyrs"), state 4
   (2->3: "Triple Attack Combo"), state 7 (4->5, the phase boundary: "new
   arena, Time Burst and Clock Burst"), state 8 (5->6: "moveset expands"),
   state 12 (7->8: "clock platforms attack").

That leaves 3->4 ("2 armoured elites", from source 2 alone -- no state
example pins it, but the health fraction match is exact and the phrase has
no other plausible transition) and 6->7 (the phase-2-to-3 boundary) with
nothing. `EquipWeapons` at stage 7 IS a wholesale moveset replacement -- the
entire `_P3` list -- so reusing "moveset expands" (already assigned to 5->6)
was considered and rejected: it is a real phrase but not a CONFIRMED one for
THIS transition, and reusing a confirmed phrase for an unconfirmed slot reads
as confirmed to anyone auditing the table later. `WHAT_CHANGES[6]` is simply
absent, and `CONFIG.milestoneLines` treats a missing entry as "no suffix" --
tested (17.6) by asserting the exact bare line, not just presence of SOME
text.

### Why `phaseEndThreshold` can be stale under the Vow, and why that's not fixed here

`StagedAI` applies `EMStageDataOverrides` to a stage's OWN table the first
time it is reached (`EnemyAILogic.lua:5615-5617`,
`OverwriteTableKeys(aiStage, aiStage.EMStageDataOverrides)`) -- an in-place
mutation of that one array entry, not a copy. `CONFIG.phaseEndThreshold`
reads a FUTURE stage (the last one in the current phase) to preview the
milestone before reaching it. If that stage's `AIEndHealthThreshold` differs
under `BossDifficultyActive` and the EM override has not applied yet
(because that stage has not been reached), the preview reads the
pre-override value.

Whether this is actually a problem is unverified either way -- it depends on
whether any Chronos `EMStageDataOverrides` block actually changes
`AIEndHealthThreshold` (none of the ones read while building this document
did; they changed `WaitDuration`, `FireWeapon` and `EquipWeapons`). No fix is
applied speculatively for a data shape not confirmed to exist. Flagged as an
open item below in case a Vow of Rivals playtest shows the milestone
previewing the wrong percentage.

### The grid's reason column checks gates, not just their presence

Stage 1's log-only "candidate gates" diagnostic (`CONFIG.candidateGates`) was
deliberately allowed to be imprecise -- it lists every gate key a weapon HAS,
not the one that is failing right now, because it's a developer log and the
alternative was reimplementing much of `IsEnemyWeaponEligible`. The grid is
player-facing, so that imprecision is not acceptable here: `CONFIG
.gridReason` actually evaluates each of the five gates it covers (calling
`game.IsWithinDistance`/`game.NumAttacksSinceWeapon`, the same primitives the
real function uses) and returns the one that is presently true, checked in
the real function's own order. `candidateGates` is reused only as the
LAST-RESORT fallback, when none of the five explains an already-confirmed
block -- at that point imprecision is honestly disclosed (the row visibly
reads as unpolished, `"blocked (GateName)"`, not textpass wording) rather
than hidden.

## Open items for the first playtest

Per spec section 3.1 and 9.1:

1. The three unmapped guide names -- Diagonal Orbs, Spiral Orbs, Spider
   Clock -- need a played fight plus his description of what he saw, matched
   against the logged `weapon=` names.
2. Confirm the timing table (research section 3/11) against the logged
   `preattack=`/`attackdist=` values.
3. Confirm the stage ladder (research section 15) fires at the health
   thresholds recorded, via the `phase begin` lines and the per-attack
   `stage=` values.
4. Confirm `eligible=`/`blocked=` match what he actually experiences in play
   (spec section 3.1 item 4) -- this is the one static reading cannot settle.
5. Confirm `shields=` and `tempus=` move the way research sections 19-20
   predict (shields non-zero while banners stand, tempus non-zero and health
   climbing while they are alive and beaming).

Stage 2 adds, on top of the above:

6. **Every `LAYOUT` value** -- position, size, colors -- per the section
   above. This is the big one; nothing here has been seen on screen.
7. Whether `ModifyTextBox`'s `FadeTarget` actually works on the background
   rectangle, which would let it fade smoothly instead of snapping.
8. Whether `GetTime({})` behaves as assumed for the wind-up bar -- monotonic,
   in seconds, unaffected by pause menus or the phase-transition's own
   `SetUnitInvulnerable`/input-block window. An unexpected jump would show as
   the bar snapping instead of draining smoothly.
9. Whether any weapon shown by its raw internal name in the NOW block should
   get a real label -- every entry in `CHRONOS_RESEARCH.md` section 9.1a's
   "unconfirmed" column, plus anything neither that section nor
   `CHRONOS_TEXTPASS.md` anticipated.
10. Whether the compact one-line shadow-duplicate treatment reads as enough,
    once a Rivals phase 3 fight actually shows one.
11. All four teardown paths (spec section 4.4), same as the DoD requires --
    the suite proves the MECHANISM (an absent tracked enemy hides the panel)
    but not that phase transitions, death and room exit all actually clear
    `ActiveEnemies` the way that mechanism assumes.

Stage 3 adds:

12. **The 6->7 transition's "what changes" text** -- the one gap in
    `WHAT_CHANGES`. If the maintainer can say what actually arrives crossing that
    boundary, textpass can add a seventh phrase and this stops being blank.
13. Whether `phaseEndThreshold` ever previews a stale percentage under the
    Vow of Rivals (see the section above) -- only reachable in a Rivals run.
14. Whether "Tempus healing" firing on any LIVE `TimeElemental2` (rather than
    only while one is actively beaming) ever reads as wrong -- e.g. shown
    right as one spawns, before it has done anything.
15. Every row `CONFIG.gridReason` cannot yet explain -- textpass section 8
    has no wording for `MaxConsecutiveUses` (9 weapons use it),
    `RequireTotalAttacks` (3), or `PreviousWeaponNot` (2), all real per
    research section 4.2. They show as `"blocked (GateName)"` until textpass
    says what they should read instead.
16. Whether the milestone and grid sections, stacked below stage 2's NOW
    block, fit inside `PANEL_HEIGHT_PX` without the box running off-screen --
    another first-guess `LAYOUT` value, now with three more variable-length
    sections beneath it.
