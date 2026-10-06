local mod = RegisterMod("Run Logger", 1)
local json = require("json")

if not (REPENTOGON and ImGui) then
    Isaac.DebugString("Run Logger: REPENTOGON is required; mod disabled")
    return
end

-- ============================================================
-- RUN LOGGER
--
-- Logs every run (items, pedestals, damage, floors, transformations) and keeps
-- aggregate stats for an in-game ImGui window ("runlogger ui" in the console).
--
-- STORAGE: mod:SaveData() writes exactly one file per mod per game save slot
-- (save1.dat, save2.dat, ...) and the sandbox has no io library, so each slot's
-- file holds everything:
--   line 1:   RLOG2 {"version": N, "settings": {...}, "recent": [...]}
--   next:     the aggregate stats as plain text lines (see encodeStatsBlock)
--   --LOG--   separator line
--   after:    the run log, one JSON run object per line (NDJSON)
-- This game's json.decode is far too slow on large input (a 225 KB stats object
-- took about 6 seconds), so only small JSON is ever decoded: the header, and one
-- run at a time. Stats are plain text decoded at string-pattern speed, and the
-- log is handled as a plain string (find/sub/concat run at C speed).
--
-- Stats are derived data and can always be rebuilt from the log
-- ("runlogger rebuildstats"). The log is capped (see Settings), so a rebuild
-- only sees runs still in it. stats.recent holds compact summaries of the last
-- runs so the window never has to decode full run records.
-- ============================================================

local AggregateStats = {}

local STATS_VERSION = 15

local function normalizeStage(stage, stageType)
    return stage or 0
end

local function floorKey(stage, stageType)
    return string.format("%d_%d", math.floor(normalizeStage(stage, stageType)), math.floor(stageType or 0))
end

-- stage_type: 0 original, 1 WotL, 2 Afterbirth, 4 Repentance, 5 Repentance alt.
local FLOOR_NAMES = {
    [1]  = { [0] = "Basement", [1] = "Cellar", [2] = "Burning Basement", [4] = "Downpour", [5] = "Dross" },
    [3]  = { [0] = "Caves", [1] = "Catacombs", [2] = "Flooded Caves", [4] = "Mines", [5] = "Ashpit" },
    [5]  = { [0] = "Depths", [1] = "Necropolis", [2] = "Dank Depths", [4] = "Mausoleum", [5] = "Gehenna" },
    [7]  = { [0] = "Womb", [1] = "Utero", [2] = "Scarred Womb", [4] = "Corpse" },
    [9]  = { [0] = "Blue Womb" },
    [10] = { [0] = "Sheol", [1] = "Cathedral" },
    [11] = { [0] = "Dark Room", [1] = "Chest" },
    [12] = { [0] = "Void" },
    [13] = { [0] = "Home" },
}

local function floorLabel(stage, stageType)
    local base = (stage <= 8) and (stage - (stage - 1) % 2) or stage
    local names = FLOOR_NAMES[base]
    local name = names and names[stageType]
    if not name then return "Stage " .. stage .. " (type " .. tostring(stageType) .. ")" end
    if stage <= 8 then name = name .. (stage % 2 == 1 and " I" or " II") end
    return name
end

-- Greed/Greedier and challenges use different floor scales, so they are
-- excluded from depth stats (skipped, not counted as 0).
local function isStandardRun(run)
    return (run.difficulty or 0) < 2 and (run.challenge or 0) == 0
end

-- Deepest stage reached. GetStage() goes backward after the Ascent, so this
-- takes the max over levels_visited; floor_reached covers older runs.
local function runMaxDepth(run)
    local best = normalizeStage(run.floor_reached, run.stage_type_reached)
    for _, lv in ipairs(run.levels_visited or {}) do
        local d = normalizeStage(lv.stage, lv.stage_type)
        if d > best then best = d end
    end
    return best
end

local function runModeKey(run)
    if (run.challenge or 0) ~= 0 then return "challenge" end
    local d = run.difficulty or 0
    if d >= 2 then return "greed" end
    if d == 1 then return "hard" end
    return "normal"
end

local FRAMES_PER_MIN = 3600   -- the game runs at 60 frames per second
local MIN_EXPOSURE_MIN = 2    -- hits/min is only shown with at least this much total exposure

-- Intentional damage, ignore
local TOLL_SOURCES = {
    ["6_5"]     = true, -- devil beggar
    ["6_2"]     = true, -- blood donation machine
    ["0_10003"] = true, -- the door to the Mausoleum
    ["5_52"]    = true, -- spiked chest
}

local function isToll(e)
    if TOLL_MASK ~= nil and e.damage_flags ~= nil and (math.floor(e.damage_flags) & TOLL_MASK) ~= 0 then
        return true
    end
    local t, v = e.source_type, e.source_variant
    return t ~= nil and v ~= nil and TOLL_SOURCES[string.format("%d_%d", math.floor(t), math.floor(v))] == true
end

local function freshBucket()
    return { items = {}, sources = {}, floors = {}, forms = {}, totalRuns = 0, completedRuns = 0,
             wins = 0, hitsSum = 0, floorRuns = 0, floorSum = 0,
             allHits = 0, allFrames = 0, tollHits = 0 }
end

local function freshStats()
    return { version = STATS_VERSION, byChar = {}, recent = {} }
end

-- One bucket per (character, mode); filters merge buckets on demand.
local function getBucket(stats, character, modeKey)
    local key = tostring(character or -1) .. ":" .. modeKey
    local b = stats.byChar[key]
    if not b then
        b = freshBucket()
        b.character, b.mode = tostring(character or -1), modeKey
        stats.byChar[key] = b
    end
    return b
end

-- Real hits per floor, using the same iframe logic as countRealHits below.
local function realHitsByFloor(damageEvents)
    local perFloor, invulnerableUntil = {}, -1
    for _, e in ipairs(damageEvents) do
        if (e.amount or 0) > 0 and (e.time or 0) >= invulnerableUntil and not isToll(e) then
            local k = floorKey(e.floor, e.stage_type)
            perFloor[k] = (perFloor[k] or 0) + 1
            invulnerableUntil = e.time + (e.iframes or 0)
        end
    end
    return perFloor
end

-- Times (frames) of a run's real hits, same iframe logic as countRealHits.
local function realHitTimes(damageEvents)
    local times, invulnerableUntil = {}, -1
    for _, e in ipairs(damageEvents) do
        local t = e.time or 0
        if (e.amount or 0) > 0 and t >= invulnerableUntil and not isToll(e) then
            times[#times + 1] = t
            invulnerableUntil = t + (e.iframes or 0)
        end
    end
    return times
end

local function ensureItemEntry(bucket, id)
    for _, entry in ipairs(bucket.items) do
        if entry.id == id then return entry end
    end
    local entry = { id = id, seen = 0, seenBlind = 0, encounteredRunCount = 0,
                    pickedUp = 0, pickedUpBlind = 0, pickUpFloorSum = 0, pickUpFloorCount = 0,
                    runCount = 0, floorRunCount = 0, floorSum = 0, winCount = 0,
                    hitsAfter = 0, framesAfter = 0 }
    table.insert(bucket.items, entry)
    return entry
end

-- Keyed on the (type, variant) PAIR: a bare type (0, 9, ...) covers many
-- distinct sources, and the variant is what tells them apart.
local function ensureSourceEntry(bucket, sourceType, sourceVariant)
    for _, entry in ipairs(bucket.sources) do
        if entry.sourceType == sourceType and entry.sourceVariant == sourceVariant then
            return entry
        end
    end
    local entry = { sourceType = sourceType, sourceVariant = sourceVariant, hitCount = 0 }
    table.insert(bucket.sources, entry)
    return entry
end

-- One entry per transformation name (each is logged once per run, when gained).
local function ensureFormEntry(bucket, name)
    for _, entry in ipairs(bucket.forms) do
        if entry.name == name then return entry end
    end
    local entry = { name = name, gained = 0, completed = 0, wins = 0,
                    gainFloorSum = 0, gainFloorCount = 0, hitsAfter = 0, framesAfter = 0 }
    table.insert(bucket.forms, entry)
    return entry
end

  -- Entity types whose damage is credited to whatever spawned them: tears (2),
  -- bombs (4), lasers (7), projectiles (9) and effects such as creep and fire jets (1000).
local FOLD_INTO_SPAWNER = { [2] = true, [4] = true, [7] = true, [9] = true, [1000] = true }
local ENTITY_PLAYER = 1

 -- Maps a raw damage event to the (type, variant) it is credited to. A folded type
  -- with a real spawner is credited to that spawner's own (type, variant). Negative
  -- types are pseudo-types:
  --   -2: environmental (0,0) hits, variant = the damage-flags bitmask
  -- The rest stand for a folded entity type, packed as type * 100000 + variant so
  -- they never merge with other rows:
  --   -3: logged before spawner tracking (no spawner field at all)
  --   -4: spawned by the player (your own tear, bomb, ...)
  --   -5: the game reported no usable spawner (-1 unknown, 0 none)
local function resolveAttribution(dmg)
    local t, v = dmg.source_type, dmg.source_variant
    if t == 0 and v == 0 and dmg.damage_flags ~= nil then
        return -2, dmg.damage_flags
    end
    local st = dmg.spawner_type
    if FOLD_INTO_SPAWNER[t] and st == nil then
        return -3, math.floor(t) * 100000 + math.floor(v)
    end
    if FOLD_INTO_SPAWNER[t] and st == ENTITY_PLAYER then
        return -4, math.floor(t) * 100000 + math.floor(v) -- hurt by something you spawned
    end
    if FOLD_INTO_SPAWNER[t] and st and st > 0 and st ~= ENTITY_PLAYER then
        return st, dmg.spawner_variant or 0
    end
    if FOLD_INTO_SPAWNER[t] and st and st <= 0 then
        return -5, math.floor(t) * 100000 + math.floor(v) -- no usable spawner: unknown (-1) or none (0)
    end
    return t, v
end

-- Compact per-run summary for the Recent Runs tab. The killer is stored as the
-- attributed (type, variant) pair and named at display time.
local RECENT_KEPT = 50

local function summarizeRun(run)
    local outcome
    if run.won == true then outcome = "won"
    elseif run.won == false then outcome = "died"
    else outcome = "abandoned" end

    local kt, kv
    if outcome == "died" and run.death_source then
        local ds = run.death_source
        kt, kv = resolveAttribution({
            source_type = ds.type, source_variant = ds.variant,
            spawner_type = ds.spawner_type, spawner_variant = ds.spawner_variant,
            damage_flags = ds.damage_flags })
    end

    local events = run.damage_events or {}
    local hits = (#events > 0) and #realHitTimes(events) or (run.hits_taken or 0)
    return {
        ts = run.timestamp or "?", character = tostring(run.character or -1),
        mode = runModeKey(run), depth = runMaxDepth(run), hits = hits,
        items = #(run.items or {}), outcome = outcome, kt = kt, kv = kv,
        seed = run.seed, slot = run.slot,
    }
end

-- seen/pickedUp count raw events (repeat pickups count); runCount/winCount/
-- floorRunCount are deduped per item per run so multi-pickups don't inflate
-- per-run averages. Abandoned runs count toward totals but never as wins or
-- losses, and non-standard runs are skipped for floor stats.
local function recordRunIntoBucket(bucket, run)
    bucket.totalRuns = bucket.totalRuns + 1

    local completed = run.won ~= nil
    local standard  = isStandardRun(run)
    local depth     = (completed and standard) and runMaxDepth(run) or nil
    local hitTimes = realHitTimes(run.damage_events or {})

    if completed then
        bucket.completedRuns = bucket.completedRuns + 1
        if run.won then bucket.wins = bucket.wins + 1 end
        bucket.hitsSum = bucket.hitsSum + #hitTimes
        if depth then
            bucket.floorRuns = bucket.floorRuns + 1
            bucket.floorSum  = bucket.floorSum + depth
        end
    end

    local encounteredThisRun = {}
    for _, spawn in ipairs(run.item_spawns or {}) do
        local entry = ensureItemEntry(bucket, spawn.id)
        entry.seen = entry.seen + 1
        if spawn.curse_of_blind then entry.seenBlind = entry.seenBlind + 1 end
        encounteredThisRun[spawn.id] = true
    end
    for id in pairs(encounteredThisRun) do
        local entry = ensureItemEntry(bucket, id)
        entry.encounteredRunCount = entry.encounteredRunCount + 1
    end

    local pickedUpThisRun = {}
    for _, item in ipairs(run.items or {}) do
        local entry = ensureItemEntry(bucket, item.id)
        entry.pickedUp = entry.pickedUp + 1
        if item.curse_of_blind then entry.pickedUpBlind = entry.pickedUpBlind + 1 end
        if standard then
            entry.pickUpFloorSum = entry.pickUpFloorSum + normalizeStage(item.floor, item.stage_type)
            entry.pickUpFloorCount = entry.pickUpFloorCount + 1
        end
        pickedUpThisRun[item.id] = true
    end

    if completed then
        for id in pairs(pickedUpThisRun) do
            local entry = ensureItemEntry(bucket, id)
            entry.runCount = entry.runCount + 1
            if run.won then entry.winCount = entry.winCount + 1 end
            if depth then
                entry.floorRunCount = entry.floorRunCount + 1
                entry.floorSum = entry.floorSum + depth
            end
        end
    end

    -- amount == 0 events (blocked/negated hits) would pollute the ranking.
    for _, dmg in ipairs(run.damage_events or {}) do
        if (dmg.amount or 0) > 0 then
            local t, v = resolveAttribution(dmg)
            local entry = ensureSourceEntry(bucket, t, v)
            entry.hitCount = entry.hitCount + 1
            if isToll(dmg) then bucket.tollHits = bucket.tollHits + 1 end
        end
    end

    -- Transformations: each form is logged once per run, when first gained.
    local gainedThisRun = {}
    for _, tf in ipairs(run.transformations or {}) do
        if tf.name and not gainedThisRun[tf.name] then
            gainedThisRun[tf.name] = tf
            local entry = ensureFormEntry(bucket, tf.name)
            entry.gained = entry.gained + 1
            if completed then
                entry.completed = entry.completed + 1
                if run.won then entry.wins = entry.wins + 1 end
            end
            if standard and tf.floor then
                entry.gainFloorSum = entry.gainFloorSum + normalizeStage(tf.floor, tf.stage_type)
                entry.gainFloorCount = entry.gainFloorCount + 1
            end
        end
    end

    -- Exposure: for each item, the real hits and frames between its first pickup
    -- in this run and the run's end (all modes, completed or abandoned: it is a
    -- rate, so a truncated run is still valid exposure). allHits/allFrames are
    -- the same quantities for the whole run, the baseline to compare against.
    local endTime, startTime = run.end_time, run.start_time or 0
    if endTime and endTime >= startTime then
        bucket.allHits = bucket.allHits + #hitTimes
        bucket.allFrames = bucket.allFrames + (endTime - startTime)
        local firstPickup = {}
        for _, item in ipairs(run.items or {}) do
            if item.time and firstPickup[item.id] == nil then firstPickup[item.id] = item.time end
        end
        for id, t in pairs(firstPickup) do
            if t <= endTime then
                local entry = ensureItemEntry(bucket, id)
                local n = 0
                for _, ht in ipairs(hitTimes) do
                    if ht >= t then n = n + 1 end
                end
                entry.hitsAfter = entry.hitsAfter + n
                entry.framesAfter = entry.framesAfter + (endTime - t)
            end
        end
        -- Same exposure measure, from the frame each transformation was gained.
        for name, tf in pairs(gainedThisRun) do
            local t = tf.time
            if t and t <= endTime then
                local entry = ensureFormEntry(bucket, name)
                local n = 0
                for _, ht in ipairs(hitTimes) do
                    if ht >= t then n = n + 1 end
                end
                entry.hitsAfter = entry.hitsAfter + n
                entry.framesAfter = entry.framesAfter + (endTime - t)
            end
        end
    end

    -- Per-floor exposure: runs that visited each floor, and real hits on it.
    if standard then
        local visited = {}
        for _, lv in ipairs(run.levels_visited or {}) do
            visited[floorKey(lv.stage, lv.stage_type)] = true
        end
        local hitsByFloor = realHitsByFloor(run.damage_events or {})
        for k in pairs(hitsByFloor) do visited[k] = true end
        if #(run.levels_visited or {}) == 0 then -- older run: use floors evidenced by logged events
            visited[floorKey(run.floor_reached, run.stage_type_reached)] = true
            for _, list in ipairs({ run.items or {}, run.item_spawns or {} }) do
                for _, e in ipairs(list) do visited[floorKey(e.floor, e.stage_type)] = true end
            end
        end
        for k in pairs(visited) do
            local f = bucket.floors[k]
            if not f then f = { runs = 0, hits = 0 }; bucket.floors[k] = f end
            f.runs = f.runs + 1
            f.hits = f.hits + (hitsByFloor[k] or 0)
        end
    end
end

function AggregateStats.RecordRun(stats, run)
    recordRunIntoBucket(getBucket(stats, run.character, runModeKey(run)), run)
    stats.recent = stats.recent or {}
    table.insert(stats.recent, 1, summarizeRun(run))
    while #stats.recent > RECENT_KEPT do table.remove(stats.recent) end
end

local ITEM_FIELDS = { "seen", "seenBlind", "encounteredRunCount", "pickedUp", "pickedUpBlind",
                      "pickUpFloorSum", "pickUpFloorCount", "runCount", "floorRunCount",
                      "floorSum", "winCount", "hitsAfter", "framesAfter" }
local FORM_FIELDS = { "gained", "completed", "wins", "gainFloorSum", "gainFloorCount",
                     "hitsAfter", "framesAfter" }
local BUCKET_FIELDS = { "totalRuns", "completedRuns", "wins", "hitsSum", "floorRuns", "floorSum",
                        "allHits", "allFrames", "tollHits" }

-- Merges every bucket matching the filters (nil = no filter) into one view.
function AggregateStats.GetView(stats, characterKey, modeSet)
    local merged, itemIdx, srcIdx, formIdx = freshBucket(), {}, {}, {}
    for _, b in pairs(stats.byChar) do
        if (not characterKey or b.character == characterKey)
           and (not modeSet or modeSet[b.mode]) then
            for _, f in ipairs(BUCKET_FIELDS) do merged[f] = merged[f] + (b[f] or 0) end
            for _, e in ipairs(b.items) do
                local m = itemIdx[e.id]
                if not m then
                    m = { id = e.id }
                    for _, f in ipairs(ITEM_FIELDS) do m[f] = 0 end
                    itemIdx[e.id] = m; table.insert(merged.items, m)
                end
                for _, f in ipairs(ITEM_FIELDS) do m[f] = m[f] + (e[f] or 0) end
            end
            for s, f in pairs(b.floors or {}) do
                local m = merged.floors[s]
                if not m then m = { runs = 0, hits = 0 }; merged.floors[s] = m end
                m.runs = m.runs + f.runs; m.hits = m.hits + f.hits
            end
            for _, e in ipairs(b.forms or {}) do
                local m = formIdx[e.name]
                if not m then
                    m = { name = e.name }
                    for _, f in ipairs(FORM_FIELDS) do m[f] = 0 end
                    formIdx[e.name] = m; table.insert(merged.forms, m)
                end
                for _, f in ipairs(FORM_FIELDS) do m[f] = m[f] + (e[f] or 0) end
            end
            for _, e in ipairs(b.sources) do
                local k = tostring(e.sourceType) .. "_" .. tostring(e.sourceVariant)
                local m = srcIdx[k]
                if not m then
                    m = { sourceType = e.sourceType, sourceVariant = e.sourceVariant, hitCount = 0 }
                    srcIdx[k] = m; table.insert(merged.sources, m)
                end
                m.hitCount = m.hitCount + e.hitCount
            end
        end
    end
    return merged
end

-- Re-derives stats by replaying every line currently in the log. A run that
-- fails to record is skipped, so one bad record can't break every rebuild.
function AggregateStats.RebuildStatsFromLog(logString)
    local stats = freshStats()
    local count, skipped = 0, 0
    for line in logString:gmatch("[^\n]+") do
        local ok, run = pcall(json.decode, line)
        if ok and type(run) == "table" then
            local okStats, err = pcall(AggregateStats.RecordRun, stats, run)
            if okStats then
                count = count + 1
            else
                skipped = skipped + 1
                Isaac.DebugString("Run Logger: skipped a run during rebuild: " .. tostring(err))
            end
        else
            skipped = skipped + 1
            Isaac.DebugString("Run Logger: WARNING - skipped unparseable log line during rebuild")
        end
    end
    Isaac.DebugString("Run Logger: rebuilt stats from " .. tostring(count) .. " logged runs"
        .. (skipped > 0 and (" (" .. skipped .. " skipped)") or ""))
    return stats
end

-- ---- Settings (per save slot, stored in the file header) ----
local DEFAULT_SETTINGS = {
    maxStoredRuns = 300,      -- oldest runs are dropped from the log past this
    maxLogKB = 1500,          -- ...or past this much log text
    logAbandoned = true,      -- log runs that end by quitting/restarting
    minAbandonedSeconds = 60, -- abandoned runs shorter than this are dropped
}

local function loadSettings(raw)
    local s = {}
    for k, default in pairs(DEFAULT_SETTINGS) do
        local v = type(raw) == "table" and raw[k] or nil
        if type(v) == type(default) then s[k] = v else s[k] = default end
    end
    s.maxStoredRuns = math.max(1, s.maxStoredRuns)
    s.maxLogKB = math.max(100, s.maxLogKB)
    return s
end

-- ---- File format ----
local FILE_HEADER = "RLOG2 "
local LOG_SEPARATOR = "\n--LOG--\n"

local function int(v) return tostring(math.floor(v or 0)) end

-- Stats as plain text lines. Every stored number is an integer, so each line
-- decodes with a single string.match / gmatch.
--   B <character> <mode> <BUCKET_FIELDS...>
--   I <item id> <ITEM_FIELDS...>          (one per item)
--   S <source type> <variant> <hits>      (one per damage source)
--   F <stage_stagetype> <runs> <hits>     (one per floor)
--   T <name, spaces as _> <FORM_FIELDS...> (one per transformation)
local function encodeStatsBlock(stats, out)
    local keys = {}
    for k in pairs(stats.byChar) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local b = stats.byChar[key]
        local head = { "B", b.character or "-1", b.mode or "normal" }
        for _, f in ipairs(BUCKET_FIELDS) do head[#head + 1] = int(b[f]) end
        out[#out + 1] = table.concat(head, " ")
        for _, e in ipairs(b.items) do
            local row = { "I", int(e.id) }
            for _, f in ipairs(ITEM_FIELDS) do row[#row + 1] = int(e[f]) end
            out[#out + 1] = table.concat(row, " ")
        end
        for _, e in ipairs(b.sources) do
            out[#out + 1] = "S " .. int(e.sourceType) .. " " .. int(e.sourceVariant) .. " " .. int(e.hitCount)
        end
        for floorKeyText, f in pairs(b.floors or {}) do
            out[#out + 1] = "F " .. floorKeyText .. " " .. int(f.runs) .. " " .. int(f.hits)
        end
        for _, e in ipairs(b.forms or {}) do
            local row = { "T", (e.name:gsub(" ", "_")) }
            for _, f in ipairs(FORM_FIELDS) do row[#row + 1] = int(e[f]) end
            out[#out + 1] = table.concat(row, " ")
        end
    end
end

local function decodeStatsBlock(block)
    local byChar, bucket = {}, nil
    for line in block:gmatch("[^\n]+") do
        local tag = line:sub(1, 1)
        if tag == "B" then
            local ch, mode, rest = line:match("^B (%S+) (%S+) (.*)$")
            bucket = nil
            if ch then
                bucket = freshBucket()
                bucket.character, bucket.mode = ch, mode
                local i = 0
                for n in rest:gmatch("%-?%d+") do
                    i = i + 1
                    local f = BUCKET_FIELDS[i]
                    if f then bucket[f] = tonumber(n) end
                end
                byChar[ch .. ":" .. mode] = bucket
            end
        elseif bucket then
            if tag == "I" then
                local e, i = nil, 0
                for n in line:gmatch("%-?%d+") do
                    i = i + 1
                    if i == 1 then
                        e = { id = tonumber(n) }
                    else
                        local f = ITEM_FIELDS[i - 1]
                        if f then e[f] = tonumber(n) end
                    end
                end
                if e then
                    for _, f in ipairs(ITEM_FIELDS) do e[f] = e[f] or 0 end
                    bucket.items[#bucket.items + 1] = e
                end
            elseif tag == "S" then
                local t, v, h = line:match("^S (%-?%d+) (%-?%d+) (%-?%d+)$")
                if t then
                    bucket.sources[#bucket.sources + 1] =
                        { sourceType = tonumber(t), sourceVariant = tonumber(v), hitCount = tonumber(h) }
                end
            elseif tag == "F" then
                local k, r, h = line:match("^F (%S+) (%-?%d+) (%-?%d+)$")
                if k then bucket.floors[k] = { runs = tonumber(r), hits = tonumber(h) } end
            elseif tag == "T" then
                local name, rest = line:match("^T (%S+) (.*)$")
                if name then
                    local e, i = { name = (name:gsub("_", " ")) }, 0
                    for n in rest:gmatch("%-?%d+") do
                        i = i + 1
                        local f = FORM_FIELDS[i]
                        if f then e[f] = tonumber(n) end
                    end
                    for _, f in ipairs(FORM_FIELDS) do e[f] = e[f] or 0 end
                    bucket.forms[#bucket.forms + 1] = e
                end
            end
        end
    end
    return byChar
end

-- Returns envelope { log, stats, settings }, readable. Data that exists but
-- can't be decoded returns an empty envelope with readable == false, so
-- callers can refuse to overwrite it.
function AggregateStats.LoadEnvelope()
    if not mod:HasData() then
        return { log = "", stats = freshStats(), settings = loadSettings(nil) }, true
    end
    local raw = mod:LoadData()

    local nl, sepStart, sepEnd
    if raw:sub(1, #FILE_HEADER) == FILE_HEADER then
        nl = raw:find("\n", 1, true)
        if nl then sepStart, sepEnd = raw:find(LOG_SEPARATOR, nl, true) end
    end
    local ok, header = false, nil
    if sepStart then ok, header = pcall(json.decode, raw:sub(#FILE_HEADER + 1, nl - 1)) end
    if not (ok and type(header) == "table") then
        Isaac.DebugString("Run Logger: WARNING - save data unreadable")
        return { log = "", stats = freshStats(), settings = loadSettings(nil) }, false
    end

    local stats = { version = header.version,
                    byChar = decodeStatsBlock(raw:sub(nl + 1, sepStart - 1)),
                    recent = header.recent or {} }
    local log = raw:sub(sepEnd + 1)
    local rebuilt = false
    if stats.version ~= STATS_VERSION then
        stats = AggregateStats.RebuildStatsFromLog(log)
        rebuilt = true
    end
    return { log = log, stats = stats, settings = loadSettings(header.settings),
             rebuilt = rebuilt }, true
end

function AggregateStats.SaveEnvelope(envelope)
    local stats = envelope.stats
    local header = json.encode({ version = stats.version, recent = stats.recent or {},
                                 settings = envelope.settings })
    local parts = { FILE_HEADER .. header }
    encodeStatsBlock(stats, parts)
    parts[#parts + 1] = "--LOG--"
    parts[#parts + 1] = envelope.log
    mod:SaveData(table.concat(parts, "\n"))
end

-- metric: "pickedUp", "seen", "pickRate", "avgFloorReached", "winRate"
function AggregateStats.GetSortedItemStats(view, metric, ascending)
    local list = {}
    for _, entry in ipairs(view.items) do
        -- pickRate ignores pedestals seen under Curse of the Blind: those picks
        -- weren't informed decisions about the specific item.
        local informedSeen   = entry.seen - (entry.seenBlind or 0)
        local informedPicked = entry.pickedUp - (entry.pickedUpBlind or 0)
        local exposureMin = (entry.framesAfter or 0) / FRAMES_PER_MIN
        local hasExposure = exposureMin >= MIN_EXPOSURE_MIN
        table.insert(list, {
            id = entry.id, seen = entry.seen, pickedUp = entry.pickedUp,
            avgFloorReached = (entry.floorRunCount > 0) and (entry.floorSum / entry.floorRunCount) or 0,
            winRate = (entry.runCount > 0) and (entry.winCount / entry.runCount) or 0,
            pickRate = informedSeen > 0 and math.min(1, informedPicked / informedSeen) or 0,
            avgFloorFound = (entry.pickUpFloorCount > 0) and (entry.pickUpFloorSum / entry.pickUpFloorCount) or 0,
            encounterRate = (view.totalRuns > 0) and (entry.encounteredRunCount / view.totalRuns) or 0,
            runCount = entry.runCount,
            floorRunCount = entry.floorRunCount,
            foundCount = entry.pickUpFloorCount,
            exposureMin = exposureMin,
            hitsPerMin = hasExposure and ((entry.hitsAfter or 0) / exposureMin) or 0,
            -- Metrics with no data for this item (shown as "--"). Such rows sort
            -- last in either direction so they never pose as the best or worst.
            known = {
                avgFloorReached = entry.floorRunCount > 0,
                winRate = entry.runCount > 0,
                pickRate = informedSeen > 0,
                hitsPerMin = hasExposure,
            },
        })
    end
    local key = metric or "pickedUp"
    table.sort(list, function(a, b)
        local ka, kb = a.known[key] ~= false, b.known[key] ~= false
        if ka ~= kb then return ka end
        local x, y = a[key], b[key]
        if x ~= y then
            if ascending then return x < y end
            return x > y
        end
        return a.id < b.id -- deterministic order for ties
    end)
    return list
end

function AggregateStats.GetSortedSourceStats(view, ascending)
    local list = {}
    for _, entry in ipairs(view.sources) do
        table.insert(list, { sourceType = entry.sourceType,
                             sourceVariant = entry.sourceVariant,
                             hitCount = entry.hitCount })
    end
    table.sort(list, function(a, b)
        if a.hitCount ~= b.hitCount then
            if ascending then return a.hitCount < b.hitCount end
            return a.hitCount > b.hitCount
        end
        if a.sourceType ~= b.sourceType then return a.sourceType < b.sourceType end
        return a.sourceVariant < b.sourceVariant -- deterministic order for ties
    end)
    return list
end

function AggregateStats.GetSortedFormStats(view, ascending)
    local list = {}
    for _, e in ipairs(view.forms or {}) do
        local exposureMin = (e.framesAfter or 0) / FRAMES_PER_MIN
        table.insert(list, {
            name = e.name, gained = e.gained, completed = e.completed,
            rate = (view.totalRuns > 0) and (e.gained / view.totalRuns) or 0,
            winRate = (e.completed > 0) and (e.wins / e.completed) or 0,
            avgFloorGained = (e.gainFloorCount > 0) and (e.gainFloorSum / e.gainFloorCount) or 0,
            floorKnown = e.gainFloorCount > 0,
            exposureMin = exposureMin,
            hitsPerMin = (exposureMin >= MIN_EXPOSURE_MIN) and ((e.hitsAfter or 0) / exposureMin) or 0,
        })
    end
    table.sort(list, function(a, b)
        if a.gained ~= b.gained then
            if ascending then return a.gained < b.gained end
            return a.gained > b.gained
        end
        return a.name < b.name -- deterministic order for ties
    end)
    return list
end

function AggregateStats.GetFloorStats(view)
    local list = {}
    for k, f in pairs(view.floors or {}) do
        local s, t = k:match("^(%d+)_(%-?%d+)$")
        if s then
            table.insert(list, { stage = tonumber(s), stageType = tonumber(t), runs = f.runs,
                                 hits = f.hits, avgHits = f.runs > 0 and f.hits / f.runs or 0 })
        end
    end
    table.sort(list, function(a, b)
        if a.stage ~= b.stage then return a.stage < b.stage end
        return a.stageType < b.stageType
    end)
    return list
end

-- ============================================================
-- STATS OVERLAY (ImGui)
-- ============================================================

local selectedCharacterKey = nil -- nil = all characters
local selectedModeSet = nil      -- nil = all modes
local viewStats = nil            -- cached filtered/merged view
local latestStats = nil          -- cached stats table for the active slot
local settings = nil             -- cached settings table for the active slot
local cachedLog = nil            -- cached log text for the active slot (nil = not loaded or unreadable)
local cachedSlot = nil           -- the slot the caches were loaded for (nil = unknown)
local loadFailed = false         -- true when the active slot's save data couldn't be read
local activeSlot = nil           -- set by MC_POST_SAVESLOT_LOAD; nil until a slot is chosen
local settingsDirtyAt = nil      -- Isaac.GetTime() of the last unsaved settings change

-- Toggled by the "runlogger toggletestmode" command or the window checkbox.
-- Everything still tracks in memory; only the final save is skipped, so
-- flipping it mid-run is safe. In-memory only: resets on game relaunch.
local testModeEnabled = false

local function markSettingsDirty() settingsDirtyAt = Isaac.GetTime() end

local MODE_FILTERS = {
    { label = "All modes",        set = nil },
    { label = "Normal + Hard",    set = { normal = true, hard = true } },
    { label = "Normal",           set = { normal = true } },
    { label = "Hard",             set = { hard = true } },
    { label = "Greed / Greedier", set = { greed = true } },
    { label = "Challenges",       set = { challenge = true } },
}
local MODE_LABELS = {}
for i, m in ipairs(MODE_FILTERS) do MODE_LABELS[i] = m.label end

-- "COLLECTIBLE_SAD_ONION" with prefix "COLLECTIBLE_" -> "Sad Onion"
local function prettifyEnumName(name, prefix)
    local stripped = name:gsub("^" .. prefix, "")
    stripped = stripped:gsub("_", " "):lower()
    stripped = stripped:gsub("(%a)([%w']*)", function(first, rest)
        return first:upper() .. rest
    end)
    return stripped
end

local PLAYER_NAME_OVERRIDES = {
    PLAYER_BLUEBABY = "???", PLAYER_THELOST = "The Lost", PLAYER_BLACKJUDAS = "Dark Judas",
    PLAYER_LAZARUS2 = "Lazarus (Risen)", PLAYER_THEFORGOTTEN = "The Forgotten",
    PLAYER_THESOUL = "The Soul", PLAYER_JACOB2 = "Jacob (alt form)",
}

local function playerDisplayName(enumName)
    local tainted = enumName:sub(-2) == "_B"
    local base = tainted and enumName:sub(1, -3) or enumName
    local name = PLAYER_NAME_OVERRIDES[base] or prettifyEnumName(base, "PLAYER_")
    if tainted then name = "Tainted " .. name:gsub("^The ", "") end
    return name
end

local characterIdToName = {}
local characterNames, characterKeys = { "All characters" }, { false }
do
    local byId = {}
    for name, id in pairs(PlayerType) do
        if id >= 0 and name:sub(1, 7) == "PLAYER_" then byId[id] = playerDisplayName(name) end
    end
    local ids = {}
    for id in pairs(byId) do table.insert(ids, id) end
    table.sort(ids)
    for _, id in ipairs(ids) do
        table.insert(characterNames, byId[id])
        table.insert(characterKeys, tostring(id))
    end
    characterIdToName = byId
end

-- Enum-derived names are the fallback when the item config has no usable name.
-- Aliased ids: the last one iterated wins, which is fine for display.
local itemIdToName = {}
for name, id in pairs(CollectibleType) do
    itemIdToName[id] = prettifyEnumName(name, "COLLECTIBLE_")
end

local sourceIdToName = {}
for name, id in pairs(EntityType) do
    sourceIdToName[id] = prettifyEnumName(name, "ENTITY_")
end
sourceIdToName[0] = "Non-entity source"

local sourceVariantOverrides = {
    ["0_0"]      = "Unknown (pre-flag data)",  -- older hits with no damage flags; the grid enum would say "Grid: Null"
    ["0_9"]      = "Retractable Spikes",       -- the grid enum says "Grid: Spikes Onoff"
    ["0_14"]     = "Red Poop",                 -- the only poop that damages you; the enum says "Grid: Poop"
    ["0_10000"] = "Unidentified non-entity source",
    ["0_10003"] = "Mausoleum Door",
    ["1000_22"]  = "Red Creep",                -- the effect enum says "Effect: Creep Red"
    ["1000_147"] = "Fire Jet",
    -- Likely shooter, for projectile rows that can't be credited to an enemy:
    ["9_1"]      = "Bone Projectile (Bonies)",
    ["9_3"]      = "Puke Projectile (Various)",
    ["9_7"]      = "Coin Projectile (Ultra Greed)",
    ["9_8"]      = "Grid Projectile (Polty Rocks)",
}

local damageFlagList = {}
for name, bit in pairs(DamageFlag) do
    if bit ~= 0 then
        table.insert(damageFlagList, { bit = bit, name = prettifyEnumName(name, "DAMAGE_") })
    end
end
table.sort(damageFlagList, function(a, b) return a.bit < b.bit end)

local function describeDamageFlags(flags)
    local parts = {}
    for _, f in ipairs(damageFlagList) do
        if (flags & f.bit) == f.bit then table.insert(parts, f.name) end
    end
    return #parts > 0 and table.concat(parts, "+") or "No flags"
end

local function resolveSourceName(sourceType, sourceVariant)
    if sourceType == -2 then return "Environment: " .. describeDamageFlags(sourceVariant) end
    local override = sourceVariantOverrides[string.format("%d_%d", math.floor(sourceType), math.floor(sourceVariant))]
    if override then return override end
    return sourceIdToName[sourceType] or ("Type " .. tostring(sourceType))
end

-- The stored variant of legacy/environment rows is a packed value or a bitmask;
-- show something meaningful instead.
local function displayVariant(sourceType, sourceVariant)
    if sourceType <= -3 then return math.floor(sourceVariant) % 100000 end
    if sourceType == -2 then return "-" end
    return sourceVariant
end

local entityNameCache = {}
local function entityConfigName(t, v)
    local key = t .. "_" .. v
    local cached = entityNameCache[key]
    if cached ~= nil then return cached or nil end
    local name = false
    pcall(function()
        for _, subtype in ipairs({ -1, 0 }) do
            local cfg = EntityConfig.GetEntity(t, v, subtype)
            -- an unknown variant comes back as the base entity; only accept an exact match
            if cfg and cfg:GetVariant() == v then
                local n = cfg:GetName()
                if type(n) == "string" and n ~= "" and n:sub(1, 1) ~= "#" then
                    name = n
                    break
                end
            end
        end
    end)
    entityNameCache[key] = name
    return name or nil
end

  -- Optional entity_names.lua next to this file, generated from the game's
  -- entities2.xml by make_entity_names.py: { ["<type>_<variant>"] = "Name", ... }.
  -- If it is missing the other naming layers below still work.
local generatedEntityNames = {}
do
    local ok, t = pcall(require, "entity_names")
    if ok and type(t) == "table" then generatedEntityNames = t end
end
local generatedCount = 0
for _ in pairs(generatedEntityNames) do generatedCount = generatedCount + 1 end
Isaac.DebugString("Run Logger: entity name table has " .. generatedCount .. " entries")

local VARIANT_ENUMS = {
    { type = 0,    label = "Grid",       enum = GridEntityType,    prefix = "GRID_" },
    { type = 2,    label = "Tear",       enum = TearVariant,       prefix = "" },
    { type = 4,    label = "Bomb",       enum = BombVariant,       prefix = "BOMB_" },
    { type = 9,    label = "Projectile", enum = ProjectileVariant, prefix = "PROJECTILE_" },
    { type = 1000, label = "Effect",     enum = EffectVariant,     prefix = "" },
}
local variantEnumNames = {} -- ["9_1"] = "Projectile: Bone"
for _, spec in ipairs(VARIANT_ENUMS) do
    if type(spec.enum) == "table" then
        local byKey = {}
        for name, id in pairs(spec.enum) do
            if type(id) == "number" then
                local key = spec.type .. "_" .. id
                byKey[key] = byKey[key] or {}
                table.insert(byKey[key], name)
            end
        end
        for key, names in pairs(byKey) do
            table.sort(names) -- constants can share an id; pick one deterministically
            variantEnumNames[key] = spec.label .. ": " .. prettifyEnumName(names[1], spec.prefix)
        end
    end
end

-- Name for a damage-source row. Lookup order: hand override, generated entity
-- table, variant enums, live entity config, then the entity type's name with the
-- variant appended (a bare entity name would make different variants look
-- identical). The pseudo-types -3/-4/-5 are unpacked and labelled here.
local function sourceRowName(sourceType, sourceVariant)
    if sourceType == -3 then -- legacy packed type/variant, see resolveAttribution
        local packed = math.floor(sourceVariant)
        return sourceRowName(packed // 100000, packed % 100000) .. " (legacy)"
    end
    if sourceType == -5 then
        local packed = math.floor(sourceVariant)
        return sourceRowName(packed // 100000, packed % 100000) .. " (spawner unknown)"
    end
    if sourceType == -4 then
        local packed = math.floor(sourceVariant)
        return "Self-inflicted: " .. sourceRowName(packed // 100000, packed % 100000)
    end
    local key = string.format("%d_%d", math.floor(sourceType), math.floor(sourceVariant))
    local name = resolveSourceName(sourceType, sourceVariant)
    if not sourceVariantOverrides[key] then
        local better = generatedEntityNames[key] or variantEnumNames[key]
            or (sourceType > 0 and entityConfigName(sourceType, sourceVariant))
        if better then
            name = better
        elseif sourceType >= 0 and sourceVariant > 0 then
            name = name .. " (v" .. sourceVariant .. ")"
        end
    end
    return name
end

-- Repentance-era items store a localization key ("#..._NAME") instead of text.
-- If the key can't be resolved the raw value is returned unchanged.
local function localizedName(raw)
    if type(raw) == "string" and raw:sub(1, 1) == "#" then
        local ok, s = pcall(Isaac.GetString, "Items", raw)
        if ok and type(s) == "string" and s ~= "" and not s:find("^StringTable::") then
            return s
        end
    end
    return raw
end

-- In-game item name (so searches match what players see), falling back to the
-- enum-derived name. Cached per id.
local itemNameCache = {}
local function itemDisplayName(id)
    local cached = itemNameCache[id]
    if cached then return cached end
    local name
    pcall(function() name = localizedName(Isaac.GetItemConfig():GetCollectible(id).Name) end)
    if type(name) ~= "string" or name == "" or name:sub(1, 1) == "#" then
        name = itemIdToName[id] or ("Item " .. tostring(id))
    end
    itemNameCache[id] = name
    return name
end

-- ---- Caches ----
-- Opening the window must not read the file every time, so the stats and
-- settings are cached. saveRunToDisk keeps them current. Mod data is per game
-- save slot, so every cache is dropped when a slot changes or a game starts.
local function ensureCaches()
    if latestStats and settings and cachedLog then return end
    local t0 = Isaac.GetTime()
    local envelope, readable = AggregateStats.LoadEnvelope()
    loadFailed = not readable
    if not readable then
        -- Show defaults, but leave cachedLog nil so saves refuse to overwrite the file.
        latestStats = latestStats or envelope.stats
        settings = settings or envelope.settings
        return
    end
    latestStats, settings, cachedLog = envelope.stats, envelope.settings, envelope.log
    cachedSlot = activeSlot
    if envelope.rebuilt then
        -- A rebuild is slow; write the result now so it is paid exactly once
        -- instead of on every load.
        AggregateStats.SaveEnvelope({ log = cachedLog, stats = latestStats, settings = settings })
    end
    Isaac.DebugString(("Run Logger: loaded slot data in %d ms%s"):format(
        Isaac.GetTime() - t0, envelope.rebuilt and " (stats rebuilt)" or ""))
end

local function getLatestStats() ensureCaches(); return latestStats end
local function getSettings() ensureCaches(); return settings end

-- Non-loading access for in-run callbacks: never touches the disk.
local function peekSettings() return settings or DEFAULT_SETTINGS end

local function getRecentRuns() return getLatestStats().recent or {} end

local function getViewStats()
    if not viewStats then
        viewStats = AggregateStats.GetView(getLatestStats(), selectedCharacterKey, selectedModeSet)
    end
    return viewStats
end

local function invalidateCaches()
    latestStats, viewStats, settings, cachedLog, cachedSlot = nil, nil, nil, nil, nil
    loadFailed = false
end

-- An empty cached log over a file that has data means the slot's data wasn't
-- ready when the cache was filled. Never trust it: saving on top of it would
-- overwrite the real log.
local function revalidateCaches()
    if cachedLog == "" and mod:HasData() then invalidateCaches() end
end

-- ---- Window state and row helpers ----
local STATS_WINDOW_ID = "RunLoggerStatsWindow"
local statsWindowBuilt = false

local currentSortMetric = "pickedUp"
local sortAscending = false     -- Items tab: false = highest first
local sourcesAscending = false  -- Damage Sources tab: false = most hits first
local formsAscending = false    -- Transformations tab: false = gained most often first
local hideUnpickedUp = false
local searchQuery = ""
local minHitsFilter = 0

local SORT_METRIC_OPTIONS = { "pickedUp", "seen", "avgFloorReached", "winRate", "pickRate", "hitsPerMin" }

-- Each row is its own ImGui text element (needed for per-row color and
-- tooltips), so each list is a fixed POOL of pre-created elements rather than
-- an unbounded string. Hundreds of elements are far costlier than one block.
local ROW_POOL_SIZE = 200
local FLOOR_POOL_SIZE = 60
local FORM_POOL_SIZE = 20
local RECENT_POOL_SIZE = RECENT_KEPT

local ITEM_NAME_COL = 30
local SOURCE_NAME_COL = 40

local function lerp(a, b, t) return a + (b - a) * t end

-- Green at t=1 (good/safe), red at t=0 (bad/dangerous).
local function goodBadColor(t)
    t = math.max(0, math.min(1, t))
    return lerp(0.9, 0.3, t), lerp(0.25, 0.9, t), 0.3
end

-- Rows are monospace columns: names are truncated to the column width so a
-- long name can never push the other columns out of line.
local function fit(s, width)
    if #s > width then return s:sub(1, width - 2) .. ".." end
    return s
end

-- Tooltip text is printf-formatted, so a literal % must be doubled.
local function setTooltip(elementId, text)
    ImGui.SetTooltip(elementId, (text:gsub("%%", "%%%%")))
end

local function updateControl(elementId, value)
    pcall(function() ImGui.UpdateData(elementId, ImGuiData.Value, value) end)
end

-- Search ignores case and punctuation: "cricket's head", "crickets head" and
-- "cricketshead" all match.
local function searchKey(s) return (s:lower():gsub("[^%w]", "")) end

local function matchesSearch(name)
    if searchQuery == "" then return true end
    return searchKey(name):find(searchKey(searchQuery), 1, true) ~= nil
end

local function filteredSortedItems()
    local filtered = {}
    for _, entry in ipairs(AggregateStats.GetSortedItemStats(getViewStats(), currentSortMetric, sortAscending)) do
        local name = itemDisplayName(entry.id)
        if not (hideUnpickedUp and entry.pickedUp == 0) and matchesSearch(name) then
            table.insert(filtered, { entry = entry, name = name })
        end
    end
    return filtered
end

local function filteredSortedSources()
    local filtered = {}
    for _, entry in ipairs(AggregateStats.GetSortedSourceStats(getViewStats(), sourcesAscending)) do
        local name = sourceRowName(entry.sourceType, entry.sourceVariant)
        if entry.hitCount >= minHitsFilter and matchesSearch(name) then
            table.insert(filtered, { entry = entry, name = name })
        end
    end
    return filtered
end

local function itemTooltip(row)
    local desc = ""
    pcall(function()
        desc = localizedName(Isaac.GetItemConfig():GetCollectible(row.entry.id).Description or "")
    end)
    if type(desc) ~= "string" or desc:sub(1, 1) == "#" then desc = "" end
    -- Pickups can exceed pedestal sightings (starting items, items that never
    -- sat on a pedestal), so cap the "of N" figure and show the rest separately.
    local e = row.entry
    local fromPedestals = math.min(e.pickedUp, e.seen)
    local line = string.format("Picked up %d of %d sightings", fromPedestals, e.seen)
    if e.pickedUp > fromPedestals then
        line = line .. string.format(" (+%d without a pedestal, e.g. starting items)",
            e.pickedUp - fromPedestals)
    end
    local rate = ""
    if e.exposureMin >= MIN_EXPOSURE_MIN then
        local v = getViewStats()
        local overall = (v.allFrames or 0) > 0 and (v.allHits / (v.allFrames / FRAMES_PER_MIN)) or nil
        rate = string.format("\n%.2f hits/min after pickup, over %.0f min of exposure; Damage you chose to take (curse/Mausoleum doors, beggars) is not counted as a hit.", e.hitsPerMin, e.exposureMin)
        if overall then rate = rate .. string.format(" (overall %.2f)", overall) end
    end
    return string.format("%s\n%s\n%s; appeared in %.0f%% of runs%s", row.name, desc, line, e.encounterRate * 100, rate)
end

local PSEUDO_TYPE_NOTES = {
    [-3] = " (logged before spawner tracking, so it is not credited to an enemy)",
    [-4] = " (spawned by you)",
    [-5] = " (the game reported no spawner for it)",
}

local function sourceTooltip(row)
    local e = row.entry
    if e.sourceType == -2 then
        return string.format("%s\nEnvironmental damage, split by damage flags\n%d hits", row.name, e.hitCount)
    end
    local t = e.sourceType
    local note = PSEUDO_TYPE_NOTES[t] or ""
    if t <= -3 then t = math.floor(e.sourceVariant) // 100000 end -- unpack the real entity type
    return string.format("%s\nentity type %s, variant %s%s\n%d hits", row.name, tostring(t),
        tostring(displayVariant(e.sourceType, e.sourceVariant)), note, e.hitCount)
end

local function buildSummaryText()
    local slotLine = "Save slot: " .. tostring(activeSlot or 1) .. "\n"
    local s = getViewStats()
    if testModeEnabled then
        slotLine = slotLine .. "TEST MODE: runs are NOT being logged.\n"
    end
    if loadFailed then
        slotLine = slotLine .. "WARNING: this slot's save data is unreadable, so runs are NOT being logged.\n"
            .. "Delete or move the slot's save file (in the mod's data folder) to start fresh.\n"
    end
    if (s.totalRuns or 0) == 0 then return slotLine .. "No runs recorded yet." end
    local done = s.completedRuns or 0
    local winRate  = done > 0 and (s.wins / done * 100) or 0
    local avgFloor = (s.floorRuns or 0) > 0 and (s.floorSum / s.floorRuns) or 0
    local avgHits  = done > 0 and (s.hitsSum / done) or 0
    local perMin = (s.allFrames or 0) > 0 and (s.allHits / (s.allFrames / FRAMES_PER_MIN)) or 0
    local text = slotLine .. string.format(
        "Runs: %d (%d completed, %d abandoned)\nWin rate: %.1f%%\nAvg floor reached: %.1f\nAvg hits taken: %.1f\nAvg hits per minute: %.2f",
        s.totalRuns, done, s.totalRuns - done, winRate, avgFloor, avgHits, perMin)
    if (s.tollHits or 0) > 0 then
        text = text .. string.format("\nDamage you chose to take (doors, machines; not counted as hits): %d", s.tollHits)
    end
    return text
end

-- Fills one tab's element pool. formatFn(row) -> text, colorFn(row) -> r,g,b,
-- tooltipFn(row) -> text (optional). Slots past #rows are blanked so no stale
-- data lingers from a previous, longer list.
local function fillRowPool(idPrefix, poolSize, rows, formatFn, colorFn, tooltipFn)
    for i = 1, poolSize do
        local elementId = idPrefix .. i
        if i <= #rows then
            local row = rows[i]
            ImGui.UpdateText(elementId, formatFn(row))
            local r, g, b = colorFn(row)
            ImGui.SetTextColor(elementId, r, g, b, 1.0)
            if tooltipFn then setTooltip(elementId, tooltipFn(row)) end
        else
            ImGui.UpdateText(elementId, "")
            if tooltipFn then setTooltip(elementId, "") end
        end
    end
end

local function pct(x) return string.format("%.0f%%", x * 100) end
local function opt(ok, fmt, v) return ok and string.format(fmt, v) or "--" end

local function refreshItemsTab()
    fillRowPool("RunLoggerItemRow", ROW_POOL_SIZE, filteredSortedItems(),
        function(row)
            local e = row.entry
            return string.format("%-" .. ITEM_NAME_COL .. "s pickedUp:%-4d seen:%-4d encounterRate:%-5s pickRate:%-5s avgFloorFound:%-5s avgFloorReached:%-5s winRate:%-5s hits/min:%s",
                fit(row.name, ITEM_NAME_COL), e.pickedUp, e.seen, pct(e.encounterRate), pct(e.pickRate),
                opt(e.foundCount > 0, "%.1f", e.avgFloorFound),
                opt(e.floorRunCount > 0, "%.1f", e.avgFloorReached),
                opt(e.runCount > 0, "%.0f%%", e.winRate * 100),
                opt(e.exposureMin >= MIN_EXPOSURE_MIN, "%.2f", e.hitsPerMin))
        end,
        function(row)
            local e = row.entry
            if e.runCount == 0 then return 0.6, 0.6, 0.6 end -- never held in a completed run: gray, not "bad"
            return goodBadColor(e.winRate)
        end,
        itemTooltip)
end

local function refreshSourcesTab()
    local rows = filteredSortedSources()
    local maxHits = 1
    for _, r in ipairs(rows) do maxHits = math.max(maxHits, r.entry.hitCount) end
    fillRowPool("RunLoggerSourceRow", ROW_POOL_SIZE, rows,
        function(row)
            local e = row.entry
            return string.format("%-" .. SOURCE_NAME_COL .. "s hits:%d",
                fit(row.name, SOURCE_NAME_COL), e.hitCount)
        end,
        function(row)
            return goodBadColor(1 - row.entry.hitCount / maxHits) -- inverted: most hits = red
        end,
        sourceTooltip)
end

local function refreshFloorsTab()
    local rows = AggregateStats.GetFloorStats(getViewStats())
    local maxAvg = 0
    for _, r in ipairs(rows) do maxAvg = math.max(maxAvg, r.avgHits) end
    fillRowPool("RunLoggerFloorRow", FLOOR_POOL_SIZE, rows,
        function(r) return string.format("%-22s avg hits: %-5.2f (n=%d runs)",
            floorLabel(r.stage, r.stageType), r.avgHits, r.runs) end,
        function(r) return goodBadColor(maxAvg > 0 and (1 - r.avgHits / maxAvg) or 1) end)
end

local function formTooltip(r)
    local v = getViewStats()
    local text = string.format("%s\nGained in %d of %d runs", r.name, r.gained, v.totalRuns)
    if r.exposureMin >= MIN_EXPOSURE_MIN then
        local overall = (v.allFrames or 0) > 0 and (v.allHits / (v.allFrames / FRAMES_PER_MIN)) or nil
        text = text .. string.format("\n%.2f hits/min after gaining, over %.0f min of exposure; Damage you chose to take (curse/Mausoleum doors, beggars) is not counted as a hit.", r.hitsPerMin, r.exposureMin)
        if overall then text = text .. string.format(" (overall %.2f)", overall) end
    end
    return text
end

local function refreshFormsTab()
    local rows = AggregateStats.GetSortedFormStats(getViewStats(), formsAscending)
    fillRowPool("RunLoggerFormRow", FORM_POOL_SIZE, rows,
        function(r)
            return string.format("%-14s gained:%-4d rate:%-5s avgFloorGained:%-5s winRate:%-5s hits/min:%s",
                r.name, r.gained, pct(r.rate),
                opt(r.floorKnown, "%.1f", r.avgFloorGained),
                opt(r.completed > 0, "%.0f%%", r.winRate * 100),
                opt(r.exposureMin >= MIN_EXPOSURE_MIN, "%.2f", r.hitsPerMin))
        end,
        function(r)
            if r.completed == 0 then return 0.6, 0.6, 0.6 end -- only seen in abandoned runs: gray, not "bad"
            return goodBadColor(r.winRate)
        end,
        formTooltip)
end

local function refreshRecentTab()
    local rows = {}
    for _, r in ipairs(getRecentRuns()) do
        if (not selectedCharacterKey or r.character == selectedCharacterKey)
           and (not selectedModeSet or selectedModeSet[r.mode]) then
            rows[#rows + 1] = r
        end
    end
    fillRowPool("RunLoggerRecentRow", RECENT_POOL_SIZE, rows,
        function(r)
            local who = characterIdToName[tonumber(r.character)] or r.character
            local killer = r.kt and (" (" .. sourceRowName(r.kt, r.kv) .. ")") or ""
            return string.format("%-19s %-18s %-9s floor:%-3d hits:%-3d items:%-3d %s%s",
                r.ts, fit(who, 18), r.mode, r.depth, r.hits, r.items, r.outcome, killer)
        end,
        function(r)
            if r.outcome == "won" then return goodBadColor(1) end
            if r.outcome == "died" then return goodBadColor(0) end
            return 0.6, 0.6, 0.6
        end)
end

-- Pushes the cached settings into the Settings tab's controls.
local function syncSettingsControls()
    local s = getSettings()
    updateControl("RunLoggerSetMaxRuns", s.maxStoredRuns)
    updateControl("RunLoggerSetMaxKB", s.maxLogKB)
    updateControl("RunLoggerSetLogAbandoned", s.logAbandoned)
    updateControl("RunLoggerSetMinAbandoned", s.minAbandonedSeconds)
end

local function refreshStatsWindow()
    viewStats = nil
    ImGui.UpdateText("RunLoggerSummaryText", buildSummaryText())
    refreshItemsTab()
    refreshSourcesTab()
    refreshFloorsTab()
    refreshFormsTab()
    refreshRecentTab()
    syncSettingsControls()
end

-- Builds the window/tab/control/row-pool tree exactly once. Each control
-- callback receives its new value as the first argument (0-based index for
-- comboboxes, boolean for checkboxes, string for text, integer for sliders).
local function ensureStatsWindowBuilt()
    if statsWindowBuilt then return end

    -- A window left over from before a script reload still has callbacks bound
    -- to the old script's closures, so it is removed and rebuilt. If it can't
    -- be removed, adopt it rather than create duplicate ids.
    local function leftover()
        return ImGui.ElementExists(STATS_WINDOW_ID) or ImGui.ElementExists("RunLoggerSummaryText")
    end
    if leftover() then
        pcall(ImGui.RemoveWindow, STATS_WINDOW_ID)
        if leftover() then
            statsWindowBuilt = true
            return
        end
    end

    local cfg = getSettings()

    ImGui.CreateWindow(STATS_WINDOW_ID, "Run Logger Stats")
    ImGui.AddText(STATS_WINDOW_ID, "", false, "RunLoggerSummaryText")

    -- Layout: controls that change what every tab shows sit above the tab bar;
    -- controls that only affect one tab live inside that tab.
    ImGui.AddCombobox(STATS_WINDOW_ID, "RunLoggerCharCombo", "Character",
        function(newIndex)
            selectedCharacterKey = characterKeys[newIndex + 1] or nil
            refreshStatsWindow()
        end,
        characterNames, 0, false)

    ImGui.AddCombobox(STATS_WINDOW_ID, "RunLoggerModeCombo", "Mode",
        function(newIndex)
            selectedModeSet = MODE_FILTERS[newIndex + 1] and MODE_FILTERS[newIndex + 1].set or nil
            refreshStatsWindow()
        end,
        MODE_LABELS, 0, false)

    ImGui.AddInputText(STATS_WINDOW_ID, "RunLoggerSearch", "Search (items and sources)",
        function(newText)
            searchQuery = newText
            refreshStatsWindow()
        end,
        "", "item or source name...")

    ImGui.AddTabBar(STATS_WINDOW_ID, "RunLoggerTabs")
    ImGui.AddTab("RunLoggerTabs", "RunLoggerItemsTab", "Items")
    ImGui.AddTab("RunLoggerTabs", "RunLoggerSourcesTab", "Damage Sources")
    ImGui.AddTab("RunLoggerTabs", "RunLoggerFloorsTab", "Hits by Floor")
    ImGui.AddTab("RunLoggerTabs", "RunLoggerFormsTab", "Transformations")
    ImGui.AddTab("RunLoggerTabs", "RunLoggerRecentTab", "Recent Runs")
    ImGui.AddTab("RunLoggerTabs", "RunLoggerSettingsTab", "Settings")

    -- Items tab
    ImGui.AddText("RunLoggerItemsTab", "Hover for column help", false, "RunLoggerItemsHeader")
    setTooltip("RunLoggerItemsHeader", table.concat({
        "pickedUp: total pickups (repeat pickups count)",
        "seen: pedestal appearances (deduped per pedestal)",
        "encounterRate: % of runs where it appeared at least once",
        "pickRate: pickedUp / seen, ignoring pedestals seen under Curse of the Blind",
        "avgFloorFound: mean floor at pickup",
        "avgFloorReached: mean deepest floor in completed standard runs holding it",
        "winRate: % of completed runs holding it that were wins",
        "hits/min: real hits per minute of play after first picking it up (needs 2+ min of exposure).",
        "    Compare with 'Avg hits per minute' above. Items found late are measured in harder rooms.",
        "-- means no data (e.g. only held in abandoned runs)",
    }, "\n"))

    ImGui.AddCombobox("RunLoggerItemsTab", "RunLoggerSortCombo", "Sort by",
        function(newIndex)
            currentSortMetric = SORT_METRIC_OPTIONS[newIndex + 1] or "winRate"
            refreshStatsWindow()
        end,
        SORT_METRIC_OPTIONS, 0, false)

    ImGui.AddCheckbox("RunLoggerItemsTab", "RunLoggerSortAscending", "Ascending (lowest first)",
        function(newState)
            sortAscending = newState
            refreshStatsWindow()
        end,
        false)
    setTooltip("RunLoggerSortAscending", "Rows with no data for the chosen column (--) always sort last.")

    ImGui.AddCheckbox("RunLoggerItemsTab", "RunLoggerHideUnpickedUp", "Hide items I never picked up",
        function(newState)
            hideUnpickedUp = newState
            refreshStatsWindow()
        end,
        false)

    for i = 1, ROW_POOL_SIZE do
        ImGui.AddText("RunLoggerItemsTab", "", false, "RunLoggerItemRow" .. i)
    end

    -- Damage Sources tab
    ImGui.AddCheckbox("RunLoggerSourcesTab", "RunLoggerSourcesAscending", "Fewest hits first",
        function(newState)
            sourcesAscending = newState
            refreshStatsWindow()
        end,
        false)

    ImGui.AddSliderInteger("RunLoggerSourcesTab", "RunLoggerMinHits", "Min hits",
        function(newVal)
            minHitsFilter = newVal
            refreshStatsWindow()
        end,
        0, 0, 50, "%d")

    for i = 1, ROW_POOL_SIZE do
        ImGui.AddText("RunLoggerSourcesTab", "", false, "RunLoggerSourceRow" .. i)
    end

    -- Hits by Floor and Recent Runs tabs
    for i = 1, FLOOR_POOL_SIZE do
        ImGui.AddText("RunLoggerFloorsTab", "", false, "RunLoggerFloorRow" .. i)
    end

    -- Transformations tab
    ImGui.AddText("RunLoggerFormsTab", "Hover for column help", false, "RunLoggerFormsHeader")
    setTooltip("RunLoggerFormsHeader", table.concat({
        "gained: runs in which you got the transformation",
        "rate: % of runs (in the current filter) where you got it",
        "avgFloorGained: mean floor when gained, standard runs only",
        "winRate: % of completed runs where you got it that were wins",
        "hits/min: real hits per minute after gaining it (needs 2+ min of exposure)",
        "-- means no data",
    }, "\n"))
    ImGui.AddCheckbox("RunLoggerFormsTab", "RunLoggerFormsAscending", "Ascending (lowest first)",
        function(newState)
            formsAscending = newState
            refreshStatsWindow()
        end,
        false)
    for i = 1, FORM_POOL_SIZE do
        ImGui.AddText("RunLoggerFormsTab", "", false, "RunLoggerFormRow" .. i)
    end
    for i = 1, RECENT_POOL_SIZE do
        ImGui.AddText("RunLoggerRecentTab", "", false, "RunLoggerRecentRow" .. i)
    end

    -- Settings tab. Test mode is session-only; everything below it is stored
    -- per save slot, applied immediately, and written to disk a moment after
    -- the last change.
    ImGui.AddCheckbox("RunLoggerSettingsTab", "RunLoggerTestMode", "Test mode (this session only): runs are NOT logged",
        function(newState)
            testModeEnabled = newState
            refreshStatsWindow()
        end,
        testModeEnabled)
    setTooltip("RunLoggerTestMode", "Everything is still tracked, but finished runs are not saved.\nResets when the game is restarted.")

    ImGui.AddText("RunLoggerSettingsTab", "Settings below are stored per save slot and apply immediately.", false, "RunLoggerSettingsNote")

    ImGui.AddSliderInteger("RunLoggerSettingsTab", "RunLoggerSetMaxRuns", "Max stored runs",
        function(v) getSettings().maxStoredRuns = v; markSettingsDirty() end,
        cfg.maxStoredRuns, 20, 1000, "%d")
    setTooltip("RunLoggerSetMaxRuns", "Oldest runs are dropped from the log past this many.\nStats keep their totals; only rebuilds are limited to stored runs.")

    ImGui.AddSliderInteger("RunLoggerSettingsTab", "RunLoggerSetMaxKB", "Max log size (KB)",
        function(v) getSettings().maxLogKB = v; markSettingsDirty() end,
        cfg.maxLogKB, 200, 8000, "%d")
    setTooltip("RunLoggerSetMaxKB", "Also drops the oldest runs once the log text exceeds this size.\nLower it if run end or loading feels slow.")

    ImGui.AddCheckbox("RunLoggerSettingsTab", "RunLoggerSetLogAbandoned", "Log abandoned runs",
        function(v) getSettings().logAbandoned = v; markSettingsDirty() end,
        cfg.logAbandoned)
    setTooltip("RunLoggerSetLogAbandoned", "Runs that end by quitting, restarting or Save & Quit.")

    ImGui.AddSliderInteger("RunLoggerSettingsTab", "RunLoggerSetMinAbandoned", "Min abandoned run length (seconds)",
        function(v) getSettings().minAbandonedSeconds = v; markSettingsDirty() end,
        cfg.minAbandonedSeconds, 0, 600, "%d")
    setTooltip("RunLoggerSetMinAbandoned", "Abandoned runs shorter than this are not logged.")

    statsWindowBuilt = true
end

local function toggleStatsWindow()
    ensureStatsWindowBuilt()
    refreshStatsWindow()
    ImGui.SetVisible(STATS_WINDOW_ID, true)
end

-- ============================================================
-- SAVING
-- ============================================================

-- Drops the oldest runs until at most maxRuns remain and the log fits in
-- maxBytes. Scans for newlines instead of splitting the log into a table, and
-- never drops the newest run.
local function trimLog(log, maxRuns, maxBytes)
    local total = 1
    for _ in log:gmatch("\n") do total = total + 1 end
    if total > maxRuns then
        local cut = 0
        for _ = 1, total - maxRuns do cut = log:find("\n", cut + 1, true) end
        log = log:sub(cut + 1)
    end
    if #log > maxBytes then
        local cut = log:find("\n", #log - maxBytes + 1, true) or log:match(".*()\n")
        if cut then log = log:sub(cut + 1) end
    end
    return log
end

local function saveRunToDisk(run)
    local t0 = Isaac.GetTime()
    revalidateCaches()
    ensureCaches() -- no-op when the slot's data is already cached
    if not cachedLog then
        -- Saving would overwrite whatever is on disk with a fresh file.
        Isaac.DebugString("Run Logger: save data unreadable; run NOT saved, existing data left untouched")
        return
    end

    local cfg = settings
    local newLine = json.encode(run)
    cachedLog = (cachedLog ~= "") and (cachedLog .. "\n" .. newLine) or newLine
    cachedLog = trimLog(cachedLog, cfg.maxStoredRuns, cfg.maxLogKB * 1024)

    local okStats, err = pcall(AggregateStats.RecordRun, latestStats, run)
    if not okStats then
        Isaac.DebugString("Run Logger: stats update failed: " .. tostring(err))
        latestStats.version = -1 -- next load rebuilds from the log
    end
    viewStats = nil

    local t1 = Isaac.GetTime()
    AggregateStats.SaveEnvelope({ log = cachedLog, stats = latestStats, settings = settings })
    settingsDirtyAt = nil -- the save just persisted the settings too
    Isaac.DebugString(("Run Logger: save took %d ms (write %d ms), log is %d bytes"):format(
        Isaac.GetTime() - t0, Isaac.GetTime() - t1, #cachedLog))
end

-- Writes only the settings change (debounced by the render callback below).
local function persistSettings()
    settingsDirtyAt = nil
    if not (cachedLog and latestStats and settings) then return end
    AggregateStats.SaveEnvelope({ log = cachedLog, stats = latestStats, settings = settings })
end

-- ============================================================
-- RUN TRACKING
-- ============================================================

local currentRun = { items = {} }

local DIFFICULTY_LABELS = {
    [0] = "Normal",
    [1] = "Hard",
    [2] = "Greed",
    [3] = "Greedier",
}

-- Set by MC_ENTITY_TAKE_DMG, consumed when the run ends; only the fatal hit matters.
local pendingDeathSource = nil

-- Re-firing callbacks must not double-log: MC_POST_PICKUP_SELECTION fires again
-- on room reload, and forms/levels are polled repeatedly.
local seenPedestals = {}
local seenLevels = {}
local seenForms = {}

-- Set on the first per-frame form check so forms already active (e.g. a resumed
-- run) are seeded rather than logged as newly gained.
local formsSeeded = false

-- item id -> index into currentRun.active_uses, so repeat uses update one entry.
-- Kept outside currentRun so it never gets serialized.
local activeUseIndexByItem = {}

local PLAYER_FORM_LABELS = {
    [PlayerForm.PLAYERFORM_GUPPY] = "Guppy",
    [PlayerForm.PLAYERFORM_LORD_OF_THE_FLIES] = "Beelzebub",
    [PlayerForm.PLAYERFORM_MUSHROOM] = "Fun Guy",
    [PlayerForm.PLAYERFORM_ANGEL] = "Seraphim",
    [PlayerForm.PLAYERFORM_BOB] = "Bob",
    [PlayerForm.PLAYERFORM_DRUGS] = "Spun",
    [PlayerForm.PLAYERFORM_MOM] = "Yes Mother?",
    [PlayerForm.PLAYERFORM_BABY] = "Conjoined",
    [PlayerForm.PLAYERFORM_EVIL_ANGEL] = "Leviathan",
    [PlayerForm.PLAYERFORM_POOP] = "Oh Crap",
    [PlayerForm.PLAYERFORM_BOOK_WORM] = "Bookworm",
    [PlayerForm.PLAYERFORM_ADULTHOOD] = "Adult",
    [PlayerForm.PLAYERFORM_SPIDERBABY] = "Spider Baby",
    [PlayerForm.PLAYERFORM_STOMPY] = "Stompy",
}

local ITEM_TYPE_LABELS = {
    [ItemType.ITEM_PASSIVE] = "passive",
    [ItemType.ITEM_ACTIVE] = "active",
    [ItemType.ITEM_FAMILIAR] = "familiar",
    [ItemType.ITEM_TRINKET] = "trinket",
}

local function getCurrentFloor()
    return Game():GetLevel():GetStage()
end

-- Stage type separates e.g. Basement / Cellar / Burning Basement
local function getCurrentStageType()
    local ok, stageType = pcall(function() return Game():GetLevel():GetStageType() end)
    if ok then return stageType end
    return -1
end

-- Resolves name and kind (active/passive/familiar/trinket) at logging time so
-- archived data is self-describing. Names of Repentance items can be raw
-- localization keys; the id is always reliable. Falls back to nil for unknown
-- ids (e.g. an item from a mod that is no longer installed).
local function getItemInfo(id)
    local ok, item = pcall(function() return Isaac.GetItemConfig():GetCollectible(id) end)
    if ok and item then
        return item.Name, (ITEM_TYPE_LABELS[item.Type] or "unknown")
    end
    return nil, nil
end

-- Curse of the Blind hides a pedestal's item from the player while the mod
-- still sees the real id; tagging those spawns/pickups marks decisions that
-- weren't informed ones.
local function isCurseOfBlindActive()
    local ok, curses = pcall(function() return Game():GetCurses() end)
    if not ok then return false end
    return curses & LevelCurse.CURSE_OF_BLIND ~= 0
end


local function getRepentogonVersion()
    local ok, v = pcall(function() return REPENTOGON and REPENTOGON.Version end)
    if ok and v then return v end
    return nil
end

-- Wall-clock time per run
local function getTimestamp()
    local ok, result = pcall(function() return os.date("%Y-%m-%d %H:%M:%S") end)
    if ok then return result end
    return nil
end

-- Initializes currentRun exactly once per run, whichever callback fires first.
local function ensureRunInitialized()
    if currentRun.run_id then return end
    local player = Isaac.GetPlayer(0)
    currentRun.run_id = tostring(Game():GetSeeds():GetStartSeed())
    currentRun.seed = Game():GetSeeds():GetStartSeedString()
    currentRun.character = player and player:GetPlayerType() or nil
    currentRun.items = currentRun.items or {}
    currentRun.active_uses = currentRun.active_uses or {}
    currentRun.item_spawns = currentRun.item_spawns or {}
    currentRun.damage_events = currentRun.damage_events or {}
    currentRun.levels_visited = currentRun.levels_visited or {}
    currentRun.transformations = currentRun.transformations or {}
    currentRun.start_time = Game():GetFrameCount()
    currentRun.difficulty = Game().Difficulty
    currentRun.challenge = Isaac.GetChallenge()
    currentRun.mode = DIFFICULTY_LABELS[currentRun.difficulty] or "Unknown"
    currentRun.mod_version = getRepentogonVersion() -- the REPENTOGON version, not this mod's
    currentRun.logger_version = "1.0"
    currentRun.toll_flag_mask = TOLL_MASK
    currentRun.timestamp = getTimestamp()
    currentRun.slot = activeSlot
    Isaac.DebugString("Run initialized: run_id=" .. tostring(currentRun.run_id))
end

-- Returns the finished run and clears all per-run state. Without this an
-- abandoned run's id/seed/character would leak into the next run.
local function endRun()
    local finished = currentRun
    currentRun = { items = {} }
    pendingDeathSource = nil
    seenPedestals = {}
    seenLevels = {}
    seenForms = {}
    formsSeeded = false
    activeUseIndexByItem = {}
    return finished
end

local function recordLevelVisited()
    ensureRunInitialized()
    local stage, stageType = getCurrentFloor(), getCurrentStageType()
    local key = tostring(stage) .. "_" .. tostring(stageType)
    if seenLevels[key] then return end
    seenLevels[key] = true
    currentRun.levels_visited = currentRun.levels_visited or {}
    table.insert(currentRun.levels_visited, { stage = stage, stage_type = stageType })
end

-- Array of {id, count}, not a table keyed by item id (see the JSON gotcha above).
local function getPlayerItemSnapshot(player)
    local snapshot = {}
    local collectibles = Isaac.GetItemConfig():GetCollectibles()
    for i = 0, collectibles.Size - 1 do
        local item = collectibles:Get(i)
        if item then
            local num = player:GetCollectibleNum(item.ID, true)
            if num > 0 then
                table.insert(snapshot, { id = item.ID, count = num })
            end
        end
    end
    return snapshot
end

-- The player's collectibles at the moment a run ends: the only exact inventory
-- in the log (pickups are recorded as they happen but removals and rerolls
-- aren't). Taken once per saved run; nil if the player can't be read.
local function finalInventory()
    local ok, snapshot = pcall(function() return getPlayerItemSnapshot(Isaac.GetPlayer(0)) end)
    if ok then return snapshot end
    return nil
end

-- Collapses raw damage events into "real" hits: an event only starts a new hit
-- if it lands after the previous counted hit's invulnerability window expired.
-- Sources with little or no iframes (fire, creep) still count as multiple hits,
-- matching the game's own treatment.
local function countRealHits(damageEvents)
    local hits = 0
    local invulnerableUntil = -1
    for _, event in ipairs(damageEvents) do
        if event.time >= invulnerableUntil and (event.amount or 0) > 0 then
            hits = hits + 1
            invulnerableUntil = event.time + (event.iframes or 0)
        end
    end
    return hits
end

-- NOTE ON CALLBACK ARGUMENTS: in this build several callbacks prepend a leading
-- `self` argument before the documented signature, so handlers below detect
-- which shape they received instead of assuming one.

mod:AddCallback(ModCallbacks.MC_POST_NEW_LEVEL, recordLevelVisited)

-- Caches are dropped when the slot changes (MC_POST_SAVESLOT_LOAD below), not on
-- every game start: reloading the slot's stats costs time and a new run in the
-- same slot doesn't need it. This only makes sure they are warm, so settings are
-- known before the run's first callbacks.
mod:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function(...)
    local args = {...}
    local isContinued = args[1]
    if type(isContinued) == "table" then isContinued = args[2] end
    revalidateCaches()
    pcall(ensureCaches)
    if isContinued then
        ensureRunInitialized()
        currentRun.continued = true
    end
end)

-- Fires many times before a run starts (the game also loads slots it doesn't
-- select). rawSlot == 0 is the pre-selection default state, where mod data and
-- game data are out of sync; only a selected slot sets activeSlot.
mod:AddCallback(ModCallbacks.MC_POST_SAVESLOT_LOAD, function(...)
    local args = {...}
    if type(args[1]) == "table" then table.remove(args, 1) end
    local saveslot, isSlotSelected, rawSlot = args[1], args[2], args[3]
    if isSlotSelected or rawSlot == 0 then
        Isaac.DebugString(("Run Logger: SAVESLOT_LOAD saveslot=%s selected=%s raw=%s")
            :format(tostring(saveslot), tostring(isSlotSelected), tostring(rawSlot)))
    end

    -- This fires repeatedly, including when a run ends and the game returns to
    -- the menu. The cache is keyed by slot, so it is only dropped and reloaded
    -- when a different slot is selected, never on repeats or in the default state.
    if rawSlot == 0 then
        activeSlot = nil
    elseif isSlotSelected then
        activeSlot = saveslot
        if cachedSlot ~= saveslot then invalidateCaches() end
        pcall(ensureCaches) -- no-op when this slot is already cached
    end
end)

mod:AddCallback(ModCallbacks.MC_POST_RENDER, function()
    if settingsDirtyAt and Isaac.GetTime() - settingsDirtyAt > 1000 then
        persistSettings()
    end
end)

-- ITEM PICKUP
mod:AddCallback(ModCallbacks.MC_POST_ADD_COLLECTIBLE, function(...)
    local n = select('#', ...)
    local args = {...}

    local collectibleType, charge, firstTime
    if type(args[1]) == "number" then
        collectibleType, charge, firstTime = args[1], args[2], args[3]
    elseif n >= 7 and type(args[2]) == "number" then
        collectibleType, charge, firstTime = args[2], args[3], args[4]
    else
        return -- unrecognized
    end

    ensureRunInitialized()
    if type(collectibleType) ~= "number" then return end

    local itemName, itemType = getItemInfo(collectibleType)
    table.insert(currentRun.items, {
        id = collectibleType,
        name = itemName,
        item_type = itemType,
        floor = getCurrentFloor(),
        stage_type = getCurrentStageType(),
        time = Game():GetFrameCount(),
        first_time = firstTime,
        charge = charge,
        curse_of_blind = isCurseOfBlindActive(),
    })
end)

-- DAMAGE TAKEN (player only). Also captures the likely death source.
local MAX_DAMAGE_EVENTS_PER_RUN = 300
mod:AddCallback(ModCallbacks.MC_ENTITY_TAKE_DMG, function(_, entity, damage, damageFlags, source, damageCountdown)
    local ok, player = pcall(function() return entity:ToPlayer() end)
    if not ok or not player then return end -- damage to something other than the player

    ensureRunInitialized()

    local sourceType, sourceVariant, sourceRaw = -1, -1, nil
    local ok2, t, v = pcall(function() return source.Type, source.Variant end)
    if ok2 and t ~= nil then
        sourceType = t
        sourceVariant = v or -1
    else
        sourceRaw = tostring(source)
    end

    local spawnerType, spawnerVariant, sourceSubType = -1, -1, -1
    pcall(function()
        local ent = source.Entity
        if ent then
            sourceSubType  = ent.SubType or -1
            spawnerType    = ent.SpawnerType or -1
            spawnerVariant = ent.SpawnerVariant or -1
        end
    end)

    table.insert(currentRun.damage_events, {
        floor = getCurrentFloor(),
        stage_type = getCurrentStageType(),
        time = Game():GetFrameCount(),
        amount = damage,
        source_type = sourceType,
        source_variant = sourceVariant,
        source_raw = sourceRaw,
        iframes = damageCountdown,
        damage_flags = damageFlags,
        source_sub_type = sourceSubType,
        spawner_type = spawnerType,
        spawner_variant = spawnerVariant,
    })

    while #currentRun.damage_events > MAX_DAMAGE_EVENTS_PER_RUN do
        table.remove(currentRun.damage_events, 1)
    end

    pendingDeathSource = { type = sourceType, variant = sourceVariant, raw = sourceRaw,
        spawner_type = spawnerType, spawner_variant = spawnerVariant, damage_flags = damageFlags }
end)

-- ACTIVE ITEM USE
mod:AddCallback(ModCallbacks.MC_POST_USE_ITEM, function(...)
    local args = {...}
    local collectibleType
    if type(args[1]) == "number" then
        collectibleType = args[1]
    elseif type(args[2]) == "number" then
        collectibleType = args[2]
    else
        return
    end

    ensureRunInitialized()
    if type(collectibleType) ~= "number" then return end

    -- One entry per item per run
    currentRun.active_uses = currentRun.active_uses or {}
    local now = Game():GetFrameCount()
    local floor = getCurrentFloor()
    local stageType = getCurrentStageType()

    local idx = activeUseIndexByItem[collectibleType]
    if idx then
        local entry = currentRun.active_uses[idx]
        entry.count = entry.count + 1
        entry.last_time = now
        entry.last_floor = floor
        entry.last_stage_type = stageType
    else
        local itemName, itemType = getItemInfo(collectibleType)
        table.insert(currentRun.active_uses, {
            id = collectibleType,
            name = itemName,
            item_type = itemType,
            count = 1,
            first_time = now,
            first_floor = floor,
            first_stage_type = stageType,
            last_time = now,
            last_floor = floor,
            last_stage_type = stageType,
        })
        activeUseIndexByItem[collectibleType] = #currentRun.active_uses
    end
end)

-- Transformations: polled once per frame
mod:AddCallback(ModCallbacks.MC_POST_PEFFECT_UPDATE, function(...)
    local args = {...}
    local player = (type(args[1]) == "table") and args[2] or args[1]
    if not player then return end

    pcall(function()
        if not formsSeeded then
            formsSeeded = true
            for formId in pairs(PLAYER_FORM_LABELS) do
                if player:HasPlayerForm(formId) then
                    seenForms[formId] = true
                end
            end
            return
        end

        for formId, label in pairs(PLAYER_FORM_LABELS) do
            if not seenForms[formId] and player:HasPlayerForm(formId) then
                seenForms[formId] = true
                ensureRunInitialized()
                table.insert(currentRun.transformations, {
                    name = label,
                    floor = getCurrentFloor(),
                    stage_type = getCurrentStageType(),
                    time = Game():GetFrameCount(),
                })
            end
        end
    end)
end)

-- PEDESTAL ITEM SPAWNS
mod:AddCallback(ModCallbacks.MC_POST_PICKUP_SELECTION, function(_, pickup, variant, subType, requestedVariant, requestedSubType, rng)
    if variant ~= PickupVariant.PICKUP_COLLECTIBLE then return end
    if type(subType) ~= "number" or subType == 0 then return end -- not yet a real item id

    ensureRunInitialized()

    local ok, seed = pcall(function() return rng:GetSeed() end)
    local pedestalKey = (ok and seed ~= nil) and tostring(seed) or tostring(pickup)

    if seenPedestals[pedestalKey] == subType then
        return -- already logged this item at this pedestal (room reload re-fire)
    end
    seenPedestals[pedestalKey] = subType

    local itemName, itemType = getItemInfo(subType)
    table.insert(currentRun.item_spawns, {
        id = subType,
        name = itemName,
        item_type = itemType,
        floor = getCurrentFloor(),
        stage_type = getCurrentStageType(),
        time = Game():GetFrameCount(),
        curse_of_blind = isCurseOfBlindActive(),
    })
end)

-- RUN END: death or win
mod:AddCallback(ModCallbacks.MC_POST_GAME_END, function(_, isGameOver)
    if not currentRun.run_id then return end
    recordLevelVisited()
    currentRun.floor_reached = getCurrentFloor()
    currentRun.stage_type_reached = getCurrentStageType()
    currentRun.end_time = Game():GetFrameCount()
    currentRun.won = isGameOver == false
    currentRun.death_source = (not currentRun.won) and pendingDeathSource or nil
    currentRun.hits_taken = countRealHits(currentRun.damage_events)

    local runToSave = endRun()
    if testModeEnabled then
        Isaac.DebugString("Run Logger: test mode ON, not saving")
    else
        runToSave.final_items = finalInventory()
        saveRunToDisk(runToSave)
    end
end)

-- RUN END: restart, save & quit, or any exit that doesn't trigger MC_POST_GAME_END.
mod:AddCallback(ModCallbacks.MC_PRE_GAME_EXIT, function(_, shouldSave)
    if not currentRun.run_id then return end -- already handled by MC_POST_GAME_END
    recordLevelVisited()
    currentRun.floor_reached = getCurrentFloor()
    currentRun.stage_type_reached = getCurrentStageType()
    currentRun.end_time = Game():GetFrameCount()
    currentRun.won = nil
    currentRun.abandoned = true
    currentRun.death_source = nil
    currentRun.hits_taken = countRealHits(currentRun.damage_events)
    currentRun.continuable_save = shouldSave

    local runToSave = endRun()
    local runDuration = (runToSave.end_time or 0) - (runToSave.start_time or 0)
    local cfg = peekSettings()

    if not cfg.logAbandoned then
        Isaac.DebugString("Run Logger: abandoned run not saved (disabled in settings)")
        return
    end
    if runDuration < cfg.minAbandonedSeconds * 60 then
        Isaac.DebugString("Run Logger: abandoned run too short, not saving (duration="
            .. tostring(runDuration) .. " frames)")
        return
    end
    if testModeEnabled then
        Isaac.DebugString("Run Logger: test mode ON, not saving")
        return
    end
    runToSave.final_items = finalInventory()
    saveRunToDisk(runToSave)
end)

-- ============================================================
-- CONSOLE COMMANDS ("runlogger <command>", open the console with `)
-- ============================================================

mod:AddCallback(ModCallbacks.MC_EXECUTE_CMD, function(...)
    local args = {...}
    local command, params
    if type(args[1]) == "string" then
        command, params = args[1], args[2]
    elseif type(args[2]) == "string" then
        command, params = args[2], args[3]
    else
        return
    end
    if command ~= "runlogger" then return end

    if params == "ui" then
        toggleStatsWindow()

    elseif params == "toggletestmode" then
        testModeEnabled = not testModeEnabled
        if statsWindowBuilt then
            updateControl("RunLoggerTestMode", testModeEnabled)
            refreshStatsWindow()
        end
        Isaac.ConsoleOutput("Run Logger: test mode "
            .. (testModeEnabled and "ON - runs will NOT be logged" or "OFF - runs will be logged") .. "\n")

    elseif params == "status" then
        Isaac.ConsoleOutput("Run Logger: test mode is " .. (testModeEnabled and "ON" or "OFF") .. "\n")

    elseif params == "rebuildstats" then
        revalidateCaches()
        ensureCaches()
        if not cachedLog then
            Isaac.ConsoleOutput("Run Logger: save data unreadable; nothing rebuilt\n")
            return
        end
        latestStats = AggregateStats.RebuildStatsFromLog(cachedLog)
        viewStats = nil
        AggregateStats.SaveEnvelope({ log = cachedLog, stats = latestStats, settings = settings })
        if statsWindowBuilt then refreshStatsWindow() end
        Isaac.ConsoleOutput("Run Logger: stats rebuilt from logged runs (totalRuns="
            .. tostring(AggregateStats.GetView(latestStats).totalRuns) .. ")\n")

    elseif params == "dumpdmgsources" then
        for name, id in pairs(EntityType) do Isaac.DebugString(tostring(id) .. "," .. name) end
        for name, id in pairs(SlotVariant) do Isaac.DebugString("SLOT," .. tostring(id) .. "," .. name) end
        for name, id in pairs(PickupVariant) do Isaac.DebugString("PICKUP," .. tostring(id) .. "," .. name) end
        for name, id in pairs(FamiliarVariant) do Isaac.DebugString("FAMILIAR," .. tostring(id) .. "," .. name) end
        for name, id in pairs(EffectVariant) do Isaac.DebugString("EFFECT," .. tostring(id) .. "," .. name) end
        for name, id in pairs(ProjectileVariant) do Isaac.DebugString("PROJECTILE," .. tostring(id) .. "," .. name) end
        for label, enum in pairs({ GRID = GridEntityType, TEAR = TearVariant, BOMB = BombVariant }) do
            for name, id in pairs(enum) do Isaac.DebugString(label .. "," .. tostring(id) .. "," .. name) end
        for name, id in pairs(DamageFlag) do Isaac.DebugString("DAMAGEFLAG," .. tostring(id) .. "," .. name) end
  end

    else
        Isaac.ConsoleOutput("Run Logger commands: runlogger ui | status | toggletestmode | rebuildstats\n")
    end
end)

Isaac.DebugString("Run Logger: mod file loaded")
