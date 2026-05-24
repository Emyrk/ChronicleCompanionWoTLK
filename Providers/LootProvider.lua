-- =============================================================================
-- Providers/LootProvider.lua
--
-- Captures loot events and emits them through the relay.  Lowest priority
-- provider -- only fills gaps when Zone, Header, and PlayerList have
-- nothing to send.
--
-- Only tracks Uncommon (green) quality and above.  Internally queued by
-- quality: Legendary > Epic > Rare > Uncommon.
--
-- Payload format:
--   L<quality>,<itemId>,<count>,<player>
--
-- Examples:
--   L4,49623,1,Arthas          (epic item, 1x, looted by Arthas)
--   L5,32837,1,Rhyd            (legendary)
--   L3,47241,2,Doydz           (rare, 2x)
--
-- Listens to CHAT_MSG_LOOT which fires for all group loot in range.
-- =============================================================================

local Log   = Chronicle.Logger
local Relay = Chronicle.Relay
local Util  = Chronicle.Util

local P = {
    priority = 5,   -- after Reset (1), Zone (2), Header (3), PlayerList (4)
}

-- ---------------------------------------------------------------------------
-- Quality thresholds
-- ---------------------------------------------------------------------------

local MIN_QUALITY    = 2   -- Uncommon (green) and above
local QUALITY_LEGENDARY = 5
local QUALITY_EPIC      = 4
local QUALITY_RARE      = 3

-- ---------------------------------------------------------------------------
-- Loot queue: sorted by quality descending (legendary first)
-- ---------------------------------------------------------------------------

local queue = {}   -- array of { quality, itemId, count, player, pushed_at, kind }
local MAX_QUEUE = 50
local lootedItemIds = {}   -- set of item IDs that dropped this session (for trade tracking)
local recentLoot = {}      -- dedup: "itemId:player:count" -> time() (expires after 5s)

--- Insert a loot entry sorted by quality (highest first).
local function enqueue(entry)
    -- Drop if queue is full (oldest low-quality item falls off)
    if #queue >= MAX_QUEUE then
        -- Remove the lowest-quality (last) entry
        queue[#queue] = nil
    end

    -- Insert sorted: find first entry with lower quality
    local inserted = false
    for i = 1, #queue do
        if entry.quality > queue[i].quality then
            table.insert(queue, i, entry)
            inserted = true
            break
        end
    end
    if not inserted then
        queue[#queue + 1] = entry
    end
end

-- ---------------------------------------------------------------------------
-- Parse CHAT_MSG_LOOT
--
-- CHAT_MSG_LOOT fires for far more than just "receives loot:" messages --
-- it also carries every Need / Greed / Pass click, every roll result,
-- and every "You won:" announcement, all of which contain the same item
-- link.  Accepting "any message that has an item link" produced 2-6x
-- phantom records per real drop because the player name differs across
-- those messages (roller, winner, looter) so itemId:player:count dedup
-- never collides.
--
-- We allowlist exactly the four corpse-loot receive formats from
-- GlobalStrings.lua:
--   LOOT_ITEM                = "%s receives loot: %s."
--   LOOT_ITEM_MULTIPLE       = "%s receives loot: %sx%d."
--   LOOT_ITEM_SELF           = "You receive loot: %s."
--   LOOT_ITEM_SELF_MULTIPLE  = "You receive loot: %sx%d."
-- Everything else -- LOOT_ROLL_*, LOOT_ITEM_CREATED_SELF*,
-- LOOT_ITEM_PUSHED_SELF* (quest reward / mail / merchant) -- is dropped
-- at the source.  Patterns are built from the live globals so localized
-- clients work without code changes.
-- ---------------------------------------------------------------------------

--- Convert a GlobalStrings.lua format string into a Lua match pattern.
-- %s placeholders become (.-) captures; %d placeholders become (%d+)
-- captures.  All other Lua pattern magic in the format string is
-- escaped so it matches literally.
-- @tparam string fmt the format string (e.g. "%s receives loot: %s.")
-- @treturn string an anchored Lua pattern with capture groups
local function toPattern(fmt)
    -- Step 1: protect %s / %d placeholders with sentinel bytes that
    -- cannot appear in a chat message.
    local s = fmt:gsub("%%s", "\1"):gsub("%%d", "\2")
    -- Step 2: escape Lua pattern magic in the remaining literal text.
    s = s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    -- Step 3: restore the placeholders as captures.
    s = s:gsub("\1", "(.-)"):gsub("\2", "(%%d+)")
    return "^" .. s .. "$"
end

-- Multi-stack variants MUST be checked before single-stack -- otherwise
-- the single-stack pattern's trailing %. captures "[Item]xN" as the
-- whole link.
local PAT_OTHER_MULTIPLE = LOOT_ITEM_MULTIPLE      and toPattern(LOOT_ITEM_MULTIPLE)      or nil
local PAT_SELF_MULTIPLE  = LOOT_ITEM_SELF_MULTIPLE and toPattern(LOOT_ITEM_SELF_MULTIPLE) or nil
local PAT_OTHER          = LOOT_ITEM              and toPattern(LOOT_ITEM)               or nil
local PAT_SELF           = LOOT_ITEM_SELF         and toPattern(LOOT_ITEM_SELF)          or nil

-- ---------------------------------------------------------------------------
-- Provider interface
-- ---------------------------------------------------------------------------

--- @treturn string provider label
function P:Label()
    return "Loot"
end

--- @treturn number count of pending loot entries
function P:Dirty()
    return #queue
end

--- @treturn string|nil payload, string|nil summary
function P:Poll()
    if #queue == 0 then return nil end

    -- Pop the highest-quality entry (index 1)
    local entry = queue[1]
    table.remove(queue, 1)

    -- Format: L<kind>,<quality>,<itemId>,<count>,<player>
    -- kind: L=loot, T=trade
    -- trade player format: "Giver>Receiver"
    local payload = string.format("L%s,%d,%d,%d,%s",
        entry.kind or "L",
        entry.quality,
        entry.itemId,
        entry.count,
        Util.Sanitize(entry.player))

    local kindLabel = entry.kind == "T" and "TRADE" or "LOOT"
    local summary = string.format("%s %s x%d (q%d)",
        kindLabel, entry.player, entry.count, entry.quality)

    return payload, summary
end

--- Return current state for UI/debug.
-- @treturn table { queue = queue }
function P:GetState()
    return {
        queue     = queue,
        lastEmitAt = 0,
    }
end

-- ---------------------------------------------------------------------------
-- Event handler
-- ---------------------------------------------------------------------------

local function onLootMsg(event, msg)
    if not msg then return end

    -- Allowlist match: only accept the four corpse-loot receive formats.
    -- Multi-stack variants checked first so the single-stack patterns
    -- don't greedy-capture "[Item]xN" as the whole link.
    local player, itemLink, count
    if PAT_OTHER_MULTIPLE then
        local p, l, c = msg:match(PAT_OTHER_MULTIPLE)
        if p then player, itemLink, count = p, l, tonumber(c) or 1 end
    end
    if not player and PAT_SELF_MULTIPLE then
        local l, c = msg:match(PAT_SELF_MULTIPLE)
        if l then player, itemLink, count = UnitName("player") or "?", l, tonumber(c) or 1 end
    end
    if not player and PAT_OTHER then
        local p, l = msg:match(PAT_OTHER)
        if p then player, itemLink, count = p, l, 1 end
    end
    if not player and PAT_SELF then
        local l = msg:match(PAT_SELF)
        if l then player, itemLink, count = UnitName("player") or "?", l, 1 end
    end
    if not player then return end  -- not a receive-loot message

    -- Get item info: name, link, quality, ...
    local itemName, _, quality = GetItemInfo(itemLink)
    if not quality or quality < MIN_QUALITY then return end

    -- Extract item ID from the link string "item:12345:..."
    local itemId = tonumber(itemLink:match("item:(%d+)"))
    if not itemId then return end

    -- Dedup: defense-in-depth against an engine re-fire of the same
    -- LOOT_ITEM line.  Most cross-message duplication is already gone
    -- via the allowlist above; this 5s window only catches a literal
    -- repeat of the same accepted message.
    local dedupKey = itemId .. ":" .. player .. ":" .. count
    local now = time()
    if recentLoot[dedupKey] and (now - recentLoot[dedupKey]) < 5 then
        return
    end
    recentLoot[dedupKey] = now

    -- Clean old dedup entries (lazy, on each new loot)
    for k, t in pairs(recentLoot) do
        if (now - t) >= 5 then
            recentLoot[k] = nil
        end
    end

    lootedItemIds[itemId] = true  -- remember this item dropped

    enqueue({
        quality   = quality,
        itemId    = itemId,
        count     = count,
        player    = player,
        pushed_at = time(),
        kind      = "L",  -- loot
    })

    Relay:Kick()
end

-- ---------------------------------------------------------------------------
-- Event wiring
--
-- We only register for CHAT_MSG_LOOT.  The allowlist patterns above
-- exclude trade pushes (LOOT_ITEM_PUSHED_SELF*) and crafted items
-- (LOOT_ITEM_CREATED_SELF*) -- the previous trade handler was removed
-- in 9576e07; lootedItemIds maintenance below is currently dead but
-- harmless.
-- ---------------------------------------------------------------------------

Chronicle.RegisterEvent("CHAT_MSG_LOOT", onLootMsg)

-- Wipe the seen-item-IDs list on zone change (new instance = fresh tracking)
Chronicle.RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
    local count = 0
    for _ in pairs(lootedItemIds) do count = count + 1 end
    if count > 0 then
        Log:Debug("LootProvider: zone changed, cleared %d tracked item IDs", count)
        lootedItemIds = {}
    end
end)

-- ---------------------------------------------------------------------------
-- Register with Relay
-- ---------------------------------------------------------------------------

Relay:RegisterProvider(P)
Chronicle.LootProvider = P
