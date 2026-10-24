# Position Telemetry Upload Specification

Status: normative for SavedVariables schema version 1 and encoding `b36-v1`.

This document defines how the Chronicle desktop uploader and server consume the
position stream written by ChronicleCompanionWoTLK. It does not define the HTTP
endpoint or multipart request shape. Whatever upload envelope is used must pair
one `WoWCombatLog.txt` with the position payload extracted from the same closed
WoW installation.

## 1. Lifecycle and ownership

The addon writes one account-wide value:

```lua
ChronicleCompanionWoTLKDB.position_payload
```

The value is append-only across characters and WoW login sessions until a
successful desktop upload resets it. There are no upload batches, per-session
acknowledgments, or persisted Chronicle session IDs.

The desktop application must:

1. Wait until WoW has exited and the SavedVariables file is stable.
2. Read `WoWCombatLog.txt` and `ChronicleCompanionWoTLKDB.position_payload`.
3. Upload both as one logical Chronicle upload.
4. Wait for a successful server response.
5. Atomically rewrite the SavedVariables file, removing only
   `ChronicleCompanionWoTLKDB.position_payload` and preserving every unrelated
   key.
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
WTF/Account/<account>/SavedVariables/ChronicleCompanionWoTLK.lua
```

The exact multipart field names and authentication scheme remain outside this
specification.

## 2. Capture semantics

The addon attempts one tick per second only while both conditions are true:

```lua
LoggingCombat()
and UnitAffectingCombat("player")
```

One tick has one observation timestamp and contains the available positions for
the visible connected raid or party roster.

Logical position fields are:

```text
observed_at_ms
map_id
guid
x
y
```

- `observed_at_ms` is an epoch-millisecond estimate formed from `time()` at addon
  load plus monotonic `GetTime()` elapsed time. Later wall-clock adjustments are
  intentionally not reflected within that addon run.
- `map_id` is the WotLK map area ID. Zero means unknown.
- `guid` is the full opaque WoW unit GUID string.
- `x` and `y` are normalized map coordinates in the inclusive range 0 through 1.

Map ID is required because normalized coordinates are meaningful only within the
map coordinate space where they were observed.

A unit is omitted from a tick when its GUID or map coordinates are unavailable.
The addon treats `0,0` returned by `GetPlayerMapPosition` as unavailable rather
than as a valid position.

If the player's position is unavailable while the world map is visible, the
addon skips the entire tick rather than risk recording coordinates from a map
the user is browsing. When the map is hidden, the addon may temporarily select
the current zone, collect the tick, and restore the previous map state.

## 3. SavedVariables object

```lua
position_payload = {
    schema_version = 1,
    encoding = "b36-v1",
    guids = {
        "0x0000000000000001",
        "0x0000000000000002",
    },
    chunks = {
        "<encoded ticks>",
        "<encoded ticks>",
    },
    current_chunk_ticks = 60,
    tick_count = 120,
    position_count = 6000,
    encoded_bytes = 49700,
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
| `schema_version` | integer | Must equal `1`. |
| `encoding` | string | Must equal `b36-v1`. |
| `guids` | array of strings | Zero-based GUID dictionary; Lua array element 1 is wire index 0. |
| `chunks` | array of strings | Ordered encoded tick blocks. |

### Diagnostic fields

The remaining fields are diagnostics. The server should retain them but must
not trust them over decoded content.

| Field | Meaning |
|---|---|
| `current_chunk_ticks` | Number of ticks in the final chunk. |
| `tick_count` | Addon-reported total ticks. |
| `position_count` | Addon-reported total unit positions. |
| `encoded_bytes` | `sum(byte_length(guid) + 1) + sum(byte_length(chunk))`, excluding Lua syntax. |
| `missing_positions` | Unit observations omitted because a position was unavailable. |
| `skipped_positions` | Unit observations omitted because they could not be encoded. |
| `skipped_ticks` | Whole ticks refused after the storage cap. |
| `capped` | Capture stopped because the storage cap was reached. |
| `warned_*` | Whether the client displayed the corresponding capacity warning. |

`chunks` are not upload batches. They are allocation blocks containing at most
60 complete ticks each. The server processes all chunks in array order as one
continuous stream. A tick never crosses a chunk boundary.

## 4. Base36 alphabet

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

## 5. Tick grammar

A chunk is one or more complete ticks concatenated together:

```text
chunk       = tick *tick
tick        = epoch ":" map-id ":" 1*50(position) ";"
epoch       = 1*base36
map-id      = 3base36
position    = guid-index x-fixed y-fixed
guid-index  = 2base36
x-fixed     = 3base36
y-fixed     = 3base36
base36      = DIGIT / %x61-7A
```

In practical parser terms:

```text
<epochMs>:<mapId3>:<position8><position8>...;
```

Each position is exactly eight characters:

```text
<guidIndex2><x3><y3>
```

Field widths and decoded ranges:

| Field | Width | Decoded range |
|---|---:|---:|
| `epochMs` | variable | Positive epoch milliseconds |
| `mapId3` | 3 | 0 through 46,655; zero is unknown |
| `guidIndex2` | 2 | 0 through 1,295 |
| `x3` | 3 | Must be 0 through 10,000 |
| `y3` | 3 | Must be 0 through 10,000 |

Recover normalized coordinates with:

```text
x = x_fixed / 10000.0
y = y_fixed / 10000.0
```

## 6. Canonical test vector

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
position 0     = dictionary index 0, x=0.1234, y=0.5678
position 1     = dictionary index 1, x=1.0000, y=0.0000
```

Base36 values:

```text
1786244400123 -> msl7so3f
631           -> 0hj
0             -> 00
1234          -> 0ya
5678          -> 4dq
1             -> 01
10000         -> 7ps
0             -> 000
```

Encoded tick:

```text
msl7so3f:0hj:000ya4dq017ps000;
```

Decoded positions:

```json
[
  {
    "observed_at_ms": 1786244400123,
    "map_id": 631,
    "guid": "0x0000000000000001",
    "x": 0.1234,
    "y": 0.5678
  },
  {
    "observed_at_ms": 1786244400123,
    "map_id": 631,
    "guid": "0x0000000000000002",
    "x": 1.0,
    "y": 0.0
  }
]
```

## 7. Decoder algorithm

Process chunks incrementally. Do not concatenate the entire payload before
parsing.

```text
validate top-level schema and dictionary
position_ordinal = 0
tick_ordinal = 0

for each chunk in chunks, preserving array order:
    require chunk is a non-empty ASCII string
    split/scan chunk on semicolon delimiters
    require no unterminated trailing tick
    require 1 through 60 ticks in the chunk

    for each tick text:
        split at the first and second colon
        decode epoch text
        require map text length is exactly 3
        decode map ID

        records = text after the second colon
        require records length is a non-zero multiple of 8
        require records length / 8 <= 50

        seen indexes = empty set
        for each 8-character record:
            decode chars 1-2 as GUID dictionary index
            decode chars 3-5 as x_fixed
            decode chars 6-8 as y_fixed

            require index exists in guids
            require index is not duplicated within this tick
            require x_fixed <= 10000
            require y_fixed <= 10000

            emit {
                tick_ordinal,
                position_ordinal,
                observed_at_ms,
                map_id,
                guid = guids[index + 1],
                x_fixed,
                y_fixed,
            }
            position_ordinal += 1

        tick_ordinal += 1
```

Preserve encoded stream order. Do not sort ticks solely by timestamp. System
clock changes between WoW sessions can produce a non-monotonic timestamp even
though append order remains authoritative.

## 8. Required validation limits

Validate before or during decoding:

| Limit | Requirement |
|---|---|
| Schema | `schema_version == 1` |
| Encoding | `encoding == "b36-v1"` |
| GUID count | 0 through 1,296 |
| GUID uniqueness | Every dictionary string must be unique |
| GUID representation | Non-empty ASCII string, maximum 64 bytes; treat as opaque |
| Chunk type | Non-empty ASCII string |
| Ticks per chunk | 1 through 60 |
| Positions per tick | 1 through 50 |
| Coordinate values | 0 through 10,000 inclusive |
| Encoded content | At most 4,128,768 bytes |

Recommended GUID matching is ASCII case-insensitive because combat-log GUID
hexadecimal casing can vary. Do not parse GUIDs through a JavaScript number or
other potentially lossy numeric type.

The server should reject the position payload, while still allowing the combat
log upload to report a useful error, when a normative field or encoded record is
invalid. Never partially reinterpret malformed fixed-width records.

## 9. Integrity and diagnostics

After decoding, recompute:

```text
decoded_tick_count
decoded_position_count
encoded_content_bytes
```

Compare those values with `tick_count`, `position_count`, and `encoded_bytes`.
A mismatch indicates truncation, manual modification, or an implementation bug.
The recommended behavior is to reject the position attachment and retain the
combat log upload with an explicit position-telemetry error.

The following fields indicate incomplete coverage but do not invalidate decoded
records:

```text
capped == true
missing_positions > 0
skipped_positions > 0
skipped_ticks > 0
map_id == 0
```

Store or surface these diagnostics so reports do not imply complete position
coverage when capture was incomplete.

## 10. Upload idempotency

The desktop app may retry after the server committed an upload but before local
files were deleted. The server must make the combined upload idempotent.

A recommended deterministic position digest is SHA-256 over the following byte
sequence, written in order:

1. ASCII `position-b36-v1`, then byte `0x0A`.
2. ASCII decimal GUID count, then byte `0x0A`.
3. For each GUID in dictionary order: ASCII decimal byte length, ASCII `:`, the
   exact GUID bytes, then byte `0x0A`.
4. ASCII decimal chunk count, then byte `0x0A`.
5. For each chunk in array order: ASCII decimal byte length, ASCII `:`, the exact
   chunk bytes, then byte `0x0A`.

Lengths are byte counts, not Unicode code-point counts. Schema version 1 permits
only ASCII GUIDs and chunks, so the values are identical in a conforming payload.

A combined upload idempotency key may be:

```text
SHA256(<combat-log-sha256-hex> ":" <position-digest-hex>)
```

The exact database key is implementation-specific, but retries with identical
combat-log bytes and position content must not create duplicate encounters or
position rows.

## 11. Encounter association

Position records are attached to the same logical upload as the combat log.
Associate them by reconstructed combat-log time, map context, and GUID:

1. Reconstruct absolute combat-log timestamps using the server's existing log
   timeline logic.
2. Match ticks to encounters whose time window contains `observed_at_ms`, using
   a small implementation-defined tolerance for clock-anchor and log-timestamp
   precision differences.
3. Use `map_id` as a consistency check and partition key when available.
4. Join `guid` to combatants using case-insensitive opaque-string comparison.
5. Keep unmatched ticks as diagnostics or discard them explicitly; never assign
   a tick to an encounter solely because it is adjacent in chunk order.

The position stream can span multiple characters, zones, instances, and login
sessions because it persists until desktop upload. Timestamp and map context,
not an addon session ID, define association.

## 12. Capacity semantics

The addon uses these thresholds:

```text
warning           = 3,145,728 encoded bytes (3 MiB)
critical warning  = 3,670,016 encoded bytes (3.5 MiB)
hard encoded cap  = 4,128,768 bytes
file budget       = 4,194,304 bytes (4 MiB)
reserved margin   = 65,536 bytes
```

At the cap, the addon keeps the complete encoded prefix and stops appending new
ticks. It does not drop old data. `capped` and `skipped_ticks` communicate the
resulting missing suffix.

The measured 50-unit, one-hour fixture contains:

```text
3,600 ticks
180,000 positions
1,491,350 encoded bytes
approximately 1.42 MiB before Lua SavedVariables syntax
```

## 13. Conformance checklist

A server implementation is conformant when it:

- Accepts the canonical test vector.
- Resolves GUID indexes with Lua-array index offset `+1`.
- Preserves chunk and tick order.
- Rejects invalid base36, field widths, indexes, duplicate indexes, and
  out-of-range coordinates.
- Enforces the GUID, chunk, tick, position, and byte limits.
- Treats GUIDs as opaque strings rather than numbers.
- Verifies decoded counts and encoded byte totals.
- Retains incomplete-coverage diagnostics.
- Makes combined combat-log and position uploads idempotent.
- Does not require a Chronicle session ID.
