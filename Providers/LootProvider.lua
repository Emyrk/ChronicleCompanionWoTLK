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
    priority = 4,   -- lowest: after Zone (1), Header (2), PlayerList (3)
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
-- The message arg contains the localized loot string with an item link.
-- We extract the item link, then use GetItemInfo for quality + item ID.
-- The player name comes from arg2 (or is "You" for self-loot patterns).
-- ---------------------------------------------------------------------------

--- Extract item link from a loot message string.
-- @tparam string msg the chat message text
-- @treturn string|nil the item link if found
local function extractItemLink(msg)
    if not msg then return nil end
    -- Item links look like: |cff......|Hitem:12345:...|h[Name]|h|r
    return msg:match("|H(item:[%d:%-]+)|h")
end

--- Extract item count from a loot message (e.g. "x3").
-- @tparam string msg the chat message text
-- @treturn number count (default 1)
local function extractCount(msg)
    if not msg then return 1 end
    local count = msg:match("x(%d+)")
    return tonumber(count) or 1
end

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

local function onLootMsg(event, msg, playerName)
    local itemLink = extractItemLink(msg)
    if not itemLink then return end

    -- Get item info: name, link, quality, ...
    local itemName, _, quality = GetItemInfo(itemLink)
    if not quality or quality < MIN_QUALITY then return end

    -- Extract item ID from the link string "item:12345:..."
    local itemId = tonumber(itemLink:match("item:(%d+)"))
    if not itemId then return end

    -- Player name: CHAT_MSG_LOOT arg2 is the sender name.
    -- For self-loot patterns, playerName might be "" or the player's name.
    local player = playerName or ""
    if player == "" then
        player = UnitName("player") or "?"
    end

    local count = extractCount(msg)

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
-- Trade tracking
--
-- On TRADE_ACCEPT_UPDATE (both sides accept), snapshot the items in the
-- trade window.  Only record items whose IDs were seen as loot drops
-- this session.
--
-- TRADE_ACCEPT_UPDATE fires with (playerAccepted, targetAccepted).
-- We capture when both are 1.
--
-- APIs:
--   GetTradePlayerItemLink(slot)  -- items we're giving (1-7)
--   GetTradeTargetItemLink(slot)  -- items we're receiving (1-7)
--   GetTradePlayerItemInfo(slot)  -- name, texture, numItems, isUsable, enchantment
--   GetTradeTargetItemInfo(slot)  -- name, texture, numItems, quality, isUsable, enchantment
-- ---------------------------------------------------------------------------

local MAX_TRADE_SLOTS = 7

local function onTradeAccept(event, playerAccepted, targetAccepted)
    if playerAccepted ~= 1 or targetAccepted ~= 1 then return end

    local myName = UnitName("player") or "?"
    local targetName = UnitName("NPC") or GetTradeTargetName and GetTradeTargetName() or "?"
    -- On 3.3.5a, trade target name might come from the TradeFrame title
    if targetName == "?" and TradeFrameRecipientNameText then
        targetName = TradeFrameRecipientNameText:GetText() or "?"
    end

    -- Items we gave away (other player receives them)
    for slot = 1, MAX_TRADE_SLOTS do
        local link = GetTradePlayerItemLink(slot)
        if link then
            local itemId = tonumber(link:match("item:(%d+)"))
            if itemId and lootedItemIds[itemId] then
                local _, _, numItems = GetTradePlayerItemInfo(slot)
                local _, _, quality = GetItemInfo(link)
                if quality and quality >= MIN_QUALITY then
                    enqueue({
                        quality   = quality,
                        itemId    = itemId,
                        count     = numItems or 1,
                        player    = myName .. ">" .. Util.Sanitize(targetName),
                        pushed_at = time(),
                        kind      = "T",  -- trade
                    })
                end
            end
        end
    end

    -- Items we received (we get them)
    for slot = 1, MAX_TRADE_SLOTS do
        local link = GetTradeTargetItemLink(slot)
        if link then
            local itemId = tonumber(link:match("item:(%d+)"))
            if itemId and lootedItemIds[itemId] then
                local _, _, numItems, quality = GetTradeTargetItemInfo(slot)
                if not quality then
                    _, _, quality = GetItemInfo(link)
                end
                if quality and quality >= MIN_QUALITY then
                    enqueue({
                        quality   = quality,
                        itemId    = itemId,
                        count     = numItems or 1,
                        player    = Util.Sanitize(targetName) .. ">" .. myName,
                        pushed_at = time(),
                        kind      = "T",  -- trade
                    })
                end
            end
        end
    end

    Relay:Kick()
end

-- ---------------------------------------------------------------------------
-- Event wiring
-- ---------------------------------------------------------------------------

Chronicle.RegisterEvent("CHAT_MSG_LOOT", onLootMsg)
Chronicle.RegisterEvent("TRADE_ACCEPT_UPDATE", onTradeAccept)

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
