-- x_rls_console: drop-in replacement for BeamNG's ImGui console (ui_console, opened with ~).
-- Based on the stock lua/ge/extensions/ui/console.lua (bCDDL 1.1, BeamNG GmbH) and keeps all of its features:
-- level filters, Lua-pattern origin filter, GE Lua / TorqueScript / CEF JS / per-vehicle command contexts,
-- command history, sandboxed commands, vehicle controls toggle, fullscreen, font size and background alpha.
-- Additions:
--   * keeps capturing log lines while the console is closed (stock only captured while open)
--   * configurable line limit (default 50,000, stock was 1,000) and no 256-char display cut
--   * on load, back-fills from beamng.log so lines from before the console was opened are there
--   * row selection: click, Ctrl+click, Shift+click, click-and-drag, Ctrl+A, arrow keys; Ctrl+C copies
--   * details pane with the selected lines as real selectable/copyable text
--   * search box that filters or highlights (plain words, "phrases", -exclusions, or Lua patterns),
--     with next/previous match (F3 / Shift+F3) and "show in context"
--   * pause keeps buffering instead of dropping lines; export to a text file

local M = {}
M.dependencies = {"ui_imgui"}

local im = ui_imgui
local guiModule = require("ge/extensions/editor/api/gui")
local gui = {setupEditorGuiTheme = nop}

local settingsPath = '/settings/xRlsDebugConsole.json'
local historyPath = '/consoleHistory.json'
local logFilePaths = {'beamng.log', '/beamng.log'}

local MAX_LINE_LEN = 65536        -- per stored line
local RENDER_LINE_LEN = 1500      -- per rendered cell (full text is in details / tooltip / copy)
local DETAILS_MAX_BYTES = 4 * 1024 * 1024
local MIN_LINES, MAX_LINES = 1000, 500000

---------------------------------------------------------------------------------------------------
-- settings
---------------------------------------------------------------------------------------------------
local cfg = {
  maxLines = 50000,
  fontScale = 0.95,
  levelFilter = {E=true, W=true, I=true, D=true, A=true},
  fullscreen = false,
  winstate = {60, 60, 1400, 850},
  loopHistory = false,
  sandboxCmd = true,
  focusOnShow = true,
  bgAlpha = 0.9,
  bgAlphaFull = 0.85,
  enableVehicleControls = true,
  rowBg = true,
  tooltipOnLongTxt = true,
  seedFromLogFile = true,
  captureWhileHidden = true,
  showDetails = true,
  detailsHeight = 180,
  searchHighlight = false,  -- false = filter mode, true = highlight mode
  searchCase = false,
  searchPattern = false,
  historySize = 100,
}

-- ImGui-bound mirrors of some settings
local p = {
  fontScale = im.FloatPtr(cfg.fontScale),
  bgAlpha = im.FloatPtr(cfg.bgAlpha),
  bgAlphaFull = im.FloatPtr(cfg.bgAlphaFull),
  loopHistory = im.BoolPtr(cfg.loopHistory),
  sandboxCmd = im.BoolPtr(cfg.sandboxCmd),
  focusOnShow = im.BoolPtr(cfg.focusOnShow),
  rowBg = im.BoolPtr(cfg.rowBg),
  tooltipOnLongTxt = im.BoolPtr(cfg.tooltipOnLongTxt),
  seedFromLogFile = im.BoolPtr(cfg.seedFromLogFile),
  captureWhileHidden = im.BoolPtr(cfg.captureWhileHidden),
  showDetails = im.BoolPtr(cfg.showDetails),
  detailsHeight = im.FloatPtr(cfg.detailsHeight),
  searchCase = im.BoolPtr(cfg.searchCase),
  searchPattern = im.BoolPtr(cfg.searchPattern),
  maxLines = im.IntPtr(cfg.maxLines),
}

local function syncPtrsFromCfg()
  for k, ptr in pairs(p) do
    if cfg[k] ~= nil then ptr[0] = cfg[k] end
  end
end

local function syncCfgFromPtrs()
  for k, ptr in pairs(p) do
    local v = ptr[0]
    if type(cfg[k]) == "boolean" then v = v == true end
    cfg[k] = v
  end
end

local function settingsSave()
  syncCfgFromPtrs()
  jsonWriteFile(settingsPath, cfg, true)
end

local function settingsLoad()
  local s = jsonReadFile(settingsPath)
  if type(s) == "table" then
    for k, v in pairs(s) do
      if cfg[k] ~= nil and type(cfg[k]) == type(v) then cfg[k] = v end
    end
  end
  cfg.maxLines = math.max(MIN_LINES, math.min(MAX_LINES, math.floor(cfg.maxLines)))
  syncPtrsFromCfg()
end

---------------------------------------------------------------------------------------------------
-- state
---------------------------------------------------------------------------------------------------
local windowOpen = im.BoolPtr(false)
local winTitle = beamng_appname .. " debug console - " .. beamng_versiond .. " - " .. beamng_buildtype .. " - " .. beamng_arch .. "##xRlsDebugConsole"

-- log storage: logs[id] = {time, level, origin, message, groupId, isContinuation, lowerMsg, lowerOrigin}
local logs = {}
local head, tail = 1, 1           -- valid ids are [head, tail)
local filtered = {}               -- sorted ids that pass the level/origin (and search, in filter mode) filters
local matches = {}                -- highlight mode: sorted ids that match the search
local matchSet = {}
local currentMatch = 0            -- index into matches
local counts = {E = 0, W = 0}
local pending = {}                -- lines that arrived while paused
local paused = false
local seedMaxT, seedGuardFrames = nil, 0

-- selection
local selected = {}
local selCount = 0
local anchorId = nil
local dragging = false
local dragAnchorRow = nil
local dragLastRow = nil
local detailsDirty = true
local detailsBuf = im.ArrayChar(2, "")
local detailsHeader = ""

-- view
local forceAutoScroll = false
local followBottom = true
local scrollMaxPrev = 0
local pendingScrollRow = nil      -- 1-based row in `filtered` to bring into view
local rowHeight = 18
local focusSearch = false
local tableFocused = false

-- filters
local originFilterBuf = im.ArrayChar(256, "")
local searchBuf = im.ArrayChar(1024, "")
local originPattern, originInvalid, originErr = "", false, ""
local searchFn, searchInvalid, searchErr = nil, false, ""
local filterKey = ""
local refilterTimer = nil

-- command input
local consoleInputField = im.ArrayChar(4096, "")
local comboCurrentItem = im.IntPtr(0)
local comboCtxTxt = "GE - Lua\0GE - TorqueScript\0CEF/UI - JS\0\0"
local vehIds = {}
local history = nil
local historyPos = -1
local vehicleActionMaps = {"VehicleCommonActionMap", "VehicleSpecificActionMap"}
local previouslyShown

local colors = {D = im.ImVec4(0.12,0.75,1,1), I = im.ImVec4(0.3,1,0.3,1), W = im.ImVec4(1,1,0,1), E = im.ImVec4(1,0.2,0.2,1)}
local defaultColor = im.ImVec4(1,1,1,1)
local dimColor = im.ImVec4(1,1,1,0.3)
local iconColors = {D = im.ImColorByRGB(32,196,255,255), I = im.ImColorByRGB(96,255,96,255), W = im.ImColorByRGB(255,255,0,255), E = im.ImColorByRGB(255,64,64,255)}
local iconButtonBgColor = im.ImColorByRGB(0, 0, 0, 0)
local iconButtonFgColor = im.ImColorByRGB(255, 255, 255, 255)
local iconButtonNoColor = im.ImColorByRGB(255, 255, 255, 128)
local matchBgU32, currentMatchBgU32

local originHelp = [[Origin filter: a Lua pattern matched against the origin column (lower-cased).
Examples:  career   ^core_   vehicle   rls
Character classes: . any, %a letters, %d digits, %w alphanumerics, %s spaces, %p punctuation.
Use % to escape magic characters ^$()%.[]*+-?]]

local searchHelp = [[Search looks in the message and the origin.
Plain mode (default):
  words        every word must appear, in any order
  "a phrase"   the exact phrase must appear
  -word        hide lines containing word
Pattern mode: the whole box is one Lua pattern.
Aa: case sensitive.

Filter mode hides lines that don't match.
Highlight mode keeps every line and highlights matches; jump with the arrows, F3 / Shift+F3 or Enter.
Ctrl+F jumps to the search box.

Rows: click, Ctrl+click, Shift+click or drag to select. Ctrl+A selects all shown, Ctrl+C copies,
Up/Down move the selection, Esc clears it. Double-click selects a whole multi-line message.
Right-click a row for more. The details pane below holds the selected text, which you can select with the mouse.]]

---------------------------------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------------------------------
local function splitLines(s)
  local out = {}
  if s:find("\r", 1, true) then s = s:gsub("\r\n", "\n"):gsub("\r", "\n") end
  local start = 1
  while true do
    local i = s:find("\n", start, true)
    if not i then out[#out + 1] = s:sub(start); break end
    out[#out + 1] = s:sub(start, i - 1)
    start = i + 1
  end
  if #out > 1 and out[#out] == "" then out[#out] = nil end
  return out
end

local function bsearch(arr, id) -- position of id in a sorted array, or nil
  local lo, hi = 1, #arr
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    local v = arr[mid]
    if v == id then return mid
    elseif v < id then lo = mid + 1
    else hi = mid - 1 end
  end
  return nil
end

local function lowerBound(arr, id) -- first position whose value >= id
  local lo, hi = 1, #arr + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if arr[mid] < id then lo = mid + 1 else hi = mid end
  end
  return lo
end

local function pruneFront(arr)
  local k = lowerBound(arr, head)
  if k == 1 then return arr end
  local out = {}
  table.move(arr, k, #arr, 1, out)
  return out
end

local function formatLine(e)
  return string.format("%s|%s|%s|%s", e[1], e[2], e[3], e[4])
end

local function wrapForTooltip(s)
  if #s > 6000 then s = s:sub(1, 6000) .. "\n... (truncated, see the details pane)" end
  return s
end

local function markDetailsDirty() detailsDirty = true end

-- Runs a piece of UI so that a Lua error can't leave ImGui's Begin/End stack unbalanced:
-- the error is logged once (not every frame) and shown at the top of the window.
local reportedErrors = {}
local lastUiError = nil
local function guard(fn, ...)
  local ok, err = xpcall(fn, debug.traceback, ...)
  if not ok then
    local first = tostring(err):match("^[^\n]*")
    lastUiError = first
    if not reportedErrors[first] then
      reportedErrors[first] = true
      log("E", "xRlsDebugConsole", "UI error: " .. tostring(err))
    end
  end
  return ok
end


-- tooltip that never treats the text as a printf format (help texts contain % characters)
local function tip(text)
  if im.IsItemHovered() then
    im.BeginTooltip()
    im.PushTextWrapPos(700)
    im.TextUnformatted(text)
    im.PopTextWrapPos()
    im.EndTooltip()
  end
end

---------------------------------------------------------------------------------------------------
-- filtering and search
---------------------------------------------------------------------------------------------------
local function compileOrigin()
  originPattern = ffi.string(originFilterBuf):lower()
  originInvalid, originErr = false, ""
  if originPattern ~= "" then
    local ok, err = pcall(string.find, "", originPattern)
    if not ok then
      originInvalid = true
      originErr = tostring(err):match(":%d+: ?(.*)") or tostring(err)
    end
  end
end

local function compileSearch()
  local q = ffi.string(searchBuf)
  searchFn, searchInvalid, searchErr = nil, false, ""
  if q:match("^%s*$") then return end
  local caseSens = p.searchCase[0]
  if not caseSens then q = q:lower() end

  local function fields(e)
    if caseSens then return e[4], e[3] end
    local lm = e[7]; if not lm then lm = e[4]:lower(); e[7] = lm end
    local lo = e[8]; if not lo then lo = e[3]:lower(); e[8] = lo end
    return lm, lo
  end

  if p.searchPattern[0] then
    local ok, err = pcall(string.find, "", q)
    if not ok then
      searchInvalid = true
      searchErr = tostring(err):match(":%d+: ?(.*)") or tostring(err)
      return
    end
    searchFn = function(e)
      local m, o = fields(e)
      local ok2, r = pcall(string.find, m, q)
      if ok2 and r then return true end
      ok2, r = pcall(string.find, o, q)
      return ok2 and r ~= nil
    end
    return
  end

  local terms = {}
  local rest = q:gsub('(%-?)"([^"]*)"', function(neg, phrase)
    if phrase ~= "" then terms[#terms + 1] = {neg == "-", phrase} end
    return " "
  end)
  for w in rest:gmatch("%S+") do
    local neg = false
    if #w > 1 and w:sub(1, 1) == "-" then neg = true; w = w:sub(2) end
    terms[#terms + 1] = {neg, w}
  end
  if #terms == 0 then return end
  searchFn = function(e)
    local m, o = fields(e)
    for i = 1, #terms do
      local t = terms[i]
      local found = m:find(t[2], 1, true) or o:find(t[2], 1, true)
      if t[1] then
        if found then return false end
      elseif not found then
        return false
      end
    end
    return true
  end
end

local function passesBase(e)
  local lf = cfg.levelFilter[e[2]]
  if not (lf or (lf == nil and cfg.levelFilter.A)) then return false end
  if originPattern ~= "" and not originInvalid then
    local lo = e[8]; if not lo then lo = e[3]:lower(); e[8] = lo end
    local ok, r = pcall(string.find, lo, originPattern)
    if not ok or not r then return false end
  end
  return true
end

-- returns visible, isMatch
local function classify(e)
  if not passesBase(e) then return false, false end
  if searchInvalid then return not cfg.searchHighlight, false end
  if not searchFn then return true, false end
  local m = searchFn(e)
  if cfg.searchHighlight then return true, m end
  return m, false
end

local function currentMatchId()
  return matches[currentMatch]
end

local function rebuildFiltered()
  local keepId = currentMatchId()
  filtered, matches, matchSet = {}, {}, {}
  local nf, nm = 0, 0
  for id = head, tail - 1 do
    local e = logs[id]
    if e then
      local vis, m = classify(e)
      if vis then nf = nf + 1; filtered[nf] = id end
      if m then nm = nm + 1; matches[nm] = id; matchSet[id] = true end
    end
  end
  currentMatch = 0
  if keepId and nm > 0 then
    local k = lowerBound(matches, keepId)
    currentMatch = math.min(k, nm)
  end
end

local function computeFilterKey()
  return table.concat({
    tostring(cfg.levelFilter.E), tostring(cfg.levelFilter.W), tostring(cfg.levelFilter.I),
    tostring(cfg.levelFilter.D), tostring(cfg.levelFilter.A),
    ffi.string(originFilterBuf), ffi.string(searchBuf),
    tostring(p.searchCase[0]), tostring(p.searchPattern[0]), tostring(cfg.searchHighlight)
  }, "\1")
end

local function applyFiltersNow()
  compileOrigin()
  compileSearch()
  rebuildFiltered()
  filterKey = computeFilterKey()
  refilterTimer = nil
end

---------------------------------------------------------------------------------------------------
-- log storage
---------------------------------------------------------------------------------------------------
local function trim()
  local limit = cfg.maxLines
  if (tail - head) <= limit + math.max(500, limit * 0.05) then return end
  local newHead = tail - limit
  for id = head, newHead - 1 do
    local e = logs[id]
    if e then
      if e[2] == "E" then counts.E = counts.E - 1 elseif e[2] == "W" then counts.W = counts.W - 1 end
    end
    logs[id] = nil
    if selected[id] then selected[id] = nil; selCount = selCount - 1; detailsDirty = true end
    matchSet[id] = nil
  end
  head = newHead
  if anchorId and anchorId < head then anchorId = nil end
  local beforeMatches = #matches
  filtered = pruneFront(filtered)
  matches = pruneFront(matches)
  if beforeMatches ~= #matches then
    currentMatch = math.max(0, currentMatch - (beforeMatches - #matches))
  end
end

local function pushEntry(t, lvl, origin, msg, groupId, cont)
  if #msg > MAX_LINE_LEN then msg = msg:sub(1, MAX_LINE_LEN) .. " ...(line truncated)" end
  local id = tail
  local e = {t, lvl, origin, msg, groupId or id, cont or false}
  logs[id] = e
  tail = tail + 1
  if not cont then
    if lvl == "E" then counts.E = counts.E + 1 elseif lvl == "W" then counts.W = counts.W + 1 end
  end
  local vis, m = classify(e)
  if vis then filtered[#filtered + 1] = id end
  if m then matches[#matches + 1] = id; matchSet[id] = true end
  return id
end

local function addLog(timer, lvl, origin, line)
  local t
  if type(timer) == "number" then t = string.format("%.3f", timer)
  elseif type(timer) == "string" then t = timer
  else t = tostring(timer) end
  lvl = tostring(lvl or "")
  origin = tostring(origin or "")
  local parts = splitLines(tostring(line or ""))
  local gid = pushEntry(t, lvl, origin, parts[1])
  for i = 2, #parts do pushEntry(t, lvl, origin, parts[i], gid, true) end
  trim()
end

local function clearConsole()
  logs, filtered, matches, matchSet = {}, {}, {}, {}
  head, tail = 1, 1
  counts = {E = 0, W = 0}
  pending = {}
  selected, selCount, anchorId = {}, 0, nil
  currentMatch = 0
  detailsDirty = true
end

-- back-fill from beamng.log (format: "  12.34567|L|origin| message", continuation lines have no prefix)
local function readLogFile()
  for _, path in ipairs(logFilePaths) do
    local ok, content = pcall(readFile, path)
    if ok and type(content) == "string" and #content > 0 then return content, path end
  end
  return nil
end

local function seedFromLogFile()
  local content, path = readLogFile()
  if not content then
    log("W", "xRlsDebugConsole", "could not read beamng.log to back-fill the console")
    return
  end
  -- keep only the last maxLines physical lines
  local limit = cfg.maxLines
  local ring, n = {}, 0
  for line in content:gmatch("([^\n]*)\n?") do
    n = n + 1
    ring[(n - 1) % limit + 1] = line
  end
  content = nil
  local first = math.max(1, n - limit + 1)
  local lastT, lastLvl, lastOrigin, lastGid = "", "A", "", nil
  local maxT
  for i = first, n do
    local line = ring[(i - 1) % limit + 1]
    if line then
      line = line:gsub("\r$", "")
      local t, lvl, origin, msg = line:match("^%s*([%d.]+)|(%a)|([^|]*)|(.*)$")
      if t then
        if msg:sub(1, 1) == " " then msg = msg:sub(2) end
        lastT, lastLvl, lastOrigin = t, lvl, origin
        lastGid = pushEntry(t, lvl, origin, msg)
        maxT = tonumber(t) or maxT
      elseif line ~= "" then
        if lastGid then
          pushEntry(lastT, lastLvl, lastOrigin, line, lastGid, true)
        else
          lastGid = pushEntry("", "A", "", line)
        end
      end
    end
  end
  trim()
  seedMaxT = maxT
  seedGuardFrames = 10
  log("I", "xRlsDebugConsole", string.format("back-filled %d lines from %s", tail - head, path))
end

local function captureFrame()
  local flog = Engine.getFrameLog and Engine.getFrameLog()
  if not flog then return end
  local guard = seedGuardFrames > 0 and seedMaxT
  if seedGuardFrames > 0 then seedGuardFrames = seedGuardFrames - 1 end
  for _, l in ipairs(flog) do
    if guard and type(l[1]) == "number" and l[1] <= seedMaxT then
      -- already read from beamng.log
    elseif paused then
      pending[#pending + 1] = l
      if #pending > cfg.maxLines then table.remove(pending, 1) end
    else
      addLog(l[1], l[2], l[3], l[4])
    end
  end
end

local function flushPending()
  local list = pending
  pending = {}
  for _, l in ipairs(list) do addLog(l[1], l[2], l[3], l[4]) end
end

local function setPaused(v)
  paused = v
  if not paused then flushPending() end
end

---------------------------------------------------------------------------------------------------
-- selection
---------------------------------------------------------------------------------------------------
local function clearSelection()
  if selCount > 0 then selected = {}; selCount = 0; detailsDirty = true end
end

local function selectId(id)
  if not selected[id] then selected[id] = true; selCount = selCount + 1; detailsDirty = true end
end

local function toggleId(id)
  if selected[id] then selected[id] = nil; selCount = selCount - 1 else selected[id] = true; selCount = selCount + 1 end
  detailsDirty = true
end

local function selectRows(a, b)
  if a > b then a, b = b, a end
  for r = math.max(1, a), math.min(#filtered, b) do selectId(filtered[r]) end
end

local function selectGroup(id)
  local e = logs[id]
  if not e then return end
  local gid = e[5]
  local i = gid
  while i < tail do
    local x = logs[i]
    if not x or x[5] ~= gid then break end
    if i >= head then selectId(i) end
    i = i + 1
  end
end

local function selectedIdsInOrder()
  local out = {}
  if selCount == 0 then return out end
  for id = head, tail - 1 do
    if selected[id] then out[#out + 1] = id end
  end
  return out
end

local function linesText(ids, messageOnly)
  local parts = {}
  for i, id in ipairs(ids) do
    local e = logs[id]
    if e then parts[#parts + 1] = messageOnly and e[4] or formatLine(e) end
  end
  return table.concat(parts, "\n")
end

local function copyIds(ids, messageOnly)
  if #ids == 0 then return end
  setClipboard(linesText(ids, messageOnly) .. "\n")
end

local function copySelected(messageOnly) copyIds(selectedIdsInOrder(), messageOnly) end

local function rebuildDetails()
  detailsDirty = false
  local ids = selectedIdsInOrder()
  local text
  if #ids == 0 then
    detailsHeader = "Nothing selected. Click a row to see its full text here."
    text = ""
  else
    local e = logs[ids[1]]
    local single = true
    for i = 2, #ids do if logs[ids[i]][5] ~= e[5] then single = false; break end end
    if single then
      detailsHeader = string.format("%s | %s | %s", e[1], e[2], e[3])
      text = linesText(ids, true)
    else
      detailsHeader = string.format("%d lines selected", #ids)
      text = linesText(ids, false)
    end
  end
  if #text > DETAILS_MAX_BYTES then
    text = text:sub(1, DETAILS_MAX_BYTES) .. "\n... (too much to show here; Ctrl+C still copies everything)"
  end
  detailsBuf = im.ArrayChar(#text + 1, text)
end

local function scrollToRow(row)
  pendingScrollRow = row
  followBottom = false
end

local function jumpToId(id, select)
  local row = bsearch(filtered, id)
  if not row then return end
  if select then clearSelection(); selectId(id); anchorId = id end
  scrollToRow(row)
end

local function gotoMatch(delta)
  local n = #matches
  if n == 0 then return end
  if currentMatch == 0 then
    -- start from the selection, or the bottom
    local from = anchorId or (delta > 0 and head - 1 or tail)
    if delta > 0 then
      currentMatch = lowerBound(matches, from + 1)
      if currentMatch > n then currentMatch = 1 end
    else
      currentMatch = lowerBound(matches, from) - 1
      if currentMatch < 1 then currentMatch = n end
    end
  else
    currentMatch = ((currentMatch - 1 + delta) % n) + 1
  end
  jumpToId(matches[currentMatch], true)
end

local function showInContext(id)
  cfg.searchHighlight = true
  applyFiltersNow()
  local k = bsearch(matches, id)
  if k then currentMatch = k end
  jumpToId(id, true)
  settingsSave()
end

---------------------------------------------------------------------------------------------------
-- export
---------------------------------------------------------------------------------------------------
local function exportIds(ids, what)
  if #ids == 0 then log("W", "xRlsDebugConsole", "nothing to export"); return end
  local stamp = os.date and os.date("%Y%m%d_%H%M%S") or tostring(math.floor(os.clock()))
  local path = "/console_export_" .. stamp .. ".txt"
  if writeFile(path, linesText(ids, false) .. "\n") then
    log("I", "xRlsDebugConsole", string.format("exported %d %s lines to %s (in the BeamNG user folder)", #ids, what, path))
  end
end

---------------------------------------------------------------------------------------------------
-- commands (same behaviour as the stock console)
---------------------------------------------------------------------------------------------------
function ConsoleInputCallback(data)
  if data.EventFlag == im.InputTextFlags_CallbackHistory then
    local prevHistoryPos = historyPos
    if data.EventKey == im.Key_UpArrow then
      historyPos = historyPos - 1
      if historyPos < 1 then
        if p.loopHistory[0] or historyPos < 0 then historyPos = #history else historyPos = 1 end
      end
    elseif data.EventKey == im.Key_DownArrow then
      historyPos = historyPos + 1
      if historyPos > #history then
        if p.loopHistory[0] then historyPos = 1 else historyPos = #history end
      end
      if prevHistoryPos == -1 then historyPos = 1 end
    end
    if #history > 0 and prevHistoryPos ~= historyPos then
      local t = history[historyPos]
      if type(t) ~= "string" then return 0 end
      local n = string.len(t)
      data.Buf = t
      data.CursorPos = n
      data.SelectionStart = n
      data.SelectionEnd = n
      data.BufTextLen = n
      data.BufDirty = true
    end
  elseif data.EventFlag == im.InputTextFlags_CallbackCharFilter and data.EventChar == 96 then -- '`'
    windowOpen[0] = false
    return 1
  end
  return 0
end

local function shiftTableEntry(t, old, new)
  local value = t[old]
  if new < old then table.move(t, new, old - 1, new + 1) else table.move(t, old + 1, new, old) end
  t[new] = value
end

local function setVehicleControlActive(b)
  for _, mapName in ipairs(vehicleActionMaps) do
    local map = scenetree.findObject(mapName)
    if map then map:setEnabled(b) end
  end
end

local function vehStrInfo(vobj)
  local strI = tostring(vobj:getId())
  strI = strI .. ", " .. vobj:getJBeamFilename()
  local pc = vobj.partConfig or ""
  if pc:sub(1, 1) == "{" or pc:sub(1, 1) == "[" then
    strI = strI .. ", *custom*"
  else
    strI = strI .. ", " .. tostring(string.match(pc, "([^./]*).pc"))
  end
  return strI .. ", " .. dumps(vobj.licenseText) .. "\0"
end

local function refreshCombo()
  comboCtxTxt = "GE - Lua\0GE - TorqueScript\0CEF/UI - JS\0"
  vehIds = {}
  if be and be:getObjectCount() > 0 then
    local playerVehicle = getPlayerVehicle(0)
    if playerVehicle and playerVehicle:getActive() then
      comboCtxTxt = comboCtxTxt .. "BeamNG - Current Vehicle " .. vehStrInfo(playerVehicle)
      vehIds = {be:getPlayerVehicleID(0)}
    end
    for i = 0, be:getObjectCount() - 1 do
      local v = be:getObject(i)
      if v:getActive() then
        table.insert(vehIds, v:getID())
        comboCtxTxt = comboCtxTxt .. "BeamNG - " .. vehStrInfo(v)
      end
    end
  end
  comboCtxTxt = comboCtxTxt .. "\0"
end

local function executeCommand(cmd)
  if history[historyPos] ~= cmd then
    table.insert(history, cmd)
  else
    shiftTableEntry(history, historyPos, #history)
  end
  historyPos = -1

  local ctx = comboCurrentItem[0]
  if ctx == 0 then
    if p.sandboxCmd[0] then
      log("I", "exec", "GELua(Sandboxed) < " .. dumps(cmd))
      local res, out = executeLuaSandboxed(cmd, 'GEConsole')
      if res then
        if type(res) == "string" and res:sub(1, 7) == "Error: " then
          log("E", "exec", res)
        else
          log("I", "exec", "return > " .. dumps(res))
        end
      end
      if out and #out > 0 then
        for _, le in ipairs(out) do print(le) end
      end
    else
      log("I", "exec", "GELua(Queue) < " .. dumps(cmd))
      Lua:queueLuaCommand(cmd)
    end
  elseif ctx == 1 then
    if not cmd:find(";[\n\r\t ]-$") then cmd = cmd .. ";" end
    log("I", "exec", "GE TS < " .. dumps(cmd))
    TorqueScript.eval(cmd)
  elseif ctx == 2 then
    log("I", "exec", "GE UI < " .. dumps(cmd))
    be:queueJS(cmd)
  else
    local vid = vehIds[ctx - 2]
    local v = vid and getObjectByID(vid)
    if not v then
      log("E", "exec", "Selected vehicle doesn't exist")
      refreshCombo()
    else
      log("I", "exec", "veh " .. tostring(vid) .. " < " .. dumps(cmd))
      v:queueLuaCommand(cmd)
    end
  end

  while #history > cfg.historySize do table.remove(history, 1) end
  jsonWriteFile(historyPath, history, true)
end

---------------------------------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------------------------------
local function show() windowOpen[0] = true end
local function hide() windowOpen[0] = false end
local function toggle() windowOpen[0] = not windowOpen[0] end

local function filteredWithLevels(levels)
  local out = {}
  for _, id in ipairs(filtered) do
    local e = logs[id]
    if e and levels[e[2]] then out[#out + 1] = id end
  end
  return out
end

local function menuBarContents()

  if im.BeginMenu("View") then guard(function()
    local changed = false
    changed = im.MenuItem2("Details pane", "", p.showDetails) or changed
    changed = im.MenuItem2("Line background", "", p.rowBg) or changed
    changed = im.MenuItem2("Tooltip on long text", "", p.tooltipOnLongTxt) or changed
    im.Separator()
    changed = im.MenuItem2("Loop history", "", p.loopHistory) or changed
    changed = im.MenuItem2("Sandbox GE commands", "", p.sandboxCmd) or changed
    changed = im.MenuItem2("Focus input on show", "", p.focusOnShow) or changed
    im.Separator()
    im.PushItemWidth(140)
    changed = im.SliderFloat("Font size", p.fontScale, 0.5, 2) or changed
    changed = im.SliderFloat("Details height", p.detailsHeight, 60, 800, "%.0f") or changed
    changed = im.SliderFloat("Background alpha", p.bgAlpha, 0.0, 1.0) or changed
    changed = im.SliderFloat("Background alpha fullscreen", p.bgAlphaFull, 0.0, 1.0) or changed
    im.PopItemWidth()
    if changed then settingsSave() end
    end); im.EndMenu()
  end

  if im.BeginMenu("Log") then guard(function()
    im.PushItemWidth(140)
    if im.InputInt("Max lines kept", p.maxLines, 1000, 10000) then
      p.maxLines[0] = math.max(MIN_LINES, math.min(MAX_LINES, p.maxLines[0]))
      settingsSave()
      trim()
    end
    im.PopItemWidth()
    if im.MenuItem2("Capture while console is closed", "", p.captureWhileHidden) then settingsSave() end
    if im.MenuItem2("Back-fill from beamng.log on load", "", p.seedFromLogFile) then settingsSave() end
    im.Separator()
    if im.MenuItem1("Reload everything from beamng.log") then
      clearConsole()
      seedFromLogFile()
    end
    if im.MenuItem1(paused and "Resume (Scroll Lock)" or "Pause (Scroll Lock)") then setPaused(not paused) end
    if im.MenuItem1("Clear") then clearConsole() end
    im.Separator()
    if im.MenuItem1("Export shown lines to file") then exportIds(filtered, "shown") end
    if im.MenuItem1("Export selected lines to file", nil, nil, selCount > 0) then exportIds(selectedIdsInOrder(), "selected") end
    end); im.EndMenu()
  end

  if im.BeginMenu("Copy") then guard(function()
    if im.MenuItem1("Copy selected lines", "Ctrl+C", nil, selCount > 0) then copySelected(false) end
    if im.MenuItem1("Copy selected messages only", nil, nil, selCount > 0) then copySelected(true) end
    im.Separator()
    if im.MenuItem1("Copy all shown lines") then copyIds(filtered) end
    if im.MenuItem1("Copy shown errors") then copyIds(filteredWithLevels({E = true})) end
    if im.MenuItem1("Copy shown errors and warnings") then copyIds(filteredWithLevels({E = true, W = true})) end
    if #matches > 0 and im.MenuItem1("Copy search matches") then copyIds(matches) end
    end); im.EndMenu()
  end

  if counts.E > 0 then im.TextColored(colors.E, "%s", tostring(counts.E) .. "E ") end
  if counts.W > 0 then im.TextColored(colors.W, "%s", tostring(counts.W) .. "W ") end
  im.TextColored(dimColor, "%s", string.format(" %d shown / %d kept (max %d)", #filtered, tail - head, cfg.maxLines))
  if selCount > 0 then im.TextUnformatted(string.format("  %d selected", selCount)) end
  if paused then im.TextColored(colors.W, "%s", string.format("  PAUSED (%d waiting)", #pending)) end

  local fsize = 24
  im.SetCursorPosX(im.GetCursorPosX() + im.GetContentRegionAvailWidth() - fsize * 2 - 8)
  if gui.uiIconImageButton(gui.icons.delete, {x = fsize, y = fsize}, iconButtonFgColor.Value, nil, iconButtonBgColor.Value, "xrls_console_clear") then
    clearConsole()
  end
  tip("Clear console")
  if gui.uiIconImageButton(cfg.fullscreen and gui.icons.fullscreen_exit or gui.icons.fullscreen, {x = fsize, y = fsize}, iconButtonFgColor.Value, nil, iconButtonBgColor.Value, "xrls_console_fullscreen") then
    if cfg.fullscreen then
      cfg.fullscreen = false
      im.SetWindowPos1(im.ImVec2(cfg.winstate[1] or 60, cfg.winstate[2] or 60), im.Cond_Always)
      im.SetWindowSize1(im.ImVec2(cfg.winstate[3] or 1400, cfg.winstate[4] or 850), im.Cond_Always)
    else
      cfg.fullscreen = true
      cfg.winstate = {im.GetWindowPos().x, im.GetWindowPos().y, im.GetWindowSize().x, im.GetWindowSize().y}
    end
    settingsSave()
  end
  tip(cfg.fullscreen and "Exit fullscreen" or "Go fullscreen")

end

local function menuBar()
  if not im.BeginMenuBar() then return end
  guard(menuBarContents)
  im.EndMenuBar()
end

local function iconToggle(icon, on, onColor, tipText)
  local imgsize = im.GetFrameHeight()
  local pressed = gui.uiIconImageButton(icon, {x = imgsize, y = imgsize}, on and onColor or iconButtonNoColor.Value, nil, iconButtonBgColor.Value)
  tip(tipText)
  im.SameLine()
  return pressed
end

local function toolbar()
  local lf = cfg.levelFilter
  if iconToggle(gui.icons.error, lf.E, iconColors.E.Value, "Errors") then lf.E = not lf.E; settingsSave() end
  if iconToggle(gui.icons.warning, lf.W, iconColors.W.Value, "Warnings") then lf.W = not lf.W; settingsSave() end
  if iconToggle(gui.icons.info, lf.I, iconColors.I.Value, "Info") then lf.I = not lf.I; settingsSave() end
  if iconToggle(gui.icons.bug_report, lf.D, iconColors.D.Value, "Debug") then lf.D = not lf.D; settingsSave() end
  if iconToggle(gui.icons.help, lf.A, iconButtonFgColor.Value, "Other") then lf.A = not lf.A; settingsSave() end
  im.Spacing(); im.SameLine()
  if iconToggle(gui.icons.directions_car, cfg.enableVehicleControls, iconButtonFgColor.Value, "Allow vehicle control while the console is open") then
    cfg.enableVehicleControls = not cfg.enableVehicleControls
    setVehicleControlActive(cfg.enableVehicleControls)
    settingsSave()
  end
  if iconToggle(gui.icons.vertical_align_bottom, forceAutoScroll, iconButtonFgColor.Value, "Always keep scrolled to the bottom") then
    forceAutoScroll = not forceAutoScroll
    if forceAutoScroll then followBottom = true end
  end
  if iconToggle(paused and gui.icons.play_arrow or gui.icons.pause, paused, colors.W, paused and "Resume (Scroll Lock)" or "Pause: new lines wait until you resume (Scroll Lock)") then
    setPaused(not paused)
  end
  im.Spacing(); im.SameLine()

  -- origin filter
  if originInvalid then im.PushStyleColor2(im.Col_FrameBg, im.ImVec4(0.6, 0, 0, 1)) end
  im.SetNextItemWidth(170)
  im.InputTextWithHint("##originFilter", "origin (Lua pattern)", originFilterBuf, im.ArraySize(originFilterBuf))
  if originInvalid then im.PopStyleColor() end
  tip(originInvalid and ("Invalid pattern: " .. originErr) or originHelp)
  im.SameLine()

  -- search
  if focusSearch then im.SetKeyboardFocusHere(); focusSearch = false end
  if searchInvalid then im.PushStyleColor2(im.Col_FrameBg, im.ImVec4(0.6, 0, 0, 1)) end
  im.SetNextItemWidth(math.max(200, im.GetContentRegionAvailWidth() - 330))
  local enter = im.InputTextWithHint("##search", "search (Ctrl+F)", searchBuf, im.ArraySize(searchBuf), im.InputTextFlags_EnterReturnsTrue)
  if searchInvalid then im.PopStyleColor() end
  tip(searchInvalid and ("Invalid pattern: " .. searchErr) or searchHelp)
  if enter then
    if refilterTimer then applyFiltersNow() end
    if cfg.searchHighlight then
      gotoMatch(im.GetIO().KeyShift and -1 or 1)
    end
    focusSearch = true
  end
  im.SameLine()
  if im.SmallButton("x##clearSearch") then ffi.fill(searchBuf, im.ArraySize(searchBuf)); applyFiltersNow() end
  tip("Clear search")
  im.SameLine()
  if im.Checkbox("Aa", p.searchCase) then settingsSave() end
  tip("Case sensitive")
  im.SameLine()
  if im.Checkbox(".*", p.searchPattern) then settingsSave() end
  tip("Treat the search as a Lua pattern")
  im.SameLine()
  if im.SmallButton(cfg.searchHighlight and "Highlight" or "Filter") then
    cfg.searchHighlight = not cfg.searchHighlight
    settingsSave()
    applyFiltersNow()
  end
  tip("Filter: hide lines that don't match.\nHighlight: show every line, highlight matches, jump between them.")
  if cfg.searchHighlight then
    im.SameLine()
    im.BeginDisabled(#matches == 0)
    if im.SmallButton("<##prevMatch") then gotoMatch(-1) end
    tip("Previous match (Shift+F3)")
    im.SameLine()
    if im.SmallButton(">##nextMatch") then gotoMatch(1) end
    tip("Next match (F3)")
    im.EndDisabled()
    im.SameLine()
    im.TextUnformatted(string.format("%s/%d", currentMatch > 0 and tostring(currentMatch) or "-", #matches))
  end
end

local function rowContextMenu(row, id, e)
  if not im.BeginPopupContextItem("##rowctx") then return end
  if not selected[id] then clearSelection(); selectId(id); anchorId = id end
  if im.MenuItem1("Copy line") then setClipboard(formatLine(e) .. "\n") end
  if im.MenuItem1("Copy message") then setClipboard(e[4] .. "\n") end
  if selCount > 1 then
    if im.MenuItem1(string.format("Copy %d selected lines", selCount)) then copySelected(false) end
    if im.MenuItem1(string.format("Copy %d selected messages", selCount)) then copySelected(true) end
  end
  if im.MenuItem1("Select whole message") then selectGroup(id) end
  im.Separator()
  if im.MenuItem1("Filter by this origin") then
    local pat = e[3]:lower():gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
    originFilterBuf = im.ArrayChar(256, "^" .. pat .. "$")
    applyFiltersNow()
    jumpToId(id, false)
  end
  if im.MenuItem1("Search for this origin") then
    searchBuf = im.ArrayChar(1024, '"' .. e[3] .. '"')
    p.searchPattern[0] = false
    applyFiltersNow()
  end
  if searchFn and not cfg.searchHighlight and im.MenuItem1("Show in context (switch search to highlight)") then
    showInContext(id)
  end
  if originPattern ~= "" and im.MenuItem1("Clear origin filter and show in context") then
    originFilterBuf = im.ArrayChar(256, "")
    applyFiltersNow()
    jumpToId(id, true)
  end
  im.EndPopup()
end

local function handleRowMouse(row, id)
  local io = im.GetIO()
  if im.IsItemClicked(0) then
    if io.KeyShift and anchorId then
      local a = bsearch(filtered, anchorId) or row
      if not io.KeyCtrl then clearSelection() end
      selectRows(a, row)
      dragAnchorRow = a
    elseif io.KeyCtrl then
      toggleId(id)
      anchorId = id
      dragAnchorRow = nil
    else
      clearSelection()
      selectId(id)
      anchorId = id
      dragAnchorRow = row
    end
    dragging = dragAnchorRow ~= nil
    dragLastRow = row
    followBottom = false
  elseif dragging and im.IsMouseDown(0) and row ~= dragLastRow
      and im.IsItemHovered(im.HoveredFlags_AllowWhenBlockedByActiveItem) then
    clearSelection()
    selectRows(dragAnchorRow, row)
    dragLastRow = row
  end
  if im.IsItemHovered() and im.IsMouseDoubleClicked(0) then
    clearSelection()
    selectGroup(id)
    anchorId = id
    if not p.showDetails[0] then p.showDetails[0] = true; settingsSave() end
  end
end

local function cellText(col, s)
  im.PushStyleColor2(im.Col_Text, col)
  im.TextUnformatted(s)
  im.PopStyleColor()
end

local function handleTableKeys()
  local io = im.GetIO()
  if io.WantTextInput then return end
  if io.KeyCtrl and im.IsKeyPressed(im.Key_C, false) then copySelected(false) end
  if io.KeyCtrl and im.IsKeyPressed(im.Key_A, false) then
    for _, id in ipairs(filtered) do selectId(id) end
  end
  if im.IsKeyPressed(im.Key_Escape, false) then clearSelection() end
  local dir = 0
  if im.IsKeyPressed(im.Key_UpArrow) then dir = -1 elseif im.IsKeyPressed(im.Key_DownArrow) then dir = 1 end
  if dir ~= 0 and #filtered > 0 then
    local cur = anchorId and bsearch(filtered, anchorId) or (dir > 0 and 0 or #filtered + 1)
    local nxt = math.max(1, math.min(#filtered, cur + dir))
    local id = filtered[nxt]
    if io.KeyShift then selectId(id) else clearSelection(); selectId(id) end
    anchorId = id
    scrollToRow(nxt)
  end
end

local function drawRow(row, id, e, curMatchId)
  if id == curMatchId then
    im.TableSetBgColor(im.TableBgTarget_RowBg1, currentMatchBgU32)
  elseif matchSet[id] then
    im.TableSetBgColor(im.TableBgTarget_RowBg1, matchBgU32)
  end
  im.TableSetColumnIndex(0)
  im.PushID1(tostring(id))
  local ok, err = xpcall(function()
    im.Selectable1("##row", selected[id] == true, im.SelectableFlags_SpanAllColumns + im.SelectableFlags_AllowOverlap)
    handleRowMouse(row, id)
    rowContextMenu(row, id, e)
  end, debug.traceback)
  im.PopID()
  if not ok then error(err, 0) end
  im.SameLine()
  local col = colors[e[2]] or defaultColor
  local headCol = e[6] and dimColor or col
  cellText(headCol, e[1])
  im.TableSetColumnIndex(1)
  cellText(headCol, e[2])
  im.TableSetColumnIndex(2)
  cellText(headCol, e[3])
  if p.tooltipOnLongTxt[0] and im.IsItemHovered() and im.CalcTextSize(e[3]).x > im.GetColumnWidth() then
    im.SetTooltip("%s", e[3])
  end
  im.TableSetColumnIndex(3)
  local msg = e[4]
  local shown = #msg > RENDER_LINE_LEN and (msg:sub(1, RENDER_LINE_LEN) .. " ...") or msg
  cellText(col, shown)
  if p.tooltipOnLongTxt[0] and im.IsItemHovered() and (#msg > RENDER_LINE_LEN or im.CalcTextSize(shown).x > im.GetColumnWidth()) then
    im.BeginTooltip()
    im.PushTextWrapPos(math.min(1200, im.GetMainViewport().WorkSize.x * 0.8))
    im.TextUnformatted(wrapForTooltip(msg))
    im.PopTextWrapPos()
    im.EndTooltip()
  end
end

local function tableBody()
  im.TableSetupScrollFreeze(0, 1)
    im.TableSetupColumn("time", im.TableColumnFlags_WidthStretch, 8)
    im.TableSetupColumn("lvl", im.TableColumnFlags_WidthStretch, 2)
    im.TableSetupColumn("origin", im.TableColumnFlags_WidthStretch, 18)
    im.TableSetupColumn("message", im.TableColumnFlags_WidthStretch, 72)
    im.TableHeadersRow()

    tableFocused = im.IsWindowFocused()
    if tableFocused then handleTableKeys() end
    if dragging and not im.IsMouseDown(0) then dragging = false end

    local curMatchId = currentMatchId()
    local clipper = im.ImGuiListClipper()
    im.ImGuiListClipper_Begin(clipper, #filtered, -1)
    local measuredY0, measuredRows = nil, 0
    while im.ImGuiListClipper_Step(clipper) do
      for row0 = clipper.DisplayStart, clipper.DisplayEnd - 1 do
        local row = row0 + 1
        local id = filtered[row]
        local e = id and logs[id]
        im.TableNextRow()
        if e then
          if not measuredY0 then measuredY0 = im.GetCursorPosY() end
          measuredRows = measuredRows + 1
          drawRow(row, id, e, curMatchId)
        end
      end
    end
    if measuredY0 and measuredRows > 1 then
      rowHeight = (im.GetCursorPosY() - measuredY0) / measuredRows
    end

    -- scrolling
    local scrollMax = im.GetScrollMaxY()
    if pendingScrollRow then
      local viewH = im.GetWindowHeight()
      local target = (pendingScrollRow - 1) * rowHeight - viewH * 0.5 + rowHeight
      im.SetScrollY(math.max(0, math.min(target, scrollMax)))
      pendingScrollRow = nil
      followBottom = false
    elseif forceAutoScroll or (followBottom and scrollMaxPrev ~= scrollMax) then
      im.SetScrollY(scrollMax)
    end
    local atBottom = im.GetScrollY() >= scrollMax - 2
    if not dragging and (im.IsWindowHovered() and im.GetIO().MouseWheel ~= 0 or im.IsMouseDragging(0)) then
      followBottom = atBottom
    elseif atBottom then
      followBottom = true
    end
    scrollMaxPrev = scrollMax
end

local function logTable(reserveBottom)
  local flags = im.TableFlags_Resizable + im.TableFlags_ScrollY + im.TableFlags_BordersOuter + im.TableFlags_Hideable
    + im.TableFlags_NoPadInnerX + (p.rowBg[0] and im.TableFlags_RowBg or 0)
  im.PushStyleVar2(im.StyleVar_FramePadding, im.ImVec2(0, 0))
  im.PushStyleColor2(im.Col_ChildBg, im.ImVec4(0, 0, 0, 0))
  local ok, err = true, nil
  if im.BeginTable("##xRlsLogTable", 4, flags, im.ImVec2(0, -reserveBottom)) then
    im.SetWindowFontScale(p.fontScale[0])
    local fontPushed = im.PushFont3("robotomono_regular")
    ok, err = xpcall(tableBody, debug.traceback)
    if fontPushed then im.PopFont() end
    im.SetWindowFontScale(1.0)
    im.EndTable()
  end
  im.PopStyleColor()
  im.PopStyleVar()
  if not ok then error(err, 0) end
end

local function detailsPane()
  if detailsDirty then rebuildDetails() end
  im.TextColored(dimColor, "%s", detailsHeader)
  im.SetWindowFontScale(p.fontScale[0])
  local fontPushed = im.PushFont3("robotomono_regular")
  im.InputTextMultiline("##details", detailsBuf, im.ArraySize(detailsBuf), im.ImVec2(-1, p.detailsHeight[0]), im.InputTextFlags_ReadOnly)
  if fontPushed then im.PopFont() end
  im.SetWindowFontScale(1.0)
end

local function commandLine(mustFocusKeyboard)
  local flags = im.InputTextFlags_EnterReturnsTrue + im.InputTextFlags_CallbackCompletion
    + im.InputTextFlags_CallbackHistory + im.InputTextFlags_CallbackCharFilter
  im.SetNextItemWidth(200)
  im.Combo2("##cmdctx", comboCurrentItem, comboCtxTxt)
  im.SameLine()
  if mustFocusKeyboard then im.SetKeyboardFocusHere() end
  im.SetNextItemWidth(im.GetContentRegionAvailWidth() - 70)
  local exec = im.InputText("##inputText", consoleInputField, im.ArraySize(consoleInputField), flags, ffi.C.ImGuiInputTextCallbackLua, "ConsoleInputCallback")
  im.SameLine()
  exec = im.SmallButton("execute") or exec
  if exec then
    previouslyShown = nil -- re-focus the input next frame
    local cmd = ffi.string(consoleInputField)
    if string.len(cmd) > 0 then
      executeCommand(cmd)
      ffi.fill(consoleInputField, im.ArraySize(consoleInputField))
    end
    followBottom = true
  end
end

local function handleWindowKeys()
  local io = im.GetIO()
  if io.KeyCtrl and im.IsKeyPressed(im.Key_F, false) then focusSearch = true end
  if im.IsKeyPressed(im.Key_F3) then
    if not cfg.searchHighlight and searchFn then
      cfg.searchHighlight = true
      applyFiltersNow()
    end
    gotoMatch(io.KeyShift and -1 or 1)
  end
end

local function windowBody(mustFocusKeyboard)
  if lastUiError then
    im.TextColored(colors.E, "%s", "Console UI error (logged once to beamng.log): " .. lastUiError)
    im.SameLine()
    if im.SmallButton("dismiss##uiErr") then lastUiError = nil end
  end
  if im.IsWindowFocused(im.FocusedFlags_RootAndChildWindows) then guard(handleWindowKeys) end
  guard(menuBar)
  guard(toolbar)

  local style = im.GetStyle()
  local reserve = im.GetFrameHeightWithSpacing() + style.ItemSpacing.y
  if p.showDetails[0] then
    reserve = reserve + p.detailsHeight[0] + im.GetTextLineHeightWithSpacing() + style.ItemSpacing.y * 2
  end
  guard(logTable, reserve)
  if p.showDetails[0] then guard(detailsPane) end
  guard(commandLine, mustFocusKeyboard)

  if not cfg.fullscreen then
    local pos, size = im.GetWindowPos(), im.GetWindowSize()
    cfg.winstate = {pos.x, pos.y, size.x, size.y}
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if windowOpen[0] ~= true then
    if previouslyShown ~= nil then setVehicleControlActive(true) end
    previouslyShown = nil
    if p.captureWhileHidden[0] then captureFrame() end
    return
  end

  local mustFocusKeyboard = p.focusOnShow[0] and not previouslyShown
  if not previouslyShown then setVehicleControlActive(cfg.enableVehicleControls) end
  previouslyShown = true

  if im.IsKeyReleased(im.Key_ScrollLock) then setPaused(not paused) end
  captureFrame()

  -- debounce re-filtering while typing
  local key = computeFilterKey()
  if key ~= filterKey then
    filterKey = key
    refilterTimer = 0.15
  end
  if refilterTimer then
    refilterTimer = refilterTimer - (dtReal or 0.016)
    if refilterTimer <= 0 then applyFiltersNow() end
  end

  if not matchBgU32 then
    matchBgU32 = im.GetColorU322(im.ImVec4(0.55, 0.45, 0.0, 0.35))
    currentMatchBgU32 = im.GetColorU322(im.ImVec4(0.9, 0.6, 0.0, 0.7))
  end

  if cfg.fullscreen then
    local vp = im.GetMainViewport()
    im.SetNextWindowPos(vp.WorkPos, im.Cond_Always)
    im.SetNextWindowSize(vp.WorkSize, im.Cond_Always)
    im.SetNextWindowBgAlpha(p.bgAlphaFull[0])
  else
    im.SetNextWindowPos(im.ImVec2(cfg.winstate[1] or 60, cfg.winstate[2] or 60), im.Cond_FirstUseEver)
    im.SetNextWindowSize(im.ImVec2(cfg.winstate[3] or 1400, cfg.winstate[4] or 850), im.Cond_FirstUseEver)
    im.SetNextWindowBgAlpha(p.bgAlpha[0])
  end

  local wflags = im.WindowFlags_MenuBar
  if cfg.fullscreen then
    wflags = wflags + im.WindowFlags_NoResize + im.WindowFlags_NoMove + im.WindowFlags_NoCollapse + im.WindowFlags_NoDocking + im.WindowFlags_NoTitleBar
  end
  if im.Begin(winTitle, windowOpen, wflags) then
    guard(windowBody, mustFocusKeyboard)
  end
  im.End()
end

---------------------------------------------------------------------------------------------------
-- lifecycle
---------------------------------------------------------------------------------------------------
local function onSerialize()
  local d = {
    windowOpen = windowOpen[0],
    originFilter = ffi.string(originFilterBuf),
    search = ffi.string(searchBuf),
    forceAutoScroll = forceAutoScroll,
  }
  local tmp = ffi.string(consoleInputField)
  if tmp and #tmp > 0 then d.consoleInputField = tmp end
  if not cfg.fullscreen then settingsSave() end
  return d
end

local function onDeserialized(data)
  windowOpen[0] = data.windowOpen or false
  originFilterBuf = im.ArrayChar(256, data.originFilter or "")
  searchBuf = im.ArrayChar(1024, data.search or "")
  if data.consoleInputField then ffi.copy(consoleInputField, tostring(data.consoleInputField)) end
  forceAutoScroll = data.forceAutoScroll or false
  applyFiltersNow()
end

local function onExtensionLoaded()
  settingsLoad()
  if not history then history = jsonReadFile(historyPath) or {} end
  guiModule.initialize(gui)
  refreshCombo()
  applyFiltersNow()
  if p.seedFromLogFile[0] then
    local ok, err = pcall(seedFromLogFile)
    if not ok then log("E", "xRlsDebugConsole", "back-fill failed: " .. tostring(err)) end
  end
end

local function onExtensionUnloaded()
  setVehicleControlActive(true)
end

local function onFileChanged(filename)
  if string.match(string.lower(filename), "/?" .. string.lower(historyPath)) then
    history = jsonReadFile(historyPath) or {}
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.onUpdate = onUpdate
M.onFileChanged = onFileChanged

M.show = show
M.hide = hide
M.toggle = toggle
M.clear = clearConsole
M.reloadFromLogFile = function() clearConsole(); seedFromLogFile() end

-- internals, for the offline test in tools/
M._t = {
  addLog = addLog, clear = clearConsole, seed = seedFromLogFile, applyFilters = applyFiltersNow,
  setSearch = function(q) searchBuf = im.ArrayChar(1024, q) end,
  setOrigin = function(q) originFilterBuf = im.ArrayChar(256, q) end,
  cfg = cfg, p = p,
  state = function() return {head = head, tail = tail, logs = logs, filtered = filtered, matches = matches,
    selected = selected, selCount = selCount, counts = counts, currentMatch = currentMatch, pending = pending} end,
  selectRows = selectRows, selectGroup = selectGroup, clearSelection = clearSelection, gotoMatch = gotoMatch,
  copySelected = copySelected, rebuildDetails = rebuildDetails, details = function() return ffi.string(detailsBuf), detailsHeader end,
  setPaused = setPaused, captureFrame = captureFrame, trim = trim,
}

M.onVehicleDestroyed = refreshCombo
M.onVehicleSwitched = refreshCombo
M.onVehicleSpawned = refreshCombo
M.onVehicleActiveChanged = refreshCombo

return M
