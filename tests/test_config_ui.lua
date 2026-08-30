--------------------------------------------------------------------------------
-- The settings pages, drawn through the REAL PeaversCommons widgets.
--
-- The bug these exist for: every body paragraph on both tabs ran off the right
-- of the panel as one endless line, so the Pace tab - which is nothing but a
-- paragraph - could not be read at all. The pages had asked for wrapping all
-- along (`{ width = width, wrap = true }`); `W:CreateLabel` accepted the table
-- and ignored both keys, never calling SetWidth or SetWordWrap. Nothing errored.
-- A FontString with no width simply sizes itself to its text and stays on one
-- line, which is exactly what it looks like.
--
-- So this loads the real Widgets.lua rather than stubbing it. A stub would have
-- happily recorded the options it was passed and agreed with the pages, which is
-- precisely the agreement that was already there and already wrong. What is
-- asserted is the thing a player can see: nothing is drawn wider than the panel
-- it is drawn in.
--
-- Needs PeaversCommons beside this addon, or PEAVERS_COMMONS pointing at it.
--------------------------------------------------------------------------------

local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$") or "."
local harness = dofile(here .. "/harness.lua")

local failures = 0
local checks = 0

local function check(ok, label)
	checks = checks + 1
	io.write(("  %s  %s\n"):format(ok and "ok  " or "FAIL", label))
	if not ok then
		failures = failures + 1
	end
end

local function case(name, fn)
	io.write(name .. "\n")
	fn()
end

--------------------------------------------------------------------------------
-- Where PeaversCommons is
--------------------------------------------------------------------------------

local function commonsRoot()
	local root = os.getenv("PEAVERS_COMMONS")
	if not root then
		-- Beside the addon (a normal checkout), else beside the repo the worktree
		-- belongs to (`<repo>/.claude/worktrees/<name>`).
		for _, candidate in ipairs({
			here .. "/../../PeaversCommons",
			here .. "/../../../../../PeaversCommons",
		}) do
			local toc = io.open(candidate .. "/PeaversCommons.toc", "r")
			if toc then
				toc:close()
				root = candidate
				break
			end
		end
	end
	assert(root, "cannot find PeaversCommons - set PEAVERS_COMMONS")
	return root
end

--------------------------------------------------------------------------------
-- A game stub that remembers geometry
--
-- The shared harness deliberately forgets everything a frame is told, because
-- its tests are about announcements. These are about pixels, so the widths and
-- the wrapping have to survive.
--------------------------------------------------------------------------------

local PANEL_WIDTH = 400

---Rough advance width of one character at the widget font size. The exact
---number does not matter - what matters is that a long string measures far
---wider than the panel unless something wrapped it.
local CHAR_WIDTH = 6
local LINE_HEIGHT = 14

local drawn = {}

local function newFontString(owner)
	-- Everything recorded lives in `rec`, which is a plain table. The permissive
	-- metatable below answers ANY missing key with a function, so a field left
	-- nil on the FontString itself would read back as a function rather than as
	-- nil - `math.min(self.width, ...)` then throws "attempt to compare number
	-- with function" and the geometry is never checked at all.
	local fs = {
		owner = owner,
		rec = {
			text = "",
			width = nil,
			wordWrap = nil, -- nil = never asked; WoW's own default is to wrap
			justifyH = nil,
			justifyV = nil,
		},
	}

	function fs:SetText(text) self.rec.text = tostring(text or "") end
	function fs:GetText() return self.rec.text end
	function fs:SetWidth(width) self.rec.width = width end
	function fs:SetWordWrap(on) self.rec.wordWrap = on end
	function fs:SetJustifyH(justify) self.rec.justifyH = justify end
	function fs:SetJustifyV(justify) self.rec.justifyV = justify end
	function fs:GetFont() return "Fonts\\FRIZQT__.TTF", 12, "" end

	---How wide the string would be on one unwrapped line.
	function fs:NaturalWidth()
		local longest = 0
		for line in (self.rec.text .. "\n"):gmatch("([^\n]*)\n") do
			longest = math.max(longest, #line * CHAR_WIDTH)
		end
		return longest
	end

	---What the player actually sees. A width caps it; without one the FontString
	---sizes itself to the text and there is nothing to make it wrap.
	function fs:RenderedWidth()
		local width, wrap = self.rec.width, self.rec.wordWrap
		if width and wrap ~= false then
			return math.min(width, self:NaturalWidth())
		end
		return self:NaturalWidth()
	end

	function fs:GetStringWidth() return self:RenderedWidth() end

	function fs:GetStringHeight()
		local width = self.rec.width
		if not width or self.rec.wordWrap == false then
			return LINE_HEIGHT
		end
		local lines = 0
		for paragraph in (self.rec.text .. "\n"):gmatch("([^\n]*)\n") do
			lines = lines + math.max(1, math.ceil((#paragraph * CHAR_WIDTH) / width))
		end
		return lines * LINE_HEIGHT
	end

	drawn[#drawn + 1] = fs

	-- Anything else a FontString is told is chrome; swallow it and keep the
	-- recorded fields intact.
	return setmetatable(fs, {
		__index = function(self, key)
			local fn = function() return self end
			rawset(self, key, fn)
			return fn
		end,
	})
end

local function newFrame(width)
	local frame = { height = 1 }

	frame.CreateFontString = function(self) return newFontString(self) end
	frame.SetHeight = function(self, h) self.height = h end
	frame.GetHeight = function(self) return self.height end
	frame.SetWidth = function(self, w) self.width = w end
	frame.GetWidth = function(self) return self.width or width or 0 end
	frame.CreateTexture = function() return newFrame(width) end
	frame.GetNumPoints = function() return 0 end
	frame.GetStringWidth = function() return 50 end
	frame.IsShown = function() return true end
	frame.GetObjectType = function() return "Frame" end
	frame.GetScale = function() return 1 end
	frame.GetEffectiveScale = function() return 1 end

	return setmetatable(frame, {
		__index = function(self, key)
			local fn = function() return self end
			rawset(self, key, fn)
			return fn
		end,
	})
end

--------------------------------------------------------------------------------
-- Load the real widgets, then the addon
--------------------------------------------------------------------------------

local game = harness.stubGame()
_G.CreateFrame = function() return newFrame(PANEL_WIDTH) end
_G.UIParent = newFrame(PANEL_WIDTH)
_G.unpack = _G.unpack or table.unpack
_G.GetLocale = function() return "enUS" end

---A font object. Theme builds one to letter-space the section eyebrows; the
---headers are short and are not what this file is checking, so it only has to
---exist and answer.
_G.CreateFont = function()
	local font = {}
	font.GetFont = function() return "Fonts\\FRIZQT__.TTF", 12, "" end
	font.SetFont = function() return true end
	return setmetatable(font, {
		__index = function(self, key)
			local fn = function() return self end
			rawset(self, key, fn)
			return fn
		end,
	})
end

local commons = harness.stubCommons(game)

-- Theme first: Widgets aliases `Theme.Colors` at load time.
local root = commonsRoot()
assert(loadfile(root .. "/src/UI/Theme.lua"))("PeaversCommons", {})
assert(loadfile(root .. "/src/UI/Widgets.lua"))("PeaversCommons", {})
assert(commons.Widgets, "PeaversCommons.Widgets did not load")

local splitsRoot = here .. "/.."
local dataRoot = os.getenv("PEAVERS_SPLITS_DATA")
if dataRoot then
	harness.loadAddon(dataRoot, "PeaversSplitsData")
end
local PS = harness.loadAddon(splitsRoot, "PeaversSplits")
assert(commons._ready, "PeaversSplits never registered a bootstrap")
commons._ready()

--------------------------------------------------------------------------------

local function buildPage(builder)
	drawn = {}
	local panel = newFrame(PANEL_WIDTH)
	panel:SetWidth(PANEL_WIDTH)
	builder(PS.ConfigUI, panel)
	return panel, drawn
end

local PAGES = {
	{ name = "Pace", builder = PS.ConfigUI.BuildPacePage },
	{ name = "Announcements", builder = PS.ConfigUI.BuildAnnouncementsPage },
}

for _, page in ipairs(PAGES) do
	case(("The %s tab"):format(page.name), function()
		local panel, strings = buildPage(page.builder)

		check(#strings > 0, "draws something")

		-- The bug, stated as the player saw it.
		local widest, widestText = 0, ""
		for _, fs in ipairs(strings) do
			local w = fs:RenderedWidth()
			if w > widest then
				widest, widestText = w, fs.rec.text
			end
		end
		check(widest <= PANEL_WIDTH,
			("nothing is drawn wider than the %dpx panel (widest is %dpx)")
				:format(PANEL_WIDTH, widest))
		if widest > PANEL_WIDTH then
			io.write(("        overflows: %s...\n"):format(widestText:sub(1, 70)))
		end

		-- Body copy is the thing that has to wrap. A paragraph that fits on one
		-- line at this width would pass the check above by accident, so require
		-- the long ones to have actually been given a width to wrap against.
		for _, fs in ipairs(strings) do
			if #fs.rec.text > 120 then
				check(fs.rec.width ~= nil and fs.rec.width > 0,
					("a %d-character paragraph has a wrap width"):format(#fs.rec.text))
				check(fs.rec.justifyH == "LEFT",
					"body copy is left-justified, not centred on each line")
			end
		end

		-- The page is a scroll child; PeaversConfig creates it 1px tall and a
		-- scroll frame takes its range from the child, so a page that never sets
		-- its own height cannot be scrolled to the bottom.
		check(panel:GetHeight() > 1,
			("sets its own height for scrolling (%d)"):format(panel:GetHeight()))
	end)
end

--------------------------------------------------------------------------------

io.write(("\n%d checks, %d failed\n"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
