--------------------------------------------------------------------------------
-- Sync - making five copies of this addon agree about one keystone
--
-- Everyone in the group who has this installed is timing the same run
-- independently, and left alone they disagree in two visible ways:
--
--   1. Anybody who reloaded is on the game's world timer rather than their own
--      `GetTime()` baseline, which is the weaker clock this addon goes out of
--      its way not to trust (see the header of Run.lua). Their splits come out
--      seconds away from everybody else's, for the same boss, in the same chat.
--
--   2. All of them talk. Three installs is three identical lines per boss, and
--      the group reads it as the addon being broken rather than as three people
--      running it.
--
-- Both are the same problem wearing different clothes - nobody has agreed who
-- is authoritative - so both are settled by one election.
--
-- ## Why elapsed crosses the wire and a timestamp never could
--
-- **`GetTime()` cannot be sent.** It counts seconds since that client started,
-- so there is no epoch two machines share; my 12345.6 means nothing on your
-- screen. What IS shareable is how far into the run we are, because that is a
-- fact about the dungeon rather than about a process. So a claim carries
-- `elapsed`, and the receiver turns it back into a baseline on its own clock:
--
--     startedAt = GetTime() - elapsed - oneWayDelay
--
-- ## Why the latency correction is deliberately crude
--
-- The message travels sender -> server -> receiver, and we only ever know our
-- own half of that. Half of our own world latency is therefore an estimate, not
-- a measurement, and it leaves tens of milliseconds on the table.
--
-- That is fine, and a PING/PONG round trip to do better would be more traffic
-- for nothing: every number this addon prints goes through `Pace.Clock`, which
-- rounds to whole seconds, and is held against pool spreads measured in
-- minutes. An error of 40ms cannot change a single character of the output. The
-- correction is here because it is three lines and always points the right way,
-- not because the tolerance demands it.
--
-- ## The election
--
-- Ordered by how much a clock is worth, which is the ordering Run.lua already
-- argues for at length:
--
--   EXACT      saw CHALLENGE_MODE_START, so the baseline is our own GetTime()
--   RECOVERED  adopted a key already in progress, so it is the game's timer
--
-- Ties break on the lower name. That is not arbitrary - it is what lets every
-- client reach the SAME answer with no negotiation round, no leader handshake,
-- and no state to get stuck in. Everyone sorts the same roster and reads off
-- the top of it.
--
-- Two winners come out of the one roster:
--
--   clockLeader  best clock in the group. A client whose own clock is strictly
--                worse adopts this baseline and stops being a second opinion.
--   speaker      best clock AMONG THOSE WILLING TO TALK, because the best clock
--                may have announcements switched off, and electing a mute
--                leader would leave the group with silence.
--
-- ## What this never does
--
-- It sends nothing about the player, it persists nothing, and it does not talk
-- outside a party. A claim is four numbers about a dungeon all five people are
-- standing in.
--------------------------------------------------------------------------------

local _, PS = ...

local PeaversCommons = _G.PeaversCommons

local Sync = {}
PS.Sync = Sync

-- Under the 16-character cap, and unmistakably ours.
local PREFIX = "PeaversSplits"

-- Bumped only on a breaking wire change. A client that does not recognise the
-- tag drops the message rather than guessing at its fields, so a half-updated
-- group degrades to everybody timing their own run - which is exactly the
-- behaviour that shipped before this file existed.
local PROTOCOL = "PS1"

local CLAIM = "CLAIM"

-- How trustworthy a clock is. Compared numerically, so the order is the point.
local QUALITY_EXACT = 2
local QUALITY_RECOVERED = 1

-- Heartbeat, and how long a silent peer stays on the roster. Three missed beats
-- before a peer is dropped, so one stutter does not trigger a re-election.
local HEARTBEAT = 15.0
local PEER_TIMEOUT = 45.0

-- A new peer is answered at once rather than at the next heartbeat, so a client
-- that just reloaded adopts the good clock in well under a second instead of
-- spending up to fifteen of them announcing off the weaker one. The jitter
-- stops four peers replying on the same frame.
local REPLY_JITTER = 0.8

-- Nothing here is chatty enough to approach the server's limit, but a bug that
-- made it chatty would be silent and expensive, so the floor is enforced.
local MIN_SEND_INTERVAL = 1.0

Sync.peers = {}
Sync.clockLeader = nil
Sync.speaker = nil

local heartbeatToken = 0
local lastSentAt = 0
local sendPending = false
local myName

--------------------------------------------------------------------------------
-- Identity
--------------------------------------------------------------------------------

---This character as `Name-Realm`, which is the space `CHAT_MSG_ADDON` names
---senders in. Resolved lazily and cached: the realm APIs are not reliable at
---the moment an addon loads, and a nil cached at login would outlive the fix.
---@return string|nil
local function fullName()
	if myName then
		return myName
	end

	if type(UnitFullName) ~= "function" then
		return nil
	end

	local name, realm = UnitFullName("player")
	if not name or name == "" then
		return nil
	end

	if not realm or realm == "" then
		realm = (type(GetNormalizedRealmName) == "function" and GetNormalizedRealmName()) or ""
	end

	myName = realm ~= "" and (name .. "-" .. realm) or name
	return myName
end

---Is this sender us? A message sent to PARTY comes back to its own sender, so
---without this every client would count itself twice - once as itself and once
---as a peer - and would then be able to elect itself through the roster.
---@param sender string
---@return boolean
local function isSelf(sender)
	local me = fullName()
	if me and sender == me then
		return true
	end

	-- Fallback for the paths that hand over a name without the realm suffix.
	if type(UnitIsUnit) == "function" then
		local ok, same = pcall(UnitIsUnit, sender, "player")
		if ok and same then
			return true
		end
	end

	return false
end

--------------------------------------------------------------------------------
-- Clock quality
--------------------------------------------------------------------------------

---What this client's own clock is worth, or nil when it has no run.
---@return number|nil
function Sync:MyQuality()
	local run = PS.Run
	if not run.active then
		return nil
	end

	-- `startedAt` is set only by Run:Start, off CHALLENGE_MODE_START. A
	-- recovered run deliberately leaves it nil and reads the game's timer.
	return run.startedAt and QUALITY_EXACT or QUALITY_RECOVERED
end

---Half of our own round trip, in seconds - the one-way delay estimate.
---@return number
local function oneWayDelay()
	if type(GetNetStats) ~= "function" then
		return 0
	end

	local ok, _, _, _, world = pcall(GetNetStats)
	if not ok or type(world) ~= "number" or world <= 0 then
		return 0
	end

	-- Sanity bound. A client reporting a ten-second latency is reporting a bug,
	-- and correcting by it would be worse than not correcting at all.
	return math.min(world / 2000, 1.0)
end

--------------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------------

---Whether there is anybody to sync WITH - checked before a heartbeat is armed
---as well as before a send, so a player running this alone never carries a
---ticker that can only ever talk to itself.
---@return boolean
local function syncPossible()
	if not PS.Config.syncEnabled then
		return false
	end

	-- A keystone is a five-man. Outside a group there is nobody to agree with,
	-- and an addon message to PARTY has nowhere to go.
	if not IsInGroup() then
		return false
	end

	return type(C_ChatInfo) == "table"
		and type(C_ChatInfo.SendAddonMessage) == "function"
end

---Whether a claim should go out this instant.
---@return boolean
local function shouldSync()
	return syncPossible() and PS.Run.active
end

---Tell the group where we think the run is, and what that opinion is worth.
function Sync:Broadcast()
	if not shouldSync() then
		return
	end

	-- Throttled is not cancelled. Dropping the claim here would lose exactly the
	-- reply a newly-arrived peer is waiting on - the one case the reply exists
	-- for - and strand them on the weaker clock until the next heartbeat. So a
	-- send that comes too soon is deferred to the moment it stops being too soon.
	local now = GetTime()
	local wait = MIN_SEND_INTERVAL - (now - lastSentAt)
	if wait > 0 then
		if not sendPending then
			sendPending = true
			C_Timer.After(wait, function()
				sendPending = false
				Sync:Broadcast()
			end)
		end
		return
	end

	local run = PS.Run
	local elapsed = run:GetElapsed()
	if not elapsed then
		return
	end

	local quality = self:MyQuality()
	if not quality then
		return
	end

	-- Willingness to talk rides along, because the speaker election has to know
	-- it before choosing. A client with announcements off is a perfectly good
	-- clock authority and a useless speaker.
	local speak = (PS.Config.announceEnabled and PS.Config.channel == "PARTY") and 1 or 0

	local message = ("%s|%s|%d|%d|%d|%d|%.1f"):format(
		PROTOCOL, CLAIM,
		run.mapID or 0,
		run.level or 0,
		quality,
		speak,
		elapsed)

	lastSentAt = now
	pcall(C_ChatInfo.SendAddonMessage, PREFIX, message, "PARTY")
end

--------------------------------------------------------------------------------
-- Receiving
--------------------------------------------------------------------------------

---@param prefix string
---@param text string
---@param sender string
function Sync:OnMessage(prefix, text, _, sender)
	if prefix ~= PREFIX or type(text) ~= "string" or type(sender) ~= "string" then
		return
	end

	if not PS.Config.syncEnabled or isSelf(sender) then
		return
	end

	local protocol, kind, mapID, level, quality, speak, elapsed =
		text:match("^(%w+)|(%w+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?%d+)|(%-?[%d%.]+)$")

	if protocol ~= PROTOCOL or kind ~= CLAIM then
		return
	end

	mapID, level = tonumber(mapID), tonumber(level)
	quality, speak, elapsed = tonumber(quality), tonumber(speak), tonumber(elapsed)

	if not (mapID and level and quality and speak and elapsed) then
		return
	end

	-- Only agree with somebody timing the run WE are timing. Without this a peer
	-- still holding a stale run from the previous key would drag our baseline
	-- onto a dungeon we finished ten minutes ago.
	--
	-- A zero on either side is not a match, it is an ABSENCE - the same rule
	-- `activeLevel` keeps in Run.lua, and for the same reason. Both clients
	-- briefly claim map 0 +0 before the game publishes the keystone, and treating
	-- that as agreement would have two clients in unidentified keys adopting each
	-- other's clocks on the strength of `0 == 0`. Neither has to wait long:
	-- Run:ResolveRun re-announces the moment the key can be named.
	local run = PS.Run
	if not run.active or not run.mapID or not run.level then
		return
	end

	if mapID < 1 or level < 1 or mapID ~= run.mapID or level ~= run.level then
		return
	end

	-- A claim outside these bounds is a bug or a lie, and either way is not
	-- something to reset a clock to. Three hours is well past a depleted key.
	if elapsed < 0 or elapsed > 10800 then
		return
	end

	if quality ~= QUALITY_EXACT and quality ~= QUALITY_RECOVERED then
		return
	end

	local now = GetTime()
	local known = self.peers[sender] ~= nil

	self.peers[sender] = {
		quality = quality,
		speak = speak == 1,
		-- Their baseline, expressed on OUR clock. This is the whole point of the
		-- exchange: `elapsed` can cross the wire, `startedAt` never could.
		startedAt = now - elapsed - oneWayDelay(),
		seenAt = now,
	}

	self:Elect()

	-- Somebody we had not heard from - answer so they can see us too, rather
	-- than making them wait out a heartbeat.
	if not known then
		C_Timer.After(REPLY_JITTER * math.random(), function()
			Sync:Broadcast()
		end)
	end
end

--------------------------------------------------------------------------------
-- The election
--------------------------------------------------------------------------------

---Drop peers we have not heard from in a while.
---@return boolean dropped
local function prune()
	local now = GetTime()
	local stale

	for name, peer in pairs(Sync.peers) do
		if (now - peer.seenAt) > PEER_TIMEOUT then
			stale = stale or {}
			stale[#stale + 1] = name
		end
	end

	-- Collected first: removing during the pairs() above is the one Lua rule
	-- this codebase keeps having to re-learn.
	for _, name in ipairs(stale or {}) do
		Sync.peers[name] = nil
	end

	return stale ~= nil
end

---Better clock wins; on a tie the lower name wins. Deterministic on purpose -
---every client runs this over the same roster and must reach the same answer
---without asking anybody.
---@return boolean
local function beats(quality, name, bestQuality, bestName)
	if not bestName then
		return true
	end
	if quality ~= bestQuality then
		return quality > bestQuality
	end
	return name < bestName
end

---Work out who holds the clock and who does the talking, then act on it.
function Sync:Elect()
	prune()

	local me = fullName()
	local myQuality = self:MyQuality()

	local leader, leaderQuality, leaderStart
	local speaker, speakerQuality

	if me and myQuality then
		leader, leaderQuality, leaderStart = me, myQuality, PS.Run.startedAt
		if PS.Config.announceEnabled and PS.Config.channel == "PARTY" then
			speaker, speakerQuality = me, myQuality
		end
	end

	for name, peer in pairs(self.peers) do
		if beats(peer.quality, name, leaderQuality, leader) then
			leader, leaderQuality, leaderStart = name, peer.quality, peer.startedAt
		end
		if peer.speak and beats(peer.quality, name, speakerQuality, speaker) then
			speaker, speakerQuality = name, peer.quality
		end
	end

	self.clockLeader = leader
	self.speaker = speaker

	if leader and me and leader ~= me and myQuality and leaderQuality > myQuality then
		self:AdoptClock(leader, leaderStart)
	end
end

---Take a peer's baseline as our own.
---
---Only ever reached when their clock is STRICTLY better than ours, which in
---practice means we reloaded and they did not. Two clients that both saw
---CHALLENGE_MODE_START already agree to within their own jitter, so swapping
---between them would be churn that changes no output.
---
---Adopting once and remembering the source is deliberate: re-deriving the
---baseline on every heartbeat would jitter our clock by whatever the latency
---estimate happened to be that second, for no gain at all.
---@param source string
---@param startedAt number|nil
function Sync:AdoptClock(source, startedAt)
	if not startedAt then
		return
	end

	local run = PS.Run
	if run.clockSource == source then
		return
	end

	run.startedAt = startedAt
	run.clockSource = source

	-- Said out loud, and only to this player. Pace already told them at recovery
	-- that their clock was the game's own - which was true when it said it, and
	-- stops being true here. Leaving that warning standing for the rest of the
	-- key would be the addon knowing better and not saying so.
	--
	-- Local, never the party: who holds the clock is this addon's business, and
	-- the other four people did not ask about it.
	PS.Announcer:Local(("Clock synced from %s - splits are on the group's clock now.")
		:format(source))

	PeaversCommons.Utils.Debug(PS, ("adopted the clock from %s - now %.1fs in")
		:format(source, run:GetElapsed() or -1))
end

---Whether this client is the one that should be talking to the group.
---
---Answering true when nobody has been elected is the important half: that is
---the state of a solo run, of a group where nobody else has the addon, and of
---the first moment of every key before anyone has spoken. The addon has to work
---when it is the only copy in the group, which is most of the time.
---@return boolean
function Sync:ShouldAnnounce()
	if not PS.Config.syncEnabled then
		return true
	end

	local speaker = self.speaker
	if not speaker then
		return true
	end

	local me = fullName()
	if not me then
		return true
	end

	return speaker == me
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

---@param token number
local function heartbeat(token)
	if heartbeatToken ~= token or not PS.Run.active or not syncPossible() then
		return
	end

	Sync:Elect()
	Sync:Broadcast()

	C_Timer.After(HEARTBEAT, function()
		heartbeat(token)
	end)
end

---A run began, by either door. Everything from the last one is meaningless now.
function Sync:OnRunStarted()
	wipe(self.peers)
	self.clockLeader = nil
	self.speaker = nil
	lastSentAt = 0

	heartbeatToken = heartbeatToken + 1
	local token = heartbeatToken

	-- Elect regardless: with no peers this settles us as our own speaker, which
	-- is the answer a solo install needs.
	self:Elect()

	if not syncPossible() then
		return
	end

	self:Broadcast()

	C_Timer.After(HEARTBEAT, function()
		heartbeat(token)
	end)
end

---The run ended. Stop talking and forget everyone.
function Sync:OnRunStopped()
	wipe(self.peers)
	self.clockLeader = nil
	self.speaker = nil
	-- Orphans the heartbeat, so it cannot beat into the next key or into none.
	heartbeatToken = heartbeatToken + 1
end

function Sync:Initialize()
	if type(C_ChatInfo) == "table" and type(C_ChatInfo.RegisterAddonMessagePrefix) == "function" then
		-- Without this the client silently discards every CHAT_MSG_ADDON for the
		-- prefix, which looks exactly like nobody else having the addon.
		pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
	end

	PeaversCommons.Utils.Debug(PS, "sync ready")
end
