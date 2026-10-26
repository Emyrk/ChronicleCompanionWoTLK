# Position and Vital Telemetry Upload Specification

Status: normative for SavedVariables schema version 3 and encoding `b36-v3`.

This document defines how the Chronicle desktop uploader and server consume the
position and vital streams written by ChronicleCompanionWoTLK. It does not
define the HTTP endpoint or multipart request shape. Whatever upload envelope is
used must pair one `WoWCombatLog.txt` with the telemetry payload extracted from
the same closed WoW installation.

## 1. Lifecycle and ownership

The addon writes one account-wide value owned by the optional
ChronicleSidekickBridgeWoTLK addon:

```lua
ChronicleSidekickBridgeWoTLKDB.position_payload
```

The value is append-only across characters and WoW login sessions until a
successful desktop upload resets it, or the user confirms **Clear positions** in
settings or via `/clog positions clear`. There are no upload batches,
per-session acknowledgments, or persisted Chronicle session IDs.

The desktop application must:

1. Wait until WoW has exited and the SavedVariables file is stable.
2. Read `WoWCombatLog.txt` and
   `ChronicleSidekickBridgeWoTLKDB.position_payload`.
3. Upload both as one logical Chronicle upload.
4. Wait for a successful server response.
5. Atomically rewrite the SavedVariables file, removing only
   `ChronicleSidekickBridgeWoTLKDB.position_payload` and preserving every
   unrelated key.
6. Delete the uploaded combat log only after the SavedVariables replacement
   succeeds.

The two local files cannot be deleted atomically together. This ordering ensures
that upload failure or SavedVariables rewrite failure leaves both artifacts
intact. If combat-log deletion fails after the payload was removed, the desktop
app must record cleanup as pending and retry deletion without creating another
server upload. Server idempotency remains the final duplicate-upload safeguard.

The desktop app should parse the SavedVariables Lua file as data and send a JSON
(or equivalent typed) mirror of `position_payload`. Neither the desktop app nor
the server should evaluate arbitrary Lua source. The usual on-disk source is:

```text
WTF/Account/<account>/SavedVariables/ChronicleSidekickBridgeWoTLK.lua
```

The exact multipart field names and authentication scheme remain outside this
specification.

Schema version 3 is not an in-place reinterpretation of versions 1 or 2. Existing
`b36-v1` and `b36-v2` payloads are preserved unchanged and block new capture until
compatible tooling uploads them or the user explicitly clears them. Historical
`b36-v2` ticks have no floor field; neither older format may be migrated by
guessing floors or reinterpreted as `b36-v3`.

## 2. Capture semantics

Position capture must be enabled in settings and compatible bridge storage must
be loaded. The addon attempts one tick per second only while both conditions are
true:

```lua
LoggingCombat()
and UnitAffectingCombat("player")
```

One tick has one observation timestamp and contains the available position and
percentage-vital samples for the visible connected raid or party roster.

Logical tick fields are:

```text
observed_at_ms
map_id
floor
guid
x
y
health_permille
resource_permille
```

- `observed_at_ms` is an epoch-millisecond estimate formed from `time()` at addon
  load plus monotonic `GetTime()` elapsed time. Later wall-clock adjustments are
  intentionally not reflected within that addon run.
- `map_id` is the WotLK map area ID. Zero means unknown.
- `floor` is the selected dungeon-map level, sampled in the same map state as
  `x` and `y`. Known integer levels are 0 through 1,294. Zero is valid and
  distinct from unknown; an absent API, invalid result, or out-of-range result
  is unknown. The floor is shared by all unit samples in the tick.
- `guid` is the full opaque WoW unit GUID string.
- `x` and `y` are normalized map coordinates in the inclusive range 0 through 1.
- `health_permille` and `resource_permille` are rounded to 0 through 1,000.
  Each step represents 0.1 percent. The reserved value 1,295 means unknown.

Map ID is required because normalized coordinates are meaningful only within the
map coordinate space where they were observed. The floor distinguishes levels
within that map; unknown floor must not be treated as level zero.

A unit is omitted from a tick when its GUID or map coordinates are unavailable.
The addon treats `0,0` returned by `GetPlayerMapPosition` as unavailable rather
than as a valid position. Missing vital APIs or a non-positive maximum do not
omit an otherwise valid position; the affected percentage is encoded as unknown.

If the player's position is unavailable while the world map is visible, the
addon skips the entire tick rather than risk recording coordinates from a map
the user is browsing. When the map is hidden, the addon may temporarily select
the current zone, collect the map ID, selected dungeon-map level, and coordinates
in that same map state, and restore the previous map state. Sample the floor
before restoration, not from the restored browsing state.

Max health, max resource, and resource type are stored in a separate state
stream. A state record is emitted on the first encoded observation of a GUID and
again only when that three-field tuple changes. Unknown values are represented
explicitly, so a transition between known and unknown state is also a change.

## 3. SavedVariables object

```lua
position_payload = {
    schema_version = 3,
    encoding = "b36-v3",
    guids = {
        "0x0000000000000001",
        "0x0000000000000002",
    },
    chunks = {
        "<encoded ticks>",
        "<encoded ticks>",
    },
    state_chunks = {
        "<encoded max/type state records>",
    },
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
    warned_soft = false,
    warned_critical = false,
    warned_cap = false,
}
```

### Normative fields

| Field | Type | Meaning |
|---|---|---|
| `schema_version` | integer | Must equal `3`. |
| `encoding` | string | Must equal `b36-v3`. |
| `guids` | array of strings | Zero-based GUID dictionary; Lua array element 1 is wire index 0. |
| `chunks` | array of strings | Ordered encoded tick blocks. |
| `state_chunks` | array of strings | Ordered max-health, max-resource, and resource-type state blocks. |

### Diagnostic fields

The remaining fields are diagnostics. The server should retain them but must
not trust them over decoded content.

| Field | Meaning |
|---|---|
| `current_chunk_ticks` | Number of ticks in the final tick chunk. |
| `current_state_chunk_records` | Number of records in the final state chunk. |
| `tick_count` | Addon-reported total ticks. |
| `position_count` | Addon-reported total unit samples. |
| `state_count` | Addon-reported total state-change records. |
| `encoded_bytes` | GUID bytes plus tick-chunk bytes plus state-chunk bytes, excluding Lua syntax. |
| `missing_positions` | Unit observations omitted because a position was unavailable. |
| `skipped_positions` | Unit observations omitted because they could not be encoded. |
| `skipped_ticks` | Whole ticks refused after the storage cap. |
| `capped` | Capture stopped because the storage cap was reached. |
| `warned_*` | Whether the client displayed the corresponding capacity warning. |

`chunks` and `state_chunks` are not upload batches. They are allocation blocks
that avoid repeated large Lua string copies. Tick chunks contain at most 60
complete ticks. State chunks contain at most 60 complete state records. The
server processes each array in array order as one continuous stream, and no
record crosses a chunk boundary.

## 4. Base36 alphabet and sentinels

All encoded numbers use lowercase ASCII base36:

```text
0123456789abcdefghijklmnopqrstuvwxyz
```

Uppercase letters, signs, spaces, prefixes, decimal points, and empty numeric
fields are invalid.

Decode by repeatedly multiplying the accumulated value by 36 and adding the
next digit value. Epoch milliseconds fit safely in a signed 64-bit integer and
in the exact integer range of an IEEE-754 double for the foreseeable lifetime
of this schema.

Reserved unknown values are:

| Logical field | Encoded | Decoded |
|---|---|---:|
| floor | `zz` | 1,295 |
| health/resource permille | `zz` | 1,295 |
| max health/resource | `zzzzz` | 60,466,175 |
| resource type | `z` | 35 |

Values between 1,001 and 1,294 are invalid in percentage fields. The five-digit
maximum fields accept 0 through 60,466,174 as known values. Resource type accepts
0 through 34 as known values. The resource type is the numeric first return value
from WotLK `UnitPowerType`; consumers should preserve it even if they do not
recognize a particular value.

## 5. Tick stream grammar

A tick chunk is one or more complete ticks concatenated together:

```text
chunk             = tick *tick
tick              = epoch ":" map-id ":" floor ":" 1*50(unit-sample) ";"
epoch             = 1*base36
map-id            = 3base36
floor             = 2base36
unit-sample       = guid-index x-fixed y-fixed health-pct resource-pct
guid-index        = 2base36
x-fixed           = 3base36
y-fixed           = 3base36
health-pct        = 2base36
resource-pct      = 2base36
base36            = DIGIT / %x61-7A
```

In practical parser terms:

```text
<epochMs>:<mapId3>:<floor2>:<unit12><unit12>...;
```

The floor is exactly two lowercase base36 characters, left-padded with zeroes.
`00` is known floor zero, `01` is floor one, and `zz` is unknown.

Each unit sample is exactly 12 characters (unchanged from `b36-v2`):

```text
<guidIndex2><x3><y3><healthPermille2><resourcePermille2>
```

Field widths and decoded ranges:

| Field | Width | Decoded range |
|---|---:|---:|
| `epochMs` | variable | Positive epoch milliseconds |
| `mapId3` | 3 | 0 through 46,655; zero is unknown |
| `floor2` | 2 | 0 through 1,294 known; 1,295 is unknown |
| `guidIndex2` | 2 | 0 through 1,295 |
| `x3` | 3 | 0 through 10,000 |
| `y3` | 3 | 0 through 10,000 |
| `healthPermille2` | 2 | 0 through 1,000, or 1,295 for unknown |
| `resourcePermille2` | 2 | 0 through 1,000, or 1,295 for unknown |

Recover normalized coordinates and percentages with:

```text
x = x_fixed / 10000.0
y = y_fixed / 10000.0
health_percent = health_permille / 10.0
resource_percent = resource_permille / 10.0
```

Do not apply those percentage formulas to the unknown sentinel.

## 6. Vital state stream grammar

The vital unit fields and this separate state stream are unchanged from
`b36-v2`. A state chunk is one or more complete state records concatenated together:

```text
state-chunk       = state-record *state-record
state-record      = epoch ":" guid-index health-max resource-max resource-type ";"
health-max        = 5base36
resource-max      = 5base36
resource-type     = 1base36
```

In practical parser terms:

```text
<effectiveEpochMs>:<guidIndex2><healthMax5><resourceMax5><resourceType1>;
```

The fixed-width body after the colon is exactly 13 characters. The timestamp is
the observation time of the tick that caused the state to be emitted.

Process state records in encoded stream order. For each GUID, a record replaces
that GUID's previous max/type tuple. Apply records whose timestamp matches a tick
before interpreting that tick's percentages. Between changes, retain the most
recent tuple in stream order. Do not sort either stream solely by timestamp;
wall-clock anchors can move backward between WoW sessions.

The percentage fields are authoritative as percentages. A known maximum permits
an approximate absolute value, but the original current value cannot always be
reconstructed exactly because the percentage was rounded to permille precision.

## 7. Canonical test vector

Input dictionary:

```json
[
  "0x0000000000000001",
  "0x0000000000000002"
]
```

Logical tick:

```text
observed_at_ms = 1786244400123
map_id         = 631
floor          = 1
unit 0         = index 0, x=0.1234, y=0.5678, health=500, resource=250
unit 1         = index 1, x=1.0000, y=0.0000, health=1000, resource=unknown
```

Logical initial state:

```text
index 0 = max health 30000, max resource 20000, resource type 0
index 1 = max health 50000, max resource 0, resource type 1
```

Selected base36 values:

```text
1786244400123 -> msl7so3f
631           -> 0hj
1 (floor)     -> 01
1234          -> 0ya
5678          -> 4dq
500           -> dw
250           -> 6y
1000          -> rs
unknown pct   -> zz
30000         -> 00n5c
20000         -> 00ffk
50000         -> 012kw
```

Encoded tick:

```text
msl7so3f:0hj:01:000ya4dqdw6y017ps000rszz;
```

Encoded state chunk:

```text
msl7so3f:0000n5c00ffk0;msl7so3f:01012kw000001;
```

Decoded unit samples:

```json
[
  {
    "observed_at_ms": 1786244400123,
    "map_id": 631,
    "floor": 1,
    "guid": "0x0000000000000001",
    "x": 0.1234,
    "y": 0.5678,
    "health_permille": 500,
    "resource_permille": 250,
    "health_max": 30000,
    "resource_max": 20000,
    "resource_type": 0
  },
  {
    "observed_at_ms": 1786244400123,
    "map_id": 631,
    "floor": 1,
    "guid": "0x0000000000000002",
    "x": 1.0,
    "y": 0.0,
    "health_permille": 1000,
    "resource_permille": null,
    "health_max": 50000,
    "resource_max": 0,
    "resource_type": 1
  }
]
```

## 8. Decoder algorithm

Process chunks incrementally. Do not concatenate the entire payload before
parsing.

```text
validate top-level schema and GUID dictionary

state_by_guid = empty map
state_records_by_timestamp_and_guid = decode state_chunks in array order

for each tick chunk in chunks, preserving array order:
    require chunk is a non-empty ASCII string
    scan complete semicolon-terminated ticks
    require 1 through 60 ticks in the chunk

    for each tick:
        require exactly three colons and split epoch, map ID, floor, and unit bytes
        decode epoch, three-character map ID, and two-character floor
        require floor is 0..1294 or exactly 1295 (unknown)
        retain floor zero as known; represent unknown as null, not zero
        require unit bytes are a non-zero multiple of 12
        require 1 through 50 unit samples

        apply the next state records emitted for this tick timestamp in
        state-stream order before producing enriched samples

        seen indexes = empty set
        for each 12-character unit sample:
            decode index, x, y, health permille, resource permille
            require index exists and is unique within the tick
            require x and y are at most 10000
            require each permille is 0..1000 or the unknown sentinel

            emit the sample with the tick map ID and floor (null if unknown),
            and the current state_by_guid tuple, if any
```

Decode the state stream independently:

```text
for each state chunk in state_chunks, preserving array order:
    require 1 through 60 complete semicolon-terminated records
    for each record:
        split at its only colon
        require a non-empty epoch and a 13-character body
        decode index, max health, max resource, and resource type
        require the index exists
        require each value is known-range or its exact unknown sentinel
        retain stream ordinal for deterministic application
```

Preserve encoded stream order. A state record is valid even if no uploaded tick
ultimately matches its timestamp; retain or report it as unmatched rather than
assigning it to an unrelated tick.

## 9. Required validation limits

Validate before or during decoding:

| Limit | Requirement |
|---|---|
| Schema | `schema_version == 3` |
| Encoding | `encoding == "b36-v3"` |
| GUID count | 0 through 1,296 |
| GUID uniqueness | Every dictionary string must be unique |
| GUID representation | Non-empty ASCII string, maximum 64 bytes; treat as opaque |
| Tick/state chunk type | Non-empty ASCII string |
| Ticks per tick chunk | 1 through 60 |
| Records per state chunk | 1 through 60 |
| Unit samples per tick | 1 through 50 |
| Floor | Exactly two lowercase base36 characters; 0 through 1,294 known, or exactly 1,295 unknown |
| Coordinate values | 0 through 10,000 inclusive |
| Percentage values | 0 through 1,000, or exactly 1,295 |
| Maximum values | 0 through 60,466,174, or exactly 60,466,175 |
| Resource type | 0 through 34, or exactly 35 |
| Encoded content | At most 4,128,768 bytes |

Recommended GUID matching is ASCII case-insensitive because combat-log GUID
hexadecimal casing can vary. Do not parse GUIDs through a JavaScript number or
other potentially lossy numeric type.

The server should reject the telemetry attachment, while still allowing the
combat log upload to report a useful error, when a normative field or encoded
record is invalid. Never partially reinterpret malformed fixed-width records.

## 10. Integrity and diagnostics

After decoding, recompute:

```text
decoded_tick_count
decoded_position_count
decoded_state_count
encoded_content_bytes
```

`encoded_content_bytes` is:

```text
sum(byte_length(guid) + 1)
+ sum(byte_length(tick_chunk))
+ sum(byte_length(state_chunk))
```

Compare those values with `tick_count`, `position_count`, `state_count`, and
`encoded_bytes`. A mismatch indicates truncation, manual modification, or an
implementation bug. The recommended behavior is to reject the telemetry
attachment and retain the combat log upload with an explicit telemetry error.

The following fields indicate incomplete coverage but do not invalidate decoded
records:

```text
capped == true
missing_positions > 0
skipped_positions > 0
skipped_ticks > 0
map_id == 0
unknown floor sentinel (not floor zero)
unknown percentage or state sentinels
```

Store or surface these diagnostics so reports do not imply complete position or
vital coverage when capture was incomplete.

## 11. Upload idempotency

The desktop app may retry after the server committed an upload but before local
files were deleted. The server must make the combined upload idempotent.

A recommended deterministic telemetry digest is SHA-256 over the following byte
sequence, written in order:

1. ASCII `position-b36-v3`, then byte `0x0A`.
2. ASCII decimal GUID count, then byte `0x0A`.
3. For each GUID in dictionary order: ASCII decimal byte length, ASCII `:`, the
   exact GUID bytes, then byte `0x0A`.
4. ASCII decimal tick-chunk count, then byte `0x0A`.
5. For each tick chunk in array order: ASCII decimal byte length, ASCII `:`, the
   exact chunk bytes, then byte `0x0A`.
6. ASCII decimal state-chunk count, then byte `0x0A`.
7. For each state chunk in array order: ASCII decimal byte length, ASCII `:`, the
   exact chunk bytes, then byte `0x0A`.

Lengths are byte counts, not Unicode code-point counts. Schema version 3 permits
only ASCII GUIDs and chunks, so the values are identical in a conforming payload.

A combined upload idempotency key may be:

```text
SHA256(<combat-log-sha256-hex> ":" <telemetry-digest-hex>)
```

The exact database key is implementation-specific, but retries with identical
combat-log bytes and telemetry content must not create duplicate encounters,
position rows, or vital rows.

## 12. Encounter association

Telemetry records are attached to the same logical upload as the combat log.
Associate them by reconstructed combat-log time, map context, and GUID:

1. Reconstruct absolute combat-log timestamps using the server's existing log
   timeline logic.
2. Match ticks to encounters whose time window contains `observed_at_ms`, using
   a small implementation-defined tolerance for clock-anchor and log-timestamp
   precision differences.
3. Use `map_id` and known `floor` as map-context consistency checks and partition
   keys when available. Keep unknown floor distinct from known floor zero.
4. Join `guid` to combatants using case-insensitive opaque-string comparison.
5. Apply state changes to same-GUID samples before deriving any approximate
   absolute vital values.
6. Keep unmatched ticks and state changes as diagnostics or discard them
   explicitly; never assign them solely because they are adjacent in a chunk.

The streams can span multiple characters, zones, instances, and login sessions
because they persist until desktop upload. Timestamp, map context, GUID, and
encoded stream order, not an addon session ID, define association.

## 13. Capacity semantics

The addon uses these thresholds:

```text
warning           = 3,145,728 encoded bytes (3 MiB)
critical warning  = 3,670,016 encoded bytes (3.5 MiB)
hard encoded cap  = 4,128,768 bytes
file budget       = 4,194,304 bytes (4 MiB)
reserved margin   = 65,536 bytes
```

A tick, newly required GUIDs, and state records caused by that tick are committed
atomically. If the complete append would exceed the cap, none of them are
written. The addon keeps the complete encoded prefix and stops appending new
ticks. It does not drop old data. `capped` and `skipped_ticks` communicate the
resulting missing suffix.

The measured 50-unit, one-hour fixture with unchanged max/type state contains:

```text
3,600 ticks
180,000 unit samples
50 initial state records
2,223,300 encoded bytes
approximately 2.12 MiB before Lua SavedVariables syntax
```

In general, tick size is `length(epochMs) + 9 + 12 * unit_count` bytes.
For a nine-character epoch, tick size is `18 + 12 * unit_count` bytes: 618
bytes at 50 units. The floor field and its colon add three bytes per tick over
historical `b36-v2` (615 bytes at 50 units), or 10,800 bytes over 3,600 ticks.
The fixture total grows from historical `b36-v2`'s 2,212,500 bytes by
`3600 * 3 = 10,800` bytes to 2,223,300 bytes; GUID and state bytes are unchanged.

Additional state records are small and occur only when a unit's max health, max
resource, or resource type changes.

## 14. Conformance checklist

A server implementation is conformant when it:

- Accepts both canonical encoded streams.
- Preserves known floor zero and unknown floor distinctly, without guessing
  floors for historical `b36-v1` or `b36-v2` payloads.
- Resolves GUID indexes with Lua-array index offset `+1`.
- Preserves tick-stream and state-stream order.
- Rejects invalid base36, field widths, indexes, duplicate tick indexes,
  out-of-range values, and non-sentinel reserved ranges.
- Enforces the GUID, chunk, tick, unit, state-record, and byte limits.
- Treats GUIDs as opaque strings rather than numbers.
- Applies max/type changes without treating rounded percentages as exact values.
- Verifies decoded counts and encoded byte totals across both streams.
- Retains incomplete-coverage and unknown-value diagnostics.
- Makes combined combat-log and telemetry uploads idempotent.
- Does not require a Chronicle session ID.
