# `dustless ram` — honest memory reporting

`dustless ram` shows what is actually in RAM and which processes are using it. It does not pretend that "free RAM" is the metric that matters.

## What the numbers mean

macOS is designed to keep as much memory occupied as possible. Free RAM is wasted RAM: the system caches files, compresses inactive pages, and leaves recently used data in memory so the next access is fast. Because of this, **"free RAM" on macOS is usually close to zero**. A tool that reports only free RAM and calls it "available" is lying to you.

`dustless ram` reports:

- **Total** — physical RAM installed.
- **Used** — active, wired, and compressed pages. These are genuinely in use; compressed pages were moved out of active RAM by the kernel but still belong to running processes.
- **Available** — an estimate of how much memory can be given to a new workload without forcing something else out. This is `total - used` in our simplified view; macOS itself reports a slightly different number that also accounts for immediately reclaimable caches.
- **Free** — pages that are genuinely unused right now. Expect this to be small.
- **Compressed** — memory the kernel has compressed to make room. This is part of "used" but can be decompressed on demand.
- **Swap** — memory moved to disk. Persistent swap use is a stronger signal of pressure than low free RAM.
- **Pressure** — read from the kernel's `vm.memory_pressure` sysctl, the same source the system uses to decide when to compress or swap. The percentage is the ratio of used to total physical memory.

The most useful single number is **memory pressure**. If it is `normal`, the system is fine regardless of how little "free" RAM appears. If it is `critical` and swap is rising, you have a real problem.

## When killing a process genuinely helps

Killing a process to free RAM is **usually theatre** on modern macOS.

- **Browsers** keep tabs in memory so switching back is instant. Killing a browser frees those pages, but the next time you open the browser it re-reads the same data from disk or the network, costing CPU, battery, and your time. The memory "saved" would have been reclaimed automatically if another app needed it.
- **Small background processes** (10–50 MB) are irrelevant. Killing them does not change the pressure picture.
- **Language servers and editors** hold project state in memory. Killing them forces a re-index, which is slower than letting macOS compress or page the data.

There is exactly one case where killing helps: **a runaway process consuming gigabytes** and not responding. Examples include a build tool with a memory leak, a test runner that spawned an unbounded number of workers, or a Electron app with a runaway renderer. In that case the process is using memory the kernel cannot reclaim because the process still owns it, and the process is not releasing it on demand. `dustless ram --kill <pid>` is designed for that case and nothing else.

## How `--kill` is designed

`dustless ram --kill <pid>` is **dry-run by default**. It will describe what it would do and how much resident memory the target holds, but it sends no signal unless you also pass `--confirm`.

- The first confirmed signal is always `SIGTERM`.
- `SIGKILL` requires a separate `--sigkill` flag. The tool does not escalate automatically.
- Critical processes (PID 1, `kernel_task`, `launchd`, `WindowServer`, the current process, Dustless itself, the parent shell, root-owned processes without `--force`) are refused.
- Processes below a small memory threshold are refused, because killing them would not meaningfully change pressure.
- After a confirmed signal, the tool reports the measured change in available memory. That change is often smaller than the target's resident memory, or zero, because macOS had other ways to reclaim the pages. That is honest output, not a bug.

## What `dustless ram` does not do

It does not "clean" or "optimise" RAM. It does not allocate and free memory to "defragment" anything. It does not restart services. It does not claim a speed improvement it cannot measure.
