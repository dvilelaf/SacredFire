# The silent hang of 2026-10-15: the first thread dump (issue #2, hang side)

The freeze users hit (a race on 2026-10-14, the Bink intro video on 2026-10-15) leaves nothing in
the log: no fault, no `Guest event wait timed out`, no GPU watchdog line, no bad packet. The
frames simply stop while the last frame statistics read 60.0 FPS. To catch it, the run is now
watched from outside: `~/.local/bin/sacredfire-watch` (BB_SAVE_LOG=1 must be on, the launcher's
*Save the log and statistics to a file*) notices that no new line reaches `logs/<stamp>.frames.csv`
for 15 s, copies the CSV, `/proc/<pid>/maps`, the thread names and the process state aside, and
sends the port `SIGALRM`, which dumps every thread's RIP and rbp chain and exits 142.

## The capture

`~/.local/share/sacredfire/logs/20261015_170629.log` (the run) and
`logs/hang-20261015_170721/` (what the watcher saved). The game was launched from the AppImage at
17:06:29, `Octane/Octane_StartScreen` finished loading at 10.63 s, the Bink intro movie started
(`BinkRequestThread`, `BinkAsy0/1`, `RADSS Thread`, `Bink Snd`, `Bink IO`, an audio port opened)
and at **20.13 s of frames the flips stopped**, mid-frame, at a perfect 16.67 ms and 17 draws/frame
(the movie's quad). 15 s later the dump was taken: **76 of 81 threads reported**.

## What the dump says: nobody is running

| threads | where they wait |
|---|---|
| 11 | `sceKernelWaitEventFlag` (`wait_pattern`) — guest threads |
| 6 + 5 + 4 | `sceKernelWaitSema` (`wait_count`) — guest threads |
| 3 | the port's `cond_wait` (the main thread and two guest threads) |
| 2 | `sceKernelUsleep` (`kernel_usleep`/`platform_sleep_ns`) — guest threads |
| 8 | libbbgpu `Vulkan::DrawPreparation::WorkerLoop` (idle, the draw-prep pool) |
| ~10 | libbbgpu / libstdc++ threads of the port (recorders, upscaler/presenter paths, one in
`__libc_poll` of another library, one blocked on a mutex inside ImGui font baking, one in a raw
`syscall`) |

Every guest thread is parked in a PS4 primitive the port implements, and no port thread is making
progress: the guest stopped producing work and the pipeline ran dry. The main thread (tid 195104)
is in `cond_wait` from guest `+0x14d433a`, which the port's own diagnostics name
**`igStreamingChunkManager thread`** — the game's streaming thread.

## The guard fired right up to the freeze

`Late label guarded: ... the write is dropped` (bbport_clobber.cpp `GuardLabel`) ran at least 500
times in that 20 s run, almost always on the same two addresses (`0x10fd1004b8`, `0x10fc9004c0`,
the fences at `+0x4c0` inside the game's two alternating command buffers, which is where
12-clobbered-dword-handoff.md says the game keeps its fence labels). The last printed one is
submission 2752, and the last `Guest write check` before the STOP is submission 3046 — i.e. the
drops were happening at the freeze. STATUS.md's clobber entry already records the matching
symptom: *"Dropping the rest of the buffer froze the game on the fence behind it"*.

That is a correlation, not yet the cause: the same drops are routine in runs that play a whole
race. What the dump cannot say — and the reason for the next step — is *which* signal is missing.

## How to read one of these dumps

* The port's own dump prints `rip`, `rip - guest_image` (image-relative: game code when it is below
  the image size, 46,065,261 bytes) and `rip - exe_base` (host-relative: the port's executable when
  it is small). For the executable the useful address is the **raw RIP** (its vaddrs start at
  0x400000), so `addr2line -f -C -e <bin>/sacredfire 0x42b92b` gives `host_start`.
* For a shared library, first find its base. The port prints `lib.so+offset` in its fault stacks;
  a base is right when **every** frame credited to that library lands in its `R E` LOAD segment.
  In this run libc sat at 0x7a0150c00000, libstdc++ at 0x7a0150800000 and libbbgpu.so at
  0x7a0151400000 (a first guess of 0x7a0151100000 was wrong: it put several frames in the
  read-only segment). The watcher now saves `/proc/<pid>/maps`, which removes the guesswork.
* Validation: at the right base, `addr2line -e libbbgpu.so 0x245bda` returns
  `Vulkan::Rasterizer::RunDrawPacket`, exactly what the port's own stack traces printed.
* `logs/dump-analyze.py` does the grouping and symbolising (edit its LOG and base table).

## Next step

A dump that names the missing signal: at the dump, print for each waiting thread the primitive and
its object — event flag id, the pattern it waits for and the flag's current bits; semaphore id and
count — plus the guest thread name the runtime already knows (it prints them at creation). With
that, one more freeze says whether the game is waiting on a fence whose label write was dropped, on
a semaphore a stuck thread never signals, or on something else entirely.
