# ChronicleCompanionWoTLK — Agent Guide

> Companion addon for **[ChronicleClassic.com](https://chronicleclassic.com)**, ported to **WoW 3.3.5a (WotLK, Interface 30300)**.
> Status: greenfield. `DispatchProbe.lua` is a throwaway proof-of-concept that validated the smuggling channel (see §3.5); everything below is the design contract for the real build.

---

## 1. Goal

WoTLK's stock combat log (`Logs/WoWCombatLog.txt`) is already rich — it has millisecond timestamps, GUIDs, spell IDs, amount/overheal/absorb/resist breakdowns, school masks, power-types, etc. We do **not** want to replace it.

What WoTLK CLEU still lacks is **per-player context**: gear (with enchants/gems), talent specs and glyphs, guild rank, item-level, set bonuses, current spec index, etc. Chronicle needs that data attached to every encounter so the website can render meaningful raid-leader reports.

**Our job:** smuggle that enrichment data **into `WoWCombatLog.txt` itself**, so users only need to upload one file. The transport mechanism is borrowed from `research/AscensionLogsCompanion`: overwrite the localized `SPELL_FAILED_*` globals so the engine writes our base64-encoded payload into the fail-reason field of `SPELL_CAST_FAILED` lines. The website demuxer reassembles the chunks server-side.

In a sentence: **stock WoTLK CLEU + smuggled `COMBATANT_INFO`-style records = a complete Chronicle log.**

---

## 2. References

| Path / URL                                                                         | What we take from it                                                                              |
|------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------|
| `research/ChronicleCompanion/`                                                     | Upstream vanilla addon. Source of truth for **what data** Chronicle wants (CI fields, formats).   |
| `research/AscensionLogsCompanion/`                                                 | WotLK-era smuggling transport. Source of truth for **how** to embed data in the combat log.       |
| `research/Interface/`                                                              | WoW 3.3.5a client Interface code (FrameXML, etc.). Reference for WotLK API signatures and UI.    |
| https://github.com/Emyrk/ChronicleCompanion/                                       | Public mirror of `research/ChronicleCompanion/`.                                                  |
| https://github.com/FangYuanWoW/AscensionLogsCompanion/                             | Public mirror of `research/AscensionLogsCompanion/`.                                              |

**Hard rule:** never copy code verbatim from `research/AscensionLogsCompanion/` (different license, different namespace). Re-derive every module in our own style under the `Chronicle.*` namespace.

---

## 3. Transport: the smuggling pipeline

```
buildCI(player) -> serialize -> compress -> base64 -> chunk -> relay queue
                                                                 |
                                                                 v
                                  overwrite SPELL_FAILED_* globals
                                                                 |
                                                                 v
                  engine fires SPELL_CAST_FAILED -> chunk lands in WoWCombatLog.txt
                                                                 |
                                                                 v
                                  COMBAT_LOG_EVENT_UNFILTERED handler
                                    - confirms landed (failedType prefix match)
                                    - advances queue / re-applies on miss
```

### Constraints

- **Lua 5.1** semantics (no `goto`, no integer-division `//`, no built-in bitwise operators — use `bit.band/bor/bxor/lshift/rshift` from `bitlib`).
- WoTLK 3.3.5 API only. **No SuperWoW / Nampower / UnitXP3** (those are vanilla-server extensions; WoTLK CLEU is sufficient for us).
- The fail-reason field truncates at **~245 characters** on Warmane 3.3.5a (confirmed by testing; earlier estimate of ~1023 was wrong). We chunk at **200 bytes** payload + sentinel header to leave headroom for the header itself.
- Base64 alphabet must exclude `|`, `,`, `:`, `"`, `\n` (combat-log framing characters). Use the URL-safe alphabet `A-Z a-z 0-9 - _` with `.` as padding.
- The relay is **only active** while `LoggingCombat()` is true, the player is in combat, and we are in a raid / party instance. Originals are captured at init and restored on scope exit / `PLAYER_LOGOUT`.
- Sentinel format: `[[CHRON_v1_<sessionId>_<guid>_<snapshotId>_<seq>/<total>]]<b64>`. The prefix must be stable so the website demuxer can grep for it.
- A `UIErrorsFrame:AddMessage` hook must silently drop messages whose first chars match the sentinel prefix — otherwise the user sees base64 garbage in the red error overlay.
- An error-handler / `StaticPopup` filter must suppress `tainted the call of the secure function` notices attributed to the addon. Taint is inherent to the technique; we hide the cosmetic surface only.

### What we will and will not smuggle

| Smuggle (chunk via relay)                                | Already in stock CLEU — do NOT re-emit |
|----------------------------------------------------------|----------------------------------------|
| Player gear (item IDs, enchants, gems, suffixes)         | Damage / heal / absorb amounts         |
| Talents (3 trees, point distribution, active spec)       | Spell IDs, school masks                |
| Glyphs (major / minor)                                   | Aura applied / refreshed / removed     |
| Guild name + rank + rank index                           | GUIDs, names, flags                    |
| Specialization label + role                              | Combat start/end (PLAYER_REGEN_*)      |
| Pet GUID ↔ owner GUID mapping                            | Pet damage attribution                 |
| Realm / region / client build / addon version            | Death, party kill                      |
| Encounter context (pull id, boss name)                   | Loot (use stock chat scrape if needed) |

Anything Chronicle's vanilla version emits as a custom event that **already exists in WoTLK CLEU** must NOT be re-emitted by us. Duplication is the failure mode that turns a 5 MB log into a 50 MB log.

---

## 3.5. Channel proof — what we confirmed on Warmane 3.3.5a (2026-05-20)

Before building any of the layered structure below, we proved the smuggling channel works with a minimum-viable probe (`DispatchProbe.lua`, ~150 lines, no abstractions). Findings to bake into the real Transport module:

- **The engine reads the Lua `SPELL_FAILED_*` global at CLEU emission time**, not a cached C string. Overwriting the global in Lua immediately changes what lands in `WoWCombatLog.txt` for the next `SPELL_CAST_FAILED` row. Confirmed payload `"hello"` arriving verbatim in the fail-reason field for a `SPELL_FAILED_MOVING` failure.
- **`CastSpellByName` is protected on 3.3.5a** and cannot be invoked from a slash command or any non-hardware code path — calling it from Lua is a silent no-op (no error, no cast, no CLEU). This kills any "synthesize our own failure to flush a chunk" design. The relay **must** piggyback on failures the player produces naturally during real play.
- **`UIErrorsFrame:AddMessage` suppression works.** Hooking it and dropping messages equal to the active payload prevents the payload from flashing on the red error overlay. This must be in place before any payload is applied, or users will see base64 garbage on screen.
- **Hijack is sticky.** Globals stay overwritten until restored; back-to-back failures all land with the current payload. This means the relay's "advance to next chunk after landing-confirmation" logic happens entirely in Lua — we don't need to coordinate with the engine.
- **Originals must be captured before the first overwrite** (we use `PLAYER_LOGIN`) and restored on `PLAYER_LOGOUT`. Never assume the localized string; capture from `_G[name]` at runtime.
- **`SPELL_FAILED_MOVING` is the easiest manual-test trigger.** Arm a payload, then try to cast anything while running. Useful for dev probes; not relevant to the production relay (which observes all failure types).
- **The fail-reason field truncates at ~245 characters on Warmane 3.3.5a.** AGENTS.md previously said ~1023; that was wrong. Set `CHUNK_MAX_BYTES = 200` in `Core/Constants.lua` to leave headroom for the sentinel header. Do not exceed 245 total (header + payload) or the tail will be silently cut.
- **The hijack is sticky across multiple failures with different payloads.** You can `arm A` → fail → `arm B` → fail and see both payloads land in sequence. This confirms the relay's chunk-advance logic (re-arm with the next chunk after landing confirmation) is entirely sound — no engine-side caching interferes.
- **Slash routing:** `/chron`, `/chronicle`, and `/clog` are the three confirmed-working slash slots.

The working probe lives at the repo root as `DispatchProbe.lua` until it is rewritten into `Transport/SpellFailedRelay.lua`. Treat the probe as throwaway; do **not** evolve it into the production module — re-derive the relay against the real Core/* substrate.

---

## 4. Directory layout

Every path is relative to the addon root (`ChronicleCompanionWoTLK/`).

```
ChronicleCompanionWoTLK.toc    -- load order, SavedVariables, Interface 30300
Init.lua                       -- boot sequence (ADDON_LOADED -> safeStart modules)

Core/
  Namespace.lua                -- _G.Chronicle = {...}; Chronicle.RegisterEvent dispatcher
  Constants.lua                -- ALL tunables, sentinel prefix, globals list, defaults
  Config.lua                   -- SavedVariables hydration + defaults merge
  Logger.lua                   -- debug/info/warn/error with color prefixes; gated by config.debug
  Metrics.lua                  -- in-memory counters for /chron status (chunks_landed, etc.)
  Queue.lua                    -- Ring buffer + small priority queue (relay rotation, inspect sched)
  Base64.lua                   -- Combat-log-safe URL alphabet
  Serialize.lua                -- AceSerializer + LibDeflate path, fallback custom serializer
  Hash.lua                     -- Fast string hash for CI dedup

Transport/
  SpellFailedRelay.lua         -- THE smuggling module: overwrite globals + landed-evidence gating
  Sentinel.lua                 -- Chunk header build/parse (kept separate so tests do not pull globals)
  AddonChannel.lua             -- (optional) addon-comms peer broadcast, for multi-logger dedup

Capture/
  LocalScan.lua                -- buildLocalCI() — gear, talents, glyphs, guild for the player
  GearScan.lua                 -- 19-slot inventory walk with item id, enchant, gems, suffix
  TalentScan.lua               -- WotLK dual-spec aware: both groups + active group index
  GlyphScan.lua                -- Major/minor glyph IDs per spec group
  InspectCache.lua             -- Peer CIs keyed by GUID, with TTL + SavedVariables persistence
  InspectLoop.lua              -- Round-robin NotifyInspect() against raid roster, throttled
  EncounterTracker.lua         -- Boss + pull id, derived from CLEU + zone (no ENCOUNTER_START on 3.3.5)
  SnapshotPipeline.lua         -- LocalScan / InspectCache -> serialize -> chunk -> enqueue

Zone/
  ZoneMonitor.lua              -- Track instance type, instance id, auto-toggle LoggingCombat()
  BossRegistry.lua             -- WotLK raid/dungeon boss list keyed by encounter creature id

UI/
  MinimapButton.lua            -- LibDBIcon-1.0 icon, status tooltip
  SettingsFrame.xml + .lua     -- Options panel registered under Interface Options
  SlashCommand.lua             -- /chronicle, /chron, /clog (see section 6)

libs/                          -- Vendored: LibStub, CallbackHandler, AceSerializer-3.0, LibDeflate,
                               --           LibDataBroker-1.1, LibDBIcon-1.0
embeds.xml                     -- Loads libs/

research/                      -- Read-only reference repos. NEVER modify, NEVER ship in zip.
```

### Module conventions

- One responsibility per file. If a file passes ~400 lines, split it.
- Every module is a table assigned into the `Chronicle.*` tree from `Core/Namespace.lua`. No new globals beyond `Chronicle`, `ChronicleCompanionWoTLKDB`, `ChronicleCompanionWoTLKCharDB`, and any `SLASH_*` slots.
- Every module exposes `.start()` (idempotent) so `Init.lua` can `pcall(mod.start)` in a uniform `safeStart()` loop.
- Modules subscribe to events via `Chronicle.RegisterEvent(event, fn)`, never by creating their own frames (one shared dispatcher in `Core/Namespace.lua`).
- All tunable numbers (TTLs, chunk sizes, ring capacities, throttle intervals, the `SPELL_FAILED_*` globals list) live in `Core/Constants.lua`. No magic numbers in module bodies.

---

## 5. SavedVariables

Declared in the TOC; hydrated by `Core/Config.lua` on `ADDON_LOADED`.

```
ChronicleCompanionWoTLKDB             -- account-wide
  config = { debug=false, hijack_enabled=true, auto_combatlog_on_raid=true,
             log_dungeons=true, broadcast_enabled=true, is_logger=true,
             silent_auto_logging=false, show_minimap=true, ... }
  peers  = { [guid] = { last_ci_hash, last_seen_at } }       -- cross-character dedup hint

ChronicleCompanionWoTLKCharDB         -- per-character
  session       = { id, started_at, realm, region, build }
  last_own_ci   = { ... }                                    -- fallback if relay could not drain
  inspect_cache = { [guid] = { ci, last_success_at } }       -- TTL: CI_STALE_MS
  metrics       = { chunks_landed, chunks_lost, eager_restores, ... }
  last_zone_ids = { [zoneName] = instanceId }                -- stale-lockout warning
```

### Rules

- Always merge defaults from `Constants.DEFAULT_CONFIG` into the loaded table — users from older versions must not lose new keys.
- Bound every list: inspect cache capped at `INSPECT_CACHE_MAX_ENTRIES`, metrics persisted as plain numbers, `last_own_ci` is a single value not a list. We will not grow `SavedVariables` unbounded — that is the bug that produced ALC's "block too big" crash; see their `Init.lua` comment.

---

## 6. Slash commands

Primary slashes: `/chronicle`, `/chron`, `/clog`. All three resolve to the same handler in `UI/SlashCommand.lua`.

| Command                  | Effect                                                                              |
|--------------------------|-------------------------------------------------------------------------------------|
| `/chron`                 | Open options panel.                                                                 |
| `/chron help`            | Print command list.                                                                 |
| `/chron version`         | Print version + active serializer path + active server profile.                     |
| `/chron log [on\|off]`   | Toggle `LoggingCombat()`; with no arg, toggles the current state.                   |
| `/chron status`          | Print metrics: queue depth, chunks landed/lost, eager restores, last flush age.     |
| `/chron debug [on\|off]` | Toggle `config.debug`. Verbose logger output to chat.                               |
| `/chron probe`           | Dev: dump current `SPELL_FAILED_*` global values + show pending chunk if any.       |
| `/chron forceci`         | Dev: bypass dedup hash and re-enqueue our own CI right now.                         |
| `/chron inspect <name>`  | Force a one-shot `NotifyInspect()` on a raid/party member.                          |
| `/chron clearcache`      | Wipe inspect cache.                                                                 |
| `/chron minimap`         | Toggle minimap button visibility.                                                   |

Output uses `Core/Logger.lua` so colors stay consistent.

---

## 7. Debug tooling

Debugging a combat-log-smuggling addon is hard because half the bugs are silent: chunks vanish into C-side strings, taint propagates without warning, the engine truncates the field. Bake the introspection in from day one.

- **`Core/Logger.lua`** — `Logger.debug()` is a no-op unless `config.debug` is true. `info / warn / error` always print. Every print is prefixed `|cff4ec3ff[Chronicle]|r` (info), yellow (warn), red (error). Errors are also fed through `geterrorhandler()` so BugSack picks them up.
- **`Core/Metrics.lua`** — single in-memory counters table (`chunks_queued`, `chunks_landed`, `chunks_lost_ttl`, `chunks_re_applied`, `eager_restores`, `hijack_activations`, `relay_payload_bytes`, `taint_errors_suppressed`). Persisted on `PLAYER_LOGOUT`. Printed by `/chron status`.
- **`/chron probe`** — reads every `SPELL_FAILED_*` global, prints whether each currently holds a sentinel chunk or its original value, plus `H.pendingChunk` so we can see exactly what the engine is about to read.
- **Sentinel landing telemetry** — every confirmed landing logs at debug level: `chunk landed: snapshot=<id> seq=<n>/<m> failedType=<truncated>`.
- **Live in-game frame (`/chron dev`)** — small scrollable text frame that streams `Logger.debug` output, gated behind `config.debug`. Optional but invaluable in raid.
- **Round-trip test** — `Test/RoundTrip.lua` (loaded only when `config.debug` is true): build a CI, serialize, base64, chunk, then immediately parse it back through `Sentinel.parse` + `Serialize.deserialize` and assert deep equality. Smoke test for the whole pipeline without needing a fight.

---

## 8. Code conventions

- **Lua style:** 4-space indents (NOT tabs — `research/ChronicleCompanion/` mixes them, do not inherit that). LF line endings.
- **No new globals** except `Chronicle`, the two `*DB` SavedVariables, and the `SLASH_*` slots.
- **Locals up top; module-scope upvalues for hot paths.** The relay's `applyChunk` runs on every cast attempt — keep it allocation-free.
- **`pcall` every external call site** that runs from an event handler, with a `Logger.warn` on failure. We never crash the user's combat frame.
- **LDoc annotations on all public functions.** Use `--- @tparam`, `--- @treturn`, `--- @tparam[opt]` for optional params. Every function in `Chronicle.*` or a provider interface must have LDoc tags so IDEs can provide autocomplete and type hints.
- **Comments explain why, not what.** When something is non-obvious (taint, CLEU arg index, truncation cap, why we picked a specific TTL), drop a multi-line comment with the measurement or source. ALC's `Constants.lua` is the gold standard for this — match that tone.
- **Constants live in `Core/Constants.lua`, only.** A magic number in a module body is a bug.
- **No `string.format` in hot paths.** Precompute prefixes in `Constants.lua`; concat once.
- **3.3.5 API compatibility:** prefer `GetTalentInfo(tab, idx, false, false, activeGroup)`, `GetActiveTalentGroup()`, `GetInventoryItemLink`, `GetGlyphSocketInfo`. Do not assume retail-only APIs (`UnitGUID` exists on 3.3.5 — that is fine).

---

## 9. Working in this repo

- The TOC's interface version is `30300` (WotLK 3.3.5a). Do not bump it.
- **TOC file paths MUST use backslashes** (`Core\Namespace.lua`, not `Core/Namespace.lua`). WoW 3.3.5a on Windows silently ignores forward-slash paths.
- **TOC file MUST be ASCII with CRLF line endings.** No UTF-8 (em dashes, arrows, etc.) in the Notes or any other TOC field. The 3.3.5a client's TOC parser chokes on non-ASCII bytes.
- **Not every `ALL_CAPS_NAME` is an event.** Many WoW identifiers that look like events are actually `GlobalStrings.lua` format strings shown via `CHAT_MSG_SYSTEM` (e.g. `INSTANCE_RESET_SUCCESS = "%s has been reset."`, `ERR_*`, most `LFG_*`). Before wiring `Chronicle.RegisterEvent("FOO")`, confirm `FOO` appears in `research/Interface/FrameXML/` as an actual event handler (e.g. registered on a frame or named in `Events.xml`), not just as a localized string. When the signal is only a system chat line, pattern-match `CHAT_MSG_SYSTEM` against an escaped version of the global string (see `Providers/ResetProvider.lua` for the canonical pattern-build).
- **All Lua source files MUST be pure ASCII.** No UTF-8 characters in strings, comments, or anywhere else. WoW 3.3.5a's Lua 5.1 parser silently fails on non-ASCII bytes, causing the entire file to not load with no error message. Use ASCII substitutes: `--` for em dash, `->` for arrow, `>` for triangle bullet, `-` for en dash.
- **`DEFAULT_CHAT_FRAME` is nil at TOC load time.** Never call `DEFAULT_CHAT_FRAME:AddMessage()` at file scope. Use event handlers (`PLAYER_LOGIN`) for chat output, or guard with `if DEFAULT_CHAT_FRAME then`.
- `research/` is read-only reference. Never modify those files; never ship them in a release zip.
- When adding a module, also wire it into `ChronicleCompanionWoTLK.toc` load order (with backslash paths) and into `Init.lua`'s `safeStart` list.
- Run nothing in the addon directory that touches `WoWCombatLog.txt`, `WTF/`, or other game files; only edit addon source.
- Releases are produced as a flat zip of the addon directory only (no `research/`, no `.git`, no `AGENTS.md`).

---

## 10. North-star checklist

We are done with the core when:

1. `/chron log on` enables stock combat logging and our relay simultaneously.
2. Pulling a raid boss produces standard CLEU lines in `WoWCombatLog.txt` plus, scattered through `SPELL_CAST_FAILED` rows, sentinel chunks that round-trip through our local deserializer back into the original CI struct.
3. `/chron status` reports `chunks_landed > 0` and `chunks_lost / chunks_landed < 0.1` over a 5-minute pull.
4. No taint popup is visible to the user during normal raiding.
5. The `WoWCombatLog.txt` from step 2 can be parsed by `chronicleclassic.com`'s WoTLK demuxer (interface contract: sentinel prefix `[[CHRON_v1_`, base64 alphabet documented above, chunk header schema in section 3).
