# Improvements -- possible follow-ups

Captured findings from reading the RPLL `AdvancedWotLKCombatLog` addon
(https://github.com/tdymel/LegacyPlayersV3/tree/master/Addons/AdvancedWotLKCombatLog).
Full analysis (~600 lines, with code excerpts and comparison tables) lives
at `~/.mux/plans/ChronicleCompanionWoTLK/addon-analysis-kc5c.md`.

Each entry below is something to investigate or implement *later*; nothing
here is shipping today.

---

## 1. Discovery Mode -- find SPELL_FAILED globals we don't know about

### Motivation

Our overwrite list in `Core/Constants.SPELL_FAILED_GLOBALS` enumerates the
216 `SPELL_FAILED_*` symbols we found in
`research/Interface/FrameXML/GlobalStrings.lua`. Warmane 3.3.5a may emit
*custom* failure reasons that aren't in stock FrameXML
(`SPELL_FAILED_CUSTOM_ERROR_N`, server-extended strings, etc.). Every such
unknown global is a wasted CLEU emission -- the original string lands in
the log instead of a chunk, and the relay never knew it had a slot
available.

### Design

Opt-in via `/chron discover` or `config.discover_mode = true`. While active:

- **Disable the relay.** No chunking, no payload, no sentinel. We are
  measuring, not transmitting.
- **Overwrite every known failure-string global with the literal `"none"`.**
  Both `SPELL_FAILED_GLOBALS` and (if probe shows they land) `ERR_OUT_OF_*`.
  Plain ASCII; nothing in the value should look like a sentinel.
- **Hook `COMBAT_LOG_EVENT_UNFILTERED`** for `SPELL_CAST_FAILED`. The
  fail-reason arg (the localized string the engine just wrote) is the
  carrier we caught the failure with.
  - If that string equals `"none"`, a known global caught the failure;
    ignore.
  - If it's *anything else*, we caught an **unknown** failure global. Log
    it once to chat: `[Chronicle Discover] Unknown fail-reason: "<text>"`.
- Maintain `discover_unknowns[<text>] = count` in memory.
  `/chron discover dump` prints the histogram. `/chron discover clear`
  resets it.
- Keep the `UIErrorsFrame:AddMessage` suppression in place so the user
  doesn't see `none` flashing on the red overlay during testing.

### Acceptance

Run discovery mode through one full raid lockout. Any string in the
histogram that *isn't* the literal `"none"` is a global we missed. Look up
its localized text in `GlobalStrings.lua` (or grep the server's patch
notes) to identify the missing symbol, then add it to
`SPELL_FAILED_GLOBALS`.

### Notes

- This same mode incidentally tests `ERR_OUT_OF_*` -- see improvement #2.
- Discovery mode is **opt-in only**. It must never run by default; setting
  every failure global to `"none"` would corrupt a normal user's combat
  log uploads.
- Persisting the histogram across sessions is fine (small, bounded) but
  not required.

---

## 2. Verify `ERR_OUT_OF_*` landing surface

### Motivation

The RPLL addon overwrites both `SPELL_FAILED_*` globals **and** the eight
`ERR_OUT_OF_*` strings (`ERR_OUT_OF_MANA`, `ERR_OUT_OF_RAGE`,
`ERR_OUT_OF_RUNES`, etc.). If these actually land in `WoWCombatLog.txt` on
3.3.5a, that's free extra landing surface -- especially valuable because
mana/rage/runes failures are far more frequent during a fight than the
typical `SPELL_FAILED_*` failures (movement, LOS, range). If they only
appear on the `UIErrorsFrame` overlay and never in CLEU, the overwrite
does nothing useful and we should leave them alone.

### What we don't know

RPLL ships with them included, but that's not evidence they work -- only
that their author thought they might.

### Design

Easiest path: use Discovery Mode (#1). Set the eight `ERR_OUT_OF_*`
globals to `"none"` along with everything else. Then:

- Drain mana on a target dummy until the next cast fails for mana.
- Read the resulting `SPELL_CAST_FAILED` row in `WoWCombatLog.txt`.
- If the fail-reason column reads `none`, the overwrite works -- include
  them permanently.
- If it reads `"Not enough mana"`, the overwrite did nothing -- exclude
  them; rely on our `AddMessage` hook to suppress the on-screen noise.

### Acceptance

A documented row in `WoWCombatLog.txt` showing either outcome. Update
`SPELL_FAILED_GLOBALS` accordingly with a comment citing the test date and
realm.

---

## 3. Peer broadcast via addon channel

### Motivation

Today every peer's `COMBATANT_INFO` requires us to call `NotifyInspect()`
on them, wait for `INSPECT_TALENT_READY`, then scrape their gear and
talents. `NotifyInspect` is a serial API (one outstanding inspect at a
time, ~3s timeout per target -- see #4) and we share it with the player's
own UI clicks, gear-inspect addons, etc. In a 25-man raid, hydrating
everyone's CI through inspect alone takes upwards of 75 seconds in the
best case and often longer.

RPLL solves this by having every client running their addon **broadcast
its own CI** to an addon channel (`CHAT_MSG_ADDON`), sharded across six
messages. Anyone in the group running RPLL receives the broadcasts and
merges them into their own roster table; only the player who has
`/combatlog` enabled actually writes the data to disk, but all of them
contribute.

For us, this means: in a raid where N people run Chronicle, **the logger
gets N players' worth of CIs for free**, no inspects needed -- including
data we cannot get from inspect at all without owner cooperation (e.g.,
exact glyph IDs are reliable from `GetGlyphSocketInfo` on `"player"`, less
reliable cross-inspect on 3.3.5).

### Design sketch

- New module `Transport/AddonChannel.lua` (already reserved in `AGENTS.md`
  s.4 as "optional"; promote to "recommended").
- Prefix: `CHRON_v1` (matches our sentinel namespace).
- On `PLAYER_LOGIN`, every Chronicle client broadcasts its own CI to:
  - `RAID` chat-type if in a raid;
  - `PARTY` if in a party but not raid;
  - nothing otherwise.
- Re-broadcast triggers: same dirty-segment events as the local CI relay
  (gear changed, talents changed, glyphs changed, spec swapped, pet
  changed, vehicle entered).
- Receivers merge incoming CIs into `inspect_cache` keyed by GUID, with
  a `source = "peer_broadcast"` field so we know not to spam an inspect
  request for them.
- Anti-flood: cap senders to 60 messages/minute (RPLL's number); drop
  with a warn-log if exceeded.
- Sharding: we already chunk CIs through the sentinel framing for the
  combat-log channel; reuse `Transport/Sentinel.lua` framing in the
  addon channel too, just with a different transport. That way a chunk
  is a chunk regardless of carrier and the website demuxer can handle
  both interchangeably.

### Honest tradeoffs

- **Only helps when peers run Chronicle.** Solo raiders and groups with
  one logger see zero benefit. But it makes Chronicle "viral" in a good
  way: more installs = better logs.
- **Addon-channel messages are silently dropped server-side beyond ~250
  bytes per message** on 3.3.5a clients. Our chunk size (200 bytes
  payload) is safe; just confirm during testing.
- **Dedup logic gets more complex.** A peer broadcasts their CI; we
  receive it; we must not re-broadcast it (loop) and we must dedup it
  against any inspect we may have already done for that same GUID. RPLL
  uses a `Synchronizers[sender] = true` table for this; we can copy the
  pattern.

### Acceptance

In a duo where both players run Chronicle, the logger's
`WoWCombatLog.txt` contains the *other* player's full CI without any
`NotifyInspect()` call having been made for them. Verified by setting
the inspect-loop module's poll interval to infinity for the test.

---

## 4. Inspect-queue throttling

### Motivation

RPLL uses a `3s` inspect timeout and "one outstanding inspect at a time"
policy. That matches Blizzard's documented serial inspect behavior on
3.3.5a -- there is no parallel inspect API. We should not try to be
clever here; clever schemes (multi-fire `NotifyInspect`, hoping replies
come back interleaved) will desync the `INSPECT_TALENT_READY` -> GUID
mapping and silently corrupt peer CIs.

### Current state

`Capture/InspectLoop.lua` (planned per `AGENTS.md` s.4) does not yet
exist. When we build it:

- One outstanding inspect at a time, tracked by `lastInspectGuid` (the
  pattern is already in `Providers/PlayerListProvider.lua` for the
  `INSPECT_TALENT_READY` handler).
- Per-inspect timeout: **3 seconds**. If `INSPECT_TALENT_READY` doesn't
  fire by then, clear `lastInspectGuid` and move on. Do not retry the
  same peer immediately; rotate to the next, and let normal round-robin
  pick them up again later.
- Suspend the inspect loop while the player has their inspect frame open
  (`InspectFrame` is shown) -- their click would steal our reply.
- Suspend during combat? RPLL does. We can probably afford to *not*
  suspend (we want inspects to converge during the long raid pulls when
  the player is mostly stationary), but the option should exist in
  config.

### Acceptance

`/chron status` reports `inspects_attempted`, `inspects_succeeded`,
`inspects_timed_out`. A 25-man raid hydrates all 25 CIs (combined with
peer broadcast, #3) within ~30 seconds of zone-in.

---

## 5. Broaden pet/vehicle cache invalidation

### Motivation

We already have `F.Pet(pet)` in `Capture/CIFormat.lua` (emits the
`E<name>,<guid>` segment) and we register `UNIT_PET` in
`Providers/PlayerListProvider.lua`. But the handler **only invalidates
when `unit == "player"`** -- when a raid hunter swaps pets mid-fight,
their `E` segment doesn't get re-emitted until something else triggers a
roster-wide dirty.

We also don't handle vehicle entry/exit at all. On WotLK that matters for:
Flame Leviathan, Mimiron's V-07-TR-0N (Vehicle), Malygos discs, Oculus
drakes, IC gunships, Wintergrasp siege engines. A unit entering a vehicle
fights with completely different spell IDs and the website needs to know
which player is driving which vehicle GUID to attribute damage.

### Design

In `Providers/PlayerListProvider.lua`:

```lua
-- Pet changed -- invalidate for ANY raid/party unit, not just self
Chronicle.RegisterEvent("UNIT_PET", function(event, unit)
    if not unit then return end           -- API can fire with nil on pet death
    local guid = UnitGUID(unit)
    if guid and players[guid] then
        markSegDirty(guid, "E", "UNIT_PET")
        Relay:Kick()
    end
end)

-- Vehicle mount/dismount -- new segment? or piggyback on E?
Chronicle.RegisterEvent("UNIT_ENTERED_VEHICLE", function(event, unit)
    if not unit then return end
    local guid = UnitGUID(unit)
    if guid and players[guid] then
        markSegDirty(guid, "V", "UNIT_ENTERED_VEHICLE")  -- new segment kind
        Relay:Kick()
    end
end)

Chronicle.RegisterEvent("UNIT_EXITED_VEHICLE", function(event, unit)
    if not unit then return end
    local guid = UnitGUID(unit)
    if guid and players[guid] then
        markSegDirty(guid, "V", "UNIT_EXITED_VEHICLE")
        Relay:Kick()
    end
end)
```

Open question: do we extend the `E` segment to include vehicle GUID, or
add a new `V<passenger_guid>,<vehicle_guid>,<ts>` segment? Probably the
latter -- pets and vehicles have different lifecycles, and merging them
into `E` would make every Flame Leviathan pull re-publish 25 `E` segments
unnecessarily.

### Acceptance

- A raid hunter swapping Felguard -> Felhunter mid-fight produces a new
  `E<...>` line in the logger's `WoWCombatLog.txt` within ~5 seconds.
- A Flame Leviathan pull produces 25 `V<...>` segments at the start and
  another 25 at the end.
- `SPEC.md` updated to document the new event triggers and (if added)
  the `V` segment format.

### Honest caveat

`UnitGUID(unit .. "vehicle")` may or may not work on 3.3.5a; we'll need a
live probe to confirm. The CLEU `sourceFlags`
`COMBATLOG_OBJECT_CONTROL_*` bits are a fallback.

---

## 6. Suppression policy comparison (for the record)

Not a planned change -- documenting why we made a different choice than
RPLL.

RPLL hides `UIErrorsFrame` entirely (`Hide()` + `Show = function() end`)
and auto-dismisses any `StaticPopup1` matching their addon name. That
works perfectly for suppression but removes legitimate UI feedback for
the entire session (no "Out of range", no "Can't do that yet", etc.).

We instead hook `UIErrorsFrame:AddMessage` and drop only messages that
match our active sentinel prefix. Legitimate errors still display. The
tradeoff: if we ever ship a payload that *doesn't* match the prefix
filter (bug in `Transport/Sentinel.lua`), it will leak to the on-screen
overlay. The hook is therefore a defense-in-depth measure, not the
primary suppression -- the primary suppression is producing only
prefix-matching payloads.

This is a deliberate UX-vs-safety tradeoff. Re-evaluate if we ever see
suppression leaks in the wild.
