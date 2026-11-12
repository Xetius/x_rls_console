-- Offline test of the console's log storage, search, selection and back-fill logic, with ImGui stubbed out.
-- Usage (from the project folder): luajit tools/test_console.lua
local ffi = require("ffi")
_G.ffi = ffi

-- engine stubs ----------------------------------------------------------------------------------
function nop() end
local logged = {}
function log(l, o, m) logged[#logged + 1] = l .. "|" .. o .. "|" .. tostring(m) end
function dumps(x) return tostring(x) end
local files = {}
function jsonReadFile(p) return files[p] end
function jsonWriteFile(p, d) files[p] = d end
local fakeLog
function readFile(p) if p == "/beamng.log" then return fakeLog end end
function writeFile(p, d) files[p] = d; return true end
local clipboard
function setClipboard(s) clipboard = s end
local frameLog = {}
Engine = {getFrameLog = function() local f = frameLog; frameLog = {}; return f end}
beamng_appname, beamng_versiond, beamng_buildtype, beamng_arch = "BeamNG.drive", "0.40", "RELEASE", "x64"
package.preload["ge/extensions/editor/api/gui"] = function() return {initialize = function() end} end

local im = setmetatable({}, {__index = function() return function() return false end end})
function im.BoolPtr(v) return {[0] = v} end
im.IntPtr, im.FloatPtr = im.BoolPtr, im.BoolPtr
function im.ImVec4(...) return {...} end
function im.ImVec2(x, y) return {x = x, y = y} end
function im.ImColorByRGB() return {Value = {}} end
function im.ArrayChar(len, val)
  val = val or ""
  local n = math.max(len, #val + 1)
  local b = ffi.new("char[?]", n)
  ffi.copy(b, val)
  return b
end
function im.ArraySize(b) return ffi.sizeof(b) end
ui_imgui = im

local M = dofile("mod/lua/ge/extensions/ui/console.lua")
local T = M._t

local failures = 0
local function check(cond, msg)
  if cond then print("ok   " .. msg) else failures = failures + 1; print("FAIL " .. msg) end
end
local function ids2msgs(ids)
  local s, out = T.state(), {}
  for _, id in ipairs(ids) do out[#out + 1] = s.logs[id][4] end
  return table.concat(out, ",")
end

-- back-fill from beamng.log ----------------------------------------------------------------------
fakeLog = table.concat({
  "  0.00364|D|logging| -- Log started",
  "  1.50000|I|career_career| loading save",
  "  2.00000|E|lua.utils| boom: stack traceback:",
  "\t[C]: in function 'error'",
  "\tfoo.lua:12: in main chunk",
  "  3.25000|W|rls_vehicle| odd thing",
  ""}, "\n")
M.onExtensionLoaded()
local s = T.state()
check(s.tail - s.head == 6, "back-fill reads 6 rows (multi-line error split into 3)")
check(s.logs[s.head + 3][6] == true and s.logs[s.head + 3][5] == s.head + 2, "continuation rows belong to their message")
check(s.counts.E == 1 and s.counts.W == 1, "error/warning counts count messages, not rows")
check(s.logs[s.head + 1][4] == "loading save", "leading space after the origin separator is dropped")

-- frame capture skips lines already read from the file, keeps capturing while closed ---------------
frameLog = {{3.0, "W", "rls_vehicle", "odd thing"}, {4.0, "I", "core_x", "new line\nsecond"}}
M.onUpdate(0.016)
s = T.state()
check(s.tail - s.head == 8, "frame log captured while console closed, old line skipped, new one split")

-- search: filter mode ------------------------------------------------------------------------------
T.setSearch("boom"); T.applyFilters()
check(ids2msgs(T.state().filtered) == "boom: stack traceback:", "plain search filters by message")
T.setSearch("CAREER"); T.applyFilters()
check(ids2msgs(T.state().filtered) == "loading save", "search matches origin, case-insensitively")
T.p.searchCase[0] = true; T.applyFilters()
check(#T.state().filtered == 0, "case-sensitive search")
T.p.searchCase[0] = false
T.setSearch('"odd thing"'); T.applyFilters()
check(ids2msgs(T.state().filtered) == "odd thing", "quoted phrase")
T.setSearch("line -second"); T.applyFilters()
check(ids2msgs(T.state().filtered) == "new line", "word with -exclusion")
T.p.searchPattern[0] = true
T.setSearch("^%d"); T.applyFilters()
check(#T.state().filtered == 0, "Lua pattern mode")
T.setSearch("foo%.lua:%d+"); T.applyFilters()
check(ids2msgs(T.state().filtered) == "\tfoo.lua:12: in main chunk", "Lua pattern finds continuation line")
T.setSearch("[unclosed"); T.applyFilters()
check(#T.state().filtered == 8, "invalid pattern doesn't hide everything")
T.p.searchPattern[0] = false

-- search: highlight mode + navigation -----------------------------------------------------------------
T.cfg.searchHighlight = true
T.setSearch([["in "]]); T.applyFilters()
s = T.state()
check(#s.filtered == 8 and #s.matches == 2, "highlight mode keeps all rows, lists 2 matches")
T.gotoMatch(1); local first = T.state().currentMatch
T.gotoMatch(1); T.gotoMatch(-1); T.gotoMatch(1); T.gotoMatch(1)
check(T.state().currentMatch == first, "match navigation wraps around")
check(T.state().selCount == 1, "jumping to a match selects it")
T.cfg.searchHighlight = false
T.setSearch(""); T.applyFilters()

-- level and origin filters ------------------------------------------------------------------------------
T.cfg.levelFilter.D = false; T.applyFilters()
check(#T.state().filtered == 7, "level filter hides debug")
T.cfg.levelFilter.D = true
T.setOrigin("^rls"); T.applyFilters()
check(ids2msgs(T.state().filtered) == "odd thing", "origin Lua pattern filter")
T.setOrigin(""); T.applyFilters()

-- selection, copy, details -----------------------------------------------------------------------------------
T.clearSelection()
T.selectRows(3, 5)
T.copySelected(false)
check(clipboard == "2.00000|E|lua.utils|boom: stack traceback:\n2.00000|E|lua.utils|\t[C]: in function 'error'\n2.00000|E|lua.utils|\tfoo.lua:12: in main chunk\n", "copy selected range as full lines")
T.rebuildDetails()
local text, header = T.details()
check(header == "2.00000 | E | lua.utils" and text:find("stack traceback", 1, true) and text:find("main chunk", 1, true), "details pane shows one whole message without prefixes")
T.clearSelection(); T.selectGroup(T.state().head + 3)
check(T.state().selCount == 3, "double-click selects the whole multi-line message")
T.copySelected(true)
check(clipboard:sub(1, 5) == "boom:", "copy messages only")

-- pause buffers instead of dropping ------------------------------------------------------------------------
T.setPaused(true)
frameLog = {{5.0, "I", "x", "while paused"}}
T.captureFrame()
check(#T.state().pending == 1 and T.state().tail - T.state().head == 8, "paused lines wait")
T.setPaused(false)
check(T.state().tail - T.state().head == 9, "resuming adds them")

-- line limit and trimming --------------------------------------------------------------------------------------
T.clear()
T.cfg.maxLines = 1000
for i = 1, 5000 do T.addLog(i, i % 10 == 0 and "E" or "I", "o", "line " .. i) end
s = T.state()
check(s.tail - s.head <= 1500 and s.tail - s.head >= 1000, "trims to roughly maxLines")
check(s.logs[s.tail - 1][4] == "line 5000" and s.filtered[1] >= s.head, "keeps newest lines, filtered list pruned")
check(s.counts.E == math.floor((s.tail - s.head) / 10 + 0.5) or math.abs(s.counts.E - (s.tail - s.head) / 10) <= 1, "error count follows trimming")
T.addLog(1, "I", "o", string.rep("x", 100000))
s = T.state()
check(#s.logs[s.tail - 1][4] < 70000, "very long lines are capped")

print(failures == 0 and "\nALL PASSED" or ("\n" .. failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
