-- Offline smoke test of the console's drawing code: runs onUpdate with the window open against a stub ImGui that
-- opens every menu and popup, and checks that every Begin/Push has its End/Pop and that no UI error was logged.
-- Usage (from the project folder): luajit tools/test_ui.lua
local realffi = require("ffi")
_G.ffi = setmetatable({C = {}}, {__index = realffi})

function nop() end
local errors = {}
function log(l, o, m) if l == "E" then errors[#errors + 1] = o .. ": " .. tostring(m) end end
function dumps(x) return tostring(x) end
local files = {}
function jsonReadFile(p) return files[p] end
function jsonWriteFile(p, d) files[p] = d end
function readFile(p) if p == "beamng.log" then return "  1.0|I|a| hello\n  2.0|E|b| boom\n\tat line 3\n" end end
function writeFile() return true end
function setClipboard() end
local frameLog = {}
Engine = {getFrameLog = function() local f = frameLog; frameLog = {}; return f end}
scenetree = {findObject = function() return nil end}
beamng_appname, beamng_versiond, beamng_buildtype, beamng_arch = "BeamNG.drive", "0.40", "RELEASE", "x64"
package.preload["ge/extensions/editor/api/gui"] = function()
  return {initialize = function(g)
    g.icons = setmetatable({}, {__index = function(_, k) return k end})
    g.uiIconImageButton = function() return false end
  end}
end

-- balance tracking ------------------------------------------------------------------------------
local depth = {}
local problems = {}
local function open(kind) depth[kind] = (depth[kind] or 0) + 1 end
local function close(kind)
  depth[kind] = (depth[kind] or 0) - 1
  if depth[kind] < 0 then problems[#problems + 1] = "extra close of " .. kind end
end

local num = function() return 20 end
local vec = function() return {x = 100, y = 20} end
local im = {}
setmetatable(im, {__index = function(_, k)
  if k:match("^%u%w*_") then return 1 end           -- enum constants such as TableFlags_ScrollY
  return function() return false end                -- anything else: a call that does nothing
end})
function im.BoolPtr(v) return {[0] = v} end
im.IntPtr, im.FloatPtr = im.BoolPtr, im.BoolPtr
function im.ImVec4(...) return {...} end
function im.ImVec2(x, y) return {x = x, y = y} end
function im.ImColorByRGB() return {Value = {}} end
function im.ArrayChar(len, val)
  val = val or ""
  local b = realffi.new("char[?]", math.max(len, #val + 1))
  realffi.copy(b, val)
  return b
end
function im.ArraySize(b) return realffi.sizeof(b) end
function im.GetIO() return {KeyCtrl = false, KeyShift = false, WantTextInput = false, MouseWheel = 0} end
function im.GetStyle() return {ItemSpacing = {x = 4, y = 4}} end
function im.GetMainViewport() return {WorkPos = {x = 0, y = 0}, WorkSize = {x = 1920, y = 1080}} end
for _, n in ipairs({"GetFrameHeight", "GetFrameHeightWithSpacing", "GetTextLineHeightWithSpacing", "GetContentRegionAvailWidth",
  "GetCursorPosX", "GetCursorPosY", "GetScrollMaxY", "GetScrollY", "GetWindowHeight", "GetColumnWidth", "GetColorU322"}) do im[n] = num end
im.CalcTextSize, im.GetWindowPos, im.GetWindowSize = vec, vec, vec
im.IsItemHovered = function() return true end       -- exercise tooltips
im.IsWindowFocused = function() return true end
im.PushFont3 = function() open("font"); return true end
im.PopFont = function() close("font") end
for _, pair in ipairs({
  {"Begin", "End", "window", true}, {"BeginTable", "EndTable", "table", true}, {"BeginMenuBar", "EndMenuBar", "menubar", true},
  {"BeginMenu", "EndMenu", "menu", true}, {"BeginPopupContextItem", "EndPopup", "popup", true},
  {"BeginTooltip", "EndTooltip", "tooltip", true}, {"BeginDisabled", "EndDisabled", "disabled", nil},
}) do
  local b, e, kind, ret = pair[1], pair[2], pair[3], pair[4]
  im[b] = function() open(kind); if ret == nil then return end; return ret end
  im[e] = function() close(kind) end
end
-- ImGui rule: End() is always called after Begin(); EndTable/EndMenu/EndPopup/EndMenuBar only when Begin* returned true
for _, pair in ipairs({{"PushStyleColor2", "PopStyleColor", "stylecolor"}, {"PushStyleVar2", "PopStyleVar", "stylevar"},
  {"PushID1", "PopID", "id"}, {"PushItemWidth", "PopItemWidth", "itemwidth"}, {"PushTextWrapPos", "PopTextWrapPos", "wrap"}}) do
  im[pair[1]] = function() open(pair[3]) end
  im[pair[2]] = function() close(pair[3]) end
end
function im.ImGuiListClipper() return {DisplayStart = 0, DisplayEnd = 0, steps = 0} end
function im.ImGuiListClipper_Begin(c, n) c.n = n end
function im.ImGuiListClipper_Step(c)
  c.steps = c.steps + 1
  if c.steps > 1 then return false end
  c.DisplayStart, c.DisplayEnd = 0, math.min(c.n, 30)
  return true
end
ui_imgui = im

local M = dofile("mod/lua/ge/extensions/ui/console.lua")
M.onExtensionLoaded()
M._t.cfg.searchHighlight = true
M._t.setSearch("boom"); M._t.applyFilters()
M._t.selectRows(1, 3)
M.show()
for frame = 1, 3 do
  frameLog = {{10 + frame, "W", "x", "frame " .. frame .. " " .. string.rep("long ", 400)}}
  M.onUpdate(0.2)
end
M._t.cfg.fullscreen = true
M.onUpdate(0.2)

local failures = 0
for k, v in pairs(depth) do
  if v ~= 0 then failures = failures + 1; print("FAIL unbalanced " .. k .. ": " .. v) end
end
for _, pr in ipairs(problems) do failures = failures + 1; print("FAIL " .. pr) end
for _, e in ipairs(errors) do failures = failures + 1; print("FAIL logged error: " .. e) end
local s = M._t.state()
if s.tail - s.head ~= 6 then failures = failures + 1; print("FAIL expected 6 rows, got " .. (s.tail - s.head)) end
print(failures == 0 and "ALL PASSED (window, menus, popups, tooltips drawn; stacks balanced; no UI errors)" or (failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)
