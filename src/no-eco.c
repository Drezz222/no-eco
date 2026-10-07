// no-eco: keeps chosen programs out of Windows 11 "Efficiency mode".
//
// Apps like Chrome and Edge put their own background processes into EcoQoS +
// Idle priority. A powercfg exclusion can't override an app's own request, so
// this re-applies "off" every few hundred milliseconds.
//
// Cost per pass is kept tiny: EnumProcesses returns PIDs only (~0.1 ms, vs
// ~4.5 ms for a Toolhelp snapshot), each PID's exe name is looked up once and
// cached, and matching processes are checked through handles kept open.
//
// Usage: no-eco.exe [--exe NAME]... [--interval MS]
//   --exe NAME      program to keep out of efficiency mode (repeatable; default chrome.exe)
//   --interval MS   how often to check, 50-10000 ms (default 250)

#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>
#include <psapi.h>
#include <shellapi.h>
#include <wchar.h>

#define DEFAULT_INTERVAL_MS 250
#define FORGET_OTHERS_MS 10000   // re-check non-matching PIDs this often, in case a PID was reused
#define MAX_PIDS 4096
#define MAX_TARGETS 32

#ifndef PROCESS_POWER_THROTTLING_EXECUTION_SPEED
#define PROCESS_POWER_THROTTLING_EXECUTION_SPEED 0x1
#endif
#define PROCESS_POWER_THROTTLING_INFO_CLASS ((PROCESS_INFORMATION_CLASS)4)

typedef struct {
    ULONG Version;
    ULONG ControlMask;
    ULONG StateMask;
} PowerThrottlingState;

typedef struct {
    DWORD pid;
    HANDLE target;   // open handle if this PID is a target program, NULL otherwise
    BOOL seen;       // present in the latest EnumProcesses result
} Known;

static Known known[MAX_PIDS];
static int knownCount = 0;
static DWORD pids[MAX_PIDS];
static const WCHAR *targets[MAX_TARGETS];
static int targetCount = 0;

static void ForceEcoOff(HANDLE h) {
    PowerThrottlingState off = { 1, PROCESS_POWER_THROTTLING_EXECUTION_SPEED, 0 };
    SetProcessInformation(h, PROCESS_POWER_THROTTLING_INFO_CLASS, &off, sizeof off);
}

static void FixProcess(HANDLE h) {
    PowerThrottlingState s = { 1, 0, 0 };
    if (GetProcessInformation(h, PROCESS_POWER_THROTTLING_INFO_CLASS, &s, sizeof s) &&
        (s.ControlMask & PROCESS_POWER_THROTTLING_EXECUTION_SPEED) &&
        (s.StateMask & PROCESS_POWER_THROTTLING_EXECUTION_SPEED)) {
        ForceEcoOff(h);
    }
    // Task Manager's efficiency mode is EcoQoS plus Idle priority; undo both.
    if (GetPriorityClass(h) == IDLE_PRIORITY_CLASS) {
        SetPriorityClass(h, NORMAL_PRIORITY_CLASS);
    }
}

static BOOL IsTargetName(const WCHAR *name) {
    for (int i = 0; i < targetCount; i++)
        if (lstrcmpiW(name, targets[i]) == 0) return TRUE;
    return FALSE;
}

// Returns an open handle if pid runs one of the target programs, otherwise NULL.
static HANDLE OpenIfTarget(DWORD pid) {
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SET_INFORMATION | SYNCHRONIZE, FALSE, pid);
    if (!h) return NULL;   // other users' / protected processes: nothing we could change anyway
    WCHAR path[MAX_PATH];
    DWORD len = MAX_PATH;
    if (QueryFullProcessImageNameW(h, 0, path, &len)) {
        const WCHAR *name = path + len;
        while (name > path && name[-1] != L'\\') name--;
        if (IsTargetName(name)) return h;
    }
    CloseHandle(h);
    return NULL;
}

static Known *Find(DWORD pid) {
    for (int i = 0; i < knownCount; i++)
        if (known[i].pid == pid) return &known[i];
    return NULL;
}

static void Pass(BOOL forgetOthers) {
    DWORD bytes;
    if (!EnumProcesses(pids, sizeof pids, &bytes)) return;
    int n = (int)(bytes / sizeof(DWORD));

    for (int i = 0; i < knownCount; i++) known[i].seen = FALSE;

    for (int i = 0; i < n; i++) {
        DWORD pid = pids[i];
        if (pid == 0) continue;
        Known *k = Find(pid);

        // A PID can be reused after a process exits; re-identify it if our view is stale.
        if (k && k->target && WaitForSingleObject(k->target, 0) == WAIT_OBJECT_0) {
            CloseHandle(k->target);
            k->target = NULL;
            k->pid = 0;
            k = NULL;
        }
        if (k && !k->target && forgetOthers) {
            k->pid = 0;
            k = NULL;
        }
        if (!k) {
            if (knownCount == MAX_PIDS) continue;
            k = &known[knownCount++];
            k->pid = pid;
            k->target = OpenIfTarget(pid);
        }
        k->seen = TRUE;
        if (k->target) FixProcess(k->target);
    }

    // Drop entries for processes that have exited (and slots cleared above).
    for (int i = 0; i < knownCount; ) {
        if (!known[i].seen) {
            if (known[i].target) CloseHandle(known[i].target);
            known[i] = known[--knownCount];
        } else {
            i++;
        }
    }
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmdLine, int show) {
    (void)hInst; (void)hPrev; (void)cmdLine; (void)show;

    DWORD interval = DEFAULT_INTERVAL_MS;
    int argc;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    for (int i = 1; argv && i + 1 < argc; i++) {
        if (lstrcmpiW(argv[i], L"--exe") == 0 && targetCount < MAX_TARGETS) {
            targets[targetCount++] = argv[++i];
        } else if (lstrcmpiW(argv[i], L"--interval") == 0) {
            long ms = wcstol(argv[++i], NULL, 10);
            interval = (DWORD)(ms < 50 ? 50 : ms > 10000 ? 10000 : ms);
        }
    }
    if (targetCount == 0) targets[targetCount++] = L"chrome.exe";

    HANDLE mutex = CreateMutexW(NULL, FALSE, L"Local\\NoEco");
    if (GetLastError() == ERROR_ALREADY_EXISTS) return 0;

    // Keep this process itself out of efficiency mode so Windows doesn't stretch its timer.
    ForceEcoOff(GetCurrentProcess());

    DWORD forgetEvery = FORGET_OTHERS_MS / interval;
    if (forgetEvery == 0) forgetEvery = 1;
    for (DWORD pass = 0;; pass++) {
        Pass(pass % forgetEvery == 0);
        Sleep(interval);
    }
    (void)mutex;
}
