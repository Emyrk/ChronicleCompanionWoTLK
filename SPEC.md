# ChronicleCompanionWoTLK Wire Protocol Specification

This document defines the message format embedded into `WoWCombatLog.txt`
via the SPELL_CAST_FAILED fail-reason field hijack.

## Transport Framing

Messages are injected into the `failedType` field of `SPELL_CAST_FAILED`
combat log events. The field has a hard limit of **245 characters** on
Warmane 3.3.5a.

### Markers

| Char | Meaning |
|------|---------|
| `[N` | Start of message N (N = digit 0-9, wraps) |
| `]`  | End of message |
| `~`  | Continuation prefix (middle/last chunks of a multi-slot message) |

### Single-slot message

```
[3Z:Dalaran,none,0,,0,0,0,571,0,]
```

### Multi-slot message

```
slot 1:  [4P0x060...;G1.51396.3820.41398.40014.0.0.0.264:2.50633.0.0.0.0.0.0
slot 2:  ~.245:5.51398.3832.41398.40051.0.0.0.264:10.50611.3860.0.0.0.0.0.258]
```

### Bin-packing

Short messages can share a single slot:

```
[4P0x...;IArthas,DEATHKNIGHT,HUMAN,2,80][5P0x...;UMy Guild][6P0x...;G1.51396...
```

### Drop detection

The server accumulates text between `[N` and `]`. If a new `[M` appears
before `]`, the previous message is discarded (incomplete). The counter
wraps 0-9.

### Reserved characters

Payloads must not contain: `|` `"` `\n` `[` `]`

Valid separators: `,` `:` `.` `;` `-` `_` and all alphanumerics.

---

## Message Types

### Z -- Zone Info

Emitted by: `ZoneProvider` (priority 1)
Re-emit: on zone change + every 10 minutes

```
Z:<name>,<instanceType>,<diffIdx>,<diffName>,<maxPlayers>,<dynDiff>,<isDynamic>,<mapID>,<lfgID>,<subZone>
```

| Field | Type | Description |
|-------|------|-------------|
| name | string | Instance or zone name (from GetInstanceInfo or GetRealZoneText) |
| instanceType | string | `none`, `party`, `raid`, `pvp`, `arena` |
| diffIdx | number | Difficulty index (1=10N, 2=25N, 3=10H, 4=25H for non-dynamic) |
| diffName | string | Localized difficulty name (e.g. "25 Player") |
| maxPlayers | number | Max players for the instance |
| dynDiff | number | Dynamic difficulty: 0=Normal, 1=Heroic (ICC-style toggle) |
| isDynamic | number | 1 if difficulty can change while zoned in, 0 otherwise |
| mapID | number | Instance map ID |
| lfgID | number | LFG dungeon ID (0 if not queued) |
| subZone | string | Current subzone name |

Example:
```
Z:Icecrown Citadel,raid,2,25 Player,25,1,1,631,0,The Frozen Throne
Z:Dalaran,none,0,,0,0,0,571,0,The Violet Citadel
```

---

### H -- Session Header

Emitted by: `HeaderProvider` (priority 2)
Re-emit: on login + every 30 minutes

```
H:<addonVersion>,<realm>,<locale>,<wowVersion>,<wowBuild>,<sessionId>
```

| Field | Type | Description |
|-------|------|-------------|
| addonVersion | string | Addon version from TOC (e.g. "0.1") |
| realm | string | GetRealmName() |
| locale | string | GetLocale() (e.g. "enUS") |
| wowVersion | string | Client version (e.g. "3.3.5a") |
| wowBuild | string | Client build number (e.g. "12340") |
| sessionId | string | 4-char random hex, unique per login session |

Example:
```
H:0.1,Icecrown,enUS,3.3.5a,12340,a8f3
```

---

### P -- Player Data (CI Segments)

Emitted by: `PlayerListProvider` (priority 3)
Each message is ONE segment for ONE player.

```
P<guid>;<segment>
```

The `<guid>` is the player's full GUID (e.g. `0x060000000008DCCC`).
The segment is prefixed by a single type character.

#### I -- Identity

Cooldown: 30 minutes

```
I<name>,<class>,<race>,<gender>,<level>
```

| Field | Type | Description |
|-------|------|-------------|
| name | string | Character name |
| class | string | English class token (WARRIOR, PALADIN, etc.) |
| race | string | English race token (HUMAN, ORC, etc.) |
| gender | number | 1=unknown, 2=male, 3=female |
| level | number | Character level |

Example:
```
P0x060000000008DCCC;IArthas,DEATHKNIGHT,HUMAN,2,80
```

#### G -- Gear

Cooldown: 5 minutes
Dirty on: UNIT_INVENTORY_CHANGED, spec change

```
G<slot>.<itemId>.<enchant>.<gem1>.<gem2>.<gem3>.<gem4>.<suffix>.<itemLevel>:<next slot>:...
```

| Field | Type | Description |
|-------|------|-------------|
| slot | number | Inventory slot index (1=Head, 2=Neck, ... 19=Tabard) |
| itemId | number | Item ID |
| enchant | number | Enchant ID (0 = none) |
| gem1-4 | number | Gem item IDs (0 = empty) |
| suffix | number | Random suffix ID (0 = none, can be negative) |
| itemLevel | number | Item level from the item link |

Slots are colon-separated. Empty slots are omitted.

Example:
```
P0x060000000008DCCC;G1.51396.3820.41398.40014.0.0.0.264:2.50633.0.0.0.0.0.0.245:5.51398.3832.41398.40051.0.0.0.264
```

Slot index reference:
```
1=Head  2=Neck  3=Shoulder  4=Shirt  5=Chest
6=Waist  7=Legs  8=Feet  9=Wrist  10=Hands
11=Finger1  12=Finger2  13=Trinket1  14=Trinket2
15=Back  16=MainHand  17=OffHand  18=Ranged  19=Tabard
```

#### T -- Talents

Cooldown: 5 minutes
Dirty on: PLAYER_TALENT_UPDATE, ACTIVE_TALENT_GROUP_CHANGED, spec change detected

```
T<activeGroup>,<numGroups>,<rankString1>,<rankString2>
```

| Field | Type | Description |
|-------|------|-------------|
| activeGroup | number | 1 or 2 (active spec) |
| numGroups | number | 1 or 2 (dual spec purchased?) |
| rankString1 | string | Spec 1: rank digits per talent, tabs separated by `}` |
| rankString2 | string | Spec 2: same format (empty if single spec) |

Rank string format: concatenation of every talent's current rank digit
(0-5) in talent-index order, with `}` separating the 3 talent tabs.

Example:
```
P0x060000000008DCCC;T1,2,05032001050000000000000000000}32000000000000000000000000000}00000000000000000000000000000,00000000000000000000000000000}00000000000000000000000000000}00000000000000000000000000000
```

#### Y -- Glyphs

Cooldown: 10 minutes
Self only (no inspect API for glyphs on 3.3.5a)
Dirty on: GLYPH_UPDATED, spec change

```
Y<activeGroup>,<major1>.<major2>.<major3>.<minor1>.<minor2>.<minor3>:<group2 same format>
```

| Field | Type | Description |
|-------|------|-------------|
| activeGroup | number | 1 or 2 |
| spell IDs | number | Glyph spell IDs, dot-separated (0 = empty socket) |

Groups are colon-separated. Order within a group: 3 major then 3 minor.

Example:
```
P0x060000000008DCCC;Y1,55440.58388.54845.58095.57719.0:0.0.0.0.0.0
```

#### U -- Guild

Cooldown: 30 minutes
Dirty on: PLAYER_GUILD_UPDATE

```
U<guildName>
```

Example:
```
P0x060000000008DCCC;UMy Guild
```

#### E -- Pet

Cooldown: 10 minutes
Dirty on: UNIT_PET

```
E<name>,<guid>
```

Example:
```
P0x060000000008DCCC;ESpot,0x060000000012ABCD
```

#### H -- Honor

Cooldown: 60 minutes
Self only

```
H<lifetimeHK>,<highestRank>,<honorCurrency>,<sessionHK>
```

Example:
```
P0x060000000008DCCC;H1523,14,75000,42
```

#### A -- Arena

Cooldown: 60 minutes
Self only

```
A<bracket>.<name>.<rating>.<played>.<won>.<personalRating>:<next bracket>:...
```

Brackets are colon-separated.

Example:
```
P0x060000000008DCCC;A2v2.Team Name.1850.120.85.1820:3v3.Other Team.2100.50.30.2050
```

---

### L -- Loot / Trade

Emitted by: `LootProvider` (priority 4)
Event-driven only (no periodic re-emit)
Filters: Uncommon (quality 2) and above
Queue sorted by quality: Legendary > Epic > Rare > Uncommon

```
L<kind>,<quality>,<itemId>,<count>,<player>
```

| Field | Type | Description |
|-------|------|-------------|
| kind | string | `L` = loot drop, `T` = trade |
| quality | number | Item quality (2=Uncommon, 3=Rare, 4=Epic, 5=Legendary) |
| itemId | number | Item ID |
| count | number | Stack count |
| player | string | Who looted it. For trades: `Giver>Receiver` |

Trades are only tracked for item IDs that were seen as loot drops in the
current instance session. The tracked item list resets on zone change.

Examples:
```
LL,4,49623,1,Arthas
LT,4,49623,1,Arthas>Doydz
LL,5,32837,1,Rhyd
```

---

### M -- Meta (Relay Stats)

Emitted by: `MetaProvider` (priority 5)
Re-emit: every 5 minutes

```
M<landed_0>,<landed_1>,<landed_2>,...,<landed_9>
```

10 values representing landed chunk counts per minute bucket.
Index 0 = current minute, index 9 = 9 minutes ago.

Example:
```
M12,8,15,3,0,0,0,0,0,0
```

---

## Provider Priority Order

| Priority | Provider | Typical size | Chunks |
|----------|----------|-------------|--------|
| 1 | Zone | ~80 chars | 1 |
| 2 | Header | ~50 chars | 1 |
| 3 | PlayerList (per segment) | 30-700 chars | 1-3 |
| 4 | Loot | ~30 chars | 1 |
| 5 | Meta | ~25 chars | 1 |

Only Gear segments (G) typically span multiple chunks. All other messages
fit in a single slot and are candidates for bin-packing.

---

## Server-Side Parsing Algorithm

```
state = IDLE
buffer = ""
counter = nil

for each SPELL_CAST_FAILED row in combat log:
    text = failedType field

    if text starts with "[" and text[2] is digit 0-9:
        if state == ACCUMULATING:
            discard buffer (incomplete message)
        counter = text[2]
        buffer = text from position 3 onward
        state = ACCUMULATING

    else if text starts with "~":
        if state == ACCUMULATING:
            buffer = buffer .. text from position 2 onward
        else:
            ignore (orphan continuation)

    else:
        ignore (real spell failure, not our data)

    -- Check for message completion
    if state == ACCUMULATING and buffer ends with "]":
        buffer = buffer without trailing "]"
        emit(buffer)  -- complete message ready for parsing
        state = IDLE
        buffer = ""

    -- Handle bin-packed messages (multiple [N...] in one field)
    -- After stripping one complete message, check if remainder
    -- starts with "[" + digit for another message in the same field.
```
