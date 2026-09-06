-- =============================================================================
-- ChronosAssist (v0.3.0) -- Stage 3 of 3: milestones and the UNAVAILABLE
-- grid, on top of stage 2's unchanged header/NOW panel and stage 1's
-- unchanged logging. See CHRONOS_TRAINER_SPEC.md (one level up, not part of
-- this repo) section 5, and DESIGN.md (repo root, not shipped) for the
-- reasoning below.
--
-- Facts, verified against the shipped scripts, that force this file's shape:
--
--   * SelectWeapon (EnemyAILogic.lua:1232) RECURSES into itself several times
--     -- a failed ChainChance roll (:1254), an emptied combo option list
--     (:1287, :1294), a combo-only selector (:1360). Each recursive call is a
--     bare global reference, so once ModUtil.Path.Wrap has replaced the global
--     slot, every one of those calls re-enters THIS wrapper too. Without the
--     re-entrancy guard below, one attack decision logs several partial lines
--     instead of one finished one.
--   * All four Chronos combat units share GenusName = "Chronos"
--     (CHRONOS_TRAINER_SPEC.md section 2) -- matching on genus would pull in
--     the Typhon assist fight and the story NPC. This matches enemy.Name
--     exactly, the way RealHecate guards with hecate.Name ~= "Hecate".
--   * The panel is rendered Jowday-DamageMeter style: CreateScreenObstacle
--     once, ModifyTextBox in place forever after -- never destroyed and
--     recreated. Visibility is a fade (ModifyTextBox FadeTarget on text;
--     SetColor alpha on the background rectangle, which has no text box to
--     fade -- see DESIGN.md), driven by one long-lived poll thread rather
--     than a watcher per fight, so all four teardown paths (phase change,
--     Chronos dying, player dying, leaving the room) reduce to the same
--     check: is a tracked Chronos still in game.ActiveEnemies.
--   * The stage ladder is EIGHT stages (4/2/2 across phases), not nine --
--     verified directly against EnemyData_Chronos.lua:344-622 while building
--     stage 2. A `ChronosPhaseTransition` entry is the FIRST stage of the
--     phase it starts, not the last stage of the one before it
--     (CONFIG.phaseStageCounts's own comment has the full trace). The
--     milestone line's PHASE/FINAL threshold depends on getting this right.
--   * The UNAVAILABLE grid's reason column checks the same five gates
--     IsEnemyWeaponEligible checks, in the SAME order (CONFIG.gridReason),
--     so the reported reason is the one that actually fired -- not merely a
--     gate that happens to be present. Textpass does not yet cover every
--     gate the real weapon data uses; an uncovered one shows a visibly
--     unpolished fallback rather than silently vanishing from the grid.
-- =============================================================================

local mods = rom.mods
mods["LuaENVY-ENVY"].auto()

---@diagnostic disable: lowercase-global
rom = rom
_PLUGIN = _PLUGIN

local modutil = mods["SGG_Modding-ModUtil"]
local reload = mods["SGG_Modding-ReLoad"]

local LOG_PREFIX = "[ChronosAssist] "

-- =============================================================================
-- Logging
-- =============================================================================

-- Deliberately rom.log.info for warnings too. In this ReturnOfModding build
-- rom.log.error RAISES rather than logs, so reporting a handled failure through
-- it turns that failure fatal. Severity is carried in the text instead.
local function logAlways(message)
    if rom and rom.log and rom.log.info then
        rom.log.info(LOG_PREFIX .. tostring(message))
    end
end

local function logWarn(message)
    if rom and rom.log and rom.log.info then
        rom.log.info(LOG_PREFIX .. "WARNING: " .. tostring(message))
    end
end

-- =============================================================================
-- Settings
-- =============================================================================
-- All three from spec section 6. GroundMarker is declared and wired to
-- nothing -- reserved for the maintainer's stage 4, per the spec's explicit
-- instruction. Panel and Enabled both gate whether any screen component is
-- created at all (test case 11): read once at install, "applies at next
-- launch/reload" like the equivalent structural settings in sibling mods.

local CONFIG = {}

local settings = {
    values = {
        Enabled = true,
        Panel = true,
        GroundMarker = true,
    },
    entries = {},
    file = nil,
    persistent = false,
}

local CONFIG_DESCRIPTIONS = {
    Enabled = "Master switch. Off leaves the fight completely vanilla and logs nothing.",
    Panel = "The on-screen box. Off creates no screen components at all. Applies at next launch/reload.",
    GroundMarker = "Show a red or green marker under Melinoe during Chronos' two instant-kill attacks, and tint the panel to match. Red means you are standing somewhere that will kill you; green means you are safe. Off leaves the panel text to carry it alone.",
}

local function sectionFor(_)
    return "General"
end

-- These are the primitives Chalk itself is built on: bind a key with a default,
-- read it with :get(), write it with :set(), flush with :save(). Going straight
-- to them means no second file to import and no dependency on how the plugin
-- folder's name maps back to a path on disk. House style across all four sibling
-- mods -- see MODDING_HADES2.md section 0 item 4.
local function loadSettings()
    local ok, err = pcall(function()
        if rom.config == nil or rom.config.config_file == nil then
            logWarn("rom.config unavailable; settings will not persist between sessions")
            return
        end
        local configDir = rom.paths and rom.paths.config and rom.paths.config() or nil
        if configDir == nil then
            logWarn("config directory unavailable; settings will not persist between sessions")
            return
        end

        local guid = (_PLUGIN and _PLUGIN.guid) or "Adicon-ChronosAssist"
        local path = rom.path.combine(configDir, guid .. ".cfg")
        local file = rom.config.config_file:new(path, true)

        for key, default in pairs(settings.values) do
            settings.entries[key] = file:bind(sectionFor(key), key, default, CONFIG_DESCRIPTIONS[key] or "")
        end

        -- Only adopt a stored value whose type matches the default, so a
        -- hand-edited .cfg cannot put a string where a boolean is expected.
        for key, entry in pairs(settings.entries) do
            local stored = entry:get()
            if type(stored) == type(settings.values[key]) then
                settings.values[key] = stored
            end
        end

        settings.file = file
        settings.persistent = true
    end)

    if not ok then
        logWarn("config load failed, using in-memory settings: " .. tostring(err))
    end
end

-- =============================================================================
-- Scoping (spec section 2) -- the trap
-- =============================================================================

-- Chronos_TyphonFight (CannotDieFromDamage assist) and NPC_Chronos_01
-- (story/Crossroads) are deliberately excluded even though they share the
-- genus. Chronos_EMShadow is included: its moveset is a strict subset of his
-- (research section 13.2) and its wind-ups matter to the player just as much.
function CONFIG.isTrackedChronos(enemy)
    return enemy ~= nil and (enemy.Name == "Chronos" or enemy.Name == "Chronos_EMShadow")
end

-- =============================================================================
-- Formatting helpers
-- =============================================================================

local function commaList(t)
    if type(t) ~= "table" or #t == 0 then return "(none)" end
    return table.concat(t, ",")
end

-- The gate keys IsEnemyWeaponEligible (EnemyAILogic.lua:1370) reads, narrowed to
-- the ones CHRONOS_RESEARCH.md section 4.2 found in live use on his weapons.
-- This is NOT a reimplementation of the eligibility rule -- the boolean always
-- comes from calling the game's own function, below. This list only names
-- which of a BLOCKED weapon's own gates could explain the block, as a hint for
-- whoever reads the log. A single confirmed reason per weapon is stage 3's
-- job, once it needs the harness treatment MODDING_HADES2.md section 3 rule 5
-- describes.
local GATE_KEYS = {
    "MinAttacksBetweenUse", "MaxConsecutiveUses", "MaxUses", "RequireTotalAttacks",
    "PreviousWeaponNot", "WeaponHistory", "WeaponHistoryMax", "BlockAsFirstWeapon",
    "MinPlayerDistance", "MaxPlayerDistance", "UnitLoSDistanceTowardPlayer",
    "MaxAttackers", "MinAttackers", "RequiresNotCharmed",
}

-- weaponData.Requirements falls back to weaponData.AIData, mirroring
-- IsEnemyWeaponEligible's own fallback at EnemyAILogic.lua:1371-1374.
function CONFIG.candidateGates(weaponData)
    if type(weaponData) ~= "table" then return "?" end
    local requirements = weaponData.Requirements or weaponData.AIData
    if type(requirements) ~= "table" then return "?" end
    local found = {}
    for _, key in ipairs(GATE_KEYS) do
        if requirements[key] ~= nil then
            found[#found + 1] = key
        end
    end
    if #found == 0 then return "?" end
    return table.concat(found, "+")
end

-- Loops enemy.WeaponOptions through the game's OWN IsEnemyWeaponEligible
-- (EnemyAILogic.lua:1370, cited in research section 12.1) rather than
-- reimplementing the gate rules -- that call is what stage 1 must prove is
-- callable and correct (spec section 3.1 item 4).
function CONFIG.scanEligibility(game, enemy)
    local eligible, blocked = {}, {}
    local weaponOptions = enemy.WeaponOptions
    local isEligibleFn = game.IsEnemyWeaponEligible
    local weaponData = game.WeaponData
    if type(weaponOptions) ~= "table" or type(isEligibleFn) ~= "function" or type(weaponData) ~= "table" then
        return eligible, blocked
    end
    for _, name in ipairs(weaponOptions) do
        local data = weaponData[name]
        local ok, isEligible = pcall(isEligibleFn, enemy, data)
        if ok and isEligible then
            eligible[#eligible + 1] = name
        elseif ok then
            blocked[#blocked + 1] = name .. ":" .. CONFIG.candidateGates(data)
        else
            blocked[#blocked + 1] = name .. ":error"
        end
    end
    return eligible, blocked
end

-- research section 19.2 / 20.2: TimeElemental2 heals him and HitShields stalls
-- his health bar -- both are why stage 1 must prove these fields are readable
-- (spec section 3.1 item 5) before the panel starts presenting numbers derived
-- from them.
function CONFIG.countTempus(game)
    local active = game.ActiveEnemies
    if type(active) ~= "table" then return 0 end
    local n = 0
    for _, unit in pairs(active) do
        if type(unit) == "table" and unit.Name == "TimeElemental2" then
            n = n + 1
        end
    end
    return n
end

-- =============================================================================
-- The per-attack log line (spec section 3)
-- =============================================================================

function CONFIG.logAttack(game, enemy, weapon, comboBefore, comboIdx, eligible, blocked)
    local weaponData = game.WeaponData and game.WeaponData[weapon]
    local aiData = weaponData and weaponData.AIData
    local preattack = aiData and aiData.PreAttackDuration
    local attackdist = aiData and aiData.AttackDistance

    logAlways(("unit=%s#%s weapon=%s phase=%s stage=%s health=%s/%s "
               .. "preattack=%s attackdist=%s combo=%s comboIdx=%s "
               .. "eligible=%s blocked=%s shields=%s tempus=%s")
        :format(
            tostring(enemy.Name), tostring(enemy.ObjectId), tostring(weapon),
            tostring(enemy.CurrentPhase), tostring(enemy.AIStageActive),
            tostring(enemy.Health), tostring(enemy.MaxHealth),
            preattack ~= nil and tostring(preattack) or "nil",
            attackdist ~= nil and tostring(attackdist) or "nil",
            comboBefore ~= nil and tostring(comboBefore) or "nil",
            comboBefore ~= nil and tostring(comboIdx or 0) or "0",
            commaList(eligible), commaList(blocked),
            tostring(enemy.HitShields or 0), tostring(CONFIG.countTempus(game))))
end

-- Once per fight and once per phase transition (spec section 3). Detected by
-- diffing enemy.CurrentPhase across calls rather than hooking
-- ChronosPhaseTransition (PresentationBiomeI.lua:704) directly: that function
-- increments CurrentPhase (:715) before StagedAI (EnemyAILogic.lua:5601)
-- applies the NEW stage's WeaponOptions via OverwriteTableKeys (:5633), so a
-- post-hoc wrap of the transition itself would log the OUTGOING stage's pool.
-- Reading it here, at actual attack-selection time, guarantees the new stage's
-- data has already settled. See DESIGN.md for the ordering trace.
function CONFIG.logPhaseBegin(enemy, why)
    local stageCount = type(enemy.AIStages) == "table" and #enemy.AIStages or -1
    logAlways(("unit=%s#%s phase %s begin (%s) health=%s/%s stages=%s weaponpool=%s")
        :format(tostring(enemy.Name), tostring(enemy.ObjectId), tostring(enemy.CurrentPhase), why,
                tostring(enemy.Health), tostring(enemy.MaxHealth),
                tostring(stageCount), commaList(enemy.WeaponOptions)))
end

-- =============================================================================
-- Player-facing labels (spec section 4.3, CHRONOS_TEXTPASS.md section 2/4)
-- =============================================================================
-- Authoritative text. Do not invent labels or improve the wording -- section 7
-- of the spec is explicit about this, and research section 9.1a found several
-- of the guide's own "internal names" actually name a PROJECTILE or
-- fire-function rather than the WEAPON key `enemy.WeaponName` ever holds --
-- ChronosClockArm (a projectile of ChronosClockwise), ChronosTimeSlow (a fire
-- function on ChronosUltimate), ChronosMiniRiftStasis (referenced by no .lua
-- file at all). Keyed here by the verified weapon-level name only. Anything
-- absent falls back to its raw internal name (CONFIG.resolveLabel) rather
-- than a guessed label.
local WEAPON_LABELS = {
    ChronosSwingLeft    = { "Scythe Slash (slow)", "wide arc, front" },
    ChronosSwingRight   = { "Scythe Slash (fast)", "wide arc, front" },
    ChronosScytheThrow  = { "Scythe Spin Throw", "arc ahead, safe up close" },
    ChronosDash         = { "Dash Slice", "at you \xe2\x80\x94 leaves a bubble" },
    ChronosRush         = { "Charge", "straight at you" },
    ChronosGrind        = { "Vortex Pull", "around him, pulls in" },
    -- ChronosCastOrbit / ChronosCastOrbit2 share a GenusName (verified,
    -- research section 9.2) and fire the same projectiles -- the data cannot
    -- tell them apart, so both get the guide's one confirmed generic label
    -- rather than a guessed "Diagonal"/"Spiral" split.
    ChronosCastOrbit    = { "Orbs", "ring around him \xe2\x80\x94 gaps are safe" },
    ChronosCastOrbit2   = { "Orbs", "ring around him \xe2\x80\x94 gaps are safe" },
    -- Clock Hands: the projectile is ChronosClockArm, but the WEAPON that
    -- fires it is ChronosClockwise / ChronosClockwise2 (verified 2026-09-05).
    ChronosClockwise    = { "Clock Hands", "sweeping \xe2\x80\x94 outrun or dash through" },
    ChronosClockwise2   = { "Clock Hands", "sweeping \xe2\x80\x94 outrun or dash through" },
    -- Time Fire Circles: only the ChronosRadialIn half is confirmed. The
    -- weapon firing the RadialOut projectile (ChronosPassiveNumberSequence)
    -- is NOT mapped here -- its own name suggests a clock-numeral mechanic
    -- rather than "closing inward circles", and lumping it in on a shared
    -- projectile family alone would be exactly the guess section 7 forbids.
    ChronosRadialIn     = { "Time Fire Circles", "closing inward \xe2\x80\x94 dash out through them" },
    ChronosBannerSummon = { "Time Banners", "shields him \xe2\x80\x94 break them" },
    -- The two insta-kills (CHRONOS_TEXTPASS.md section 4). Ground marker /
    -- red-green safety indicator is explicitly out of scope here (spec
    -- section 1.2) -- these render exactly like any other NOW entry.
    ChronosRadial2      = { "\xe2\x9a\xa0 CLOCK BURST", "move toward center ring" },
    ChronosRadial3      = { "\xe2\x9a\xa0 TIME BURST", "run to the lit clock numeral" },
}

-- Naming-convention suffixes research section 13.1 documents (_P3, _EM) plus
-- the combo-step suffixes seen in WeaponData_Chronos.lua (ComboStart/Middle/
-- End -- e.g. "ChronosSwingRightComboStart" is literally a Scythe Slash
-- (fast) with a combo-step suffix). Tried only after an exact match fails.
-- This is pattern-based fallback onto an ALREADY-confirmed label, not a
-- guess at new wording -- the text shown is still only ever one of the
-- strings above or the raw internal name, never invented prose.
local LABEL_SUFFIXES = { "ComboStart", "ComboMiddle", "ComboEnd", "_P3", "_EM", "_Assist" }

-- Returns label, description or nil, nil if truly unmapped -- the caller
-- shows the raw internal name in that case (spec section 7: do not fill the
-- gap yourself).
function CONFIG.resolveLabel(weaponName)
    if weaponName == nil then return nil, nil end
    local entry = WEAPON_LABELS[weaponName]
    if entry ~= nil then return entry[1], entry[2] end
    for _, suffix in ipairs(LABEL_SUFFIXES) do
        if #weaponName > #suffix and weaponName:sub(-#suffix) == suffix then
            entry = WEAPON_LABELS[weaponName:sub(1, -#suffix - 1)]
            if entry ~= nil then return entry[1], entry[2] end
        end
    end
    return nil, nil
end

-- =============================================================================
-- Header stage-within-phase numbering (CHRONOS_TEXTPASS.md section 1:
-- "Phase 1 . stage <N> of 4", "Phase 2 . stage <N> of 2", "Phase 3 . stage
-- <N> of 2")
-- =============================================================================
-- Derived live from enemy.AIStages rather than hardcoded 4/2/2, so a future
-- patch to the stage ladder (EnemyData_Chronos.lua:344) moves this with it.
--
-- A TransitionFunction == "ChronosPhaseTransition" entry is the FIRST stage
-- of the phase it starts, not the last stage of the one before it --
-- StagedAI (EnemyAILogic.lua:5601) calls CallFunctionName(aiStage
-- .TransitionFunction, ...) at :5755, inside the SAME loop iteration that
-- applies that entry's own AIData, so the transition belongs to the stage
-- it is attached to. Verified directly against EnemyData_Chronos.lua:344-622,
-- which has eight entries split 4/2/2 -- an earlier version of this function
-- (and of CHRONOS_RESEARCH.md section 15) closed the OLD phase on the
-- transition entry itself and got 5/2/1, one stage short in phase 3.
function CONFIG.phaseStageCounts(enemy)
    local stages = enemy.AIStages
    local counts = {}
    if type(stages) ~= "table" then return counts end
    local phaseIdx = 1
    local count = 0
    for _, stage in ipairs(stages) do
        if type(stage) == "table" and stage.TransitionFunction == "ChronosPhaseTransition" then
            counts[phaseIdx] = count
            phaseIdx = phaseIdx + 1
            count = 0
        end
        count = count + 1
    end
    counts[phaseIdx] = count
    return counts
end

-- Returns (stage-within-phase, stages-in-that-phase), either possibly nil if
-- AIStages is unavailable.
function CONFIG.stageWithinPhase(enemy)
    local counts = CONFIG.phaseStageCounts(enemy)
    local phase = enemy.CurrentPhase or 1
    if counts[phase] == nil then return nil, nil end
    local before = 0
    for p = 1, phase - 1 do
        before = before + (counts[p] or 0)
    end
    return (enemy.AIStageActive or 0) - before, counts[phase]
end

function CONFIG.headerText(enemy)
    local within, total = CONFIG.stageWithinPhase(enemy)
    if within == nil then
        return ("Phase %s"):format(tostring(enemy.CurrentPhase))
    end
    return ("Phase %s \xc2\xb7 stage %s of %s"):format(tostring(enemy.CurrentPhase), tostring(within), tostring(total))
end

-- =============================================================================
-- The NOW block (spec section 4.3) and the combo preview (section 4.3 /
-- CHRONOS_TEXTPASS.md section 3)
-- =============================================================================

local function formatSeconds(s)
    return ("%.1fs"):format(s)
end

-- enemy.ActiveWeaponCombo is captured BEFORE SelectWeapon runs (the hook
-- stashes it as ChronosAssist_ComboForNow) because the combo's FINAL step
-- clears it internally (EnemyAILogic.lua:1301-1303) -- the same reason
-- stage 1's logAttack captures comboBefore before calling base.
--
-- WeaponCombo steps are either a plain string (the common case, e.g.
-- ChronosRushCombo's three steps) or a table like
-- { WeaponName = "ChronosScytheThrow_P3" } (ChronosScytheThrowDouble_P3,
-- ChronosNumberCombo, ...). Read in full: when such a table carries its own
-- WeaponOptions list with more than one entry, GetRandomValue over it
-- (EnemyAILogic.lua:1290) is a genuine random draw and the next step is NOT
-- deterministic -- no Chronos combo currently does this (every WeaponOptions
-- list found has exactly one entry, making the "random" draw a no-op), but
-- this checks rather than assumes, and shows no name if it ever does.
function CONFIG.computeComboLine(game, enemy)
    local comboName = enemy.ChronosAssist_ComboForNow
    if comboName == nil then return "" end
    local weaponData = game.WeaponData and game.WeaponData[comboName]
    local steps = weaponData and weaponData.WeaponCombo
    if type(steps) ~= "table" then return "" end
    local idx = enemy.ActiveWeaponComboIndex or 0
    local total = #steps
    if idx <= 0 or idx >= total then return "" end -- no combo yet, or that was the final step

    local nextStep = steps[idx + 1]
    local nextName = nil
    if type(nextStep) == "string" then
        nextName = nextStep
    elseif type(nextStep) == "table" then
        local options = nextStep.WeaponOptions
        if options == nil then
            nextName = nextStep.WeaponName
        elseif type(options) == "table" and #options == 1 then
            nextName = options[1]
        end
        -- #options > 1: a genuine random draw. nextName stays nil, and the
        -- line below omits the "-> name" rather than guess.
    end

    if nextName == nil then
        return ("NEXT IN COMBO   %d of %d"):format(idx, total)
    end
    local label = CONFIG.resolveLabel(nextName) or nextName
    return ("NEXT IN COMBO   %d of %d \xe2\x86\x92 %s"):format(idx, total, label)
end

-- Pure computation of what the NOW block should show, given the enemy and
-- the current time (GetTime({}), Main.lua:2/448 -- a live world-time read,
-- not accumulated poll ticks, so it does not drift). Separated from the
-- actual ModifyTextBox calls so the suite can assert on it without faking
-- the whole screen API.
function CONFIG.computeNowBlock(game, enemy, now)
    local weapon = enemy.WeaponName
    local start = enemy.ChronosAssist_WindupStart
    if weapon == nil or start == nil then
        return { name = "", description = "", combo = "", barFraction = nil }
    end

    local label, description = CONFIG.resolveLabel(weapon)
    label = label or weapon
    description = description or ""

    local total = enemy.ChronosAssist_WindupTotal
    local barFraction = nil
    local nameLine = label
    if total ~= nil and total > 0 then
        local elapsed = (now or 0) - start
        local remaining = math.max(0, total - elapsed)
        barFraction = math.max(0, math.min(1, remaining / total))
        nameLine = label .. "    " .. formatSeconds(remaining)
    end

    return {
        name = nameLine,
        description = description,
        combo = CONFIG.computeComboLine(game, enemy),
        barFraction = barFraction,
    }
end

-- Shadow duplicates (spec section 4.3, CHRONOS_TEXTPASS.md section 5). Just
-- the one line the textpass defines -- no bar, no description -- deliberately
-- less detail than the primary NOW block; research section 13.2 notes a
-- duplicate's moveset is a strict subset of his and it is never the one-shot,
-- so the bar's precision matters far less here. Picks the first live shadow
-- found; if more than one is ever alive at once (untested -- Rivals phase 3
-- only) only that one is shown. See DESIGN.md.
function CONFIG.findShadow(game, excludeId)
    local active = game.ActiveEnemies
    if type(active) ~= "table" then return nil end
    for id, unit in pairs(active) do
        if type(unit) == "table" and unit.Name == "Chronos_EMShadow" and id ~= excludeId then
            return unit
        end
    end
    return nil
end

function CONFIG.duplicateLine(shadow)
    if shadow == nil or shadow.WeaponName == nil then return "" end
    local label = CONFIG.resolveLabel(shadow.WeaponName) or shadow.WeaponName
    return "\xe2\xa7\x89 duplicate \xe2\x80\x94 " .. label
end

-- =============================================================================
-- Milestones (spec section 5.1, CHRONOS_TEXTPASS.md section 6)
-- =============================================================================

local function round(x)
    return math.floor(x + 0.5)
end

-- CHRONOS_TEXTPASS.md section 6's fixed vocabulary, one entry per stage
-- whose crossing brings a named change -- keyed by the STAGE THAT IS ENDING
-- (WHAT_CHANGES[3] is what arrives when stage 3 ends and stage 4 begins).
-- Traced against EnemyData_Chronos.lua's own EquipWeapons diffs (DESIGN.md
-- has the full derivation) and confirmed against research section 18's own
-- worked examples -- states 1, 4, 7 and 8/12 each pin one entry exactly.
--
-- Stage 6 (the last stage of phase 2, crossing into phase 3) has NO entry.
-- Textpass's six phrases were traced to six of the seven real transitions;
-- none of them was confirmed against this one. Left nil rather than guessed
-- (spec section 7) -- the milestone line omits the "-- what changes" suffix
-- for this transition alone. See DESIGN.md.
local WHAT_CHANGES = {
    [1] = "6 satyrs",
    [2] = "Triple Attack Combo",
    [3] = "2 armoured elites",
    [4] = "new arena, Time Burst and Clock Burst",
    [5] = "moveset expands",
    [7] = "clock platforms attack",
}

-- The static threshold (0-1 fraction) the LAST stage of the given phase ends
-- at -- i.e. the health fraction at which the NEXT phase begins. Read from
-- the AIStages array directly rather than simulated, since that stage may
-- not have been reached yet. Caveat: EMStageDataOverrides mutate a stage's
-- OWN table in place the first time StagedAI reaches it
-- (EnemyAILogic.lua:5615-5617), so previewing a not-yet-reached stage under
-- the Vow reads the un-overridden value -- flagged in DESIGN.md, not fixed
-- here, since there is no live signal for an override that has not applied
-- yet.
function CONFIG.phaseEndThreshold(enemy)
    local counts = CONFIG.phaseStageCounts(enemy)
    local phase = enemy.CurrentPhase or 1
    local before = 0
    for p = 1, phase - 1 do before = before + (counts[p] or 0) end
    local lastIdx = before + (counts[phase] or 0)
    local stage = enemy.AIStages and enemy.AIStages[lastIdx]
    local aiData = stage ~= nil and stage.AIData
    return aiData and aiData.AIEndHealthThreshold
end

-- Returns an array of 1 or 2 lines (spec section 5.1): NEXT + PHASE/FINAL,
-- collapsed to one when the current stage is the last one in its phase (the
-- two would otherwise show the same percentage and the same "what changes").
-- Percentage only, from live enemy.Health/MaxHealth/AIEndHealthThreshold
-- (research section 15.2a) -- never absolute damage, since MaxHealth differs
-- per phase (20000/16000/26000).
function CONFIG.milestoneLines(enemy)
    if enemy.MaxHealth == nil or enemy.MaxHealth <= 0 or enemy.AIEndHealthThreshold == nil then
        return {}
    end
    local healthFraction = (enemy.Health or 0) / enemy.MaxHealth
    local nextPercent = round((healthFraction - enemy.AIEndHealthThreshold) * 100)
    local nextWhat = WHAT_CHANGES[enemy.AIStageActive or 0]

    local counts = CONFIG.phaseStageCounts(enemy)
    local phase = enemy.CurrentPhase or 1
    local before = 0
    for p = 1, phase - 1 do before = before + (counts[p] or 0) end
    local isLastStageOfPhase = (enemy.AIStageActive or 0) >= before + (counts[phase] or 0)

    local phaseLabel = (phase >= 3) and "FINAL" or ("PHASE " .. tostring(phase + 1))

    if isLastStageOfPhase then
        local line = ("%s   %d%% away"):format(phaseLabel, nextPercent)
        if nextWhat ~= nil then line = line .. " \xe2\x80\x94 " .. nextWhat end
        return { line }
    end

    local nextLine = ("NEXT   %d%% away"):format(nextPercent)
    if nextWhat ~= nil then nextLine = nextLine .. " \xe2\x80\x94 " .. nextWhat end

    local phaseThreshold = CONFIG.phaseEndThreshold(enemy)
    if phaseThreshold == nil then return { nextLine } end
    local phasePercent = round((healthFraction - phaseThreshold) * 100)
    return { nextLine, ("%s   %d%% away"):format(phaseLabel, phasePercent) }
end

-- =============================================================================
-- Status lines (spec section 5.3, CHRONOS_TEXTPASS.md section 7)
-- =============================================================================

-- research section 20.2: HitShields is a plain live integer, spent one per
-- hit, no inference needed.
function CONFIG.statusLines(game, enemy)
    local lines = {}
    if (enemy.HitShields or 0) > 0 then
        lines[#lines + 1] = ("\xe2\x96\xa3 Shielded \xc3\x97%d \xe2\x80\x94 break the banners"):format(enemy.HitShields)
    end
    -- research section 19.2: "beaming" is the real trigger, but no live
    -- boolean for that was found -- a live TimeElemental2 is the best
    -- available proxy (stage 1 already established the count is readable).
    -- Flagged for the maintainer: confirm this doesn't fire while one is alive but
    -- not yet casting.
    if CONFIG.countTempus(game) > 0 then
        lines[#lines + 1] = "\xe2\x9f\xb2 Tempus healing \xe2\x80\x94 kill the adds"
    end
    return lines
end

-- =============================================================================
-- The UNAVAILABLE grid (spec section 5.2, CHRONOS_TEXTPASS.md section 8)
-- =============================================================================

-- Determines WHICH of a blocked weapon's gates actually explains it, checked
-- in the SAME order IsEnemyWeaponEligible itself checks them
-- (EnemyAILogic.lua:1417, 1442, 1510, 1516, 1641) so the FIRST one that
-- really currently fails is reported -- not just the first one whose field
-- happens to be present. Stage 1's log-only "candidate gates" list could
-- afford that ambiguity; a player-facing row cannot, per spec section 7's
-- own Vortex Pull warning about exactly this kind of wrong attribution.
-- Returns nil if none of these five explain it -- the caller falls back to
-- CONFIG.candidateGates rather than showing nothing (spec section 7: do not
-- silently drop a row that IS blocked, but do not invent wording for it
-- either).
function CONFIG.gridReason(game, enemy, weaponData)
    local requirements = weaponData.Requirements or weaponData.AIData
    if type(requirements) ~= "table" then return nil end

    if requirements.MinAttacksBetweenUse ~= nil then
        local since = game.NumAttacksSinceWeapon(enemy, weaponData.Name)
        if since >= 0 and since < requirements.MinAttacksBetweenUse then
            return ("in %d attacks"):format(requirements.MinAttacksBetweenUse - since)
        end
    end

    if requirements.MaxUses ~= nil and enemy.WeaponHistory ~= nil then
        -- EnemyAILogic.lua:1442-1453 -- deliberately NOT genus-collapsed,
        -- unlike NumAttacksSinceWeapon: matched exactly, prevWeapon ==
        -- weaponData.Name.
        local numUses = 0
        for i = 1, #enemy.WeaponHistory do
            if enemy.WeaponHistory[i] == weaponData.Name then numUses = numUses + 1 end
        end
        if numUses >= requirements.MaxUses then
            return ("%d of %d uses left"):format(math.max(0, requirements.MaxUses - numUses), requirements.MaxUses)
        end
    end

    -- EnemyAILogic.lua:1510-1520 skips both distance gates entirely while
    -- charmed -- matched here so a charmed enemy is never misattributed to
    -- range.
    if not enemy.IsCharmed then
        if requirements.MaxPlayerDistance ~= nil then
            local within = game.IsWithinDistance({ Id = enemy.ObjectId, DestinationId = game.CurrentRun.Hero.ObjectId,
                Distance = requirements.MaxPlayerDistance, ScaleY = requirements.MaxPlayerDistanceScaleY })
            if not within then return "only when you're closer" end
        end
        if requirements.MinPlayerDistance ~= nil then
            local within = game.IsWithinDistance({ Id = enemy.ObjectId, DestinationId = game.CurrentRun.Hero.ObjectId,
                Distance = requirements.MinPlayerDistance, ScaleY = requirements.MinPlayerDistanceScaleY })
            if within then return "only when you're farther" end
        end
    end

    if requirements.UnitLoSDistanceTowardPlayer ~= nil then
        return "no line of sight"
    end

    return nil
end

-- One row per currently-ineligible weapon in enemy.WeaponOptions -- ready
-- attacks are not listed (spec section 5.2: "ready" is the uninteresting
-- state and covers most attacks most of the time). Always calls the game's
-- own IsEnemyWeaponEligible for the boolean, exactly like stage 1's
-- scanEligibility -- never reimplemented.
function CONFIG.gridRows(game, enemy)
    local rows = {}
    local weaponOptions = enemy.WeaponOptions
    local isEligibleFn = game.IsEnemyWeaponEligible
    local weaponData = game.WeaponData
    if type(weaponOptions) ~= "table" or type(isEligibleFn) ~= "function" or type(weaponData) ~= "table" then
        return rows
    end
    for _, name in ipairs(weaponOptions) do
        local data = weaponData[name]
        local ok, eligible = pcall(isEligibleFn, enemy, data)
        if ok and not eligible then
            local reason = (data ~= nil and CONFIG.gridReason(game, enemy, data)) or nil
            if reason == nil then
                -- Textpass section 8 does not yet cover every gate research
                -- section 4.2 documents (MaxConsecutiveUses, RequireTotalAttacks,
                -- PreviousWeaponNot, ...) -- shown rather than silently
                -- omitted, but visibly not the polished wording (spec
                -- section 7: say the gap exists, do not fill it yourself).
                reason = "blocked (" .. CONFIG.candidateGates(data) .. ")"
            end
            local label = CONFIG.resolveLabel(name) or name
            rows[#rows + 1] = ("  %s    %s"):format(label, reason)
        end
    end
    return rows
end

-- =============================================================================
-- Rendering (spec section 4.1) -- Jowday's DamageMeter pattern: create once,
-- ModifyTextBox in place forever after. See DESIGN.md for the background's
-- alpha-toggle vs the text anchors' FadeTarget, and for the layout constants.
-- =============================================================================

-- First-guess starting values, not yet seen on screen (the maintainer drives all
-- playtesting -- MODDING_HADES2.md section 5). ObjectiveStartX/Y = 130/150
-- (HUDData.lua:13-14) is the nearest confirmed real HUD element; this sits
-- below where a short 1-2 line objective text would end. Width/height
-- fractions are calibrated against Jowday's OWN empirical baseline
-- (JowdayDPS.Main.lua:527-544: Fraction 1.0 == roughly 440x250px, their
-- config.DisplayWidth+Margin and a 250px unit) since it is the only known
-- working reference for this exact rectangle01 obstacle -- not a documented
-- engine constant. Tune every value here by eye once this is on screen.
local LAYOUT = {
    X = 50,
    Y = 230,
    LINE_HEIGHT = 22,
    RECT_BASE_WIDTH = 440,
    RECT_BASE_HEIGHT = 250,
    PANEL_WIDTH_PX = 340,
    -- header (2) + NOW block (up to 4) + duplicate (1) + milestone (up to 2)
    -- + status (up to 2) + grid (header + up to 6 rows) + margin. Fixed
    -- height, not resized as rows appear/disappear -- unused rows are simply
    -- blank text, the same simplification stage 2 made for the NOW block.
    PANEL_HEIGHT_PX = 420,
    BAR_WIDTH_PX = 220,
    BAR_HEIGHT_PX = 10,
    BACKGROUND_COLOR = { 0.05, 0.05, 0.09, 0.6 },
    -- Stage 4. The box is tinted to match the ground marker so peripheral
    -- vision catches the flip; alpha stays low so the text remains readable.
    --
    -- TWO COLOUR SCALES LIVE IN THIS FILE. These go to SetColor on a screen
    -- obstacle and are 0-1, matching Jowday's DamageMeter. The marker's
    -- colours go to CreateAnimation and are 0-255. Do not "fix" either to
    -- match the other -- both are correct for their call, and getting one
    -- backwards yields black, which looks like the feature is simply broken.
    PANEL_COLOR = { 0.05, 0.05, 0.09, 0.6 },
    SAFE_COLOR = { 0.06, 0.30, 0.10, 0.72 },
    UNSAFE_COLOR = { 0.36, 0.05, 0.06, 0.72 },
    BAR_COLOR = { 0.85, 0.75, 0.35, 1.0 },
    FADE_DURATION = 0.2,
    -- Row offsets, in LINE_HEIGHT units, for the anchors below the fixed
    -- stage-2 rows (title=0, status=1, nowName=2, nowBar=3, nowDescription=4,
    -- nowCombo=5, duplicate=6).
    MILESTONE_ROW = 7,   -- up to 2 lines
    STATUS_ROW = 9,      -- up to 2 lines
    GRID_ROW = 11,       -- header + up to 6 rows
}

local POLL_INTERVAL = 0.1

-- All screen anchors, keyed by name. Created exactly once (Panel.lua state
-- below), never destroyed -- that is what makes "zero leaked components"
-- true regardless of how many fights start and end in one session.
local ScreenAnchors = {}

local Panel = {
    created = false,
    watcherStarted = false,
    generation = 0,
    visible = nil,       -- nil until first render, so the very first poll
                          -- always writes rather than skipping on a false
                          -- "no change" match against an unset value.
    lastText = {},        -- change-detection memo: anchor name -> last Text
    lastBarFraction = nil,
}

-- =============================================================================
-- Stage 4 -- the safe/unsafe indicator for the two insta-kills.
--
-- Both deal 999 with IgnoreDodge = true, so position is the only answer, and
-- their rules are OPPOSITE. PreviousWeaponNot forces them to alternate
-- (WeaponData_Chronos.lua), so misreading one sends the player exactly the
-- wrong way. That is the whole reason this exists.
--
-- Geometry is read off disk, not derived. Content\Game\Projectiles\
-- Enemy_BiomeI_Projectiles.sjson:
--
--   ChronosCircle              DamageRadius 400,  no hollow  -> kills 0..400
--   ChronosCircleInverted      DamageRadius 9000, Hollow 8300 -> kills 700..
--   ChronosCircleInvertedSmall DamageRadius 9000, Hollow 8850 -> kills 150..
--
-- A "hollow blast" damages from (DamageRadius - HollowBlastRadiusBand) outward,
-- so the hollow centre is the safe part. Hence:
--
--   CLOCK BURST (ChronosRadial2, both circles at Chronos) -- safe 400..700
--   TIME BURST  (ChronosRadial3, one circle at a ClockFacePoint) -- safe 0..150
--
-- All three carry DamageRadiusScaleX = 1.175 and DamageRadiusScaleY = 0.6, so
-- every zone is an ellipse. Normalise the offset by those before comparing to
-- a radius; comparing raw distance would be wrong on both axes.
-- =============================================================================

local SAFE = {
    SCALE_X = 1.175,
    SCALE_Y = 0.6,
    CLOCK_BURST_INNER = 400,
    CLOCK_BURST_OUTER = 700,
    TIME_BURST_RADIUS = 150,
    -- Field stashed on the enemy, namespaced per MODDING_HADES2 section 2.
    TARGET_FIELD = "ChronosAssist_BurstTargetId",
}

-- The two weapons, and the instruction each shows. Text is fixed --
-- CHRONOS_TEXTPASS.md section 4 -- because colour carries the state, not words.
local BURSTS = {
    ChronosRadial2    = { kind = "CLOCK_BURST", label = "CLOCK BURST",
                          instruction = "move toward center ring" },
    ChronosRadial3    = { kind = "TIME_BURST",  label = "TIME BURST",
                          instruction = "run to the lit clock numeral" },
    ChronosRadial3_EM = { kind = "TIME_BURST",  label = "TIME BURST",
                          instruction = "run to the lit clock numeral",
                          bubbles = true },
}

function CONFIG.burstFor(weaponName)
    return weaponName ~= nil and BURSTS[weaponName] or nil
end

-- Distance from (x1,y1) to (x2,y2) with the isometric squash removed, so it can
-- be compared against a DamageRadius directly.
function CONFIG.normalisedDistance(x1, y1, x2, y2)
    if x1 == nil or y1 == nil or x2 == nil or y2 == nil then return nil end
    local dx = (x2 - x1) / SAFE.SCALE_X
    local dy = (y2 - y1) / SAFE.SCALE_Y
    return math.sqrt(dx * dx + dy * dy)
end

-- nil means "cannot tell" -- never guess. A wrong green on a 999 is worse than
-- no indicator at all, so every unknown returns nil and the caller shows no
-- colour rather than a colour it cannot justify.
function CONFIG.isSafeFrom(kind, distance)
    if distance == nil then return nil end
    if kind == "CLOCK_BURST" then
        return distance > SAFE.CLOCK_BURST_INNER and distance < SAFE.CLOCK_BURST_OUTER
    elseif kind == "TIME_BURST" then
        return distance < SAFE.TIME_BURST_RADIUS
    end
    return nil
end

-- Returns nil when no insta-kill is winding up. Otherwise the label, the fixed
-- instruction, and safe = true/false/nil.
--
-- CLOCK BURST measures from Chronos: both its circles are anchored on him.
-- TIME BURST measures from the ClockFacePoint the game itself chose -- captured
-- from GetTargetId (see installSafeZoneHook). If that capture failed, safe is
-- nil and the instruction still shows.
function CONFIG.safeZoneState(game, enemy)
    if not settings.values.Enabled or not settings.values.GroundMarker then return nil end
    if enemy == nil then return nil end
    local burst = CONFIG.burstFor(enemy.WeaponName)
    if burst == nil then return nil end

    local hero = game.CurrentRun and game.CurrentRun.Hero
    local heroId = hero and hero.ObjectId
    local hx, hy = nil, nil
    if heroId ~= nil and type(game.GetLocation) == "function" then
        local loc = game.GetLocation({ Id = heroId })
        hx, hy = loc and loc.X, loc and loc.Y
    end

    local cx, cy = nil, nil
    local anchorId = enemy.ObjectId
    if burst.kind == "TIME_BURST" then anchorId = enemy[SAFE.TARGET_FIELD] end
    if anchorId ~= nil and type(game.GetLocation) == "function" then
        local loc = game.GetLocation({ Id = anchorId })
        cx, cy = loc and loc.X, loc and loc.Y
    end

    local distance = CONFIG.normalisedDistance(cx, cy, hx, hy)
    return {
        kind = burst.kind,
        label = burst.label,
        instruction = burst.instruction,
        bubbles = burst.bubbles == true,
        safe = CONFIG.isSafeFrom(burst.kind, distance),
    }
end

local function makeTextBox(game, name, x, y, offsetY)
    ScreenAnchors[name] = game.CreateScreenObstacle({ Name = "BlankObstacle", X = x, Y = y + (offsetY or 0) })
    game.CreateTextBox({
        Id = ScreenAnchors[name],
        Text = "",
        Font = "LatoSemibold",
        FontSize = 14,
        Justification = "Left",
        Color = game.Color and game.Color.White or nil,
        OutlineThickness = 2.0,
        OutlineColor = game.Color and game.Color.Black or nil,
        ShadowOffset = { 1, 2 },
        ShadowBlur = 0,
        ShadowAlpha = 1,
        ShadowColor = game.Color and game.Color.Black or nil,
    })
    -- Starts invisible; ensurePanel's first tick decides real visibility.
    game.ModifyTextBox({ Id = ScreenAnchors[name], FadeTarget = 0, FadeDuration = 0 })
end

-- Creates every anchor exactly once. Gated on Enabled+Panel by the caller, so
-- with either off, NOTHING here ever runs (spec test case 11).
local function createPanelAnchors(game)
    if Panel.created then return end

    ScreenAnchors["Background"] = game.CreateScreenObstacle({ Name = "rectangle01", X = LAYOUT.X, Y = LAYOUT.Y })
    game.SetScaleX({ Id = ScreenAnchors["Background"], Fraction = LAYOUT.PANEL_WIDTH_PX / LAYOUT.RECT_BASE_WIDTH })
    game.SetScaleY({ Id = ScreenAnchors["Background"], Fraction = LAYOUT.PANEL_HEIGHT_PX / LAYOUT.RECT_BASE_HEIGHT })
    -- Alpha 0: the background has no text box, so FadeTarget does not apply
    -- to it (see DESIGN.md) -- SetColor's alpha channel is the hide mechanism.
    game.SetColor({ Id = ScreenAnchors["Background"],
                     Color = { LAYOUT.BACKGROUND_COLOR[1], LAYOUT.BACKGROUND_COLOR[2], LAYOUT.BACKGROUND_COLOR[3], 0 } })

    makeTextBox(game, "HeaderTitle", LAYOUT.X, LAYOUT.Y, 0)
    makeTextBox(game, "HeaderStatus", LAYOUT.X, LAYOUT.Y, LAYOUT.LINE_HEIGHT)
    makeTextBox(game, "NowName", LAYOUT.X, LAYOUT.Y, LAYOUT.LINE_HEIGHT * 2)
    makeTextBox(game, "NowDescription", LAYOUT.X, LAYOUT.Y, LAYOUT.LINE_HEIGHT * 4)
    makeTextBox(game, "NowCombo", LAYOUT.X, LAYOUT.Y, LAYOUT.LINE_HEIGHT * 5)
    makeTextBox(game, "Duplicate", LAYOUT.X, LAYOUT.Y, LAYOUT.LINE_HEIGHT * 6)
    -- These three grow and shrink line by line (milestone: 1-2, status: 0-2,
    -- grid: header + 0-N rows), so they are written with the RawText +
    -- Append + NumLineBreaks=1 idiom (spec section 4.1, SelectFirstBoon's
    -- pattern) rather than one fixed anchor per row the way the NOW block's
    -- fixed-shape lines are.
    makeTextBox(game, "Milestone", LAYOUT.X, LAYOUT.Y, LAYOUT.LINE_HEIGHT * LAYOUT.MILESTONE_ROW)
    makeTextBox(game, "Status", LAYOUT.X, LAYOUT.Y, LAYOUT.LINE_HEIGHT * LAYOUT.STATUS_ROW)
    makeTextBox(game, "Grid", LAYOUT.X, LAYOUT.Y, LAYOUT.LINE_HEIGHT * LAYOUT.GRID_ROW)

    -- Research section 15.4b: a single scaled rectangle, not text glyphs --
    -- only one attack winds up at a time. Sits on its own row (line 3 of the
    -- "one thing per line" layout, section 15.4a) between the name and the
    -- description.
    ScreenAnchors["NowBar"] = game.CreateScreenObstacle({
        Name = "rectangle01", X = LAYOUT.X, Y = LAYOUT.Y + LAYOUT.LINE_HEIGHT * 3 })
    game.SetScaleY({ Id = ScreenAnchors["NowBar"], Fraction = LAYOUT.BAR_HEIGHT_PX / LAYOUT.RECT_BASE_HEIGHT })
    game.SetScaleX({ Id = ScreenAnchors["NowBar"], Fraction = 0 })
    game.SetColor({ Id = ScreenAnchors["NowBar"], Color = LAYOUT.BAR_COLOR })

    game.ModifyTextBox({ Id = ScreenAnchors["HeaderTitle"], RawText = "CHRONOS" })

    Panel.created = true
end

-- Fades every text anchor and toggles the background's alpha. Idempotent
-- against its own last state (Panel.visible) so a fight that stays active
-- across many poll ticks does not re-issue the same fade every 0.1s.
local function setPanelVisible(game, visible)
    if Panel.visible == visible then return end
    Panel.visible = visible
    local target = visible and 1 or 0
    for _, name in ipairs({ "HeaderTitle", "HeaderStatus", "NowName", "NowDescription", "NowCombo", "Duplicate",
                            "Milestone", "Status", "Grid" }) do
        if ScreenAnchors[name] ~= nil then
            game.ModifyTextBox({ Id = ScreenAnchors[name], FadeTarget = target, FadeDuration = LAYOUT.FADE_DURATION })
        end
    end
    local bg = LAYOUT.BACKGROUND_COLOR
    game.SetColor({ Id = ScreenAnchors["Background"], Color = { bg[1], bg[2], bg[3], visible and bg[4] or 0 } })
end

-- Writes one text anchor only if its content changed, so a poll tick with
-- nothing new to say costs one table lookup instead of an engine call.
local function writeIfChanged(game, name, text)
    if Panel.lastText[name] == text then return end
    Panel.lastText[name] = text
    game.ModifyTextBox({ Id = ScreenAnchors[name], RawText = text })
end

-- Same change-detection as writeIfChanged, for an anchor whose line COUNT
-- varies (milestone, status, grid). RawText on the first line, then
-- Append=true with NumLineBreaks=1 per line after -- SelectFirstBoon's
-- multi-line idiom, spec section 4.1. An empty array clears the box.
local function writeMultilineIfChanged(game, name, lines)
    local joined = table.concat(lines, "\n")
    if Panel.lastText[name] == joined then return end
    Panel.lastText[name] = joined
    game.ModifyTextBox({ Id = ScreenAnchors[name], RawText = lines[1] or "" })
    for i = 2, #lines do
        game.ModifyTextBox({ Id = ScreenAnchors[name], RawText = lines[i], Append = true, NumLineBreaks = 1 })
    end
end

-- The marker under Melinoe. Attached to the hero, tinted red or green, shown
-- only while an insta-kill is winding up.
--
-- This is the half that matters: during a 999 wind-up the player is watching
-- their character and the arena, not a box in the corner. The panel says what
-- to do once; the marker says whether they have done it yet, with no eye
-- movement. Same technique as RealHecate's ground marker, attached to the hero
-- instead of an enemy.
-- Sprite, not a light: a light adds to whatever the floor already is and
-- clips toward white. RealHecate learned this over roughly fifteen playtest
-- cycles; see its DESIGN.md.
--
-- Colour is CreateAnimation's Color argument as {R, G, B, A} in **0-255**, not
-- the 0-1 the animation data itself uses. Two scales for the same idea, and
-- getting it backwards yields a black tint that looks like nothing. Tinting
-- the hero with SetColor would recolour Melinoe herself, not the marker.
--
-- Because the colour lives on the animation, changing it means stopping and
-- recreating -- cheap, since it only happens when safe/unsafe actually flips,
-- not every tick.
--
-- GUARD: do not pass Group. RealHecate's header records that copying a Group
-- from the animation's own data filed the sprite into a render group that
-- never draws, and it logged success while showing nothing for ten versions.
local MARKER_ANIM = "ApolloGroundGlow"
local MARKER_SCALE = 3.0
local MARKER_SAFE = { 60, 235, 90, 220 }
local MARKER_UNSAFE = { 235, 40, 40, 220 }
local Marker = { attached = false, lastSafe = nil }

local function detachMarker(game, heroId)
    if not Marker.attached then return end
    if type(game.StopAnimation) == "function" then
        game.StopAnimation({ Name = MARKER_ANIM, DestinationId = heroId })
    end
    Marker.attached = false
    Marker.lastSafe = nil
end

local function setMarker(game, state)
    if not settings.values.Enabled or not settings.values.GroundMarker then
        state = nil
    end
    local hero = game.CurrentRun and game.CurrentRun.Hero
    local heroId = hero and hero.ObjectId
    if heroId == nil then return end

    -- No insta-kill, or we cannot justify a colour: take the marker away.
    -- Showing a colour we are not sure of is the one failure this feature
    -- cannot have, so "unknown" is treated exactly like "no attack".
    if state == nil or state.safe == nil then
        detachMarker(game, heroId)
        return
    end

    if Marker.attached and Marker.lastSafe == state.safe then return end
    detachMarker(game, heroId)
    if type(game.CreateAnimation) ~= "function" then return end
    game.CreateAnimation({
        Name = MARKER_ANIM,
        DestinationId = heroId,
        Scale = MARKER_SCALE,
        Color = state.safe and MARKER_SAFE or MARKER_UNSAFE,
    })
    Marker.attached = true
    Marker.lastSafe = state.safe
end

-- The panel box tinted to match, so peripheral vision catches the flip even
-- when the text goes unread.
local function setPanelTint(game, state)
    if not Panel.created then return end
    local tint = LAYOUT.PANEL_COLOR
    if state ~= nil and state.safe ~= nil then
        tint = state.safe and LAYOUT.SAFE_COLOR or LAYOUT.UNSAFE_COLOR
    end
    if Panel.lastTint ~= tint then
        Panel.lastTint = tint
        game.SetColor({ Id = ScreenAnchors["Background"], Color = tint })
    end
end

local function renderPanel(game, primary)
    writeIfChanged(game, "HeaderStatus", CONFIG.headerText(primary))

    local now = (game.GetTime and game.GetTime({})) or 0
    local block = CONFIG.computeNowBlock(game, primary, now)
    writeIfChanged(game, "NowName", block.name)
    writeIfChanged(game, "NowDescription", block.description)
    writeIfChanged(game, "NowCombo", block.combo)

    local fraction = block.barFraction or 0
    if Panel.lastBarFraction ~= fraction then
        Panel.lastBarFraction = fraction
        game.SetScaleX({ Id = ScreenAnchors["NowBar"], Fraction = fraction * (LAYOUT.BAR_WIDTH_PX / LAYOUT.RECT_BASE_WIDTH) })
    end

    local shadow = CONFIG.findShadow(game, primary.ObjectId)
    writeIfChanged(game, "Duplicate", CONFIG.duplicateLine(shadow))

    writeMultilineIfChanged(game, "Milestone", CONFIG.milestoneLines(primary))
    writeMultilineIfChanged(game, "Status", CONFIG.statusLines(game, primary))

    local gridRows = CONFIG.gridRows(game, primary)
    local gridLines = { "UNAVAILABLE" }
    for _, row in ipairs(gridRows) do gridLines[#gridLines + 1] = row end
    writeMultilineIfChanged(game, "Grid", gridLines)

    -- Stage 4. Overrides the NOW block while an insta-kill is up: its label and
    -- fixed instruction replace the ordinary lines, since nothing else on the
    -- panel matters for those 3.77 seconds.
    local safeState = CONFIG.safeZoneState(game, primary)
    if safeState ~= nil then
        writeIfChanged(game, "NowDescription", safeState.instruction)
        if safeState.bubbles then
            writeIfChanged(game, "NowCombo", "2 big bubbles")
        end
    end
    setMarker(game, safeState)
    setPanelTint(game, safeState)
end

-- The one real Chronos if he is alive; a live shadow only as a fallback (a
-- shadow with no paired real fight is not an expected scenario, but this
-- keeps the panel showing SOMETHING rather than nothing if it ever happens).
-- Returns nil, meaning "no fight", when neither Enabled nor Panel holds --
-- checked every tick so toggling either via hot reload takes effect within
-- one POLL_INTERVAL, no restart needed.
local function findPrimary(game)
    if not settings.values.Enabled or not settings.values.Panel then return nil end
    local active = game.ActiveEnemies
    if type(active) ~= "table" then return nil end
    local fallback = nil
    for _, enemy in pairs(active) do
        if type(enemy) == "table" and CONFIG.isTrackedChronos(enemy) then
            if enemy.Name == "Chronos" then return enemy end
            fallback = fallback or enemy
        end
    end
    return fallback
end

-- One long-lived poll thread for the whole mod session, not one per fight --
-- unlike RealHecate's watchClones, there is nothing here that needs
-- retiring: a single "is a tracked Chronos alive" check covers every
-- teardown path in spec section 4.4 (phase change, Chronos dying, player
-- dying, leaving the room) uniformly, because all four end with Chronos gone
-- from game.ActiveEnemies. See DESIGN.md.
local function watchFight(game, generation)
    while true do
        if Panel.generation ~= generation then return end
        local primary = findPrimary(game)
        if primary == nil then
            setPanelVisible(game, false)
        else
            setPanelVisible(game, true)
            local ok, err = pcall(renderPanel, game, primary)
            if not ok then
                logWarn("panel render failed this tick: " .. tostring(err))
            end
        end
        game.wait(POLL_INTERVAL)
    end
end

-- Idempotent: creates anchors and starts the watcher at most once. Called
-- from on_ready (first load) and on_reload (so flipping Panel/Enabled on in
-- the .cfg and hot-reloading picks it up without a restart).
local function ensurePanel(game)
    if not settings.values.Enabled or not settings.values.Panel then return end
    if not Panel.created then createPanelAnchors(game) end
    if not Panel.watcherStarted then
        Panel.watcherStarted = true
        Panel.generation = Panel.generation + 1
        game.thread(watchFight, game, Panel.generation)
    end
end

-- =============================================================================
-- Install
-- =============================================================================

local function installHooks(game)
    local ModUtil = game.ModUtil
    if ModUtil == nil or ModUtil.Path == nil or ModUtil.Path.Wrap == nil then
        logWarn("ModUtil.Path.Wrap unavailable; hooks not installed")
        return false
    end

    -- Wraps every enemy's weapon selection in the game -- SelectWeapon is not
    -- Chronos-specific -- but isTrackedChronos exits immediately for anything
    -- else, so the cost elsewhere is one extra call.
    -- Stage 4. GetTargetId (EnemyAILogic.lua:5372) is where the game picks the
    -- ClockFacePoint that Time Burst makes safe -- TargetFromGroup =
    -- "ClockFacePoints", TargetMinDistance = 800. Let it choose, then read the
    -- answer: the same "submit to the game's own judge" pattern WheresEris
    -- uses, so the marker can never point somewhere vanilla would not have.
    -- Post-wrap only; the return value is passed through untouched.
    ModUtil.Path.Wrap("GetTargetId", function(base, enemy, aiData)
        local targetId = base(enemy, aiData)
        local ok = pcall(function()
            if CONFIG.isTrackedChronos(enemy)
                and aiData ~= nil and aiData.TargetFromGroup == "ClockFacePoints" then
                enemy[SAFE.TARGET_FIELD] = targetId
            end
        end)
        if not ok then enemy[SAFE.TARGET_FIELD] = nil end
        return targetId
    end)

    ModUtil.Path.Wrap("SelectWeapon", function(base, enemy)
        if not settings.values.Enabled or not CONFIG.isTrackedChronos(enemy) then
            return base(enemy)
        end

        -- Re-entrancy guard -- see the file header. Only the OUTERMOST call
        -- logs; every recursive call this attack decision makes falls straight
        -- to base with no extra work.
        if enemy.ChronosAssist_InSelectWeapon then
            return base(enemy)
        end

        -- Captured BEFORE base runs: a combo's last step clears
        -- enemy.ActiveWeaponCombo internally (EnemyAILogic.lua:1301-1303), so
        -- reading it only after the call would miss that this pick was
        -- combo-driven.
        local comboBefore = enemy.ActiveWeaponCombo
        local lastPhase = enemy.ChronosAssist_LastPhase

        enemy.ChronosAssist_InSelectWeapon = true
        local ok, weapon = pcall(base, enemy)
        enemy.ChronosAssist_InSelectWeapon = false
        if not ok then error(weapon, 0) end

        -- A logging failure must not take a real attack decision down with it;
        -- vanilla has already produced a working weapon pick by this point.
        local okLog, err = pcall(function()
            if lastPhase == nil then
                CONFIG.logPhaseBegin(enemy, "first seen")
            elseif lastPhase ~= enemy.CurrentPhase then
                CONFIG.logPhaseBegin(enemy, "phase transition")
            end
            enemy.ChronosAssist_LastPhase = enemy.CurrentPhase

            local eligible, blocked = CONFIG.scanEligibility(game, enemy)
            CONFIG.logAttack(game, enemy, weapon, comboBefore, enemy.ActiveWeaponComboIndex, eligible, blocked)

            -- Stamped for the panel's poll thread (a separate coroutine, so it
            -- cannot just read locals here): the wind-up's start time and total
            -- duration, and which combo (if any) drove this pick, captured the
            -- same pre-call way stage 1's logging does and for the same reason.
            local weaponData = game.WeaponData and game.WeaponData[weapon]
            local aiData = weaponData and weaponData.AIData
            enemy.ChronosAssist_WindupStart = (game.GetTime and game.GetTime({})) or 0
            enemy.ChronosAssist_WindupTotal = aiData and aiData.PreAttackDuration or nil
            enemy.ChronosAssist_ComboForNow = comboBefore
        end)
        if not okLog then
            logWarn("logging failed, leaving the attack untouched: " .. tostring(err))
        end

        return weapon
    end)

    return true
end

-- =============================================================================
-- Boot
-- =============================================================================

loadSettings()

-- Runs ONCE. A second call would nest a second ModUtil.Path.Wrap around
-- SelectWeapon -- see MODDING_HADES2.md section 2, "guard your hook
-- registration". reload.auto_single() already guarantees this for us, the way
-- every sibling mod relies on it.
local function on_ready(game)
    if installHooks(game) then
        local okPanel, errPanel = pcall(ensurePanel, game)
        if not okPanel then
            logWarn("panel install failed, logging still works: " .. tostring(errPanel))
        end
        logAlways(("installed; logging is %s; panel is %s%s")
            :format(settings.values.Enabled and "on" or "off",
                    (settings.values.Enabled and settings.values.Panel) and "on" or "off",
                    settings.persistent and "" or " (settings not persisted)"))
    end
end

-- Runs on load AND on every hot reload, so it must be safe to repeat.
-- Re-reads settings, and lazily creates/starts the panel if Panel/Enabled was
-- just turned on -- ensurePanel is idempotent, so this is safe to call every
-- reload even when the panel already exists.
local function on_reload()
    loadSettings()
    local okPanel, errPanel = pcall(ensurePanel, rom.game)
    if not okPanel then
        logWarn("panel install failed on reload: " .. tostring(errPanel))
    end
    logAlways(("settings reloaded; logging is %s; panel is %s")
        :format(settings.values.Enabled and "on" or "off",
                (settings.values.Enabled and settings.values.Panel) and "on" or "off"))
end

if reload ~= nil and type(reload.auto_single) == "function" then
    local loader = reload.auto_single()
    modutil.once_loaded.game(function()
        local ok, err = pcall(function()
            local game = rom.game
            if game == nil then
                logWarn("rom.game is nil; not installing")
                return
            end
            loader.load(function() on_ready(game) end, on_reload)
        end)
        if not ok then
            logWarn("install failed, plugin inactive: " .. tostring(err))
        end
    end)
else
    -- ReLoad is a declared dependency, but a profile can be missing it.
    -- Falling back costs hot reload and nothing else.
    logWarn("SGG_Modding-ReLoad unavailable; installing without hot reload")
    modutil.once_loaded.game(function()
        local ok, err = pcall(function()
            local game = rom.game
            if game == nil then
                logWarn("rom.game is nil; not installing")
                return
            end
            on_ready(game)
        end)
        if not ok then
            logWarn("install failed, plugin inactive: " .. tostring(err))
        end
    end)
end

-- Exposed for the test suite only. The game ignores the return value of a
-- plugin chunk, so this costs nothing at runtime.
return {
    CONFIG = CONFIG,
    settings = settings,
    saveSetting = function(key, value) settings.values[key] = value end,
    ensurePanel = ensurePanel,
    ScreenAnchors = ScreenAnchors,
    Panel = Panel,
    LAYOUT = LAYOUT,
    POLL_INTERVAL = POLL_INTERVAL,
}
