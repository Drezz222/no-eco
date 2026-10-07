# End-to-end test for no-eco.exe against a live, running program (Chrome by default).
# Puts real processes of that program into efficiency mode, then checks no-eco switches
# them back, how fast, and what it costs. Writes a report to test-reports\.
#
#   powershell -ExecutionPolicy Bypass -File test\test-no-eco.ps1 [-ExePath dist\no-eco-arm64.exe] [-Target chrome.exe]

param(
    [string]$ExePath,
    [string]$Target = 'chrome.exe'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $ExePath) {
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $ExePath = Join-Path $root "dist\no-eco-$arch.exe"
}
$ExePath = (Resolve-Path $ExePath).Path
$reportDir = Join-Path $root 'test-reports'
New-Item -ItemType Directory -Force $reportDir | Out-Null
$targetName = [IO.Path]::GetFileNameWithoutExtension($Target)

Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class EcoTest {
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint a, bool i, int pid);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll")] static extern bool SetPriorityClass(IntPtr h, uint c);
  [DllImport("kernel32.dll")] static extern uint GetPriorityClass(IntPtr h);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetProcessInformation(IntPtr h, int cls, ref S info, int size);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetProcessInformation(IntPtr h, int cls, ref S info, int size);
  [StructLayout(LayoutKind.Sequential)] struct S { public uint V; public uint C; public uint St; }
  public static IntPtr Open(int pid) { return OpenProcess(0x1000 | 0x0200, false, pid); }
  public static void MakeEco(IntPtr h) { S s = new S { V = 1, C = 1, St = 1 }; SetProcessInformation(h, 4, ref s, 12); SetPriorityClass(h, 0x40); }
  public static bool IsEco(IntPtr h) { S s = new S { V = 1 }; GetProcessInformation(h, 4, ref s, 12); return ((s.C & 1) != 0 && (s.St & 1) != 0) || GetPriorityClass(h) == 0x40; }
}
"@

$lines = @("no-eco end-to-end test - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", "exe: $ExePath", "target: $Target", "")
$fail = 0
function Check($name, $ok, $detail) {
    $script:lines += "{0}  {1}  ({2})" -f $(if ($ok) { 'PASS' } else { $script:fail++; 'FAIL' }), $name, $detail
}

$subjects = @(Get-Process $targetName -ErrorAction SilentlyContinue | Select-Object -First 5)
if (-not $subjects) { throw "$Target must be running." }
$handles = @($subjects | ForEach-Object { [EcoTest]::Open($_.Id) } | Where-Object { $_ -ne [IntPtr]::Zero })

# 1. Start a fresh no-eco for this test (any copy already running is stopped, then restarted at the end).
$wasRunning = Get-Process no-eco* -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Path
Get-Process no-eco* -ErrorAction SilentlyContinue | Stop-Process
Start-Sleep -Milliseconds 300
$prog = Start-Process $ExePath -ArgumentList '--exe', $Target -PassThru
Start-Sleep -Milliseconds 600
Check 'no-eco running' (-not $prog.HasExited) "pid $($prog.Id)"

# 2. Reaction time: put a process into efficiency mode, time until it's switched back.
$sw = New-Object Diagnostics.Stopwatch; $lat = @()
for ($i = 0; $i -lt 30; $i++) {
    $h = $handles[$i % $handles.Count]
    [EcoTest]::MakeEco($h); $sw.Restart()
    while ([EcoTest]::IsEco($h) -and $sw.ElapsedMilliseconds -lt 3000) { Start-Sleep -Milliseconds 5 }
    $lat += $sw.ElapsedMilliseconds
    Start-Sleep -Milliseconds (Get-Random -Minimum 30 -Maximum 300)
}
$sorted = $lat | Sort-Object
Check 'every process switched back out of efficiency mode' ($sorted[-1] -lt 3000) "30 trials"
Check 'reaction time under 500 ms' ($sorted[-1] -lt 500) ("median {0} ms, max {1} ms" -f $sorted[15], $sorted[-1])
foreach ($h in $handles) { [void][EcoTest]::CloseHandle($h) }

# 3. Only one copy can run.
$second = Start-Process $ExePath -PassThru; Start-Sleep 1
Check 'second copy exits immediately' $second.HasExited ''

# 4. Cost over 60 s.
$prog.Refresh(); $c1 = $prog.TotalProcessorTime.TotalMilliseconds; Start-Sleep -Seconds 60; $prog.Refresh()
$cpuPct = 100 * ($prog.TotalProcessorTime.TotalMilliseconds - $c1) / 60000
Check 'CPU under 0.5% of one core' ($cpuPct -lt 0.5) ("{0:N3}%" -f $cpuPct)
$privMB = $prog.PrivateMemorySize64 / 1MB
Check 'private memory under 5 MB' ($privMB -lt 5) ("{0:N1} MB" -f $privMB)

# 5. No target process left in efficiency mode.
$eco = 0; $total = 0
foreach ($p in Get-Process $targetName) {
    $h = [EcoTest]::Open($p.Id)
    if ($h -ne [IntPtr]::Zero) { $total++; if ([EcoTest]::IsEco($h)) { $eco++ }; [void][EcoTest]::CloseHandle($h) }
}
Check "no $Target process in efficiency mode" ($eco -eq 0) "$eco of $total"

# Restore whatever was running before the test.
Stop-Process -Id $prog.Id -ErrorAction SilentlyContinue
if ($wasRunning) { Start-Sleep -Milliseconds 300; Start-Process $wasRunning | Out-Null }

$lines += "", $(if ($fail) { "RESULT: $fail check(s) FAILED" } else { 'RESULT: all checks passed' })
$lines += "Re-run: powershell -ExecutionPolicy Bypass -File test\test-no-eco.ps1"
$report = Join-Path $reportDir ("no-eco-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$lines | Set-Content -Encoding utf8 $report
$lines
"Report: $report"
if ($fail) { exit 1 }
