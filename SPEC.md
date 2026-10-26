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

Emitted by: `ZoneProvider` (priority 2)
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

Emitted by: `HeaderProvider` (priority 3)
Re-emit: on relay activation, 1 minute after the first emit, then every 5 minutes

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

### V -- Vehicle Control Change

Emitted by: `VehicleProvider` (priority 3, after Header by registration order)
Event-driven only. Repeated observations of the same assignment are deduplicated.

```
V<timestampMs>,<action>,<vehicleGuid>,<controllerGuid>,<vehicleName>,<controllerName>
```

| Field | Type | Description |
|-------|------|-------------|
| timestampMs | number | Approximate Unix epoch milliseconds when the addon observed the change, not when the relay landed it |
| action | string | `A` = assign control, `R` = release control |
| vehicleGuid | string | Vehicle, turret, or other controlled-unit GUID used by CLEU |
| controllerGuid | string | Controlling character GUID |
| vehicleName | string | Vehicle or turret name at observation time |
| controllerName | string | Character name at observation time |

Examples:

```
V1786244400123,A,0xF150008124016D18,0x000000000000000A,Salvaged Siege Engine,Chronicle
V1786244415440,R,0xF150008124016D18,0x000000000000000A,Salvaged Siege Engine,Chronicle
```

Mappings are time-dependent. The same vehicle or turret GUID can be released by
one character and later assigned to another. Consumers must apply records in
observed timestamp/order and must not treat the mapping as session-global.

The timestamp is embedded because relay delivery depends on naturally occurring
cast failures and may be disconnected from the actual vehicle transition.

---

### P -- Player Data (CI Segments)

Emitted by: `PlayerListProvider` (priority 4)
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

Emitted by: `LootProvider` (priority 5)
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

### RG -- Raid Group Layout

Emitted by: `RaidGroupProvider` (priority 6)
Re-emit: while in a raid, on zone changes and when membership or subgroup placement changes

```
RG:<group1-slot1>,...,<group1-slot5>,<group2-slot1>,...,<group8-slot5>
```

The payload always contains 40 comma-separated GUID fields arranged as eight
five-player subgroup blocks. Empty subgroup positions are empty fields. Members
within a subgroup are ordered by their current raid roster index. GUID fields
contain only hexadecimal digits, omitting both the `0x` prefix and leading
zeroes. No numeric conversion is used.

Example (abbreviated):
```
RG:8DCCC,,,,,8EFE8,...
```

---

### M -- Meta (Relay Stats)

Emitted by: `MetaProvider` (priority 7)
Re-emit: every 5 minutes

```
M<dirty>,<landed_0>,<landed_1>,<landed_2>,...,<landed_9>
```

| Field | Type | Description |
|-------|------|-------------|
| dirty | number | Total dirty segment count across all providers at emit time |
| landed_0..9 | number | Landed chunk counts per minute bucket (0 = current, 9 = 9 min ago) |

Example:
```
M5,12,8,15,3,0,0,0,0,0,0
```

---

## Provider Priority Order

| Priority | Provider | Typical size | Chunks |
|----------|----------|-------------|--------|
| 1 | Reset | ~15 chars | 1 |
| 2 | Zone | ~80 chars | 1 |
| 3 | Header / Vehicle | ~50 chars | 1 |
| 4 | PlayerList (per segment) | 30-700 chars | 1-3 |
| 5 | Loot | ~30 chars | 1 |
| 6 | RaidGroup | ~760 chars | 3-4 |
| 7 | Meta | ~25 chars | 1 |

Gear segments (G) and full RaidGroup layouts commonly span multiple chunks.
Other messages normally fit in one slot and are candidates for bin-packing.

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

---

## SavedVariables Position Payload

The normative desktop/server decoding and validation contract is documented in
[`POSITION_SPEC.md`](POSITION_SPEC.md).

Position telemetry does not use the failed-cast transport. It is stored under:

```text
ChronicleSidekickBridgeWoTLKDB.position_payload
```

Position capture requires the optional
[ChronicleSidekickBridgeWoTLK](https://github.com/Emyrk/ChronicleSidekickBridgeWoTLK)
addon, installed as a sibling under `Interface/AddOns`. The main TOC declares
`OptionalDeps` so the bridge loads first when installed, without preventing the
main addon from loading when it is absent or disabled. Without a loaded bridge
and a compatible `storage_version = 1` database, position sampling stays off;
`/clog positions` reports the blocking reason. Other Chronicle features remain
available. There is no fallback to the main addon's storage.

The options window (`/clog`) includes a **Capture positions** checkbox. Changes
apply immediately: unchecking stops the sampler, and checking starts it if the
normal combat/logging gates are satisfied. If bridge storage is unavailable,
the checkbox is unchecked and disabled with a dependency explanation. This does
not erase the saved preference; it becomes selectable again when compatible
storage is available. Turning capture off does not delete collected data.

Use **Clear positions** in the options window or `/clog positions clear` to
open a confirmation dialog. Accepting discards all captured position history,
including any legacy main-addon position payload, and resets counters, blocks,
GUIDs, cap warnings, and last-sample diagnostics. Other bridge payloads and addon
settings are preserved. The action can recover capped or unreadable position
payloads, but requires a loaded bridge with a compatible storage container.
Cancel or Escape leaves data unchanged. Sampling resumes immediately if enabled
and capture gates are met, so new data may appear after clearing. WoW writes the
reset data at logout or `/reload`; the addon does not delete the file itself.

The bridge owns the account-wide file:

```text
WTF/Account/<ACCOUNT>/SavedVariables/ChronicleSidekickBridgeWoTLK.lua
```

On upgrade, an existing main-addon `position_payload` migrates when the bridge
has no payload. The legacy key is removed only after payload validation succeeds.
If both locations contain separate payloads, capture blocks rather than merging
or replacing either history; upload and clear the legacy payload while WoW is
closed before resuming. Missing or incompatible bridge storage leaves legacy
data untouched.

Existing `b36-v1` and `b36-v2` payloads are preserved unchanged and block new
capture until uploaded by compatible tooling or explicitly cleared by the user.
They must not be reinterpreted as `b36-v3` or migrated by guessing floors.

The account-wide table is uploaded beside `WoWCombatLog.txt` after WoW exits.
After both files upload successfully, the desktop application deletes the combat
log and removes only the `position_payload` key from the SavedVariables file.
The addon recreates an empty payload on the next login.

Capture runs once per second only while both `LoggingCombat()` and
`UnitAffectingCombat("player")` are true. Each tick contains one epoch timestamp,
one map ID, one selected dungeon-map level (floor), and the available GUID/x/y,
health-permille, and resource-permille samples for the visible party or raid. The map ID is required because normalized
x/y coordinates are only meaningful in the map coordinate space where they were
observed. The floor is sampled in the same map state as x/y, before restoring
any previous map selection. Floor zero is valid and distinct from unknown.
Max health, max resource, and numeric resource type are written to a
separate state stream on first observation and whenever the tuple changes.

Coordinates come from the stock 3.3.5 `GetPlayerMapPosition` API, not world-space
unit positions. A `(0, 0)` result means unavailable and is never saved. Some
instances do not expose usable map positions even after selecting the current
zone; being nearby or visible does not guarantee coordinates. If every unit is
unavailable, the sampler continues retrying but appends no tick. Missing vital
values use reserved unknown sentinels without dropping a valid position.
`/clog positions` shows the last sampled map/floor, raw player coordinates, and
available/missing unit counts to distinguish this case from a storage failure.
Close the world map to permit current-zone selection; test outdoors to check
whether the limitation is specific to an instance. SavedVariables are flushed
to disk by WoW at logout or UI reload, not every sampling tick.

### Experimental enemy-coordinate probe

`/clog positions probe` prints raw `GetPlayerMapPosition` results for existing
`player`, `target`, `focus`, `mouseover`, and `targettarget` unit tokens, together
with GUID, hostility/player flags, API-call success, map ID, and dungeon level.
This one-shot diagnostic does not require combat, logging, or bridge storage;
it never changes map selection, starts a timer, or writes captured samples.
An API-call success only means the call returned without an error, not that
its coordinates are usable. Zeroes and API errors remain visible.

The bundled stock FrameXML uses this API for player and group map markers, not
arbitrary enemies. That does not prove native enemy-token behavior either way.
To test on the actual client, select the current zone/floor manually and keep
the map selection unchanged. First confirm the player baseline is usable.
First target a friendly group member to test whether the `target` alias works
for a known supported unit. Then target a hostile NPC and run the probe
repeatedly while the NPC moves and the player remains stationary, then while
the player moves and the NPC remains stationary. Try another enemy and repeat outdoors and in the desired instance.
Zeroes, nils, or coordinates that merely mirror the player are not evidence of
enemy positioning. Independent movement-correlated results are needed before
adding enemy coordinates to stored telemetry. Even a successful target probe
would not establish a way to enumerate every active enemy.

### Table shape

```lua
position_payload = {
    schema_version = 3,
    encoding = "b36-v3",
    guids = { "0x0000000000000001", "0x0000000000000002" },
    chunks = { "<encoded ticks>", "<encoded ticks>" },
    state_chunks = { "<encoded max/type changes>" },
    current_chunk_ticks = 60,
    current_state_chunk_records = 12,
    tick_count = 120,
    position_count = 6000,
    state_count = 62,
    encoded_bytes = 74860,
    missing_positions = 0,
    skipped_positions = 0,
    skipped_ticks = 0,
    capped = false,
}
```

`chunks` are internal string blocks of at most 60 ticks. `state_chunks` contain
at most 60 complete max/type records. They limit Lua string copying and
SavedVariables table overhead; they are not upload batches. The uploader
processes each array in order as one continuous stream.

### `b36-v3` encoding

All numeric fields use lowercase base36.

```text
<epochMs>:<mapId3>:<floor2>:<unit12><unit12>...;
```

Each per-tick unit sample is fixed-width and unchanged from `b36-v2`:

```text
<guidIndex2><x3><y3><healthPermille2><resourcePermille2>
```

State changes are unchanged from `b36-v2` and use a separate
semicolon-terminated stream:

```text
<effectiveEpochMs>:<guidIndex2><healthMax5><resourceMax5><resourceType1>;
```

- `epochMs`: observation time in epoch milliseconds, variable-width base36.
- `mapId3`: map area ID, left-padded to three base36 characters.
- `floor2`: selected dungeon-map level, left-padded to two lowercase base36
  characters; known integers 0 through 1,294 (`00` is valid zero). `zz` (1,295)
  means unknown when the API is absent or its result is invalid or out of range.
- `guidIndex2`: zero-based index into `guids`, left-padded to two characters.
- `x3`, `y3`: normalized coordinates multiplied by 10,000 and rounded.
- Percentage fields use permille values 0 through 1,000; `zz` means unknown.
- Maximum fields accept 0 through 60,466,174; `zzzzz` means unknown.
- Resource type is the numeric `UnitPowerType` value; `z` means unknown.

At 50 units sampled every second, the measured one-hour fixture is approximately
2,223,300 encoded bytes (2.12 MiB) plus small SavedVariables syntax overhead.
For a nine-character epoch, a tick is `18 + 12 * unit_count` bytes: 618 bytes
at 50 units, versus 615 in historical `b36-v2`. The new floor and colon add
three bytes per tick, or 10,800 bytes across 3,600 ticks (historical fixture:
2,212,500 bytes). See `POSITION_SPEC.md` for canonical vectors and validation.
The store warns at 3 MiB and 3.5 MiB, then stops encoded data at 3.94 MiB. The
remaining 64 KiB of the 4 MiB file budget is reserved for Lua SavedVariables
syntax and metadata. A tick, new GUIDs, and its state changes are committed
atomically; previously captured data is never deleted.
