# Havoc Anti-Cheat

Adonis Anti Cheat toolkit (the **paid AC product** — not the Adonis admin panel).
Research notes + two live-validated tools, extracted from
[`havoc-hub`](https://github.com/Randeyeuhm/havoc-hub) with full history.
Target environment: Roblox + Volt executor (Windows).

## The AC model (short version)

- hidden instance tree: `"" > Client > Core > Anti` (ModuleScript); a scan loop
  runs every ~5s **client-side**
- frozen registry of detectors: `indexInstance`, `newindexInstance`,
  `namecallInstance`, `indexEnum`, `namecallEnum`, `eqEnum` — each re-baselines
  once, then compares later ticks; any deviation → "Detected" packet → kick /
  disconnect / crash escalations
- per-tick battery beyond the registry: anti-kick method probes, vanilla
  error-text probes (`FireServer`/`InvokeServer`), `GetRealPhysicsFPS` dot-call
- freeze trap: if a reporter runs in a `getgenv` environment it wipes
  workspace/players/ReplicatedStorage and freezes the client

## Components

| file | what it does |
|---|---|
| `adonis_kill.luau` | zombifies every detector closure in the registry (`hookfunction` → `return false`). Live-verified 6/6 hooked, auto-rediscovery (module reload safe), no tamper paths (noops never throw, never touched by the AC's self-checks) |
| `stealth_spy.luau` | companion approach: blanks the detector baselines (data-only writes, `table.clear` because the registry is frozen) + installs the native spy. Self-check `SPY.status()`, clean restore `SPY.stop()` |

## House rules (learned the hard way)

- **never** call AC internals (`checkStack`, detector functions) from your own
  thread — it captures your stack as the baseline and false-positives you on the
  next scan
- **never** hook `FireServer` / `InvokeServer` *methods*, `GetLogHistory`,
  `GetRealPhysicsFPS`, or `Player:Kick` — the per-tick battery probes exactly those
- namecall / metamethod hooks are safe **once the registry detectors are zombified**
- frozen tables: blind via `table.clear` / pairs-loop; direct assignment throws
  and a swallowed pcall makes it a silent no-op (kick candidate)
- validate by **surviving scan periods** (~15-20s+), never by invoking detector
  functions to "test" them

## Integration

`havoc-hub`'s bridge (`v2.4+`) auto-detects Adonis at boot and every 20s and arms
the bypass itself. These standalone tools share the same state table
(`HAVOC_AC_STATE`), so either path keeps the other consistent.
