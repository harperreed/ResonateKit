Absolutely. Here’s a sharp, GitHub-ready issue set that explains why the Swift player isn’t working yet and what to fix—framed against the working Go path.

---

## 1) Codec negotiation advertises Opus/FLAC but decoders are unimplemented (hard crash / no audio)

**Symptom**
Server negotiates Opus/FLAC; Swift tries to decode, but the decoder is a stub with a `fatalError` (or equivalent “not yet implemented”), so playback never starts.

**Evidence**
Swift docs explicitly say **PCM only is supported now**; do **not** advertise Opus/FLAC. 
Swift `AudioDecoder` factory: Opus/FLAC branches are “TODO / fatal,” only PCM returns a real decoder. 
Meanwhile the CLI README claims “Supports PCM, Opus, and FLAC,” which misleads and causes bad negotiation. 

**Impact**
Negotiating Opus/FLAC yields decoding failure → silence or crash.

**Fix**
Until Opus/FLAC are implemented, **only advertise PCM** in `ClientHello`. (Matches your Go flow where negotiated formats match actual decoders.) 

---

## 2) Audio chunk **binary type** mismatch with server (Swift expects wrong type)

**Symptom**
Swift’s `BinaryMessageType` treats **audio = 0**, but the bring-up notes say **CRITICAL**: audio chunks are **type 1** in the current server. This yields “unknown/ignored messages,” no audio path.

**Evidence**
Swift binary enum defines `.audioChunk = 0`. 
Bring-up doc: “CRITICAL: server uses message type **1** for audio chunks. Corrected from earlier implementation using type **0**.” 
Go client currently routes **type 0** as audio (historic behavior), which is why Go “just works” with your server variant. 

**Impact**
Swift ignores/ mishandles incoming audio frames → silence.

**Fix**
Align Swift to the server you’re actually talking to. If the server is on “type 1,” change Swift’s `.audioChunk` discriminator to `1` (and keep artwork/visualizer lanes in sync). If the server is still on “type 0” like the Go client path, keep Swift at 0. (One source of truth, please.)

---

## 3) No timestamp-based playout before scheduler integration (plays on arrival → drift & drops)

**Symptom**
Swift initially played chunks on arrival without honoring server timestamps, causing drift/jitter. The design doc spells this out.

**Evidence**
Design: current flow is **broken**—no scheduling; must insert `AudioScheduler`. 

**Impact**
On a real network, audio stutters or desyncs vs. the Go player (which uses a timestamp-ordered scheduler). The Go scheduler does a 10 ms tick, ±50 ms window, and drops late frames. 

**Fix**
Keep the new `AudioScheduler` path: **WebSocket → Decode → Scheduler → Player** with 10 ms tick and ±50 ms window, mirroring Go. 

---

## 4) Clock sync **time base** mismatch vs server’s `loop.time()` (monotonic) → “always late” frames

**Symptom**
Server timestamps chunks using its **monotonic event-loop clock** and checks “late” against that same base. If the client converts to local Unix or a different monotonic origin, packets look late and get dropped.

**Evidence**
Server timestamps + lateness checks are all in `loop.time()`; this is the root cause of “Audio chunk should have played already.” 

**Impact**
Even “synced” clients look late; Swift thinks it’s fine, server thinks it’s not. Go solved this by matching server loop-origin math. 

**Fix**
Have Swift’s `ClockSynchronizer` compute and use **server loop origin** (when the server’s clock would be zero) and **express client timestamps in that same domain**—exactly like the Go workaround described. (Your Swift sync now does NTP-style + drift; add loop-origin derivation from the first good sample.) 

---

## 5) Wrong mapping of server timestamp → CoreAudio host time (AudioQueue)

**Symptom**
Swift sets `AudioTimeStamp.mHostTime = serverTimestamp * 1000` (μs→ns) directly. But `mHostTime` uses **mach absolute time** units, not nanoseconds, and must be converted with `AudioGetCurrentHostTime` or `mach_timebase_info`. Feeding raw μs yields buffers scheduled at nonsense times.

**Evidence**
The AudioQueue path shows `mHostTime` constructed straight from server μs, which is not CoreAudio host-time space. 

**Impact**
“Scheduled” buffers miss their slot—either immediate or super late.

**Fix**
Convert server timestamp → **local host time** properly:

1. server μs → **local absolute nanoseconds** (after time-base conversion per Issue #4),
2. convert to **mach absolute (host) ticks** via `AudioConvertHostTimeFromNanos` or `mach_absolute_time` + `mach_timebase_info`. Then set `mHostTime`.

---

## 6) Enqueue-on-arrival path still present (race with scheduler)

**Symptom**
`AudioPlayer` had (or still has) an old “enqueue chunk now” API; that path can bypass scheduling.

**Evidence**
Design calls it out: remove `enqueue(chunk:)`; use `playPCM(_:)` fed by the `AudioScheduler`. 

**Impact**
Two paths into playback = timing bugs and hard-to-reproduce stutter.

**Fix**
Delete or hard-deprecate direct enqueue. Keep **only** the scheduler → `playPCM()` path. 

---

## 7) AsyncStream lifecycle & task leaks (scheduler “dies” after first stream)

**Symptom**
If the scheduler’s `AsyncStream` is `finish()`ed during `stop()`, later streams won’t receive chunks; also background tasks weren’t cancelled on disconnect.

**Evidence**
Comparison doc lists “CRITICAL” bug: stream finished early and zombie tasks leaked; fixed by separating `stop()`/`finish()` and cancelling tasks. 

**Impact**
First stream may work; subsequent connects are silent or degraded.

**Fix**
Ensure the current tree (with `stop` vs `finish` and tracked tasks) is in your build; verify all scheduler/telemetry tasks are stored & cancelled on disconnect. 

---

## 8) Buffering/backpressure missing or mis-placed (over/underruns)

**Symptom**
Without capacity tracking and pruning, you either flood the player or underrun.

**Evidence**
Swift has `BufferManager`, but it only helps if you schedule *before* playback and prune by playback time. The design covers target buffer (≈150 ms), ±50 ms window, and 10 ms tick—matching Go. 

**Impact**
Stutter under jitter; weird “bursts and gaps.”

**Fix**
Keep `BufferManager` wired into the scheduler’s timing (received → scheduled → played → prune). Aim for ~120–200 ms steady buffer like Go. 

---

## 9) Discovery & transport divergence (two different stacks)

**Symptom**
Examples pin Starscream; library code uses `URLSessionWebSocketTask`; discovery via `NWBrowser` exists but may not be plugged into the CLI. Easy to connect to wrong URL/path (`/resonate`) or wrong server.

**Evidence**
Swift discovery produces `ws://host:port/resonate`. Ensure the CLI uses it, not a raw host string. 

**Impact**
You connect, but not to the right path or not to the server that’s actually streaming.

**Fix**
Single transport, single discovery—for the example app, wire `ServerDiscovery` → select server → `ResonateClient.connect(url)` with the **resolved** ws URL (including `/resonate`). 

---

## 10) Docs inconsistency leads to mis-configuration (engineers turn on wrong features)

**Symptom**
One doc says “Swift is production-ready and fixed 3 bugs”, while the bring-up says “PCM only” and scheduler was just added. This misleads devs to enable Opus/FLAC or skip scheduler.

**Evidence**
“Go vs Swift Comparison” claims “ready for production” while bring-up flags PCM-only + scheduler changes.  and 

**Impact**
Confused configuration → silent player.

**Fix**
Make a single **Source of Truth** checklist in the repo root (README) that matches current code reality:

* ✅ PCM only,
* ✅ Scheduler required,
* ✅ Binary type value (1 or 0) that matches **your** server,
* ✅ Clock sync uses **server loop origin**.

---

# Quick “Do-This-Now” patch list

1. **Advertise PCM only** in `ClientHello` until decoders land. 
2. **Set audio binary type** to match the running server (very likely `1`). 
3. **Add server loop-origin** to ClockSynchronizer (mirror Go’s fix). 
4. **Convert server μs → CoreAudio host time** correctly before `AudioQueueEnqueue…`. 
5. **Route EVERYTHING through the AudioScheduler**; remove direct enqueue paths. 
6. **Ensure AsyncStream tasks are tracked & cancelled**; don’t `finish()` on mere pause. 
7. **Make the example app** use `ServerDiscovery` to produce a ws URL with `/resonate`. 

---

If you want, I can turn this into individual GitHub issues with titles, repro steps, expected/actual, and code-pointer links. The Go side is clean; the Swift side just needs these shims so it speaks the same timebase, binary type, and scheduling contract as the server.  

