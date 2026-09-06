-- Mock ReturnOfModding surface: rom.log, rom.config, rom.mods, rom.paths.
-- Records what the plugin did so the suite can assert on it. No ImGui here --
-- stage 1 ships no panel, so there is nothing for one to draw.
local M = { logs = {}, saves = 0 }

-- ------------------------------------------------------------ rom.config ----
-- Mirrors the primitives Chalk is built on: config_file:new(path, true),
-- :bind(section, key, default, description) -> entry, entry:get()/:set(),
-- and config_file:save().
local function makeConfig(initial, opts)
  opts = opts or {}
  local store = {}
  for k, v in pairs(initial or {}) do store[k] = v end
  M.store = store

  local file
  file = {
    bind = function(_, section, key, default, description)
      M.bound = M.bound or {}
      M.bound[key] = { section = section, default = default, description = description }
      if store[key] == nil then store[key] = default end
      return {
        get = function() return store[key] end,
        set = function(_, v) store[key] = v end,
      }
    end,
    save = function() M.saves = M.saves + 1 end,
  }

  return {
    config_file = {
      new = function(_, path, save)
        if opts.throw then error("simulated config_file failure") end
        M.configPath = path
        return file
      end,
    },
  }
end

function M.install(game, configOpts, configInitial, modutilOpts)
  M.logs = {}
  M.saves = 0
  M.bound = nil
  M.store = nil
  M.configPath = nil
  M.pendingGameLoad = nil
  M.onReady = nil
  M.onReload = nil

  rom = {
    game = game,
    log = {
      info = function(m) M.logs[#M.logs + 1] = m end,
      -- Faithful to the real binding: rom.log.error RAISES. Any use of it from
      -- the main chunk kills the module load. Encoded here so the mistake
      -- cannot come back unnoticed.
      error = function(m) error(m, 2) end,
      warning = function(m) M.logs[#M.logs + 1] = "WARN " .. m end,
    },
    path = { combine = function(a, b) return a .. "\\" .. b end },
    paths = { config = function() return "C:\\fake\\config" end },
    mods = {
      ["LuaENVY-ENVY"] = { auto = function() end },
      ["SGG_Modding-ModUtil"] = {
        once_loaded = { game = function(cb) M.pendingGameLoad = cb end },
      },
      -- ReLoad's auto_single().load(on_ready, on_reload) calls both on first
      -- load; a hot reload later calls on_reload again. Recorded so the suite
      -- can drive a reload without a game.
      ["SGG_Modding-ReLoad"] = {
        auto_single = function()
          return {
            load = function(on_ready, on_reload)
              M.onReady, M.onReload = on_ready, on_reload
              on_ready()
              on_reload()
            end,
          }
        end,
      },
    },
  }

  if modutilOpts and modutilOpts.noReload then
    rom.mods["SGG_Modding-ReLoad"] = nil
  end

  if modutilOpts and modutilOpts.absent then
    rom.mods["SGG_Modding-ModUtil"] = { once_loaded = { game = function(cb) M.pendingGameLoad = cb end } }
  end

  -- A real branch, not an `a and b and nil or c` chain: that always yields c in
  -- Lua and would silently install a working backend for the "absent" scenario.
  if not (configOpts and configOpts.absent) then
    rom.config = makeConfig(configInitial, configOpts)
  end

  _PLUGIN = { guid = "Adicon-ChronosAssist" }
end

function M.logsContaining(needle)
  local out = {}
  for _, line in ipairs(M.logs) do
    if tostring(line):find(needle, 1, true) then out[#out + 1] = line end
  end
  return out
end

return M
