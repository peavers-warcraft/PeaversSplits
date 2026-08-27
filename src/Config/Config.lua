--------------------------------------------------------------------------------
-- PeaversSplits Configuration
-- Uses PeaversCommons.ConfigManager with AceDB-3.0 for profile management.
--
-- DISPLAY AND ANNOUNCEMENT PREFERENCES ONLY. The benchmark lives in
-- PeaversSplitsData and is read-only: nothing here may write a split or a pace,
-- and nothing timing-shaped may ever be persisted into PeaversSplitsDB. The
-- settings below only decide what is said and where.
--
-- Note there are no data-quality settings, and there must not be. The published
-- pool has already refused to publish anything under its sample floor, so there
-- is nothing left here to filter and no threshold that would mean anything - a
-- "minimum runs" slider could only ever hide data that already cleared the bar.
--------------------------------------------------------------------------------

local _, PS = ...

local PeaversCommons = _G.PeaversCommons
local ConfigManager = PeaversCommons.ConfigManager

local PS_DEFAULTS = {
	-- Announcements.
	--
	-- `channel` is PARTY by default because a keystone split is a fact about the
	-- group's run, not about the player, and calling it out is the whole point of
	-- the addon. "self" is offered for anyone who would rather keep it to
	-- themselves. SAY and YELL are deliberately not offered: they reach people
	-- who did not opt into anything.
	announceEnabled = true,
	channel = "PARTY",

	-- What rides along with the delta.
	--
	-- The spread is on by default and the reasoning is the same as the website's:
	-- a delta of forty seconds means nothing on a boss where the middle half of
	-- the pool spans four minutes, and a bare "+0:40" invites the reader to
	-- conclude something the number cannot support.
	showSpread = true,
	showSampleSize = false,

	-- Say once, at the start of a run, what is being compared against - or that
	-- nothing is. Without it the addon is silent on an uncovered level and looks
	-- broken rather than honest.
	announceStart = true,

	-- The end-of-run line, after CHALLENGE_MODE_COMPLETED.
	announceFinish = true,

	-- The live bar. The chat line is the record; the bar is the instrument, and
	-- it is the half that shows a gap *opening* rather than reporting it once the
	-- boss is already down.
	showBar = true,
	lockBar = false,
	barPoint = "CENTER",
	barRelativePoint = "CENTER",
	barX = 0,
	barY = 200,

	DEBUG_ENABLED = false,
}

PS.Config = ConfigManager:NewWithAceDB(
	PS,
	PS_DEFAULTS,
	{
		savedVariablesName = "PeaversSplitsDB",
		profileType = "shared",
	}
)
