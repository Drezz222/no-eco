# no-eco

A tiny Windows 11 background program that keeps the apps you choose — Chrome by default — out of **Efficiency mode** (the green leaf in Task Manager).

- **16 KB** native executable (ARM64 and x64), no window, no installer, no dependencies
- Reacts in **~0.15 s** on average (max ~0.27 s) when an app drops a process into Efficiency mode
- Costs **~0.15% of one CPU core** and **~1.4 MB** of memory

## Why

Since Windows 11 22H2, Chromium browsers put their own background processes into Efficiency mode (EcoQoS + Idle priority). It saves battery, but with many tabs open it can make tab switching, scrolling and background work noticeably sluggish — especially on ARM laptops like Snapdragon X, where throttled work is pushed onto slower cores.

Windows' own per-app setting (`powercfg /powerthrottling disable`) doesn't help here: it only stops *Windows* from throttling an app, not an app throttling *itself*. no-eco watches for that and switches it back off.

## How it differs from other fixes

| Approach | Limitation | no-eco |
|---|---|---|
| Chrome flag `--disable-features=UseEcoQoSForBackgroundProcess` | Only applies when Chrome is started from a shortcut you've edited — not when another app opens a link or from a shortcut you missed. Users report it no longer works reliably on some Windows 11 builds. | Works however the app was started, with no changes to the app |
| `powercfg /powerthrottling disable` | Stops Windows' throttling only; the leaf stays because the app requests it itself | Overrides the app's own request |
| Task Manager → right-click → Efficiency mode | Manual, one process at a time, lost as soon as the app re-applies it | Automatic and continuous |
| Process Lasso | Full process manager; polls every process on the system; the x64 build runs under emulation on ARM PCs | Watches only the programs you name; native ARM64 build |
| PowerShell scripts | Load the whole .NET runtime (~40–60 MB) and are slow to enumerate processes | ~1.4 MB, 16 KB on disk |
| — | Most fixes are Chrome-only | Any program: Chrome, Edge, Brave, Discord, Teams… |

Measured on the same Snapdragon X Plus laptop, same Chrome session (~50 Chrome processes):

| | CPU (share of one core) | Memory | Reaction time |
|---|---|---|---|
| Process Lasso (x64, emulated) | ~1.25% | ~31 MB | not measured |
| PowerShell script, 5 s interval | ~0.2% | ~36–59 MB | up to 5 s |
| **no-eco** | **~0.15%** | **~1.4 MB** | **~0.15 s avg, ~0.27 s max** |

## The trade-off

Efficiency mode exists to save battery. Turning it off for an app means its background tabs/processes run at full speed, so **expect shorter battery life** while that app is open. On mains power it's usually a pure win; on battery, decide for yourself.

## Install

1. Download `no-eco-arm64.exe` (Snapdragon / ARM PCs) or `no-eco-x64.exe` (Intel / AMD) from [Releases](../../releases), and put it somewhere permanent, e.g. `C:\Tools\no-eco.exe`.
2. Run it once to try it. Nothing appears — it runs in the background. The leaf should disappear from that app's processes in Task Manager.
3. To start it automatically at login, run in PowerShell (no admin needed):

   ```powershell
   Register-ScheduledTask -TaskName "no-eco" -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME) -Action (New-ScheduledTaskAction -Execute "C:\Tools\no-eco.exe") -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries)
   ```

   Add arguments with `-Argument "--exe msedge.exe --exe brave.exe"` on `New-ScheduledTaskAction`.

The executables are unsigned, so Windows SmartScreen may warn on first run. They're built from this source by GitHub Actions — see the build log and `SHA256SUMS.txt` on each release — or build them yourself (below).

## Usage

```
no-eco.exe [--exe NAME]... [--interval MS]
```

| Option | Default | |
|---|---|---|
| `--exe NAME` | `chrome.exe` | Program to keep out of Efficiency mode. Repeat for several. Matched by file name, case-insensitive. |
| `--interval MS` | `250` | How often to check, 50–10000 ms. Lower reacts faster; higher uses (even) less CPU. |

Examples:

```powershell
no-eco.exe                                         # Chrome
no-eco.exe --exe msedge.exe                        # Edge
no-eco.exe --exe chrome.exe --exe Discord.exe      # several programs
no-eco.exe --interval 1000                         # check once a second
```

Only one copy runs at a time; starting a second one exits immediately. To stop it: Task Manager → Details → `no-eco.exe` → End task. To remove autostart: `Unregister-ScheduledTask -TaskName "no-eco" -Confirm:$false`.

## How it works

Every interval it:

1. Lists running process IDs with `EnumProcesses` (~0.1 ms — a full Toolhelp snapshot costs ~4.5 ms, which made an earlier version use 10× more CPU).
2. Looks up the program name only for process IDs it hasn't seen before, and remembers the answer (non-matching IDs are re-checked every 10 s in case Windows reuses an ID).
3. For each matching process, through a handle kept open: if EcoQoS is on, turns it off with `SetProcessInformation(ProcessPowerThrottling)`; if the priority is Idle, sets it back to Normal.

It runs as your user, needs no admin rights, and can only affect processes you could change in Task Manager yourself.

## Build

Requires [Zig](https://ziglang.org) (used as a C cross-compiler; builds both architectures from any OS):

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1
```

Outputs `dist/no-eco-arm64.exe` and `dist/no-eco-x64.exe`.

## Test

An end-to-end test runs against a live program: it puts real processes into Efficiency mode and checks no-eco switches them back, how fast, and what it costs, then writes a report to `test-reports/`:

```powershell
powershell -ExecutionPolicy Bypass -File test\test-no-eco.ps1                       # Chrome
powershell -ExecutionPolicy Bypass -File test\test-no-eco.ps1 -Target msedge.exe    # another program
```

## License

[MIT](LICENSE)
