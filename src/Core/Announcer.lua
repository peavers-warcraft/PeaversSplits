--------------------------------------------------------------------------------
-- Announcer - putting a split where the group can read it
--
-- Two destinations, and the difference matters:
--
--   Split() goes to the configured CHANNEL. Other people read it.
--   Local()  goes only to the player's own frame. Nobody else sees it.
--
-- Anything about the addon's own state - "no pace published", "data addon
-- missing" - is Local. Nobody else in the party installed this and nobody else
-- needs to hear about its configuration. Only the split itself is worth four
-- other people's chat frame.
--
-- ## The channel rules, which are about not being a nuisance
--
-- 1. PARTY ONLY, and only inside a party. `SendChatMessage("...", "PARTY")`
--    outside a group errors, and a keystone is by definition a five-man, so the
--    guard costs nothing and covers the solo-testing case.
--
-- 2. NEVER SAY OR YELL. They reach everyone standing nearby, none of whom asked
--    for it. The config does not offer them and this file would refuse them
--    anyway - a config value is not a permission slip.
--
-- 3. NEVER OUTSIDE A KEYSTONE. Everything here is driven off Run, which is only
--    active between CHALLENGE_MODE_START and completion, so there is no path
--    from a raid boss to a party message. The `activeChannel` guard is the
--    belt-and-braces.
--
-- 4. ONE LINE PER BOSS. Run already dedupes ENCOUNTER_END, which is the real
--    defence; the throttle here catches anything that slips past it. Repeating
--    a split is worse than not sending it - it reads as the group having killed
--    the boss twice.
--------------------------------------------------------------------------------

local _, PS = ...

local PeaversCommons = _G.PeaversCommons

local Announcer = {}
PS.Announcer = Announcer

-- The only channels this addon will ever send to. A value outside this set -
-- from a hand-edited SavedVariables, or a config bug - degrades to the player's
-- own frame rather than being sent somewhere nobody consented to.
local ALLOWED = {
	PARTY = true,
	self = true,
}

local lastSent = ""
local lastSentAt = 0
local REPEAT_WINDOW = 2.0

---Where a group-facing line should actually go, or nil for "nowhere".
---@return string|nil channel
local function activeChannel()
	if not PS.Config.announceEnabled then
		return nil
	end

	local channel = PS.Config.channel
	if not ALLOWED[channel] then
		PeaversCommons.Utils.Debug(PS, ("channel %s is not allowed - keeping it local")
			:format(tostring(channel)))
		return nil
	end

	if channel == "self" then
		return nil
	end

	-- A keystone is a five-man, so this is only false while testing alone. It is
	-- also what stops SendChatMessage erroring outside a group.
	if not IsInGroup() then
		return nil
	end

	return channel
end

---Print to the player's own chat frame, with the addon's prefix.
---@param message string
function Announcer:Local(message)
	PeaversCommons.Utils.Print(PS, message)
end

---Send a split to the group, falling back to the player's own frame.
---
---The fallback is deliberate rather than a silent drop: someone running solo,
---or with announcements off, still wants to see their own splits. What changes
---is only who else does.
---@param message string
function Announcer:Split(message)
	local now = GetTime()
	if message == lastSent and (now - lastSentAt) < REPEAT_WINDOW then
		PeaversCommons.Utils.Debug(PS, "identical line inside the repeat window - dropped")
		return
	end
	lastSent, lastSentAt = message, now

	local channel = activeChannel()
	if not channel then
		self:Local(message)
		return
	end

	-- pcall because SendChatMessage is a protected-adjacent surface that throws
	-- on a bad channel, and a keystone is the worst possible moment to find out.
	local ok, err = pcall(SendChatMessage, message, channel)
	if not ok then
		PeaversCommons.Utils.Debug(PS, ("SendChatMessage failed: %s"):format(tostring(err)))
		self:Local(message)
	end
end

---Forget the repeat window. Called when a run starts, so two runs of the same
---dungeon back to back cannot have the second's first split swallowed as a
---duplicate of the first's.
function Announcer:Reset()
	lastSent, lastSentAt = "", 0
end
