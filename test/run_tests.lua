-- ChronosAssist stage 1 test suite. Run from this directory:
--     lua run_tests.lua
--     luajit run_tests.lua
--
-- Both interpreters, always. The game ships LuaJIT and the two differ in ways
-- that have bitten sibling mods before.

local PLUGIN = "../src/main.lua"
local HARNESS = "./harness.lua"
local M = dofile("./mocks.lua")

local passed, failed = 0, 0
local failures = {}

-- Assertions must FAIL, not raise: a regression that makes a value nil must
-- read as one red line, not abort the run and hide every later section.
local function check(name, condition, detail)
  if condition then
    passed = passed + 1
  else
    failed = failed + 1
    detail = detail and tostring(detail) or nil
    if detail and #detail > 200 then
      detail = detail:sub(1, 197) .. "..."
    end
    failures[#failures + 1] = name .. (detail and ("  -- " .. detail) or "")
  end
end

local function countMatching(lines, needle)
  local n = 0
  for _, line in ipairs(lines) do
    if tostring(line):find(needle, 1, true) then n = n + 1 end
  end
  return n
end

-- Boots the plugin against fresh fakes. With no arguments this is EXACTLY the
-- shipping configuration: the mock config store starts empty, so Enabled
-- binds to the plugin's own default (true).
local function boot(initial, opts)
  opts = opts or {}
  local G = dofile(HARNESS)
  M.install(G, opts.configOpts, initial, { noReload = opts.noReload, noModUtil = opts.noModUtil })
  if opts.noModUtil then G.ModUtil = nil end
  local plugin = dofile(PLUGIN)
  if M.pendingGameLoad then M.pendingGameLoad() end
  return G, plugin
end

-- =============================================================================
-- 1. Scoping (spec section 2) -- the trap
-- =============================================================================

do
  local G = boot()
  local chronos = G.spawnChronos()
  G.SelectWeapon(chronos)
  check("1.1 Chronos produces an attack log line",
        countMatching(M.logs, "weapon=") >= 1, M.logs[#M.logs])
end

do
  local G = boot()
  local shadow = G.spawnChronos({ Name = "Chronos_EMShadow" })
  G.SelectWeapon(shadow)
  check("1.2 Chronos_EMShadow produces an attack log line",
        countMatching(M.logs, "weapon=") >= 1)
end

do
  local G = boot()
  local typhonAssist = G.spawnChronos({ Name = "Chronos_TyphonFight" })
  G.SelectWeapon(typhonAssist)
  check("1.3 Chronos_TyphonFight produces NO attack log line despite shared genus",
        countMatching(M.logs, "weapon=") == 0, table.concat(M.logs, " | "))
end

do
  local G = boot()
  local npc = G.spawnChronos({ Name = "NPC_Chronos_01" })
  G.SelectWeapon(npc)
  check("1.4 NPC_Chronos_01 produces NO attack log line despite shared genus",
        countMatching(M.logs, "weapon=") == 0)
end

-- =============================================================================
-- 2. Enabled=false leaves the fight untouched (spec section 6 / test case 11)
-- =============================================================================

do
  local G = boot({ Enabled = false })
  local chronos = G.spawnChronos()
  local picked = G.SelectWeapon(chronos)
  check("2.1 Enabled=false still resolves a real weapon pick",
        picked ~= nil, tostring(picked))
  check("2.2 Enabled=false logs no attack line",
        countMatching(M.logs, "weapon=") == 0, table.concat(M.logs, " | "))
  check("2.3 Enabled=false logs no phase-begin line",
        countMatching(M.logs, "begin") == 0)
end

-- =============================================================================
-- 3. Re-entrancy guard (DESIGN.md) -- SelectWeapon recurses on ChainChance
-- =============================================================================

do
  local G = boot()
  local chronos = G.spawnChronos()
  chronos.ChainedWeapon = "ChronosChainTest"
  G.RandomChanceQueue = { false }  -- ChainChance fails -> base recurses once
  G.SelectWeapon(chronos)
  check("3.1 one recursive SelectWeapon call still produces exactly one attack log line",
        countMatching(M.logs, "weapon=") == 1, table.concat(M.logs, " | "))
  check("3.2 the wrap itself was installed exactly once",
        G.wrapped.SelectWeapon == 1)
end

-- =============================================================================
-- 4. Eligibility scan, and the distance-gate direction
-- =============================================================================

do
  local G = boot()
  local chronos = G.spawnChronos({
    WeaponOptions = { "ChronosSwingRight", "ChronosGrind" },
    DistanceToPlayerFake = 100, -- inside ChronosGrind's MinPlayerDistance = 275
  })
  G.SelectWeapon(chronos)
  local line = M.logsContaining("weapon=")[1]
  check("4.1 close range: ChronosGrind is blocked, not eligible",
        line ~= nil and line:find("blocked=ChronosGrind:") ~= nil, line)
  check("4.2 blocked reason names MinPlayerDistance as a candidate gate",
        line ~= nil and line:find("MinPlayerDistance") ~= nil, line)
end

do
  local G = boot()
  local chronos = G.spawnChronos({
    WeaponOptions = { "ChronosSwingRight", "ChronosGrind" },
    DistanceToPlayerFake = 1000, -- outside MinPlayerDistance -> eligible
    ForcedPickIndex = 1,
  })
  G.SelectWeapon(chronos)
  local line = M.logsContaining("weapon=")[1]
  check("4.3 far range: ChronosGrind is eligible, not blocked",
        line ~= nil and line:find("eligible=") ~= nil
        and line:find("ChronosGrind", 1, true) ~= nil
        and line:find("blocked=ChronosGrind:") == nil,
        line)
end

-- Sabotage check for 4.1/4.2, done by hand while writing this suite (see
-- CONTRIBUTING.md): flipping the MinPlayerDistance branch in
-- harness.lua's IsEnemyWeaponEligible to `if not G.IsWithinDistance(...)`
-- (the MaxPlayerDistance shape) turned 4.1 red, confirming the test actually
-- exercises the direction it claims to.

-- =============================================================================
-- 5. Genus grouping (research section 12.1, corrected 2026-09-05) --
--    ChronosCastOrbit / ChronosCastOrbit2, VERIFIED against WeaponData_Chronos.lua
-- =============================================================================

do
  -- ChronosCastOrbit2 is put in WeaponOptions alongside a weapon with no
  -- gates at all and left UNPICKED (ForcedPickIndex selects the other one):
  -- if it were picked, the fake SelectWeapon's own append to WeaponHistory
  -- would put ChronosCastOrbit2 last in its OWN history and self-block on
  -- the very next scan (see 5.2's comment) -- correct behavior, but it would
  -- swamp the thing this test actually checks, which is whether the PRIOR
  -- "ChronosCastOrbit" entry alone is enough to block it via genus collapse.
  local G = boot()
  local chronos = G.spawnChronos({
    WeaponOptions = { "ChronosSwingRight", "ChronosCastOrbit2" },
    WeaponHistory = { "ChronosCastOrbit" }, -- used the OTHER half of the genus last attack
    ForcedPickIndex = 1,
  })
  G.SelectWeapon(chronos)
  local line = M.logsContaining("weapon=")[1]
  check("5.1 ChronosCastOrbit2 reads ChronosCastOrbit's cooldown via GenusName",
        line ~= nil and line:find("blocked=ChronosCastOrbit2:MinAttacksBetweenUse") ~= nil,
        line)
end

do
  -- The negative case: ChronosRush has NO GenusName (corrected finding), so
  -- ChronosCastOrbit history must NOT count toward its cooldown. Rush itself
  -- is left un-picked (ForcedPickIndex selects SwingRight instead), so its
  -- own history is exactly the fixture's -- otherwise picking it would append
  -- itself and self-block on the very next scan, which is a separate, correct
  -- behavior (see 5.1) and would make this assertion about the wrong thing.
  local G = boot()
  local chronos = G.spawnChronos({
    WeaponOptions = { "ChronosSwingRight", "ChronosRush" },
    WeaponHistory = { "ChronosCastOrbit", "ChronosCastOrbit" },
    ForcedPickIndex = 1,
  })
  G.SelectWeapon(chronos)
  local line = M.logsContaining("weapon=")[1]
  check("5.2 ChronosRush is unaffected by an unrelated weapon's history (no shared genus)",
        line ~= nil and line:find("eligible=") ~= nil
        and line:find("ChronosRush", 1, true) ~= nil
        and line:find("blocked=ChronosRush:", 1, true) == nil,
        line)
end

-- =============================================================================
-- 6. Combo fields (spec section 4.3 / 15.2)
-- =============================================================================

do
  local G = boot()
  local chronos = G.spawnChronos({
    ActiveWeaponCombo = "ChronosSwingCombo",
    ActiveWeaponComboIndex = 0,
  })
  G.SelectWeapon(chronos)
  local line = M.logsContaining("weapon=")[1]
  check("6.1 mid-combo: combo= names the active combo",
        line ~= nil and line:find("combo=ChronosSwingCombo", 1, true) ~= nil, line)
  check("6.2 mid-combo: comboIdx= is 1 for the first step",
        line ~= nil and line:find("comboIdx=1", 1, true) ~= nil, line)
end

do
  local G = boot()
  local chronos = G.spawnChronos()
  G.SelectWeapon(chronos)
  local line = M.logsContaining("weapon=")[1]
  check("6.3 outside a combo: combo=nil",
        line ~= nil and line:find("combo=nil", 1, true) ~= nil, line)
  check("6.4 outside a combo: comboIdx=0",
        line ~= nil and line:find("comboIdx=0", 1, true) ~= nil, line)
end

do
  -- The combo's LAST step clears enemy.ActiveWeaponCombo internally
  -- (EnemyAILogic.lua:1301-1303) before our post-hoc code reads it -- this is
  -- exactly why comboBefore is captured BEFORE base runs (DESIGN.md).
  local G = boot()
  local chronos = G.spawnChronos({
    ActiveWeaponCombo = "ChronosSwingCombo",
    ActiveWeaponComboIndex = 1, -- about to take the FINAL step
  })
  G.SelectWeapon(chronos)
  local line = M.logsContaining("weapon=")[1]
  check("6.5 the combo's final step still reports combo=, not nil",
        line ~= nil and line:find("combo=ChronosSwingCombo", 1, true) ~= nil, line)
  check("6.6 ActiveWeaponCombo is cleared on the enemy after the final step",
        chronos.ActiveWeaponCombo == nil)
end

-- =============================================================================
-- 7. Phase-begin logging (spec section 3, "once per fight and once per phase
--    transition")
-- =============================================================================

do
  local G = boot()
  local chronos = G.spawnChronos()
  G.SelectWeapon(chronos)
  check("7.1 the very first attack logs a fight-begin line",
        countMatching(M.logs, "phase 1 begin (first seen)") == 1,
        table.concat(M.logs, " | "))
end

do
  local G = boot()
  local chronos = G.spawnChronos()
  G.SelectWeapon(chronos)                 -- fight begin
  G.SelectWeapon(chronos)                 -- same phase, no new begin line
  check("7.2 an unchanged phase logs no additional begin line",
        countMatching(M.logs, "begin") == 1, table.concat(M.logs, " | "))

  chronos.CurrentPhase = 2
  G.SelectWeapon(chronos)
  check("7.3 a phase change logs a transition-begin line",
        countMatching(M.logs, "phase 2 begin (phase transition)") == 1,
        table.concat(M.logs, " | "))
end

do
  local G = boot()
  local chronos = G.spawnChronos({ WeaponOptions = { "ChronosSwingRight", "ChronosBannerSummon" } })
  G.SelectWeapon(chronos)
  local line = M.logsContaining("begin")[1]
  check("7.4 the begin line's weaponpool matches WeaponOptions at call time",
        line ~= nil and line:find("weaponpool=ChronosSwingRight,ChronosBannerSummon", 1, true) ~= nil,
        line)
end

do
  local G = boot()
  local chronos = G.spawnChronos()
  G.SelectWeapon(chronos)
  local line = M.logsContaining("begin")[1]
  check("7.5 the begin line's stage count is the fight-wide total (8), not per-phase",
        line ~= nil and line:find("stages=8", 1, true) ~= nil, line)
end

-- =============================================================================
-- 8. Shields and tempus (spec section 3.1 item 5 / research 19-20)
-- =============================================================================

do
  local G = boot()
  local chronos = G.spawnChronos({ HitShields = 3 })
  G.spawnTempus(2)
  G.SelectWeapon(chronos)
  local line = M.logsContaining("weapon=")[1]
  check("8.1 shields= reads the live HitShields field",
        line ~= nil and line:find("shields=3", 1, true) ~= nil, line)
  check("8.2 tempus= counts live TimeElemental2 units",
        line ~= nil and line:find("tempus=2", 1, true) ~= nil, line)
end

do
  local G = boot()
  local chronos = G.spawnChronos()
  G.SelectWeapon(chronos)
  local line = M.logsContaining("weapon=")[1]
  check("8.3 shields=0 and tempus=0 when neither is present",
        line ~= nil and line:find("shields=0", 1, true) ~= nil
        and line:find("tempus=0", 1, true) ~= nil, line)
end

-- =============================================================================
-- 9. Wind-up and range fields
-- =============================================================================

do
  local G = boot()
  local chronos = G.spawnChronos({
    WeaponOptions = { "ChronosSwingRight" },
    ForcedPickIndex = 1,
  })
  G.SelectWeapon(chronos)
  local line = M.logsContaining("weapon=")[1]
  check("9.1 preattack= reads AIData.PreAttackDuration",
        line ~= nil and line:find("preattack=1.34", 1, true) ~= nil, line)
  check("9.2 attackdist= reads AIData.AttackDistance",
        line ~= nil and line:find("attackdist=500", 1, true) ~= nil, line)
end

-- =============================================================================
-- 10. Degraded environments do not crash the plugin
-- =============================================================================

do
  local G, plugin = boot(nil, { noModUtil = true })
  check("10.1 ModUtil absent: plugin still loads",
        plugin ~= nil)
  check("10.2 ModUtil absent: a warning is logged",
        countMatching(M.logs, "ModUtil.Path.Wrap unavailable") == 1)
end

do
  local G, plugin = boot(nil, { noReload = true })
  local chronos = G.spawnChronos()
  G.SelectWeapon(chronos)
  check("10.3 ReLoad absent: hooks still install and logging still works",
        countMatching(M.logs, "weapon=") >= 1)
end

-- =============================================================================
-- 11. Header stage-within-phase numbering (CHRONOS_TEXTPASS.md section 1),
--     against the REAL 4/2/2 AIStages shape -- this is the off-by-one
--     CONFIG.phaseStageCounts's own comment traces, so it is tested at every
--     stage boundary, not just one example.
-- =============================================================================

do
  local G, plugin = boot()
  local cases = {
    { stage = 1, phase = 1, expect = "Phase 1 \xc2\xb7 stage 1 of 4" },
    { stage = 2, phase = 1, expect = "Phase 1 \xc2\xb7 stage 2 of 4" },
    { stage = 4, phase = 1, expect = "Phase 1 \xc2\xb7 stage 4 of 4" },
    { stage = 5, phase = 2, expect = "Phase 2 \xc2\xb7 stage 1 of 2" },
    { stage = 6, phase = 2, expect = "Phase 2 \xc2\xb7 stage 2 of 2" },
    { stage = 7, phase = 3, expect = "Phase 3 \xc2\xb7 stage 1 of 2" },
    { stage = 8, phase = 3, expect = "Phase 3 \xc2\xb7 stage 2 of 2" },
  }
  for _, c in ipairs(cases) do
    local chronos = G.spawnChronos({ AIStageActive = c.stage, CurrentPhase = c.phase })
    local text = plugin.CONFIG.headerText(chronos)
    check(("11.%d headerText(stage=%d, phase=%d) == %q"):format(c.stage, c.stage, c.phase, c.expect),
          text == c.expect, text)
  end
end

-- =============================================================================
-- 12. Label resolution (CHRONOS_TEXTPASS.md sections 2/4)
-- =============================================================================

do
  local _, plugin = boot()
  local label, desc = plugin.CONFIG.resolveLabel("ChronosGrind")
  check("12.1 exact match resolves label and description",
        label == "Vortex Pull" and desc == "around him, pulls in", tostring(label))

  local l2 = plugin.CONFIG.resolveLabel("ChronosSwingRightComboStart")
  check("12.2 combo-step suffix falls back to the base attack's label",
        l2 == "Scythe Slash (fast)", tostring(l2))

  local l3, d3 = plugin.CONFIG.resolveLabel("ChronosSomethingNeverSeen")
  check("12.3 a truly unmapped weapon resolves to nil, nil (caller shows the raw name)",
        l3 == nil and d3 == nil)

  local l4 = plugin.CONFIG.resolveLabel("ChronosRadial2")
  check("12.4 the insta-kills use the textpass's exact glyph + label",
        l4 == "\xe2\x9a\xa0 CLOCK BURST", tostring(l4))
end

-- =============================================================================
-- 13. The NOW block (spec section 4.3) -- pure computation
-- =============================================================================

do
  local G, plugin = boot()
  local chronos = G.spawnChronos()
  chronos.WeaponName = "ChronosSwingRight"       -- PreAttackDuration 1.34
  chronos.ChronosAssist_WindupStart = 10.0
  chronos.ChronosAssist_WindupTotal = 1.34

  local block = plugin.CONFIG.computeNowBlock(G, chronos, 10.0)
  check("13.1 at t=0 into the windup, the bar is full and the timer shows the total",
        block.barFraction == 1.0 and block.name:find("1.3s", 1, true) ~= nil, block.name)

  local mid = plugin.CONFIG.computeNowBlock(G, chronos, 10.0 + 1.34 / 2)
  check("13.2 halfway through, the bar is at ~0.5",
        mid.barFraction > 0.45 and mid.barFraction < 0.55, tostring(mid.barFraction))

  local done = plugin.CONFIG.computeNowBlock(G, chronos, 10.0 + 5.0)
  check("13.3 past the windup's end, the bar clamps at 0, never negative",
        done.barFraction == 0, tostring(done.barFraction))

  check("13.4 the description line comes from the textpass",
        block.description == "wide arc, front", block.description)
end

do
  -- Sabotage-relevant case: an UNMAPPED weapon must show its raw internal
  -- name, never invented prose (spec section 7).
  local G, plugin = boot()
  local chronos = G.spawnChronos()
  chronos.WeaponName = "ChronosNeverMapped"
  chronos.ChronosAssist_WindupStart = 0
  chronos.ChronosAssist_WindupTotal = 1.0
  local block = plugin.CONFIG.computeNowBlock(G, chronos, 0)
  check("13.5 an unmapped weapon shows its raw internal name",
        block.name:find("ChronosNeverMapped", 1, true) ~= nil, block.name)
end

do
  -- No windup in progress (fresh fight, nothing selected yet).
  local G, plugin = boot()
  local chronos = G.spawnChronos()
  local block = plugin.CONFIG.computeNowBlock(G, chronos, 0)
  check("13.6 with no windup started, every field is blank and the bar is absent",
        block.name == "" and block.description == "" and block.barFraction == nil)
end

-- =============================================================================
-- 14. NEXT IN COMBO (spec section 4.3, CHRONOS_TEXTPASS.md section 3) --
--     blank outside a combo, deterministic inside one, never guessed.
-- =============================================================================

do
  local G, plugin = boot()
  local chronos = G.spawnChronos({ ActiveWeaponComboIndex = 1 })
  chronos.ChronosAssist_ComboForNow = "ChronosSwingCombo" -- steps: SwingRight, SwingLeft
  local line = plugin.CONFIG.computeComboLine(G, chronos)
  check("14.1 mid-combo names the deterministic next step",
        line == "NEXT IN COMBO   1 of 2 \xe2\x86\x92 Scythe Slash (slow)", line)
end

do
  local G, plugin = boot()
  local chronos = G.spawnChronos({ ActiveWeaponComboIndex = 2 })
  chronos.ChronosAssist_ComboForNow = "ChronosSwingCombo" -- 2 of 2: the FINAL step
  local line = plugin.CONFIG.computeComboLine(G, chronos)
  check("14.2 the combo's final step shows nothing -- there is no next attack to preview",
        line == "", line)
end

do
  local G, plugin = boot()
  local chronos = G.spawnChronos()
  chronos.ChronosAssist_ComboForNow = nil
  local line = plugin.CONFIG.computeComboLine(G, chronos)
  check("14.3 outside a combo the line is blank, not guessed",
        line == "", line)
end

do
  -- A table-type combo step whose WeaponOptions has exactly one candidate is
  -- still deterministic (EnemyAILogic.lua:1290's GetRandomValue over a
  -- one-element list always returns that element).
  local G, plugin = boot()
  G.WeaponData["ChronosComboTableTest"] = {
    Name = "ChronosComboTableTest",
    WeaponCombo = {
      "ChronosSwingRight",
      { WeaponName = "ChronosDash" },
    },
  }
  local chronos = G.spawnChronos({ ActiveWeaponComboIndex = 1 })
  chronos.ChronosAssist_ComboForNow = "ChronosComboTableTest"
  local line = plugin.CONFIG.computeComboLine(G, chronos)
  check("14.4 a singleton-WeaponName table step is still shown by name",
        line:find("Dash Slice", 1, true) ~= nil, line)
end

do
  -- A table-type step with a genuinely random WeaponOptions pool (>1
  -- candidate) must NOT guess a name -- no Chronos combo currently does
  -- this (DESIGN.md / the doc comment above computeComboLine), but the
  -- function is written to check rather than assume, and this proves it.
  local G, plugin = boot()
  G.WeaponData["ChronosComboRandomTest"] = {
    Name = "ChronosComboRandomTest",
    WeaponCombo = {
      "ChronosSwingRight",
      { WeaponOptions = { "ChronosDash", "ChronosRush" } },
    },
  }
  local chronos = G.spawnChronos({ ActiveWeaponComboIndex = 1 })
  chronos.ChronosAssist_ComboForNow = "ChronosComboRandomTest"
  local line = plugin.CONFIG.computeComboLine(G, chronos)
  check("14.5 a genuinely random next step shows the count but no guessed name",
        line == "NEXT IN COMBO   1 of 2", line)
end

-- =============================================================================
-- 15. Shadow duplicates (CHRONOS_TEXTPASS.md section 5)
-- =============================================================================

do
  local G, plugin = boot()
  local chronos = G.spawnChronos()
  local shadow = G.spawnChronos({ Name = "Chronos_EMShadow" })
  shadow.WeaponName = "ChronosScytheThrow"
  local found = plugin.CONFIG.findShadow(G, chronos.ObjectId)
  check("15.1 findShadow locates a live Chronos_EMShadow, excluding the primary",
        found ~= nil and found.ObjectId == shadow.ObjectId)
  local line = plugin.CONFIG.duplicateLine(found)
  check("15.2 the duplicate line uses the marker glyph and the resolved label",
        line == "\xe2\xa7\x89 duplicate \xe2\x80\x94 Scythe Spin Throw", line)
end

do
  local G, plugin = boot()
  local line = plugin.CONFIG.duplicateLine(nil)
  check("15.3 no live shadow: the duplicate line is blank", line == "")
end

-- =============================================================================
-- 16. Rendering lifecycle (spec section 4.1/4.2/4.4) -- imperative side
-- =============================================================================

do
  -- Settings off: test case 11. Nothing at all gets created.
  local G = boot({ Panel = false })
  check("16.1 Panel=false creates zero screen obstacles",
        next(G.obstacles) == nil, tostring(next(G.obstacles)))
end

do
  local G = boot({ Enabled = false })
  check("16.2 Enabled=false also creates zero screen obstacles",
        next(G.obstacles) == nil)
end

do
  -- REGRESSION GUARD. Loading the plugin must reach ZERO engine drawing
  -- calls. on_ready runs inside the game's own Lua init, where
  -- CreateScreenObstacle reaches SpawnScreenObstacle before the engine's
  -- GroupManager exists and kills the process with an
  -- EXCEPTION_ACCESS_VIOLATION -- a native fault, so the pcall around
  -- ensurePanel catches nothing and the mod cannot even log that it failed.
  -- Two launches died exactly here. Panel construction belongs to the
  -- watcher, in gameplay; nothing may move it back.
  local G, plugin = boot()
  check("16.3 Panel=true (default) still creates zero obstacles at load time",
        next(G.obstacles) == nil, tostring(next(G.obstacles)))

  -- boot() already ran on_ready then on_reload once each (the ReLoad mock's
  -- contract) -- both call ensurePanel. Call it an explicit third time,
  -- simulating a later hot reload, and confirm it stays inert.
  plugin.ensurePanel(G)
  check("16.4 ensurePanel is idempotent and still touches no engine API",
        next(G.obstacles) == nil)

  -- The panel arrives with the fight, not before it.
  G.tick(1, plugin.POLL_INTERVAL)
  check("16.3b a poll tick with no Chronos still creates nothing",
        next(G.obstacles) == nil)
  G.spawnChronos()
  G.tick(1, plugin.POLL_INTERVAL)
  local countAfterFight = 0
  for _ in pairs(G.obstacles) do countAfterFight = countAfterFight + 1 end
  check("16.3c the first tick that finds a Chronos builds the panel",
        countAfterFight > 0, tostring(countAfterFight))

  -- And builds it exactly once.
  G.tick(3, plugin.POLL_INTERVAL)
  local countLater = 0
  for _ in pairs(G.obstacles) do countLater = countLater + 1 end
  check("16.3d later ticks create zero new obstacles",
        countLater == countAfterFight, ("%d -> %d"):format(countAfterFight, countLater))
end

do
  -- Visibility: no tracked Chronos alive -> hidden. A live one -> shown.
  -- All four teardown paths in spec section 4.4 reduce to this one check
  -- (DESIGN.md), so this single test stands in for phase change, Chronos
  -- dying, player dying and leaving the room alike -- each of those is, from
  -- the panel's point of view, indistinguishable from "not in ActiveEnemies".
  local G, plugin = boot()
  G.tick(1, plugin.POLL_INTERVAL) -- no Chronos yet
  check("16.5 no fight active: no background anchor exists to be drawn",
        plugin.ScreenAnchors["Background"] == nil)
  check("16.6 no fight active: no text box is written at all",
        #G.modifyCalls == 0, tostring(#G.modifyCalls))

  local chronos = G.spawnChronos()
  G.tick(1, plugin.POLL_INTERVAL)
  local bg = G.obstacles[plugin.ScreenAnchors["Background"]]
  check("16.7 a live Chronos appears: the panel is built and fades in",
        bg ~= nil and bg.Color[4] == plugin.LAYOUT.BACKGROUND_COLOR[4],
        bg and tostring(bg.Color[4]) or "no background")

  G.ActiveEnemies[chronos.ObjectId] = nil -- death, room exit, etc. -- same signal either way
  G.tick(1, plugin.POLL_INTERVAL)
  bg = G.obstacles[plugin.ScreenAnchors["Background"]]
  check("16.8 the tracked Chronos is gone: the panel hides again, with zero new obstacles",
        bg.Color[4] == 0)
end

do
  -- Change detection: a poll tick with nothing new to say must not re-issue
  -- ModifyTextBox for the same content.
  local G, plugin = boot()
  local chronos = G.spawnChronos()
  G.tick(1, plugin.POLL_INTERVAL)
  local before = G.textWriteCount(plugin.ScreenAnchors["HeaderStatus"])
  G.tick(3, plugin.POLL_INTERVAL) -- nothing about the enemy changed
  local after = G.textWriteCount(plugin.ScreenAnchors["HeaderStatus"])
  check("16.9 unchanged content across three more ticks writes nothing new",
        after == before, ("%d -> %d"):format(before, after))

  chronos.CurrentPhase = 2
  G.tick(1, plugin.POLL_INTERVAL)
  local afterChange = G.textWriteCount(plugin.ScreenAnchors["HeaderStatus"])
  check("16.10 a real change (phase advance) does write again",
        afterChange == after + 1, ("%d -> %d"):format(after, afterChange))
end

do
  -- The bar's fraction actually drains across real poll ticks end-to-end,
  -- through SelectWeapon -> the hook's stamping -> the watcher thread ->
  -- CONFIG.computeNowBlock -- not just the pure function in isolation (13.x).
  local G, plugin = boot()
  local chronos = G.spawnChronos({
    WeaponOptions = { "ChronosSwingRight" },  -- PreAttackDuration 1.34
    ForcedPickIndex = 1,
  })
  G.SelectWeapon(chronos)
  G.tick(1, plugin.POLL_INTERVAL)
  local barId = plugin.ScreenAnchors["NowBar"]
  local widthFraction = plugin.LAYOUT.BAR_WIDTH_PX / plugin.LAYOUT.RECT_BASE_WIDTH
  local first = G.obstacles[barId].ScaleX
  check("16.11 right after the windup starts, the bar is at (or near) full width",
        first > widthFraction * 0.9, tostring(first))

  for _ = 1, 10 do G.tick(1, plugin.POLL_INTERVAL) end -- +1.0s of the 1.34s windup
  local later = G.obstacles[barId].ScaleX
  check("16.12 partway through the windup, the bar has visibly drained",
        later < first, ("%s -> %s"):format(tostring(first), tostring(later)))
end

-- =============================================================================
-- 17. Milestones (spec section 5.1, CHRONOS_TEXTPASS.md section 6)
-- =============================================================================

do
  -- Not the last stage of its phase: two lines, NEXT with a confirmed
  -- "what changes", PHASE 2 with no suffix (spec's own examples never
  -- attach one to a non-collapsed PHASE line).
  local G, plugin = boot()
  local chronos = G.spawnChronos({
    AIStageActive = 1, CurrentPhase = 1,
    MaxHealth = 20000, Health = 20000 * 0.90, AIEndHealthThreshold = 0.75,
  })
  local lines = plugin.CONFIG.milestoneLines(chronos)
  check("17.1 two lines when not at the phase's last stage",
        #lines == 2, tostring(#lines))
  check("17.2 NEXT line: percent and the confirmed what-changes text",
        lines[1] == "NEXT   15% away \xe2\x80\x94 6 satyrs", lines[1])
  -- Phase 1's LAST stage ends at 0% health, so at 90% health the distance to
  -- the phase boundary is 90 percentage points, not 100 -- research's own
  -- "100% away" mockup is for a fight that JUST started at full health.
  check("17.3 PHASE line: percent only, no suffix",
        lines[2] == "PHASE 2   90% away", lines[2])
end

do
  -- Last stage of phase 1 (stage 4): collapses to one line, using the
  -- CONFIRMED what-changes text for that exact transition (research 18
  -- state 7).
  local G, plugin = boot()
  local chronos = G.spawnChronos({
    AIStageActive = 4, CurrentPhase = 1,
    MaxHealth = 20000, Health = 20000 * 0.06, AIEndHealthThreshold = 0.00,
  })
  local lines = plugin.CONFIG.milestoneLines(chronos)
  check("17.4 collapses to one line at a phase boundary",
        #lines == 1, tostring(#lines))
  check("17.5 the collapsed line uses PHASE 2 and the confirmed suffix",
        lines[1] == "PHASE 2   6% away \xe2\x80\x94 new arena, Time Burst and Clock Burst", lines[1])
end

do
  -- Last stage of phase 2 (stage 6): ALSO a phase boundary, but with no
  -- confirmed what-changes text (DESIGN.md) -- must show no suffix at all,
  -- not a guessed one.
  local G, plugin = boot()
  local chronos = G.spawnChronos({
    AIStageActive = 6, CurrentPhase = 2,
    MaxHealth = 16000, Health = 16000 * 0.10, AIEndHealthThreshold = 0.00,
  })
  local lines = plugin.CONFIG.milestoneLines(chronos)
  check("17.6 the unconfirmed phase-2-to-3 boundary has no guessed suffix",
        lines[1] == "PHASE 3   10% away", lines[1])
end

do
  -- Last stage overall (stage 8, phase 3): the label is FINAL, not "PHASE 4".
  local G, plugin = boot()
  local chronos = G.spawnChronos({
    AIStageActive = 8, CurrentPhase = 3,
    MaxHealth = 26000, Health = 26000 * 0.20, AIEndHealthThreshold = 0.00,
  })
  local lines = plugin.CONFIG.milestoneLines(chronos)
  check("17.7 the fight's final stage uses the FINAL label, never PHASE 4",
        lines[1] == "FINAL   20% away", lines[1])
end

-- =============================================================================
-- 18. Status lines (spec section 5.3, CHRONOS_TEXTPASS.md section 7)
-- =============================================================================

do
  local G, plugin = boot()
  local chronos = G.spawnChronos({ HitShields = 4 })
  local lines = plugin.CONFIG.statusLines(G, chronos)
  check("18.1 shields present: the exact textpass line, with the live count",
        lines[1] == "\xe2\x96\xa3 Shielded \xc3\x974 \xe2\x80\x94 break the banners", lines[1])
end

do
  local G, plugin = boot()
  local chronos = G.spawnChronos()
  G.spawnTempus(3)
  local lines = plugin.CONFIG.statusLines(G, chronos)
  check("18.2 tempus present: the exact textpass line",
        lines[1] == "\xe2\x9f\xb2 Tempus healing \xe2\x80\x94 kill the adds", lines[1])
end

do
  local G, plugin = boot()
  local chronos = G.spawnChronos()
  local lines = plugin.CONFIG.statusLines(G, chronos)
  check("18.3 neither condition holds: no lines at all",
        #lines == 0, tostring(#lines))
end

-- =============================================================================
-- 19. The UNAVAILABLE grid (spec section 5.2, CHRONOS_TEXTPASS.md section 8)
-- =============================================================================

do
  local G, plugin = boot()
  local chronos = G.spawnChronos({
    WeaponHistory = { "ChronosBannerSummon" }, -- used once, then 24 other attacks since
  })
  -- Appended AFTER, not before: NumAttacksSinceWeapon scans from the END
  -- backward, so these are what makes "since" count up from the use.
  for _ = 1, 24 do table.insert(chronos.WeaponHistory, "ChronosSwingRight") end
  local reason = plugin.CONFIG.gridReason(G, chronos, G.WeaponData["ChronosBannerSummon"])
  check("19.1 MinAttacksBetweenUse: \"in N attacks\" with the correct remaining count",
        reason == "in 1 attacks", reason)
end

do
  local G, plugin = boot()
  local chronos = G.spawnChronos({ DistanceToPlayerFake = 5000 }) -- far outside ChronosGrind's 275
  local reason = plugin.CONFIG.gridReason(G, chronos, G.WeaponData["ChronosGrind"])
  check("19.2 MinPlayerDistance blocks when the player IS within it -- \"only when you're farther\"",
        reason == nil, tostring(reason)) -- far away: NOT blocked by this gate
end

do
  local G, plugin = boot()
  local chronos = G.spawnChronos({ DistanceToPlayerFake = 100 }) -- inside 275
  local reason = plugin.CONFIG.gridReason(G, chronos, G.WeaponData["ChronosGrind"])
  check("19.3 close range: the direction is right -- \"only when you're farther\", never \"closer\"",
        reason == "only when you're farther", reason)
end

do
  -- MaxUses, in isolation.
  local G, plugin = boot()
  local chronos = G.spawnChronos({
    WeaponHistory = { "ChronosMaxUsesTest", "ChronosMaxUsesTest" },
  })
  local reason = plugin.CONFIG.gridReason(G, chronos, G.WeaponData["ChronosMaxUsesTest"])
  check("19.4 MaxUses: \"N of M uses left\", remaining not used",
        reason == "0 of 2 uses left", reason)
end

do
  -- MaxUses must NOT genus-collapse, unlike MinAttacksBetweenUse.
  local G, plugin = boot()
  local chronos = G.spawnChronos({
    WeaponHistory = { "ChronosGenusMaxUsesA", "ChronosGenusMaxUsesA" },
  })
  local reason = plugin.CONFIG.gridReason(G, chronos, G.WeaponData["ChronosGenusMaxUsesB"])
  check("19.5 MaxUses does not collapse by genus -- B's own history is untouched by A's uses",
        reason == nil, tostring(reason))
end

do
  local G, plugin = boot()
  local reason = plugin.CONFIG.gridReason(G, G.spawnChronos(), G.WeaponData["ChronosRush"])
  check("19.6 UnitLoSDistanceTowardPlayer: \"no line of sight\" (ChronosRush carries this gate)",
        reason == "no line of sight", tostring(reason))
end

do
  -- A gate CHRONOS_TEXTPASS.md section 8 does not cover falls back visibly
  -- rather than vanishing from the grid or guessing wording.
  local G, plugin = boot()
  local reason = plugin.CONFIG.gridReason(G, G.spawnChronos(), G.WeaponData["ChronosUnknownGateTest"])
  check("19.7 an uncovered gate returns nil from gridReason (caller supplies the fallback)",
        reason == nil)
end

do
  -- End-to-end: gridRows only lists BLOCKED weapons, with resolved labels,
  -- and applies the uncovered-gate fallback text.
  local G, plugin = boot()
  local realEligible = G.IsEnemyWeaponEligible
  G.IsEnemyWeaponEligible = function(enemy, weaponData)
    if weaponData ~= nil and weaponData.Name == "ChronosUnknownGateTest" then return false end
    return realEligible(enemy, weaponData)
  end
  local chronos = G.spawnChronos({
    WeaponOptions = { "ChronosSwingRight", "ChronosGrind", "ChronosUnknownGateTest" },
    DistanceToPlayerFake = 100, -- blocks ChronosGrind
  })
  local rows = plugin.CONFIG.gridRows(G, chronos)
  check("19.8 ready attacks (ChronosSwingRight) are not listed",
        #rows == 2, tostring(#rows))
  local joined = table.concat(rows, " | ")
  check("19.9 ChronosGrind's row uses its resolved label and the right direction",
        joined:find("Vortex Pull    only when you're farther", 1, true) ~= nil, joined)
  check("19.10 the uncovered-gate weapon shows the visible fallback, not silence",
        joined:find("blocked (MaxConsecutiveUses)", 1, true) ~= nil, joined)
  G.IsEnemyWeaponEligible = realEligible
end

-- =============================================================================
-- 20. Rendering lifecycle -- stage 3's multi-line anchors
-- =============================================================================

do
  local G, plugin = boot()
  local chronos = G.spawnChronos({
    Health = 20000 * 0.90, MaxHealth = 20000, AIEndHealthThreshold = 0.75,
    AIStageActive = 1, CurrentPhase = 1,
    WeaponOptions = { "ChronosGrind" }, DistanceToPlayerFake = 100,
  })
  G.tick(1, plugin.POLL_INTERVAL)

  local milestoneBox = G.textBoxes[plugin.ScreenAnchors["Milestone"]]
  check("20.1 the milestone anchor's rendered text has two lines",
        milestoneBox.Text:find("\n", 1, true) ~= nil, milestoneBox.Text)

  local gridBox = G.textBoxes[plugin.ScreenAnchors["Grid"]]
  check("20.2 the grid anchor starts with the UNAVAILABLE header",
        gridBox.Text:sub(1, #"UNAVAILABLE") == "UNAVAILABLE", gridBox.Text)
  check("20.3 the grid anchor lists the blocked weapon below the header",
        gridBox.Text:find("Vortex Pull", 1, true) ~= nil, gridBox.Text)

  -- Change detection applies to multi-line anchors too.
  local before = G.textWriteCount(plugin.ScreenAnchors["Grid"])
  G.tick(3, plugin.POLL_INTERVAL)
  local after = G.textWriteCount(plugin.ScreenAnchors["Grid"])
  check("20.4 an unchanged grid across three more ticks writes nothing new",
        after == before, ("%d -> %d"):format(before, after))
end

-- =============================================================================
-- Summary

-- =============================================================================
-- 21. Stage 4 -- the safe/unsafe indicator for the two insta-kills.
--
-- Geometry from Enemy_BiomeI_Projectiles.sjson, recorded in
-- CHRONOS_RESEARCH.md section 10.0. Clock Burst is safe in the 400..700 band
-- around Chronos; Time Burst is safe within 150 of the ClockFacePoint the game
-- chose. Both ellipses: ScaleX 1.175, ScaleY 0.6.
-- =============================================================================
do
  local G, plugin = boot()
  local C = plugin.CONFIG

  -- Pure geometry first. A raw distance would pass these by accident, so each
  -- uses an offset where the squash changes the answer.
  local d = C.normalisedDistance(0, 0, 1.175 * 500, 0)
  check("21.1 X offset is divided by 1.175", math.abs(d - 500) < 0.01, tostring(d))
  d = C.normalisedDistance(0, 0, 0, 0.6 * 500)
  check("21.2 Y offset is divided by 0.6", math.abs(d - 500) < 0.01, tostring(d))

  check("21.3 Clock Burst: inside the inner circle is NOT safe",
        C.isSafeFrom("CLOCK_BURST", 399) == false, "399")
  check("21.4 Clock Burst: in the band is safe",
        C.isSafeFrom("CLOCK_BURST", 550) == true, "550")
  check("21.5 Clock Burst: outside the band is NOT safe",
        C.isSafeFrom("CLOCK_BURST", 701) == false, "701")
  check("21.6 Time Burst: inside 150 is safe",
        C.isSafeFrom("TIME_BURST", 149) == true, "149")
  check("21.7 Time Burst: outside 150 is NOT safe",
        C.isSafeFrom("TIME_BURST", 151) == false, "151")

  -- The rules are opposite. Standing on Chronos survives one and kills you in
  -- the other; this is the whole reason the feature exists.
  check("21.8 the two rules disagree at the same distance",
        C.isSafeFrom("CLOCK_BURST", 100) == false and C.isSafeFrom("TIME_BURST", 100) == true,
        "100")

  check("21.9 an unknown distance is nil, never a guess",
        C.isSafeFrom("CLOCK_BURST", nil) == nil, "nil")
  check("21.10 an unknown attack kind is nil",
        C.isSafeFrom("SOMETHING_ELSE", 500) == nil, "nil")
end

do
  local G, plugin = boot()
  local C = plugin.CONFIG
  local chronos = { Name = "Chronos", ObjectId = 10, WeaponName = "ChronosRadial2" }
  G.CurrentRun.Hero = { ObjectId = 1 }
  G.locations[10] = { X = 0, Y = 0 }

  -- 550 normalised: inside the band.
  G.locations[1] = { X = 1.175 * 550, Y = 0 }
  local st = C.safeZoneState(G, chronos)
  check("21.11 Clock Burst in the band reports safe", st ~= nil and st.safe == true, tostring(st and st.safe))
  check("21.12 and its instruction is the fixed textpass string",
        st.instruction == "move toward center ring", st.instruction)

  G.locations[1] = { X = 1.175 * 200, Y = 0 }
  st = C.safeZoneState(G, chronos)
  check("21.13 Clock Burst inside the inner circle reports unsafe", st.safe == false, tostring(st.safe))

  chronos.WeaponName = "ChronosScytheThrow"
  check("21.14 an ordinary attack produces no indicator",
        C.safeZoneState(G, chronos) == nil, "nil")
end

do
  -- Time Burst measures from the ClockFacePoint the GAME chose, captured out
  -- of GetTargetId rather than guessed.
  local G, plugin = boot()
  local C = plugin.CONFIG
  local chronos = { Name = "Chronos", ObjectId = 10, WeaponName = "ChronosRadial3" }
  G.CurrentRun.Hero = { ObjectId = 1 }
  G.locations[10] = { X = 0, Y = 0 }
  G.locations[77] = { X = 3000, Y = 3000 }

  G.nextTargetId = 77
  G.GetTargetId(chronos, { TargetFromGroup = "ClockFacePoints" })
  check("21.15 the chosen ClockFacePoint is captured",
        chronos.ChronosAssist_BurstTargetId == 77, tostring(chronos.ChronosAssist_BurstTargetId))

  G.locations[1] = { X = 3000 + 1.175 * 100, Y = 3000 }
  local st = C.safeZoneState(G, chronos)
  check("21.16 near the lit numeral is safe -- not near Chronos", st.safe == true, tostring(st.safe))

  G.locations[1] = { X = 0, Y = 0 }   -- standing ON Chronos
  st = C.safeZoneState(G, chronos)
  check("21.17 standing on Chronos during Time Burst is UNSAFE", st.safe == false, tostring(st.safe))

  chronos.ChronosAssist_BurstTargetId = nil
  st = C.safeZoneState(G, chronos)
  check("21.18 no captured target: safe is nil, never a guess", st.safe == nil, tostring(st.safe))
  check("21.19 and the instruction still shows",
        st.instruction == "run to the lit clock numeral", st.instruction)
end

do
  local G, plugin = boot({ GroundMarker = false })
  local C = plugin.CONFIG
  local chronos = { Name = "Chronos", ObjectId = 10, WeaponName = "ChronosRadial2" }
  G.CurrentRun.Hero = { ObjectId = 1 }
  G.locations[10] = { X = 0, Y = 0 }
  G.locations[1] = { X = 0, Y = 0 }
  check("21.20 GroundMarker off produces no indicator at all",
        C.safeZoneState(G, chronos) == nil, "nil")
end

do
  local G, plugin = boot()
  local C = plugin.CONFIG
  local chronos = { Name = "Chronos", ObjectId = 10, WeaponName = "ChronosRadial3_EM" }
  G.CurrentRun.Hero = { ObjectId = 1 }
  local st = C.safeZoneState(G, chronos)
  check("21.21 the Rivals Time Burst warns about the two big bubbles",
        st ~= nil and st.bubbles == true, tostring(st and st.bubbles))
end

-- =============================================================================

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then
  print("\nFAILURES:")
  for _, f in ipairs(failures) do print("  " .. f) end
  os.exit(1)
end
