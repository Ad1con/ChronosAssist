-- Fake game globals for ChronosAssist stages 1-2. Stage 1: a faithful-enough
-- SelectWeapon (including its recursion) and a SCOPED reproduction of
-- IsEnemyWeaponEligible -- see DESIGN.md "What the test harness does and does
-- not reproduce" for exactly what that does and does not cover, and why a
-- fuller copy is stage 3's job rather than this one's. Stage 2 adds the
-- screen-rendering fakes and a cooperative thread scheduler, RealHecate-style,
-- so the panel's poll loop can be driven deterministically instead of
-- sleeping.

local unpack = table.unpack or unpack

local G = {}

-- ---------------------------------------------------------------- state ----

G.ActiveEnemies = {}
G.CurrentRun = { Hero = { ObjectId = 1, Health = 100, MaxHealth = 100 } }

-- A fake clock the suite advances explicitly, rather than reading os.clock().
-- Deterministic and matches GetTime({})'s real signature (Main.lua:2/448).
G.FakeTime = 0
function G.GetTime(_)
  return G.FakeTime
end
function G.advanceTime(seconds)
  G.FakeTime = G.FakeTime + seconds
end

G.Color = { White = "White", Black = "Black", Gray = "Gray" }

-- Real field paths, verified against WeaponData_Chronos.lua:
--   AIData.PreAttackDuration, AIData.AttackDistance  -- always under AIData
--   Requirements.MinAttacksBetweenUse, .MinPlayerDistance, etc. -- a SEPARATE
--   table from AIData when gating fields are present (ChronosGrind:1666-1674)
G.WeaponData = {
  ChronosSwingRight = {
    Name = "ChronosSwingRight",
    AIData = { PreAttackDuration = 1.34, AttackDistance = 500 },
  },
  -- research section 15.4 / CHRONOS_TRAINER_SPEC.md section 5.2: MinPlayerDistance
  -- blocks when the player IS within it -- the direction an early draft had
  -- backwards. Fixture exists specifically to exercise that.
  ChronosGrind = {
    Name = "ChronosGrind",
    AIData = { PreAttackDuration = 0.53, AttackDistance = 600 },
    Requirements = { MinAttacksBetweenUse = 12, MinPlayerDistance = 275 },
  },
  ChronosBannerSummon = {
    Name = "ChronosBannerSummon",
    AIData = { PreAttackDuration = 1.40, AttackDistance = 150 },
    Requirements = { MinAttacksBetweenUse = 25, RequireTotalAttacks = 5, MaxUses = 2 },
  },
  -- Plain, ungrouped weapon -- no GenusName, no relation to any other entry.
  -- ChronosRush and ChronosRush_P3 were originally used here as a "shares a
  -- cooldown via GenusName" example, on research section 12.1's word; that
  -- claim was WRONG (corrected 2026-09-05) -- WeaponData_Chronos.lua has only
  -- three GenusName occurrences total, and neither Rush weapon has one. See
  -- CHRONOS_RESEARCH.md section 12.1 and DESIGN.md. The real example,
  -- ChronosCastOrbit/ChronosCastOrbit2, is below.
  -- UnitLoSDistanceTowardPlayer = 1100 is the REAL value on the real
  -- ChronosRush (WeaponData_Chronos.lua:968), included here for the grid's
  -- "no line of sight" row.
  ChronosRush = {
    Name = "ChronosRush",
    AIData = { PreAttackDuration = 1.17, AttackDistance = 850 },
    Requirements = { MinAttacksBetweenUse = 6, UnitLoSDistanceTowardPlayer = 1100 },
  },
  -- GenusName collapse, VERIFIED (WeaponData_Chronos.lua:2665-2667,
  -- :2738-2741): ChronosCastOrbit and ChronosCastOrbit2 both resolve to genus
  -- "ChronosCastOrbit" and must read as one cooldown, not two.
  ChronosCastOrbit = {
    Name = "ChronosCastOrbit",
    GenusName = "ChronosCastOrbit",
    AIData = { PreAttackDuration = 0.83, AttackDistance = 150 },
    Requirements = { MinAttacksBetweenUse = 6 },
  },
  ChronosCastOrbit2 = {
    Name = "ChronosCastOrbit2",
    GenusName = "ChronosCastOrbit",
    AIData = { PreAttackDuration = 0.83, AttackDistance = 150 },
    Requirements = { MinAttacksBetweenUse = 6 },
  },
  -- research section 10: the two insta-kills can never follow each other.
  ChronosRadial2 = {
    Name = "ChronosRadial2",
    AIData = { PreAttackDuration = 3.77 },
    Requirements = { PreviousWeaponNot = { "ChronosRadial3" } },
  },
  ChronosRadial3 = {
    Name = "ChronosRadial3",
    AIData = { PreAttackDuration = 3.77 },
    Requirements = { PreviousWeaponNot = { "ChronosRadial2" } },
  },
  -- A combo, for the combo/comboIdx fields. Shape mirrors WeaponCombo entries
  -- being plain weapon-name strings (EnemyAILogic.lua:1297).
  ChronosSwingCombo = {
    Name = "ChronosSwingCombo",
    AIData = { PreAttackDuration = 0.1 },
    WeaponCombo = { "ChronosSwingRight", "ChronosSwingLeft" },
  },
  ChronosSwingLeft = {
    Name = "ChronosSwingLeft",
    AIData = { PreAttackDuration = 1.96, AttackDistance = 500 },
  },
  -- ChainChance recursion (EnemyAILogic.lua:1250-1254) -- the re-entrancy
  -- hazard DESIGN.md documents. ChainChance sits top-level on the weapon, not
  -- under AIData or Requirements, matching the real field.
  -- Stage 3 grid fixtures: MaxUses in isolation (no other gate to interfere),
  -- and a genus pair to prove MaxUses does NOT collapse like
  -- MinAttacksBetweenUse does (EnemyAILogic.lua:1442-1453 compares
  -- prevWeapon == weaponData.Name directly, no GenusName fallback).
  ChronosMaxUsesTest = {
    Name = "ChronosMaxUsesTest",
    AIData = { PreAttackDuration = 0.5 },
    Requirements = { MaxUses = 2 },
  },
  ChronosGenusMaxUsesA = {
    Name = "ChronosGenusMaxUsesA",
    GenusName = "ChronosGenusMaxUses",
    AIData = { PreAttackDuration = 0.5 },
    Requirements = { MaxUses = 2 },
  },
  ChronosGenusMaxUsesB = {
    Name = "ChronosGenusMaxUsesB",
    GenusName = "ChronosGenusMaxUses",
    AIData = { PreAttackDuration = 0.5 },
    Requirements = { MaxUses = 2 },
  },
  -- An unrecognized gate (research section 4.2 lists MaxConsecutiveUses as
  -- real and used, but CHRONOS_TEXTPASS.md section 8 has no row text for it)
  -- -- exercises the fallback path.
  ChronosUnknownGateTest = {
    Name = "ChronosUnknownGateTest",
    AIData = { PreAttackDuration = 0.5 },
    Requirements = { MaxConsecutiveUses = 1 },
  },
  ChronosChainTest = {
    Name = "ChronosChainTest",
    AIData = { PreAttackDuration = 0.5 },
    ChainChance = 0.5,
  },
}

-- Recorders the suite asserts on.
G.logs = {}
G.wrapped = {}

-- ------------------------------------------------------------- threading ----
-- The game runs these as coroutines and resumes them on its own clock. Here
-- the suite is the clock, exactly RealHecate's harness pattern: thread()
-- starts the body immediately (matching the game, which runs a threaded
-- function up to its first wait), and tick() advances every suspended one.

G.threads = {}
G.threadErrors = {}

-- The real thread() reaches SessionMapState (Main.lua:189), which does not
-- exist until a session is under way. Starting the watcher at load therefore
-- raised here and the panel silently never appeared -- twice, through two
-- playtests, because the error is catchable and the mod logged on happily.
-- The mock had no such dependency, so it could not have caught either one.
-- A session exists once a room has enemies in it; spawnChronos sets the flag.
function G.thread(fn, ...)
  if G.SessionMapState == nil then
    error("attempt to index global 'SessionMapState' (a nil value)", 0)
  end
  local args = { ... }
  local co = coroutine.create(function() fn(unpack(args)) end)
  G.threads[#G.threads + 1] = { co = co }
  local ok, err = coroutine.resume(co)
  if not ok then G.threadErrors[#G.threadErrors + 1] = tostring(err) end
  return co
end

function G.wait(seconds)
  coroutine.yield(seconds)
end

-- Resumes every suspended thread once per tick, advancing the fake clock by
-- POLL_INTERVAL first so a poll loop reading GetTime sees consistent progress.
function G.tick(count, secondsPerTick)
  local resumed = 0
  for _ = 1, (count or 1) do
    G.advanceTime(secondsPerTick or 0)
    for _, t in ipairs(G.threads) do
      if coroutine.status(t.co) == "suspended" then
        resumed = resumed + 1
        local ok, err = coroutine.resume(t.co)
        if not ok then G.threadErrors[#G.threadErrors + 1] = tostring(err) end
      end
    end
  end
  return resumed
end

function G.liveThreadCount()
  local n = 0
  for _, t in ipairs(G.threads) do
    if coroutine.status(t.co) == "suspended" then n = n + 1 end
  end
  return n
end

-- ------------------------------------------------------------ rendering ----
-- CreateScreenObstacle returns a raw Id directly (verified against
-- JowdayDPS.Main.lua:540, 566: `ScreenAnchors[x] = game.CreateScreenObstacle(...)`
-- used straight as an Id afterwards) -- unlike CreateScreenComponent, which
-- the spec explicitly says NOT to use here and which returns a {Id=...} table.

local nextObstacleId = 800000
G.obstacles = {}       -- id -> { Name = ... }, created exactly once each
G.textBoxes = {}        -- id -> last CreateTextBox args
G.modifyCalls = {}      -- every ModifyTextBox call, in order
G.scaleXCalls = {}
G.scaleYCalls = {}
G.colorCalls = {}

function G.CreateScreenObstacle(args)
  nextObstacleId = nextObstacleId + 1
  G.obstacles[nextObstacleId] = { Name = args.Name, X = args.X, Y = args.Y }
  return nextObstacleId
end

function G.CreateTextBox(args)
  G.textBoxes[args.Id] = args
end

function G.ModifyTextBox(args)
  G.modifyCalls[#G.modifyCalls + 1] = args
  local box = G.textBoxes[args.Id]
  if box ~= nil then
    if args.Text ~= nil then box.Text = args.Text end
    if args.RawText ~= nil then
      if args.Append then
        box.Text = (box.Text or "") .. "\n" .. args.RawText
      else
        box.Text = args.RawText
      end
    end
    if args.FadeTarget ~= nil then box.FadeTarget = args.FadeTarget end
  end
end

function G.SetScaleX(args)
  G.scaleXCalls[#G.scaleXCalls + 1] = args
  if G.obstacles[args.Id] ~= nil then G.obstacles[args.Id].ScaleX = args.Fraction end
end

function G.SetScaleY(args)
  G.scaleYCalls[#G.scaleYCalls + 1] = args
  if G.obstacles[args.Id] ~= nil then G.obstacles[args.Id].ScaleY = args.Fraction end
end

function G.SetColor(args)
  G.colorCalls[#G.colorCalls + 1] = args
  if G.obstacles[args.Id] ~= nil then G.obstacles[args.Id].Color = args.Color end
end

-- How many times ModifyTextBox was called for a given anchor id with a Text
-- or RawText payload (i.e. a real content write, not just a fade). Used to
-- assert change-detection actually skips no-op ticks.
function G.textWriteCount(id)
  local n = 0
  for _, call in ipairs(G.modifyCalls) do
    if call.Id == id and (call.Text ~= nil or call.RawText ~= nil) then n = n + 1 end
  end
  return n
end

-- --------------------------------------------------------------- ModUtil ----

G.ModUtil = {
  Path = {
    Wrap = function(name, wrapper)
      local base = G[name]
      if base == nil then
        error("ModUtil.Path.Wrap called on a global the harness does not define: " .. tostring(name))
      end
      G.wrapped[name] = (G.wrapped[name] or 0) + 1
      G[name] = function(...) return wrapper(base, ...) end
    end,
  },
}

-- ------------------------------------------------------------ stage 4 ----

-- Object positions. Tests set G.locations[id] = { X = , Y = }.
G.locations = {}
function G.GetLocation(args)
  return G.locations[args and args.Id] or { X = 0, Y = 0 }
end

-- Real signature from EnemyAILogic.lua:5372. The harness returns whatever a
-- test parks in G.nextTargetId, which stands in for the game's own choice from
-- the ClockFacePoints group.
G.nextTargetId = nil
function G.GetTargetId(enemy, aiData)
  if aiData ~= nil and aiData.TargetFromGroup ~= nil then
    return G.nextTargetId
  end
  return enemy and enemy.TargetId or nil
end

-- --------------------------------------------------------- eligibility ----

-- Copied from EnemyAILogic.lua:5865, translated to G.WeaponData. See its
-- GenusName collapse: ChronosRush and ChronosRush_P3 share a cooldown reading
-- because both resolve to genus "ChronosRush".
function G.NumAttacksSinceWeapon(enemy, weaponName)
  if weaponName == nil or enemy == nil or enemy.WeaponHistory == nil then
    return -1
  end
  if G.WeaponData[weaponName] and G.WeaponData[weaponName].GenusName ~= nil then
    weaponName = G.WeaponData[weaponName].GenusName
  end
  local numAttacks = 0
  for i = #enemy.WeaponHistory, 1, -1 do
    local prevWeapon = enemy.WeaponHistory[i]
    local skipWeapon = false
    if G.WeaponData[prevWeapon] ~= nil then
      if G.WeaponData[prevWeapon].SkipWeaponCount then
        skipWeapon = true
      end
      if G.WeaponData[prevWeapon].GenusName ~= nil then
        prevWeapon = G.WeaponData[prevWeapon].GenusName
      end
    end
    if prevWeapon == weaponName then
      return numAttacks
    end
    if not skipWeapon then
      numAttacks = numAttacks + 1
    end
  end
  return -1
end

function G.IsWithinDistance(args)
  local enemy = G.ActiveEnemies[args.Id]
  local d = (enemy and enemy.DistanceToPlayerFake) or 0
  return d <= args.Distance
end

-- A SCOPED reproduction of EnemyAILogic.lua:1370-1520 -- see DESIGN.md for
-- exactly why this does not cover the whole function and why that is the
-- right call for stage 1's suite.
function G.IsEnemyWeaponEligible(enemy, weaponData)
  if weaponData == nil then return true end
  local requirements = weaponData.Requirements or weaponData.AIData
  if requirements == nil then return true end

  if requirements.MinAttacksBetweenUse ~= nil then
    local since = G.NumAttacksSinceWeapon(enemy, weaponData.Name)
    if since >= 0 and since < requirements.MinAttacksBetweenUse then return false end
  end

  if requirements.RequireTotalAttacks ~= nil
      and (enemy.WeaponHistory == nil or #enemy.WeaponHistory <= requirements.RequireTotalAttacks) then
    return false
  end

  if requirements.PreviousWeaponNot ~= nil and enemy.WeaponHistory ~= nil then
    local prev = enemy.WeaponHistory[#enemy.WeaponHistory]
    for _, banned in ipairs(requirements.PreviousWeaponNot) do
      if prev == banned then return false end
    end
  end

  if requirements.MaxUses ~= nil and enemy.WeaponHistory ~= nil then
    local uses = 0
    for _, w in ipairs(enemy.WeaponHistory) do
      if w == weaponData.Name then uses = uses + 1 end
    end
    if uses >= requirements.MaxUses then return false end
  end

  -- EnemyAILogic.lua:1510-1520, the direction CHRONOS_TRAINER_SPEC.md section
  -- 5.2 warns an early draft had backwards.
  if requirements.MaxPlayerDistance ~= nil then
    if not G.IsWithinDistance({ Id = enemy.ObjectId, Distance = requirements.MaxPlayerDistance }) then
      return false
    end
  end

  if requirements.MinPlayerDistance ~= nil then
    if G.IsWithinDistance({ Id = enemy.ObjectId, Distance = requirements.MinPlayerDistance }) then
      return false
    end
  end

  return true
end

-- --------------------------------------------------------- SelectWeapon ----

-- A simplified translation of EnemyAILogic.lua:1232, keeping only what the
-- suite needs: ChainChance recursion (:1250-1254, the re-entrancy hazard
-- DESIGN.md documents) and a combo walk (:1268-1303), both filtered through
-- the eligibility fake above. The self-call on the next line goes through
-- G.SelectWeapon (a fresh table lookup), exactly mirroring how the real
-- function's bare `SelectWeapon(enemy)` resolves through whatever the CURRENT
-- global is -- which is what lets ModUtil.Path.Wrap observe the recursion.
local function fakeSelectWeaponImpl(enemy)
  if enemy.ChainedWeapon ~= nil then
    local chained = enemy.ChainedWeapon
    local data = G.WeaponData[chained]
    if data ~= nil and data.ChainChance ~= nil and not G.RandomChance(data.ChainChance) then
      enemy.ChainedWeapon = nil
      return G.SelectWeapon(enemy)
    end
    enemy.WeaponName = chained
    enemy.ChainedWeapon = nil
    enemy.WeaponHistory = enemy.WeaponHistory or {}
    table.insert(enemy.WeaponHistory, chained)
    return chained
  end

  if enemy.ActiveWeaponCombo ~= nil then
    enemy.ActiveWeaponComboIndex = enemy.ActiveWeaponComboIndex + 1
    local combo = G.WeaponData[enemy.ActiveWeaponCombo].WeaponCombo
    local pick = combo[enemy.ActiveWeaponComboIndex]
    enemy.WeaponName = pick
    if enemy.ActiveWeaponComboIndex >= #combo then
      enemy.ActiveWeaponCombo = nil
    end
    enemy.WeaponHistory = enemy.WeaponHistory or {}
    table.insert(enemy.WeaponHistory, pick)
    return pick
  end

  local eligible = {}
  for _, name in ipairs(enemy.WeaponOptions or {}) do
    if G.IsEnemyWeaponEligible(enemy, G.WeaponData[name]) then
      eligible[#eligible + 1] = name
    end
  end
  local pick = eligible[enemy.ForcedPickIndex or 1] or eligible[1]
  enemy.WeaponName = pick
  enemy.WeaponHistory = enemy.WeaponHistory or {}
  if pick ~= nil then table.insert(enemy.WeaponHistory, pick) end
  return pick
end
G.SelectWeapon = fakeSelectWeaponImpl

-- Scripted per test: a queue of true/false results, consumed in order, so a
-- ChainChance failure-then-success sequence is exact rather than random.
G.RandomChanceQueue = {}
function G.RandomChance(_)
  local next_ = table.remove(G.RandomChanceQueue, 1)
  if next_ == nil then return true end
  return next_
end

-- ---------------------------------------------------------------- helpers ----

local nextObjectId = 900000
local function nextId()
  nextObjectId = nextObjectId + 1
  return nextObjectId
end

-- The REAL AIStages shape, copied field-for-field from
-- EnemyData_Chronos.lua:344-622 (TransitionFunction and AIEndHealthThreshold
-- only -- the rest of each entry's real content is irrelevant to what this
-- mod reads). Eight entries, split 4/2/2 across phases -- a
-- ChronosPhaseTransition entry is the FIRST stage of the phase it starts
-- (CONFIG.phaseStageCounts's own comment traces exactly why), matching
-- CHRONOS_TEXTPASS.md section 1's "stage <N> of 4"/"of 2"/"of 2".
-- AIEndHealthThreshold is nested under .AIData on every real entry
-- (EnemyData_Chronos.lua:351, :380, :427, ...) -- NOT top-level. An earlier
-- version of this fixture had it top-level, which cost nothing while only
-- phaseStageCounts (TransitionFunction only) read this table, but silently
-- broke CONFIG.phaseEndThreshold once stage 3 needed the threshold itself.
local function fakeAIStages()
  return {
    { AIData = { AIEndHealthThreshold = 0.75 } },                                                    -- 1: Phase 1
    { AIData = { AIEndHealthThreshold = 0.50 }, TransitionFunction = "ChronosMinorStageTransition" }, -- 2: 1.25
    { AIData = { AIEndHealthThreshold = 0.25 }, TransitionFunction = "ChronosMinorStageTransition" }, -- 3: 1.5 (combos join)
    { AIData = { AIEndHealthThreshold = 0.00 }, TransitionFunction = "ChronosMinorStageTransition" }, -- 4: 1.75
    { AIData = { AIEndHealthThreshold = 0.50 }, TransitionFunction = "ChronosPhaseTransition" },      -- 5: Phase 2 (both insta-kills join here)
    { AIData = { AIEndHealthThreshold = 0.00 }, TransitionFunction = "ChronosMinorStageTransition" }, -- 6: 2.5
    { AIData = { AIEndHealthThreshold = 0.50 }, TransitionFunction = "ChronosPhaseTransition" },      -- 7: Phase 3, Rivals only
    { AIData = { AIEndHealthThreshold = 0.00 }, TransitionFunction = "ChronosMinorStageTransition" }, -- 8: 3.5
  }
end

-- Spawns a tracked (or, for scoping tests, deliberately untracked) Chronos
-- unit with the live fields main.lua reads.
function G.spawnChronos(overrides)
  -- An enemy in a room means a session exists, which is what thread() needs.
  G.SessionMapState = G.SessionMapState or {}
  local id = nextId()
  local enemy = {
    ObjectId = id,
    Name = "Chronos",
    Health = 20000,
    MaxHealth = 20000,
    CurrentPhase = 1,
    AIStageActive = 1,
    AIStages = fakeAIStages(),
    WeaponOptions = { "ChronosSwingRight", "ChronosGrind", "ChronosBannerSummon" },
    WeaponHistory = {},
    HitShields = 0,
    DistanceToPlayerFake = 1000,
  }
  for k, v in pairs(overrides or {}) do enemy[k] = v end
  G.ActiveEnemies[id] = enemy
  return enemy
end

function G.spawnTempus(count)
  for _ = 1, (count or 1) do
    local id = nextId()
    G.ActiveEnemies[id] = { ObjectId = id, Name = "TimeElemental2" }
  end
end

return G
