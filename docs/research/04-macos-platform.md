# macOS platform facts for Airbag — research note 04

Date: 2026-10-17. Scope: the macOS engineering substrate for Airbag's two binaries (the `airbag` hook/CLI and the menu bar app): libproc and the process table, ancestry walking, FSEvents, IOPM assertions, the app shell (LSUIElement, SMAppService, MenuBarExtra, Settings, activation), building/signing/notarizing a `.app` from SwiftPM with Command Line Tools only, CLI↔app IPC, SQLite with two writers, the `/usr/bin/git` shim, signals, and the test toolchain.

Method: every "measured" or "verified by probe" statement comes from small SwiftPM packages written to the session scratchpad, built with `swift build -c release` (Apple Swift 6.1.2, CLT 16.4, SDK macOS 15.5) and run on this machine: macOS 15.7.9 (24G830), Apple M4, 16 GB, Claude Desktop hosting Claude Code 2.1.295. Probes were deleted after the run. Header facts were read from the CLT SDK at `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` (primary source, cited by header path). Web sources were fetched 2026-10-17 unless noted.

Tags: [verified] = read in the primary source or observed locally today; [likely] = secondary source or strong inference; [unverified] = not confirmed.

## TL;DR

1. libproc is cheap enough for a 1–2 s radar poll: a full listening-socket scan (436 pids, 4173 fds, 399 sockets, 20 listeners) takes 0.8–1.1 ms median; `lsof -nP -iTCP -sTCP:LISTEN` takes 20 ms [measured]. `proc_pidinfo` works only for same-uid processes (EPERM for root and other users, confirmed outside the tool sandbox); `sysctl KERN_PROC_ALL` sees every process (397 in 0.07 ms) and is the only way to see zombies and other users' ppid/pgid [verified].
2. The ancestry chain from a hook process is walkable with `PROC_PIDTBSDINFO.pbi_ppid` and ends at the agent executable; under Claude Desktop it is `hook → zsh → claude.app/Contents/MacOS/claude → disclaimer → Claude.app → launchd`. `sh -c "cmd"` exec-optimizes away the shell; `/bin/sh` re-execs as `/bin/bash` when it stays [verified].
3. FSEvents with `FileEvents|NoDefer|WatchRoot` on a dispatch queue delivers the first event in 0.3–12 ms, coalesces 200 appends into 1–2 events, honours at most 8 exclusion paths (9 → `false`), reports editor atomic saves as `Renamed` on the final path, delivers `RootChanged` with event id 0, and replays history from a stored `sinceWhen` ending in `HistoryDone` — replay is one coalesced record per path and not in event-id order, and flag sets are cumulative per path, so never match exact flag combinations [verified, re-probed].
4. `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep)` works unprivileged, shows the process name and reason in `pmset -g assertions`, supports a timeout; it cannot stop lid-close or menu sleep [verified/Apple QA1340].
5. A `MenuBarExtra(.window)` app built with SwiftPM, `LSUIElement=true`, idles at 14 MB physical footprint, 0.0% CPU, 4 threads, and does not instantiate the popover content until first click (no `onAppear`, no `.task` ticks) [measured]. Known gaps: no API to open/close it or reach the `NSStatusItem`; agent-app sheets/alerts lost input on 14.0; `SettingsLink`/`openSettings` need an activation-policy dance in menu bar apps [verified sources].
6. CLT-only toolchain reality: `swift build` works, `.lproj/Localizable.strings` works, `.xcstrings` silently does not (compiles, returns the key at runtime), `Bundle.module` does not find the resource bundle inside a `.app` (own accessor needed), `--arch arm64 --arch x86_64` fails (needs xcbuild) but `--triple x86_64-apple-macosx14.0` + `lipo` works, XCTest is absent (`no such module 'XCTest'`), Swift Testing works, `notarytool`/`stapler`/`codesign`/`iconutil` are present [verified].
7. Ad-hoc hardened-runtime signing of the SwiftPM output succeeds (`flags=0x10002(adhoc,runtime)`, `--verify --strict --deep` passes, `spctl` rejects); real distribution needs a Developer ID Application certificate (Apple Developer Program Account Holder), `--options runtime --timestamp`, notarization and stapling; macOS Sequoia removed the Control-click Gatekeeper bypass, and Homebrew 7 has no `--no-quarantine` flag any more [verified].
8. IPC: a Unix domain socket in a 0700 directory is the right CLI↔app channel: POSIX round trip 4 µs, `NWConnection(.unix)` 18 µs, `LOCAL_PEERPID`/`LOCAL_PEERCRED` give the hook's pid/uid for free; `NWListener` creates the socket file 0755, so the directory must carry the permission. XPC needs a launchd Mach service (`MachServices` plist key) and is only worth it if the app becomes an SMAppService launch agent [verified].
9. System SQLite 3.43.2 (THREADSAFE=2, FTS5, WAL autocheckpoint 1000) with `journal_mode=WAL`, `busy_timeout`, `BEGIN IMMEDIATE`: two processes doing 2000 single-row transactions each saw 0 `SQLITE_BUSY` and a 27 ms worst wait; a concurrent reader did 725k reads with 0 BUSY [measured]. CLI open+insert+close costs ~3 ms per invocation.
10. `/usr/bin/git` is a 118 KB libxcselect shim; `xcode-select -p` honours a bogus `DEVELOPER_DIR` without validating it, so detect CLT by checking `<dir>/usr/bin/git` exists (or the `com.apple.pkg.CLTools_Executables` receipt) and never exec the shim when it does not, or the install dialog pops [verified/likely].

## 1. libproc and the process table

### 1.1 API surface (header-verified)

Source: `MacOSX.sdk/usr/include/libproc.h` and `sys/proc_info.h` [verified].

| Call / flavor | Returns | Notes |
| --- | --- | --- |
| `proc_listallpids(buf, bytes)` | number of `pid_t` entries written (count, not bytes, on this OS); with `nil,0` an upper bound | Probe: `nil` → 456, fill → 437 with 436 non-zero entries + one `0` for kernel_task. Allocate `bound + slack` entries and count non-zero entries rather than trusting the arithmetic; `libproc.h` only documents `proc_listpidspath` as "number of bytes" [verified by probe]. |
| `proc_pidinfo(pid, PROC_PIDTBSDINFO=3, 0, &proc_bsdinfo, size)` | `pbi_status`, `pbi_ppid`, `pbi_uid`, `pbi_pgid`, `pbi_comm[16]`, `pbi_name[32]`, `e_tdev` (controlling tty, `0xFFFFFFFF` = none), `pbi_start_tvsec/usec` | Same-uid only (EPERM otherwise). |
| `proc_pidinfo(pid, PROC_PIDTASKINFO=4, …)` | `pti_virtual_size`, `pti_resident_size` (bytes), `pti_total_user/system` (Mach absolute time), `pti_threadnum` | Same-uid only. |
| `proc_pid_rusage(pid, RUSAGE_INFO_V4, &rusage_info_v4)` | `ri_phys_footprint`, `ri_user_time`, `ri_system_time`, … (V6 is current) | Same-uid only. `ri_phys_footprint` is the Activity Monitor "Memory" number. |
| `proc_pidpath(pid, buf, 4*MAXPATHLEN)` | executable path | Works for other users' processes too (`/sbin/launchd` for pid 1). `PROC_PIDPATHINFO_MAXSIZE` is not imported into Swift; use `4 * Int(MAXPATHLEN)`. |
| `proc_pidinfo(pid, PROC_PIDVNODEPATHINFO=9, …)` | `pvi_cdir.vip_path` = current working directory | Same-uid only. This is the project-attribution signal for the radar. |
| `proc_pidinfo(pid, PROC_PIDLISTFDS=1, …)` then `proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO=3, &socket_fdinfo, size)` | per-fd `socket_info`: `soi_kind == SOCKINFO_TCP`, `soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN (1)`, `tcpsi_ini.insi_lport`, `insi_vflag & INI_IPV6 (0x2)`, `insi_laddr` | Same-uid only. |
| `proc_listchildpids(ppid, …)`, `proc_listpgrppids(pgid, …)` | pids | Available since 10.7; handy for descendant kills. |

Process status constants (`sys/proc.h`): `SIDL 1, SRUN 2, SSLEEP 3, SSTOP 4, SZOMB 5` [verified].

Mach time units: `pti_total_user`, `ri_user_time` are Mach absolute time; on this M4 `mach_timebase_info` is 125/3, so ns = v × 125 / 3. Convert before showing CPU time [verified by probe].

Memory numbers for the same probe process: `pti_resident_size` 2400 KB vs `ri_phys_footprint` 1424 KB. For the ~100 MB budget, measure `phys_footprint` (also what `footprint(1)` and Activity Monitor show), not RSS [verified].

### 1.2 Permission limits (same results inside and outside the Claude Code tool sandbox) [verified]

```
pid 1 (launchd, uid 0) from uid 501:
   PROC_PIDTBSDINFO        fail errno=1 (EPERM)
   PROC_PIDTASKINFO        fail errno=1
   proc_pidpath            /sbin/launchd          <- works
   PROC_PIDVNODEPATHINFO   fail errno=1
   proc_pid_rusage         fail errno=1
   PROC_PIDLISTFDS         fail errno=1 (Operation not permitted)
```

Consequences:
- Of 436 pids, 275 were same-uid and fully inspectable; 161 (root, `_windowserver`, etc.) are invisible to `proc_pidinfo`. Independent re-probe (C, 2026-10-17): pid 1, a root daemon (`mobileactivationd`) and non-root other-uid processes (`mdworker_shared` uid 89, `ANEStorageMaintainer` uid 296) all return `EPERM` for `PROC_PIDTBSDINFO`/`TASKINFO`/`VNODEPATHINFO`/`LISTFDS` and `proc_pid_rusage`, while `proc_pidpath` succeeds for every one of them [verified]. That is fine for the radar: dev servers run as the user. Homebrew services, Docker Desktop's VM helper, Lima/colima (`limactl` showed up as a same-uid listener on `:::53` and `127.0.0.1:60856`) are all user processes.
- To walk an ancestry chain past a root-owned process (only launchd in practice), or to build a complete tree, use `sysctl({CTL_KERN, KERN_PROC, KERN_PROC_ALL})`: 397 `kinfo_proc` records (648 bytes each) in 0.07 ms median, including `e_ppid`, `e_pgid`, `e_ucred.cr_uid`, `p_stat`, `p_starttime`, `p_comm`, `e_tdev` for every process [verified]. This is also the only unprivileged way to detect zombies (`p_stat == 5`).
- Zombies: after `SIGKILL` of a child that nobody has `waitpid`'ed yet, `proc_listallpids` still lists it and `kill(pid, 0)` returns 0, but `proc_pidinfo` and `proc_pidpath` fail with `ESRCH`; `sysctl` shows `p_stat=5` [verified]. Treat `ESRCH` from `proc_pidinfo` as "gone", never `kill(pid,0)==0` as "alive".

### 1.3 Listening TCP sockets, IPv6 and port endianness [verified by probe]

`insi_lport` is an `int` that carries the 16-bit port in network byte order; convert with `UInt16(bigEndian: UInt16(truncatingIfNeeded: insi_lport))`. Observed raw/converted pairs: 47115 → 3000, 13568 → 53, 40719 → 3999, 14357 → 5432, 60184 → 6379. `insi_vflag & INI_IPV6` selects `insi_laddr.ina_6` (`in6_addr`) vs `insi_laddr.ina_46.i46a_addr4` (`in_addr`); `inet_ntop` prints them.

Dual-stack reality: ControlCenter (AirPlay receiver) listens on `0.0.0.0:5000` and `:::5000` as two sockets; `limactl` listens only on `:::53` (an IPv6 any-socket that also accepts IPv4 unless `IPV6_V6ONLY`). The radar should group by `(pid, port)` and show the address family as a detail.

Copy-pasteable core (Swift 5 mode; wrap the globals in an actor for Swift 6):

```swift
import Darwin

struct Listener { let pid: pid_t; let fd: Int32; let port: UInt16; let v6: Bool; let addr: String }

func listeners(of pid: pid_t) -> [Listener] {
    let need = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard need > 0 else { return [] }                       // EPERM for other users, ESRCH for zombies
    let stride = MemoryLayout<proc_fdinfo>.size
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(need) / stride + 32)
    let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
    guard got > 0 else { return [] }
    var out: [Listener] = []
    for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
        var si = socket_fdinfo(); let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, size) == size,
              si.psi.soi_kind == SOCKINFO_TCP else { continue }
        let tcp = si.psi.soi_proto.pri_tcp
        guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
        var ins = tcp.tcpsi_ini
        let v6 = (ins.insi_vflag & UInt8(INI_IPV6)) != 0
        let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: ins.insi_lport))
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if v6 { inet_ntop(AF_INET6, &ins.insi_laddr.ina_6, &buf, socklen_t(buf.count)) }
        else  { inet_ntop(AF_INET,  &ins.insi_laddr.ina_46.i46a_addr4, &buf, socklen_t(buf.count)) }
        out.append(Listener(pid: pid, fd: fd.proc_fd, port: port, v6: v6, addr: String(cString: buf)))
    }
    return out
}
```

### 1.4 Cost per full scan (this machine, Apple M4, release build, 5 iterations each) [measured]

| Scan | pids | visited (same uid) | fds | sockets | listeners | median | notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| all pids: BSDINFO + LISTFDS + FDSOCKETINFO | 436 | 275 | 4173 | 399 | 20 | 1.1 ms (sandboxed) / 0.8 ms (unsandboxed) | min 0.7, max 1.4 |
| same + PROC_PIDTASKINFO per pid | 436 | 275 | 4173 | 399 | 20 | 1.2 ms / 0.9 ms | RAM/CPU columns are ~free |
| BSDINFO only, all pids | 436 | — | — | — | — | 0.17–0.24 ms | tree/ancestry refresh |
| `sysctl KERN_PROC_ALL` | 397 | all | — | — | — | 0.07 ms | one syscall, all users |
| `lsof -nP -iTCP -sTCP:LISTEN` | | | | | 20 | 20 ms wall | spawns a process |
| `netstat -anv -p tcp` | | | | | 22 lines | < 5 ms wall | spawns a process; `pcblist_n` sysctl underneath, pid is "last pid" |
| whole `procprobe scan` process (10 runs incl. Foundation load, 21 scans) | | | | | | 20 ms per run | CLI startup ≈ 4 ms (`walk`, 10 runs = 40 ms) |

Independent re-measurement (separate C probe, `clang -O2`, 7 iterations, busier machine): 632 pids / 377 same-uid / 4990 fds / 394 sockets / 20 listeners → 1.39 ms median (0.86–1.71 ms); `sysctl KERN_PROC_ALL` 0.079 ms median; `lsof -nP -iTCP -sTCP:LISTEN` 36 ms wall. The absolute numbers scale with the process/fd count; budget 1–2 ms per full scan, not 0.8 ms [verified].

At a 2 s poll the radar costs ≈ 0.05 % of one core; even 500 ms polling stays under 0.2 % [measured + arithmetic]. Rather than polling at all, use the hook events (PreToolUse/PostToolUse) to trigger a rescan and poll slowly (5–10 s) in between.

Observed listeners (excerpt, this machine) show the attribution data the radar gets for free from `cwd`:

```
 70386 node     127.0.0.1:3999  cwd=/Users/…/qost/web/.next/standalone
 63044 ssh      0.0.0.0:3000    cwd=/Users/…/qost           (port forward, not a dev server)
 63012 limactl  :::53           cwd=/Users/…/qost
   616 ControlCenter 0.0.0.0:5000 + :::5000  cwd=/        (AirPlay receiver: the classic port-5000 conflict)
```

### 1.5 PID reuse guard

`pbi_start_tvsec` (or `kinfo_proc.kp_proc.p_starttime`) plus pid identifies a process instance; Claude Code's own registry stores the same pair as `pid` + `procStart` in `~/.claude/sessions/<pid>.json` (see note 01). Store `(pid, start)` for every process Airbag attributes to a session and re-validate before `kill` [verified header + note 01].

## 2. Walking the ancestry chain from a hook to the agent

Probe `walk` from inside the Claude Code Bash tool (Claude Desktop 2.31226.1 hosting Claude Code 2.1.295) [verified]:

```
pid=86259 ppid=86201 pgid=86201 uid=501 tty=- comm=procprobe  path=…/procprobe
pid=86201 ppid=11328 pgid=86201 uid=501 tty=- comm=zsh        path=/bin/zsh
pid=11328 ppid=11327 pgid=11327 uid=501 tty=- comm=claude     path=/Users/…/Library/Application Support/Claude/claude-code/2.1.295/9d6405864fdc/claude.app/Contents/MacOS/claude
pid=11327 ppid=94586 pgid=11327 uid=501 tty=- comm=disclaimer path=/Applications/Claude.app/Contents/Helpers/disclaimer
pid=94586 ppid=1     pgid=94586 uid=501 tty=- comm=Claude     path=/Applications/Claude.app/Contents/MacOS/Claude
pid 1: bsdinfo failed errno=1 (EPERM)  -> stop at ppid==1 or use sysctl for the last hop
```

Spawn test (`procprobe spawn` runs `sh -c "<self> walk"` and `sh -c "<self> walk; true"`) [verified]:
- `sh -c "<single command>"`: the shell exec-optimizes; the child's parent is the spawner directly (no `sh` in the chain).
- `sh -c "<cmd>; true"`: a shell stays, and it shows up as `comm=bash path=/bin/bash` because macOS `/bin/sh` re-executes `/bin/bash` (controlled by `/private/var/select/sh` → `/bin/bash`). Re-probed: `pbi_comm`, `pbi_name` and `proc_pidpath` report `bash`/`/bin/bash` and `$BASH_VERSION` is `3.2.57(1)-release`, but `ps -o comm` prints the argv[0] `sh` (`ps -o ucomm` prints `bash`), so tools that read argv see `sh` while libproc sees `bash` [verified]. Do not pattern-match on `sh`; match on the agent, not on the shell.

Algorithm for the `airbag` hook binary:
1. `pid = getppid()`; loop: `PROC_PIDTBSDINFO` → record `(pid, name, path, start, pgid, e_tdev)`; stop when `pbi_ppid <= 1`, EPERM, or depth 32.
2. The agent is the first ancestor whose `proc_pidpath` matches a known pattern: `…/claude.app/Contents/MacOS/claude` or basename `claude` (Claude Code), `codex`, `node` whose argv (via `sysctl KERN_PROCARGS2`, same-uid only, see note 01) contains `claude`/`codex`/`cursor-agent`/`gemini`, `Cursor Helper`, etc. Prefer the environment: Claude Code exports `CLAUDE_PID` and `CLAUDE_CODE_SESSION_ID` to hooks and tool children (note 01, verified there); the walk is the fallback and the cross-check.
3. The terminal is the first ancestor that is a GUI app bundle (`/Applications/*.app/Contents/MacOS/*`): `Claude.app`, `Terminal`, `iTerm2`, `Code`, `Cursor`, `WezTerm`, `kitty`, `Ghostty`. Its pid is what `NSRunningApplication(processIdentifier:)` needs to bring it forward (section 5.5).
4. `e_tdev` is `0xFFFFFFFF` for every process in the Claude Desktop chain (no controlling tty). In a terminal-launched session it is the tty device; `devname(dev_t(bitPattern: e_tdev), S_IFCHR)` returns `ttys003`-style names [verified API; value in terminal sessions likely]. Terminal.app tabs and iTerm2 sessions expose a `tty` property to AppleScript, which makes "jump to the tab that runs this agent" possible at the cost of an Automation permission (section 5.5) [likely].

Process-group facts observed in the same run [verified]:
- The Bash tool's `zsh` is its own group leader (`pgid == pid`); commands it runs inherit that pgid. Killing a dev server by `kill(-pgid)` while the session is alive would therefore kill the agent's tool shell. After the shell exits, the group is orphaned and `kill(-pgid)` is safe and complete.
- `Foundation.Process` puts its child in a new process group (`pgid == child pid`), so `Process.terminate()` does not reach grandchildren; use `kill(-pid, …)` on the child's pid when Airbag itself spawns helpers.

## 3. FSEvents from Swift

### 3.1 API facts (header: `CoreServices.framework/Frameworks/FSEvents.framework/Headers/FSEvents.h`) [verified]

- Create flags: `UseCFTypes 0x1`, `NoDefer 0x2`, `WatchRoot 0x4`, `IgnoreSelf 0x8`, `FileEvents 0x10`, `MarkSelf 0x20`, `UseExtendedData 0x40`, `FullHistory 0x80`. `kFSEventStreamEventIdSinceNow = 0xFFFFFFFFFFFFFFFF`.
- Event flags used by Airbag: `MustScanSubDirs 0x1`, `UserDropped 0x2`, `KernelDropped 0x4`, `EventIdsWrapped 0x8`, `HistoryDone 0x10`, `RootChanged 0x20`, `Mount 0x40`, `Unmount 0x80`, `ItemCreated 0x100`, `ItemRemoved 0x200`, `ItemInodeMetaMod 0x400`, `ItemRenamed 0x800`, `ItemModified 0x1000`, `ItemFinderInfoMod 0x2000`, `ItemChangeOwner 0x4000`, `ItemXattrMod 0x8000`, `ItemIsFile 0x10000`, `ItemIsDir 0x20000`, `ItemIsSymlink 0x40000`, `OwnEvent 0x80000`, `ItemIsHardlink 0x100000`, `ItemIsLastHardlink 0x200000`, `ItemCloned 0x400000`.
- `FSEventStreamSetExclusionPaths`: "A maximum of 8 directories maybe specified" (10.9+). Probe: 8 paths → `true`, 9 → `false`.
- `FSEventStreamScheduleWithRunLoop` is `API_DEPRECATED("Use FSEventStreamSetDispatchQueue instead.", macos(10.5, 13.0))`; use `FSEventStreamSetDispatchQueue`.
- Persistence helpers: `FSEventStreamGetLatestEventId`, `FSEventsGetCurrentEventId`, `FSEventsCopyUUIDForDevice(dev_t)`, `FSEventsGetLastEventIdForDeviceBeforeTime`.

Apple's programming guide adds: store the last processed event id regularly; compare the device UUID before trusting a stored id (different UUID, or current id lower than stored → discard history and rescan); treat the event list as advisory and run periodic full sweeps; on `MustScanSubDirs`/`*Dropped` rescan recursively; on `RootChanged` (event id 0, needs `WatchRoot`) rescan and find the new location with `open` + `fcntl(F_GETPATH)`; start monitoring before scanning to avoid a gap (Apple, "Using the FSEvents Framework", https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html, accessed 2026-10-17) [verified].

### 3.2 Probe results (APFS Data volume, dispatch queue, flags `FileEvents|NoDefer|WatchRoot|UseCFTypes`) [verified]

Latency and threading: every callback ran off the main thread on the supplied queue. With latency 0.1 s the first event of a step arrived 0.3–12 ms after the syscall (NoDefer delivers the first event immediately), the remainder of a burst 101 ms later; with latency 0 everything arrived within 1–12 ms.

| Action | Events delivered (relative paths, flags) — one run; flags vary between runs, see the caveat below the table |
| --- | --- |
| create `a.txt` | `a.txt Created|Modified|XattrMod|IsFile` |
| append to `a.txt` | `a.txt Modified|IsFile` |
| Foundation `write(atomically: true)` | `.dat.nosync148E8.B7yY3j Created|Renamed|XattrMod|IsFile`, then `a.txt Renamed|IsFile`, then `a.txt Renamed|Modified|ChangeOwner|IsFile` |
| editor style: write `a.txt.tmp`, `rename(2)` over `a.txt` | `a.txt.tmp Created|Renamed|Modified|XattrMod`, `a.txt Renamed`, `a.txt Renamed|Modified|ChangeOwner` |
| `rename a.txt → b.txt` | `a.txt Renamed`, `b.txt Renamed` with consecutive ids (185492521, 185492522) |
| `mkdir sub; create sub/c.txt` | `sub Created|XattrMod|IsDir`, `sub/c.txt Created|Modified|XattrMod|IsFile` |
| `chmod b.txt` | `b.txt ChangeOwner|IsFile` (permission changes surface as ChangeOwner) |
| `rm b.txt` | `b.txt Removed|IsFile` |
| write `node_modules/pkg/index.js` with `node_modules` excluded | only `node_modules Created|IsDir` (the excluded directory's own creation in the parent); nothing inside |
| write `.git/HEAD` with `.git` excluded | only `.git Created|IsDir` |
| 200 appends without sleeping | 1 event (latency 0) or 2 events (latency 0.1: one immediate, one coalesced at +101 ms) |
| `rm -r sub` | `sub/c.txt Removed|IsFile`, `sub Removed|IsDir` (one event per removed path) |
| rename the watched root away | `RootChanged` with id 0 and path = root, then `<root> Renamed|IsDir` |
| rename it back | second `RootChanged` (id 0); the stream keeps working afterwards (`after-move.txt` events arrived) |

Flag sets are cumulative per path, not a description of the last operation [verified, second probe 2026-10-17]: in an independent C run the append to `a.txt` arrived as `Created|Modified|XattrMod|IsFile` (not `Modified|IsFile`), the 200 appends to `b.txt` after its rename arrived as one `Renamed|Modified|IsFile` event, and a plain `rename(2)` atomic save ended as `a.txt Created|Renamed|Modified|XattrMod|IsFile` with no `ChangeOwner` (the `ChangeOwner` in the table comes from Foundation's atomic write doing a chmod). The stable facts are: an event on a path means "this path changed, stat it"; `Renamed` on a path can mean either side of a rename; `Removed`, `RootChanged`, `MustScanSubDirs`, `*Dropped` and `HistoryDone` are reliable. Never branch on exact flag combinations.

History replay: a second stream created with `sinceWhen` = the id captured before the actions replayed the history (including files under the previously excluded directories, because the replay stream had no exclusions) and ended with `HistoryDone` carrying the latest id, ~350 ms after start. The first run reported "25 events in order"; the second, independent run delivered one coalesced record per path and *not* in event-id order (ids 192174002, 192173849, 192173843, 192173841, 192174011, 192173931, 192173856, 192173865, then `HistoryDone`), so a replay consumer must treat the batch as an unordered set of changed paths and must not use per-event ids for ordering [verified; the "in order" wording of the first run is withdrawn]. Device UUID via `FSEventsCopyUUIDForDevice(st_dev)` = `C6707AA2-…` for the Data volume.

"Since now" slop: in the second run, six events caused by the shell's `rm -rf`/`mkdir` executed a few milliseconds before `FSEventStreamCreate(…, kFSEventStreamEventIdSinceNow, …)` were delivered anyway. Consumers must be idempotent and must not assume the first event is newer than the stream.

Volumes: event ids are per host but persistence must be keyed by device UUID; a stream may watch roots on several volumes, and `Mount`/`Unmount` flags arrive for volume changes [verified header]. External/network volumes are out of Airbag's v1 scope.

TCC: FSEvents on project folders under `~/Work`, `~/src`, `~/qost` needs no permission. Project folders under `~/Desktop`, `~/Documents`, `~/Downloads` trigger the per-folder prompt on first file access; Apple states access is implied without a prompt when the user picked the folder in an Open panel, dragged it onto the app, or opened it via Finder, and that `NSDesktopFolderUsageDescription`/`NSDocumentsFolderUsageDescription`/`NSDownloadsFolderUsageDescription` are "optional but highly recommended" (https://developer.apple.com/documentation/bundleresources/information-property-list/nsdesktopfolderusagedescription, accessed 2026-10-17) [verified doc; behaviour with FSEvents specifically unverified]. No Full Disk Access is involved.

### 3.3 Copy-pasteable stream setup

```swift
import CoreServices

final class Watcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.airbag.fsevents", qos: .utility)
    var onEvents: (([(path: String, flags: FSEventStreamEventFlags, id: FSEventStreamEventId)]) -> Void)?

    func start(root: String, since: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
               latency: CFTimeInterval = 0.5, exclude: [String]) {
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer |
                           kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes |
                           kFSEventStreamCreateFlagMarkSelf)          // OwnEvent flag marks Airbag's own rollback writes
        let callback: FSEventStreamCallback = { _, info, n, paths, flags, ids in
            let me = Unmanaged<Watcher>.fromOpaque(info!).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self) as! [String]
            me.onEvents?((0..<n).map { (arr[$0], flags[$0], ids[$0]) })
        }
        stream = FSEventStreamCreate(nil, callback, &ctx, [root] as CFArray, since, latency, flags)
        precondition(FSEventStreamSetExclusionPaths(stream!, Array(exclude.prefix(8)) as CFArray))  // max 8
        FSEventStreamSetDispatchQueue(stream!, queue)
        FSEventStreamStart(stream!)
    }
    func stop() { guard let s = stream else { return }; FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil }
}
```

Exclusion budget: 8 paths per stream is tight (`node_modules`, `.git`, `.next`, `dist`, `build`, `.venv`, `target`, `.airbag`). Use the stream exclusions for the heaviest directories and filter the rest in the callback with an ignore list; or run one stream per project root so each gets its own 8.

## 4. Keep-awake: IOPM assertions [verified by probe]

Header: `IOKit.framework/Headers/pwr_mgt/IOPMLib.h`. `IOPMAssertionCreateWithName(type, level, reason, &id)` (10.6+), `IOPMAssertionCreateWithProperties(dict, &id)` with `kIOPMAssertionTimeoutKey` ("TimeoutSeconds") and `kIOPMAssertionTimeoutActionKey`, `IOPMAssertionRelease`. QA1340 limits the reason string to 128 characters and states forced sleep (lid close, Apple menu, thermal/low battery) cannot be prevented, only idle sleep (https://developer.apple.com/library/archive/qa/qa1340/_index.html, accessed 2026-10-17).

Probe output (unprivileged, on battery):

```
IOPMAssertionCreateWithName -> success id=42618
IOPMAssertionCreateWithProperties(timeout 60s) -> success id=42619
pmset -g assertions:
   pid 84957(pmprobe): [...] PreventUserIdleSystemSleep named: "Airbag probe: 1 agent session active"
   pid 84957(pmprobe): [...] PreventUserIdleSystemSleep named: "Airbag probe: timed 60s"   Timeout will fire in 60 secs Action=TimeoutActionRelease
release -> true, true   (gone from pmset afterwards)
```

`IOPSGetProvidingPowerSourceType(IOPSCopyPowerSourcesInfo())` returned `"Battery Power"`, which is the guard Airbag needs for "hold only on AC" (issue #85261 in note 00 is exactly the on-battery failure mode) [verified].

```swift
import IOKit.pwr_mgt
var id: IOPMAssertionID = 0
let rc = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                     "Airbag: 2 agent sessions running" as CFString, &id)   // <= 128 chars
// … later
IOPMAssertionRelease(id)
```

Design: one assertion per app, created when the first live session appears and released when the last one ends, with a safety timeout (e.g. 4 h, `TimeoutActionRelease`) renewed by the poller, and never held on battery below a threshold. Closed-lid operation is out of scope (needs `pmset disablesleep`, root).

## 5. App shell

### 5.1 LSUIElement and activation policy

`LSUIElement` (Boolean, macOS 10.0+): "the app is an agent app that runs in the background and doesn't appear in the Dock" (https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement, accessed 2026-10-17) [verified]. The probe app launched with `LSUIElement=true` reported `NSApp.activationPolicy() == .accessory (1)` [verified]. Apple's MenuBarExtra page: a menu-bar-only app is terminated automatically if the user removes the extra from the menu bar; set `LSUIElement` to hide the Dock icon [verified].

### 5.2 Login item: SMAppService (macOS 13+) vs launchd agent

Header `ServiceManagement.framework/Headers/SMAppService.h`: `mainApp`, `agent(plistName:)`, `daemon(plistName:)`, `loginItem(identifier:)`, `register()`, `unregister()`, `status`, `openSystemSettingsLoginItems()` are all `API_AVAILABLE(macos(13.0))` [verified]. Status cases: `notRegistered`, `enabled`, `requiresApproval` ("registered, but the user needs to take action in System Preferences"), `notFound` (https://developer.apple.com/documentation/servicemanagement/smappservice/status-swift.enum, accessed 2026-10-17) [verified]. `register()` for the main app means "the application launches on subsequent logins"; for a LaunchAgent it is "immediately bootstrapped"; errors `kSMErrorAlreadyRegistered`, `kSMErrorLaunchDeniedByUser` (https://developer.apple.com/documentation/servicemanagement/smappservice/register(), accessed 2026-10-17) [verified]. macOS shows a "Background Items Added" notification the first time an app registers [likely].

`launchd.plist(5)` (local man page) [verified]: `BundleProgram` is "an app-bundle relative path to the executable … only supported for plists that are installed using SMAppService"; `AssociatedBundleIdentifiers` ties the job to the app in the Login Items UI; `LimitLoadToSessionType` restricts agents to `Aqua` sessions; `Sockets` gives launch-on-demand sockets fetched with `launch_activate_socket(3)`; `MachServices` registers Mach bootstrap names (prerequisite for XPC from another process).

```swift
import ServiceManagement
let svc = SMAppService.mainApp
switch svc.status {
case .enabled: break
case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
default: try? svc.register()          // kSMErrorAlreadyRegistered is not an error for us
}
```

Decision: ship as `SMAppService.mainApp` (one toggle in Settings, visible in System Settings › General › Login Items, no plist). Keep `agent(plistName:)` + `Sockets`/`MachServices` as a later option if on-demand launch of the app by the CLI (socket activation) becomes necessary. Homebrew casks uninstall such apps with `uninstall quit: "<bundle id>", login_item: "<Name>"` (the Ice cask does exactly this, section 6.6).

### 5.3 MenuBarExtra: availability, measured behaviour, known bugs

SwiftUI interface (`SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface`): `MenuBarExtra` and `WindowMenuBarExtraStyle` `@available(macOS 13.0, *)`; `SettingsLink` and `EnvironmentValues.openSettings` `@available(macOS 14.0, *)`; `dismissWindow` 14.0; `Settings` scene 11.0 [verified]. Apple's page documents `isInserted` (binding; set to `false` when the user removes the item) and the `.window` style as "a popover-like window from the menu bar icon" (https://developer.apple.com/documentation/swiftui/menubarextra, accessed 2026-10-17) [verified].

Measured on the probe app (SwiftPM release build, `MenuBarExtra(.window)` + `Settings`, launched via `open`, never clicked) [verified]:

| Metric | Value |
| --- | --- |
| `phys_footprint` (`footprint`, `top MEM`) | 14 MB |
| `ps RSS` | 56 MB (shared framework pages; not the budget number) |
| CPU after 7–9 s idle (`top -l 3`) | 0.0 % |
| threads | 4 |
| windows at t+5 s | two `NSStatusBarWindow` 30×37, no content window |
| content view lifecycle | `onAppear`/`.task` never fired until the icon is clicked → timers in the content do not run in the background |
| `.app` on disk | 556 KB (101 KB arm64 executable; universal 185 KB) |

Known limitations and bugs, by source:
- No first-party API to show/hide/toggle the extra programmatically, to disable it, to reach the `NSStatusItem` or the popup `NSWindow`; "still the case as of Xcode 26". With the `.menu` style SwiftUI blocks the run loop while the menu is open, so bindings do not update and the menu cannot be dismissed programmatically (orchetect/MenuBarExtraAccess README, https://github.com/orchetect/MenuBarExtraAccess, accessed 2026-10-17) [verified source].
- `.window` style: no fade-out on dismissal, no selection state, awkward resizing; the replacement library FluidMenuBarExtra used an `NSWindow` and was archived read-only on 2026-01-20 (https://github.com/lfroms/fluid-menu-bar-extra/blob/main/README.md, accessed 2026-10-17) [verified source].
- macOS 14.0: in an `LSUIElement` app, a `.sheet` (and `.alert`) presented from the menu bar content stops accepting keyboard/mouse input after interacting with a `TextField`; regression from 13.2; no answer or workaround in the thread (Apple Developer Forums 740640, Oct 2023–Jan 2024, https://developer.apple.com/forums/thread/740640) [verified source; not re-tested on 15.7].
- macOS 14.5: with "Automatically hide and show the menu bar: Always", the `.window` style hides the menu bar when the pointer moves into the popover; removing `.autoHideMenuBar` from `presentationOptions` is ignored; `.menu` style unaffected; unanswered (Apple Developer Forums 761204, Aug 2024, https://developer.apple.com/forums/thread/761204) [verified source].
- "Agent is active" focus: a `.window` extra opened from a background app does not make the app active, so text fields and keyboard shortcuts inside it need `NSApp.activate()` first [likely; consistent with the Settings findings below].

### 5.4 Opening the Settings window from a MenuBarExtra app

- macOS 14 removed the `NSApp.sendAction(Selector(("showSettingsWindow:")))` hack (13: `showSettingsWindow:`, ≤12: `showPreferencesWindow:`); it now errors and points to `SettingsLink` [verified secondary: steipete.me 2025, https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items/, accessed 2026-10-17; Apple forums 739831].
- `SettingsLink` (14+) inside a MenuBarExtra works but the window opens behind other apps because an accessory app is not active; `openSettings` (14+) works on 15 but "fails silently" on 15.5 if a hidden `Window` scene is declared after `Settings`, and does nothing on macOS 26 without an existing SwiftUI render tree (same source) [likely].
- Working pattern (same source, confirmed by SettingsAccess and VibeTunnel code): `NSApp.setActivationPolicy(.regular)` → short delay → `NSApp.activate()` → `openSettings()`/`SettingsLink` pre-action → on the Settings view's `onDisappear` restore `.accessory`. Apple documents `openSettings` as "Opens the window associated to the Settings scene defined by this app, if one exists" (https://developer.apple.com/documentation/swiftui/environmentvalues/opensettings, accessed 2026-10-17) [verified].

Airbag decision: do not depend on the SwiftUI `Settings` scene at all. Use a normal `Window("Settings", id: "settings")` scene opened with `@Environment(\.openWindow)` plus the activation-policy flip, or an AppKit `NSWindowController` with `NSHostingView`. Both avoid the `openSettings` render-tree dependency and work identically on 14, 15 and 26 [design, based on the above].

### 5.5 Bringing Terminal / iTerm2 / VS Code / Claude Desktop forward

AppKit headers [verified]: `-[NSApplication activateIgnoringOtherApps:]` is `API_DEPRECATED("… Use NSApp.activate instead.")`; `NSApplicationActivateIgnoringOtherApps` is `API_DEPRECATED("ignoringOtherApps is deprecated in macOS 14 and will have no effect.", macos(10.6, 14.0))`; `-[NSRunningApplication activateWithOptions:]` returns whether the request was sent. Apple's cooperative-activation article (macOS 14): activation is a request, not a command; the active app should `NSApp.yieldActivation(to: target)` and then `target.activate()`; `NSWorkspace` does this automatically when opening URLs or apps (https://developer.apple.com/documentation/appkit/passing-control-from-one-app-to-another-with-cooperative-activation, accessed 2026-10-17) [verified].

What Airbag can do without extra permissions:
- Activate the terminal app that hosts a session: `NSRunningApplication(processIdentifier: terminalPid)?.activate(options: [])` after `NSApp.yieldActivation(to:)` — Airbag is active while the user clicks in its popover, so the yield is honoured [likely].
- Open the project in an editor: `NSWorkspace.shared.open(URL(string: "vscode://file/<path>")!)` / `cursor://file/<path>`; `open -a Terminal <dir>` / `NSWorkspace.open([dirURL], withApplicationAt: terminalURL)` opens a new window at the directory [likely].
- Jumping to the specific tab that runs the agent needs Apple events (`tell application "Terminal" … whose tty is "/dev/ttys003"`, iTerm2 sessions have `tty` too). That requires `NSAppleEventsUsageDescription` (10.14+, "required if your app uses APIs that send Apple events", https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription) and, under the hardened runtime, the `com.apple.security.automation.apple-events` entitlement (not needed for apps signed with the same team id, https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events, both accessed 2026-10-17) [verified docs]; the user then sees a per-target Automation prompt. Ship it as an opt-in "Focus tab" feature, never required.
- Claude Desktop sessions have no tty; the best Airbag can do is activate `Claude.app` [verified chain].

### 5.6 NSStatusItem + NSPopover fallback

Headers [verified]: `NSStatusItem.button` (10.10+), `isVisible` and `autosaveName` (10.12+), `behavior` with `removalAllowed` and `terminationOnRemoval`; `NSPopover.behavior` is `applicationDefined` (default), `transient` (1), `semitransient` (2). The usual recipe: `NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)`, `button.action` toggles an `NSPopover` with `contentViewController = NSHostingController(rootView:)`, `behavior = .transient`, `show(relativeTo: button.bounds, of: button, preferredEdge: .minY)`, plus `NSApp.activate()` for key input and an `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown])` to close on outside clicks. Cost is ~150 lines and it removes every limitation in 5.3 (programmatic open/close, exact placement, animation). Keep the SwiftUI content identical and swap the host if MenuBarExtra bites in testing on 14.x.

## 6. Building, signing and notarizing a `.app` from SwiftPM with CLT only

### 6.1 What the CLT toolchain has and lacks [verified]

| Tool | Present? |
| --- | --- |
| `swift-build`, `swiftc` 6.1.2, `lipo`, `strip`, `otool`, `install_name_tool` | yes (CLT) |
| `codesign`, `spctl`, `plutil`, `iconutil`, `pkgbuild`, `productbuild`, `ditto` | yes (macOS) |
| `xcrun notarytool`, `xcrun stapler` | yes (`/Library/Developer/CommandLineTools/usr/bin/`) |
| `actool`, `ibtool`, `xcstringstool`, `xcodebuild`, `xcbuild`, `altool` | no |
| XCTest | no (`swift test` → `error: no such module 'XCTest'`) |
| Swift Testing | yes (`Testing.framework` in CLT; "Testing Library Version: 124.4") |
| Signing identities | `security find-identity -v -p codesigning` → 0 on this machine |

Default toolchain target is `arm64-apple-macosx15.0`; without `platforms: [.macOS(.v14)]` the binary would require macOS 15 [verified].

### 6.2 Package layout that worked

```swift
// swift-tools-version:6.1
import PackageDescription
let package = Package(
  name: "Airbag",
  defaultLocalization: "en",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "AirbagCore"),                                   // rules, registry, snapshot engine (shared)
    .executableTarget(name: "airbag", dependencies: ["AirbagCore"]), // hook/CLI
    .executableTarget(name: "AirbagApp", dependencies: ["AirbagCore"],
                      resources: [.process("Resources")],           // Resources/en.lproj/Localizable.strings, ru.lproj/…
                      linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ServiceManagement")]),
    .testTarget(name: "AirbagCoreTests", dependencies: ["AirbagCore"]),  // Swift Testing only
  ])
```

Facts observed with this layout [verified]:
- `@main struct AirbagApp: App` in an `executableTarget` compiles and runs in Swift 6 language mode (one global needed `nonisolated(unsafe)`).
- `swift build -c release` output: `.build/arm64-apple-macosx/release/AirbagApp` (101 KB) and `AirbagApp_AirbagApp.bundle/{Info.plist, en.lproj/Localizable.strings, ru.lproj/Localizable.strings}`. `otool -l`: `LC_BUILD_VERSION minos 14.0 sdk 15.5`; all Swift runtime libraries resolve to `/usr/lib/swift/*.dylib` (no embedding needed on macOS 14+); two `LC_RPATH`s: `@loader_path` and `/Library/Developer/CommandLineTools/Library/Developer/Frameworks` — the latter is a developer-machine path; drop it with `install_name_tool -delete_rpath /Library/Developer/CommandLineTools/Library/Developer/Frameworks <exe>` before signing (verified to leave the binary with no stray rpath).
- `Bundle.module`: SwiftPM generates `resource_bundle_accessor.swift` that only tries `Bundle.main.bundleURL/AirbagApp_AirbagApp.bundle` and a hard-coded `.build/...` path, then `fatalError`s. Inside `Airbag.app` that first path is the `.app` root (not `Contents/Resources`), so `Bundle.module` fails on a user's machine (or silently uses the developer's `.build` path on yours). Use an own accessor and never call `Bundle.module` from the app:

```swift
extension Bundle {
    static let airbag: Bundle = {
        let name = "AirbagApp_AirbagApp.bundle"
        for url in [Bundle.main.resourceURL?.appendingPathComponent(name),   // Airbag.app/Contents/Resources/
                    Bundle.main.bundleURL.appendingPathComponent(name)]       // bare executable in .build
            .compactMap({ $0 }) { if let b = Bundle(url: url) { return b } }
        return Bundle.module                                                  // dev-only fallback
    }()
}
// usage: Text("menu.summary", bundle: .airbag) / String(localized: "menu.summary", bundle: .airbag)
```
  Verified: with the `.build` bundle renamed away (simulating an end-user machine) the assembled app loaded `Contents/Resources/AirbagApp_AirbagApp.bundle` and resolved strings.
- Localization: `.lproj/Localizable.strings` works end to end; the system (preferred languages `ru-KZ, kk-KZ`) picked `ru.lproj` automatically, and `open Airbag.app --args -AppleLanguages "(ru)"` forces it. `Localizable.xcstrings` builds ("Copying Localizable.xcstrings") but at runtime `String(localized:)` returns the key (`hello`) in both `en` and `ru`: SwiftPM copies the JSON verbatim and nothing compiles it without `xcstringstool`. Do not use `.xcstrings` on the CLT toolchain; CI with Xcode would hide the problem.
- Universal binary: `swift build -c release --arch arm64 --arch x86_64` fails with `xcbuild executable … does not exist`; `swift build -c release --triple x86_64-apple-macosx14.0` followed by `lipo -create .build/arm64-apple-macosx/release/AirbagApp .build/x86_64-apple-macosx/release/AirbagApp -output AirbagApp` produces a fat binary (`x86_64 arm64`, 185 KB).
- Swift Testing: `swift test` ran one `@Test` ("Target Platform: arm64e-apple-macos14.0"); mixing an `import XCTest` file in the same test target breaks the whole test build. Keep the suite Swift Testing only; CI with Xcode may add XCTest later if needed.

### 6.3 Assembly script (verified steps)

```bash
#!/bin/sh
set -eu
APP=build/Airbag.app; EXE=.build/arm64-apple-macosx/release/AirbagApp
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$EXE" "$APP/Contents/MacOS/Airbag"
cp .build/arm64-apple-macosx/release/airbag "$APP/Contents/Helpers/airbag"          # the hook/CLI binary
cp -R .build/arm64-apple-macosx/release/AirbagApp_AirbagApp.bundle "$APP/Contents/Resources/"
install_name_tool -delete_rpath /Library/Developer/CommandLineTools/Library/Developer/Frameworks "$APP/Contents/MacOS/Airbag" || true
cp packaging/Info.plist "$APP/Contents/Info.plist"; plutil -lint "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
iconutil -c icns packaging/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"   # iconset: icon_16x16.png … icon_512x512@2x.png
# sign inside-out: nested code first, then the app (never --deep for signing)
SIGN=${SIGN:--}   # "-" = ad-hoc for local runs; "Developer ID Application: Name (TEAMID)" for release
codesign --force --options runtime --timestamp --sign "$SIGN" "$APP/Contents/Helpers/airbag"
codesign --force --options runtime --timestamp --sign "$SIGN" "$APP/Contents/Resources/AirbagApp_AirbagApp.bundle"
codesign --force --options runtime --timestamp --sign "$SIGN" --identifier dev.airbag.app "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"
```

Minimal `Info.plist` that launched correctly: `CFBundleDevelopmentRegion en`, `CFBundleExecutable`, `CFBundleIconFile AppIcon`, `CFBundleIdentifier`, `CFBundleInfoDictionaryVersion 6.0`, `CFBundleName`, `CFBundlePackageType APPL`, `CFBundleShortVersionString`, `CFBundleVersion`, `CFBundleLocalizations [en, ru]`, `LSMinimumSystemVersion 14.0`, `LSUIElement true`, `NSPrincipalClass NSApplication`, `NSHighResolutionCapable true` [verified]. Add `NSAppleEventsUsageDescription`, `NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription` when those features ship.

`iconutil -c iconset Some.icns -o X.iconset` and `iconutil -c icns X.iconset -o AppIcon.icns` both work with CLT only (round trip verified; 399 KB icns). Generate the PNGs with `sips -z N N` from a 1024 px master.

### 6.4 Signing results and notarization requirements

Ad-hoc hardened runtime on the SwiftPM output [verified]: `codesign -dvv` → `CodeDirectory v=20500 flags=0x10002(adhoc,runtime)`, `Signature=adhoc`, `TeamIdentifier=not set`, `Runtime Version=15.5.0`; `codesign --verify --strict --deep` → "valid on disk … satisfies its Designated Requirement"; `spctl -a -vv --type exec` → `rejected` (expected without Developer ID). The `.app` launched and ran normally under the ad-hoc signature.

Apple's requirements (https://developer.apple.com/documentation/security/resolving-common-notarization-issues and https://developer.apple.com/documentation/security/customizing-the-notarization-workflow, both accessed 2026-10-17) [verified]:
- "You can only notarize apps that you sign with a Developer ID certificate" (Developer ID Application for apps; Developer ID Installer for pkgs). Generating it requires being the Account Holder of a team in the Apple Developer Program (https://developer.apple.com/developer-id/, accessed 2026-10-17); the program fee is not stated on these pages [verified pages; USD 99/year is common knowledge, unverified here].
- Hardened runtime enabled (`--options runtime`), secure timestamp (`--timestamp`, needs internet, only `timestamp.apple.com`), no `com.apple.security.get-task-allow`, SDK ≥ 10.9, all nested executables signed, entitlements plist ASCII XML (`plutil -lint`), submitted as zip/dmg/pkg: `ditto -c -k --keepParent Airbag.app Airbag.zip`.
- Workflow: `xcrun notarytool store-credentials "airbag-notary" --apple-id … --team-id … --password <app-specific>`; `xcrun notarytool submit Airbag.zip --keychain-profile airbag-notary --wait`; `xcrun notarytool log <id> --keychain-profile airbag-notary log.json` (check warnings even on Accepted); `xcrun stapler staple Airbag.app`; then re-zip the stapled app for distribution (a zip itself cannot be stapled; standalone binaries get tickets but cannot be stapled). Most submissions finish in 5 minutes, 98 % within 15; 75 per day limit.
- Entitlements for Airbag: none for v1. Library validation stays on (no third-party plugins). Add only `com.apple.security.automation.apple-events` if the AppleScript tab-focus feature ships. No sandbox (Homebrew distribution, libproc on other processes, writing hooks into `~/.claude`).
- The bundled CLI `Contents/Helpers/airbag` is a Mach-O executable inside the app: it is signed with the same identity and covered by the app's notarization ticket; hooks invoke it by absolute path.

### 6.5 Gatekeeper and quarantine

- Apple, "Updates to runtime protection in macOS Sequoia", 2024-08-06: "users will no longer be able to Control-click to override Gatekeeper when opening software that isn't signed correctly or notarized"; they must go to System Settings › Privacy & Security (https://developer.apple.com/news/?id=saqachfa, accessed 2026-10-17) [verified]. Apple's support article confirms the "Open Anyway" flow and that Catalina and later require notarization by default (https://support.apple.com/en-us/102445, accessed 2026-10-17) [verified].
- Homebrew: "On macOS, apps, installers and other executable artefacts that Gatekeeper can assess must pass Homebrew's Gatekeeper checks" and "A cask must use a download published by the developer" (https://docs.brew.sh/Acceptable-Casks, accessed 2026-10-17) [verified]. Homebrew 7.0.4 on this machine: `brew help install` and the online manpage (both halves, searched for "quarantine") list no `--[no-]quarantine` option any more; `Library/Homebrew/cask/download.rb` calls `Quarantine.cask!(cask:, download_path:)` after every download (lines 78 and 211 via `quarantine(path)`). The base `cask/quarantine.rb` defines `cask!` as an empty stub; the macOS implementation in `extend/os/mac/cask/quarantine.rb` (prepended as `ClassMethods`) returns early only when `Quarantine.available?` is false (no working `xattr`/FFI) or when the file is already quarantined, and otherwise writes the attribute; neither `cask/config.rb`, `cask/installer.rb` nor `cmd/install.rb` contains a quarantine switch. So every cask download carries `com.apple.quarantine`, Gatekeeper evaluates every install, and an un-notarized Airbag would send every user into System Settings › Privacy & Security [verified in local Homebrew source, re-checked 2026-10-17]. Note that Acceptable Casks does not say "notarized": it requires that artefacts "pass Homebrew's Gatekeeper checks" and "must not require System Integrity Protection or Gatekeeper to be disabled or bypassed"; the download rule reads "published by the developer or by a distribution source the developer publicly endorses" [verified].

### 6.6 Cask template (modelled on `jordanbaird-ice`, https://raw.githubusercontent.com/Homebrew/homebrew-cask/HEAD/Casks/j/jordanbaird-ice.rb, accessed 2026-10-17) [verified source]

```ruby
cask "airbag" do
  version "0.1.0"
  sha256 "<sha256 of the zip>"

  url "https://github.com/<org>/airbag/releases/download/v#{version}/Airbag-#{version}.zip"
  name "Airbag"
  desc "Safety net for local AI coding agents: snapshots, rollback, circuit breaker, port radar"
  homepage "https://github.com/<org>/airbag"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"      # Ice uses `depends_on macos: :sonoma`; the comparison form is also accepted [likely]

  app "Airbag.app"
  binary "#{appdir}/Airbag.app/Contents/Helpers/airbag"   # gives hooks a stable /opt/homebrew/bin/airbag path [likely]

  uninstall quit:       "dev.airbag.app",
            login_item: "Airbag"

  zap trash: [
    "~/Library/Application Support/Airbag",
    "~/Library/Caches/dev.airbag.app",
    "~/Library/Preferences/dev.airbag.app.plist",
  ]
end
```

Ice's cask also shows `auto_updates true` with a Sparkle appcast; Airbag can start without an updater (Homebrew upgrades it) and add Sparkle later. Homebrew's cookbook: `zap` runs only with `--zap` and must not remove user-created files (snapshots live in the project's hidden store, so keep them out of `zap`), `uninstall quit:` sends the quit Apple event, login items are only present after first launch (https://docs.brew.sh/Cask-Cookbook, accessed 2026-10-17) [verified].

## 7. CLI ↔ app IPC [verified by probe]

| Option | Facts | Verdict |
| --- | --- | --- |
| Unix domain socket, POSIX | `socket/bind/listen/accept`; echo round trip 4.2 µs; `getsockopt(SOL_LOCAL, LOCAL_PEERPID / LOCAL_PEEREPID / LOCAL_PEERCRED)` returned the client's pid and `uid=501` (also `LOCAL_PEERTOKEN` = audit token, `sys/un.h`); with `umask(077)` the socket file is mode 0700; `sun_path` is 104 bytes, `~/Library/Application Support/Airbag/airbag.sock` is 68 chars here, `$TMPDIR` is 49 | Use for the app's listener. |
| Unix domain socket, Network.framework | `NWParameters.tcp` + `requiredLocalEndpoint = .unix(path:)` for `NWListener`; `NWConnection(to: .unix(path:), using: .tcp)`; round trip 17.7 µs; a plain POSIX client connects to it fine; the socket file is created 0755 and the API exposes no fd for `LOCAL_PEERCRED` | Acceptable for the app side only if the parent directory is 0700; otherwise prefer POSIX. |
| XPC | Needs a launchd job with `MachServices` (man `launchd.plist`) for `NSXPCConnection(machServiceName:)`; XPC service bundles are per-client processes bundled in the app (https://developer.apple.com/documentation/xpc, accessed 2026-10-17); the app would have to be an `SMAppService.agent` | Not for v1. |
| `DistributedNotificationCenter` | one-way, no payload guarantees, zero setup | Fine as a "registry changed" ping from CLI to app [likely]. |
| SQLite only + file watch | CLI writes rows; the app watches the DB directory with FSEvents/`DispatchSource` | Works even when the app is down; latency ≈ FSEvents latency. |

Decision: SQLite is the source of truth and must be enough on its own (hooks work with the app closed). The socket is an optimisation: the hook connects (fails fast with `ENOENT`/`ECONNREFUSED` when the app is down), sends one JSON line (`{"op":"pre_tool","session":…,"cwd":…,"cmd":…}`), optionally waits ≤ 50 ms for `{"snapshot":"ok"}`, and the app learns the hook's pid from `LOCAL_PEERPID`. Socket at `~/Library/Application Support/Airbag/airbag.sock` inside a 0700 directory (`umask` before `bind`; unlink stale file at start; `chmod 0600` after).

## 8. SQLite from Swift without dependencies [verified by probe]

`import SQLite3` resolves to the system library: `sqlite3_libversion() = 3.43.2 (2023-10-10)`, `sqlite3_threadsafe() = 2` (multi-thread; one connection per thread or serialize yourself), compile options include `THREADSAFE=2 ENABLE_FTS5 ENABLE_RTREE ENABLE_SNAPSHOT ENABLE_API_ARMOR ENABLE_COLUMN_METADATA ENABLE_DBSTAT_VTAB OMIT_LOAD_EXTENSION DEFAULT_WAL_AUTOCHECKPOINT=1000 DEFAULT_WAL_SYNCHRONOUS=1 DEFAULT_SYNCHRONOUS=2 MAX_MMAP_SIZE=1073741824 MAX_VARIABLE_NUMBER=500000`. JSON functions are built in since 3.38 (no `JSON1` option listed, as expected) [likely].

WAL semantics (https://www.sqlite.org/wal.html, accessed 2026-10-17) [verified]: readers do not block writers and vice versa; one writer at a time; `journal_mode=WAL` is persistent in the file (probe: `wal` survived reopen); `-wal`/`-shm` must stay with the DB; all processes must be on one host; `synchronous=NORMAL` commits are not synced (durable except power loss; checkpoint syncs); automatic checkpoint at 1000 pages; checkpoint starvation if readers never gap; `SQLITE_BUSY` still possible during recovery, last-connection cleanup or exclusive locking mode. Busy handler (https://www.sqlite.org/c3ref/busy_timeout.html, …/busy_handler.html, accessed 2026-10-17) [verified]: per connection, default off (probe: `PRAGMA busy_timeout` → 0); SQLite skips the handler and returns `SQLITE_BUSY` immediately when a read transaction tries to upgrade to a write while another writer waits (deadlock avoidance) — hence always `BEGIN IMMEDIATE` for writes. The WAL page also notes a rare WAL-reset corruption bug in 3.7.0–3.51.2 (fixed in 3.51.3, backports 3.44.6/3.50.7) requiring two connections writing or checkpointing at the same instant; macOS 15.7.9 ships 3.43.2.

Two-writer measurements (two separate processes, `BEGIN IMMEDIATE`, `synchronous=NORMAL`):

| Scenario | Result |
| --- | --- |
| A and B: 2000 single-row txns each, `busy_timeout=5000`, plus a reader hammering `SELECT count(*)` | 0 `SQLITE_BUSY`; A 51 ms total (max single wait 27.2 ms), B 28 ms; reader 725 081 reads, 0 BUSY |
| C and D: same with `busy_timeout=0` and a manual 0.5 ms retry loop | 3 and 17 `SQLITE_BUSY` on `BEGIN IMMEDIATE` per 2000 txns |
| E and F: 5000 rows each in batches of 50 | 100 txns in 3–7 ms per writer, 0 BUSY |
| single writer, 2000 txns | 17 ms (≈ 8 µs per transaction) |
| CLI process: open + `PRAGMA journal_mode=WAL` + 1 insert txn + close | ≈ 3 ms per invocation (10 runs: 30 ms) |

Recommended connection setup (both binaries):

```sql
PRAGMA journal_mode=WAL;          -- once; persistent
PRAGMA synchronous=NORMAL;        -- per connection
PRAGMA busy_timeout=5000;         -- per connection (sqlite3_busy_timeout)
PRAGMA foreign_keys=ON;
-- CLI only: PRAGMA wal_autocheckpoint=0;   let the app do checkpoints (reduces concurrent checkpoints; see WAL-reset note)
-- App, every few minutes when idle: PRAGMA wal_checkpoint(TRUNCATE);
```

Open with `sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_NOMUTEX, nil)`, one connection per thread/actor, prepared statements cached, `BEGIN IMMEDIATE … COMMIT` around every write, retry on `SQLITE_BUSY` from `BEGIN IMMEDIATE` with jitter. Registry location: `~/Library/Application Support/Airbag/registry.sqlite` (0700 directory; same host, local APFS, so WAL is fine). The `-shm` file is 32 KB and `-wal` shrinks to 0 after `wal_checkpoint(TRUNCATE)` (observed).

## 9. Running git

- `/usr/bin/git` is a 118 864-byte universal (x86_64, arm64e) shim that links `/usr/lib/libxcselect.dylib`; it resolves to the active developer directory. Here: `xcode-select -p` → `/Library/Developer/CommandLineTools`, `git version 2.39.5 (Apple Git-154)`, CLT receipt `com.apple.pkg.CLTools_Executables 16.4.0.0.1.1747106510` [verified].
- `xcode-select -p` honours `DEVELOPER_DIR` without validating it (`DEVELOPER_DIR=/nonexistent xcode-select -p` printed `/nonexistent`, exit 0) [verified]. With no developer directory at all it prints "unable to get active developer directory" and exits 2, and any shim (`git`, `xcrun`, `clang`) prints "xcode-select: note: No developer tools were found, requesting install …" and opens the GUI install dialog [likely; widely reported, e.g. Stack Overflow 52522565 cited in note 00; not reproducible here without uninstalling CLT]. `xcode-select --install` "Opens a user interface dialog to request automatic installation of the command line developer tools" (local man page) [verified].
- Detection recipe for Airbag (never exec the shim blindly):
  1. `dir = $(xcode-select -p)`; if exit ≠ 0 → no toolchain.
  2. Accept only if `<dir>/usr/bin/git` (CLT) or `<dir>/usr/bin/git` under `Xcode.app/Contents/Developer` exists and is executable; otherwise treat as missing even if `xcode-select -p` succeeded (bogus `DEVELOPER_DIR`).
  3. Prefer a Homebrew git when present (`/opt/homebrew/bin/git`, `/usr/local/bin/git`; absent on this machine).
  4. Cache the resolved path; re-check after macOS updates (the classic "invalid active developer path" breakage from note 00).
- Invocation hygiene for the snapshot store (generic git behaviour, [likely]): `GIT_DIR=<project>/.airbag/store.git GIT_WORK_TREE=<project>`, `GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1` to isolate from user config, `-c core.hooksPath=/dev/null -c gc.auto=0 -c core.fsmonitor=false -c core.autocrlf=false -c core.excludesFile=<airbag ignore>`, `GIT_TERMINAL_PROMPT=0`, run via `posix_spawn` with its own process group and a timeout. A missing git must degrade to "snapshots disabled, show a one-click fix" rather than a crash; an own content-addressed store is the alternative (open question).

## 10. Signals: SIGTERM then SIGKILL, process groups [verified by probe]

`man 2 kill`: negative pid → signal every process in that group (a variant of `killpg`); `ESRCH` when nothing matches. Probe sequence with `posix_spawn` + `POSIX_SPAWN_SETPGROUP`/`posix_spawnattr_setpgroup(0)` (the `POSIX_SPAWN_SETSID` flag exists in `sys/spawn.h` as `0x0400` but is only usable through the raw flag):

```
sh pid=86282 pgid=86282 ; children sleep 86283, 86284 pgid=86282 (trap '' TERM inherited)
kill(-86282, SIGTERM) -> 0 ; after 300 ms: sh alive, 2 children alive   (SIGTERM ignored)
kill(-86282, SIGKILL) -> 0 ; after 300 ms: children 0, sh exists (zombie) until waitpid -> ESRCH
plain child sleep: kill(pid, SIGTERM) -> zombie: kill(pid,0)=0, listed by proc_listallpids, proc_pidinfo/proc_pidpath ESRCH, sysctl p_stat=5
```

Stop recipe for the radar:
1. Re-validate `(pid, start_time)`; refuse if changed.
2. Decide the target set: for an orphan (ppid 1, pgid of a dead shell) send to `-pgid` so `npm run dev` wrappers and their `node`/`next-server` children die together; for a process whose session is alive, send to the pid and its descendants (walk ppid from a `KERN_PROC_ALL` snapshot, or `proc_listchildpids`), never to the group that contains the agent's shell.
3. `SIGTERM`, poll every 100 ms up to 5 s using `proc_pidinfo` (ESRCH or `p_stat==5` means gone), then `SIGKILL` only as a separate, explicit user action ("Force stop"), as note 00 recommends.
4. Zombies are the parent's problem (the agent shell reaps them); show them as "exited" not "running".

## 11. Testing with CLT

`swift test` with Swift Testing works (`@Test`, `#expect`; "Testing Library Version: 124.4"); XCTest is not installed with CLT 16.4 and any `import XCTest` fails the build [verified]. Swift Testing covers the rule engine, path matching, registry and snapshot-store logic; UI is tested manually or in CI with Xcode. Note that SwiftPM test targets can depend on library targets only in practice; keep both executables thin and all logic in `AirbagCore`.

## 12. What this means for Airbag — design implications

1. Two binaries, one core: `AirbagCore` (rules, registry, snapshot store, libproc helpers) + `airbag` CLI (4 ms startup, 3 ms SQLite write) + `AirbagApp`. The hook path budget is ~10 ms before the git snapshot; the snapshot itself (git add/commit on a hidden store) is the only expensive step and must run with a hard timeout and a "skip if snapshot < N s old" rule.
2. Radar engine: poll `sysctl KERN_PROC_ALL` (0.07 ms) for the tree and liveness, then `PROC_PIDLISTFDS` + `PROC_PIDFDSOCKETINFO` only for same-uid pids (0.8–1.1 ms total), `PROC_PIDVNODEPATHINFO` for cwd, `PROC_PIDTASKINFO`/`proc_pid_rusage` for RAM (`phys_footprint`) and CPU (Mach units × timebase). Attribute by `cwd` under a registered project/worktree root first, then by ancestry to a live agent pid, then by inherited `CLAUDE_CODE_SESSION_ID`/`CLAUDE_PID` from `KERN_PROCARGS2` (note 01), then by the registry's historical `(session → pgid, start)` records for orphans. Group dual-stack sockets by `(pid, port)`.
3. Hook-side agent identification: env first (`CLAUDE_PID`), ancestry walk second (stop at EPERM/ppid 1; do not key on `sh`), store `(agent pid, start, terminal app pid, tty)` in the registry so the app can later activate the right terminal and, with opt-in Automation, the right tab.
4. Snapshot triggers from FSEvents: `FileEvents|NoDefer|WatchRoot|MarkSelf` on a utility dispatch queue, latency 0.5–1 s (coalescing is per path, not per tree, so `rm -rf src/` emits one event per file), debounce per project (e.g. 2 s quiet), treat `Renamed` on a watched path as content change and never branch on exact flag combinations (flags are cumulative per path; stat the path instead), ignore `OwnEvent` (Airbag's own rollbacks), treat `RootChanged` as "project moved/deleted: rescan or pause", persist `(device UUID, last id)` per project and replay with `sinceWhen` at launch (`HistoryDone` closes the gap; the replay batch is per-path coalesced and unordered, so treat it as a set of paths to diff), do a full rescan on `MustScanSubDirs`/`*Dropped`/UUID mismatch. Exclusions: 8 stream-level paths per project (one stream per project) plus a callback-level ignore list; always exclude the snapshot store itself.
5. Per-project hidden store as a git repository (`GIT_DIR` outside the user's `.git`): keep git invocation isolated (section 9) and treat a missing CLT as a degraded mode with a one-click `xcode-select --install`; never trigger the dialog implicitly.
6. App shell: SwiftUI `MenuBarExtra(.window)` is viable on 14/15 (14 MB, 0 % idle, lazy content) but plan the `NSStatusItem`+`NSPopover` fallback behind the same SwiftUI view; do not use the `Settings` scene or `openSettings`; open settings via `openWindow` + activation-policy flip; call `NSApp.activate()` before showing anything that needs keyboard input; avoid `.sheet`/`.alert` inside the extra on 14.0 (use windows).
7. Login item: `SMAppService.mainApp` with a toggle; handle `.requiresApproval` by opening Login Items. No launchd plist in v1.
8. IPC: SQLite registry in WAL mode with `busy_timeout` and `BEGIN IMMEDIATE` is the contract; the Unix socket (POSIX listener in a 0700 dir, `LOCAL_PEERPID`) is an accelerator for "snapshot before this command" acknowledgements and for live UI updates; the CLI must succeed with the app absent.
9. Distribution: CLT-only build + `lipo` universal + ad-hoc signing for local dev; release requires Developer ID + notarization + stapling (budget the Apple Developer Program membership); Homebrew cask with `binary` symlink for the CLI so hook commands reference `/opt/homebrew/bin/airbag` (or the app writes the absolute `Contents/Helpers/airbag` path and rewrites hooks on move). Sequoia's Gatekeeper change makes notarization non-negotiable for a free utility's first impression.
10. Keep-awake (v1.1): one `PreventUserIdleSystemSleep` assertion with a timeout and an AC-power guard via `IOPSGetProvidingPowerSourceType`; document that lid-close sleep is not prevented.
11. Memory/CPU budget tracking: measure `phys_footprint` (not RSS); the empty shell is 14 MB, leaving ~85 MB for registry caches, FSEvents buffers and SwiftUI timeline views; poll the radar at 2–5 s and on hook events to keep idle CPU under 0.1 %.
12. Localization: `.lproj/Localizable.strings` with `String(localized:bundle:)` through an own bundle accessor; `.xcstrings` is off the table on the CLT toolchain.

## 13. Open questions

1. `proc_listallpids` return semantics across macOS 14.x: count (as measured on 15.7.9) vs bytes; code defensively (count non-zero entries) until checked on a 14.x machine.
2. FSEvents on folders under `~/Desktop`/`~/Documents`/`~/Downloads` for a non-sandboxed app: whether events are delivered before the TCC prompt and whether an `NSOpenPanel` selection suppresses the prompt for FSEvents reads (Apple documents implied consent for file access, not for FSEvents specifically).
3. MenuBarExtra regressions on macOS 14.0–14.3 (sheet/alert input loss, keyboard focus in `.window`) were not re-tested here (only 15.7.9 available); needs a 14.x VM or machine before deciding on the AppKit fallback.
4. `NWEndpoint.unix` minimum OS: in the 15.5 SDK's `Network.swiftinterface` the `unix(path:)` case carries no availability attribute of its own (the enum is `@available(macOS 10.14, …)`), and it compiled for a 14.0 target without diagnostics; Apple's reference lists it as macOS 13.0+ [unverified]. Irrelevant for a 14+ target, but worth knowing if the deployment target ever drops.
5. Whether `depends_on macos: ">= :sonoma"` and `binary "#{appdir}/…"` for an app-bundled CLI are accepted by the current cask audit (`brew audit --cask --new`); the Ice cask uses the plain symbol form and no `binary`.
6. Git dependency vs own content-addressed store: a store that does not depend on `/usr/bin/git` removes the CLT prompt problem and the user-config isolation work, at the cost of writing diff/rollback plumbing; decide after measuring git snapshot latency on a 10k-file project.
7. Socket activation (`SMAppService.agent` + `Sockets`) to launch the app on the first hook event when the user quit it: desirable for "hooks always protected", but changes the login-item UX; defer and measure demand.
8. macOS 14 system SQLite version and whether it also predates the WAL-reset fix (3.51.3); mitigation (single checkpointer) is cheap either way.
9. Terminal tab focusing via Apple events (`tty` matching) was not exercised; verify the AppleScript dictionaries of Terminal, iTerm2, Ghostty and WezTerm before promising the feature.
10. Which Developer ID / notarization identity the project will use (personal vs organisation team) and who holds the Account Holder role; this gates the first Homebrew cask submission and the `brew audit --cask --new` run.

## Sources

Local primary sources (CLT 16.4, SDK macOS 15.5, read 2026-10-17): `usr/include/libproc.h`, `usr/include/sys/proc_info.h`, `usr/include/sys/proc.h`, `usr/include/sys/un.h`, `usr/include/sys/spawn.h`, `usr/include/sys/resource.h`, `CoreServices.framework/Frameworks/FSEvents.framework/Headers/FSEvents.h`, `IOKit.framework/Headers/pwr_mgt/IOPMLib.h`, `ServiceManagement.framework/Headers/SMAppService.h`, `AppKit.framework/Headers/{NSApplication,NSRunningApplication,NSStatusItem,NSPopover}.h`, `SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface`, `Network.framework/Modules/Network.swiftmodule/arm64e-apple-macos.swiftinterface`; man pages `kill(2)`, `launchd.plist(5)`, `xcode-select(1)`; SwiftPM-generated `resource_bundle_accessor.swift`.

Web sources (accessed 2026-10-17):
- Apple, Customizing the notarization workflow — https://developer.apple.com/documentation/security/customizing-the-notarization-workflow
- Apple, Resolving common notarization issues — https://developer.apple.com/documentation/security/resolving-common-notarization-issues
- Apple, Developer ID — https://developer.apple.com/developer-id/
- Apple, Updates to runtime protection in macOS Sequoia (2024-08-06) — https://developer.apple.com/news/?id=saqachfa
- Apple Support, Open a Mac app from an unknown developer — https://support.apple.com/en-us/102445
- Apple, SMAppService / register() / Status — https://developer.apple.com/documentation/servicemanagement/smappservice
- Apple, MenuBarExtra — https://developer.apple.com/documentation/swiftui/menubarextra
- Apple, openSettings — https://developer.apple.com/documentation/swiftui/environmentvalues/opensettings
- Apple, LSUIElement — https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement
- Apple, NSDesktopFolderUsageDescription — https://developer.apple.com/documentation/bundleresources/information-property-list/nsdesktopfolderusagedescription
- Apple, NSAppleEventsUsageDescription — https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription
- Apple, com.apple.security.automation.apple-events — https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events
- Apple, Passing control from one app to another with cooperative activation — https://developer.apple.com/documentation/appkit/passing-control-from-one-app-to-another-with-cooperative-activation
- Apple, NSApplication.activate() — https://developer.apple.com/documentation/appkit/nsapplication/activate()
- Apple, XPC overview — https://developer.apple.com/documentation/xpc
- Apple, Using the FSEvents Framework (archive) — https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html
- Apple, QA1340 Registering and unregistering for sleep and wake notifications / preventing sleep — https://developer.apple.com/library/archive/qa/qa1340/_index.html
- orchetect/MenuBarExtraAccess README — https://github.com/orchetect/MenuBarExtraAccess
- lfroms/fluid-menu-bar-extra README (archived 2026-01-20) — https://github.com/lfroms/fluid-menu-bar-extra/blob/main/README.md
- Apple Developer Forums 740640 (sheet input lost in agent app, macOS 14.0) — https://developer.apple.com/forums/thread/740640
- Apple Developer Forums 761204 (menu bar auto-hide with `.window`, macOS 14.5) — https://developer.apple.com/forums/thread/761204
- Peter Steinberger, Showing Settings from macOS Menu Bar Items (2025) — https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items/
- SQLite, Write-Ahead Logging — https://www.sqlite.org/wal.html
- SQLite, sqlite3_busy_timeout / sqlite3_busy_handler — https://www.sqlite.org/c3ref/busy_timeout.html, https://www.sqlite.org/c3ref/busy_handler.html
- Homebrew, Acceptable Casks — https://docs.brew.sh/Acceptable-Casks
- Homebrew, Cask Cookbook — https://docs.brew.sh/Cask-Cookbook
- Homebrew, brew manpage — https://docs.brew.sh/Manpage
- Homebrew cask `jordanbaird-ice` — https://raw.githubusercontent.com/Homebrew/homebrew-cask/HEAD/Casks/j/jordanbaird-ice.rb
- Homebrew cask `stats` (launchctl/zap example) — https://raw.githubusercontent.com/Homebrew/homebrew-cask/HEAD/Casks/s/stats.rb
- swift-package-manager 6.1, `generateResourceAccessor()` (Bundle.module template) — https://raw.githubusercontent.com/swiftlang/swift-package-manager/release/6.1/Sources/Build/BuildDescription/SwiftModuleBuildDescription.swift
- Homebrew source on this machine (7.0.4): `Library/Homebrew/cask/download.rb`, `cask/quarantine.rb`, `extend/os/mac/cask/quarantine.rb`
- Apple, Notarizing macOS software before distribution — https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution

## Verification log (independent re-check, 2026-10-17)

Method: a second engineer re-derived each claim from primary sources without reusing the original probes: new C programs (`clang`, CLT 16.4) for libproc, sysctl, FSEvents, signals; a new SwiftPM package (`swift build -c release`, Swift 6.1.2) for the toolchain claims; a Swift script for `Foundation.Process`; shell probes from inside the Claude Code Bash tool for the ancestry chain; SDK headers, man pages and local Homebrew source for API facts; Apple/Homebrew/SQLite pages fetched today (Apple pages read through their `tutorials/data/...json` payloads because the HTML shell is empty without JavaScript). Verdicts: **holds** (claim supported as written), **holds with correction** (claim true but the doc text was changed), **withdrawn** (doc text removed or downgraded).

| # | Claim (section) | Check performed | Verdict |
| --- | --- | --- | --- |
| 1 | `proc_pidinfo` flavors and `proc_pid_rusage` fail with `EPERM` for other uids incl. root; `proc_pidpath` works; `sysctl KERN_PROC_ALL` lists everything incl. zombies `p_stat==5` (1.2, 10) | C probe: pid 1, root `mobileactivationd`, uid 89 `mdworker_shared`, uid 296 → `r=0 errno=1` for TBSDINFO/TASKINFO/VNODEPATHINFO/LISTFDS, `rusage r=-1 errno=1`; `proc_pidpath` succeeded for all. `KERN_PROC_ALL` 556 records × 648 B. SIGKILLed, unreaped child: `kill(pid,0)=0`, present in `proc_listallpids`, `proc_pidinfo`/`proc_pidpath` → `ESRCH`, sysctl `p_stat=5` | holds (other-uid evidence added) |
| 2 | `insi_lport` is the port in network byte order inside an `int`; `INI_IPV6` selects `ina_6`; dual-stack = two sockets (1.3) | C probe with `ntohs((uint16_t)insi_lport)`: 47115→3000, 13568→53, 40719→3999, 14357→5432, 60184→6379, 34835→5000; ControlCenter listed as `0.0.0.0:5000` + `:::5000` and `0.0.0.0:7000` + `:::7000`; `limactl` `:::53` v6 only; 20 listeners, matching the original count | holds |
| 3 | Full libproc scan ≈ 0.8–1.1 ms, `lsof` 20 ms, sysctl 0.07 ms (1.4) | New timed C probe, 7 iterations: 632 pids / 377 visible / 4990 fds / 394 sockets → 1.39 ms median (0.86–1.71); sysctl 0.079 ms; `lsof` 36 ms wall | holds with correction (budget 1–2 ms; numbers scale with process count) |
| 4 | Hook ancestry `zsh → claude.app/…/claude → disclaimer → Claude.app → launchd`; `sh -c "cmd"` exec-optimises; `/bin/sh` re-execs `/bin/bash`; tool shell is group leader (2) | `ps` walk from the Bash tool: `91018 zsh (pgid 91018) → 11328 claude (…/claude-code/2.1.295/9d6405864fdc/claude.app/Contents/MacOS/claude) → 11327 disclaimer → 94586 Claude → 1`. `sh -c 'ps -p $$'` printed `comm=ps` with pid == `$$` (exec). `sh -c '…; true'`: `pbi_comm=bash`, `proc_pidpath=/bin/bash`, `$BASH_VERSION=3.2.57(1)-release`, `/private/var/select/sh → /bin/bash`; `ps -o comm` shows `sh` (argv[0]) | holds with correction (argv vs libproc naming nuance added) |
| 5 | `FSEventStreamSetExclusionPaths` max 8 (header + 9→false); `ScheduleWithRunLoop` deprecated macOS 13 (3.1) | Header `FSEvents.h:1419` "A maximum of 8 directories maybe specified"; line 1157 `API_DEPRECATED("Use FSEventStreamSetDispatchQueue instead.", macos(10.5, 13.0))`. C probe: 7→1, 8→1, 9→0, 10→0 | holds |
| 6 | FSEvents behaviour: first event 0.3–12 ms, 200 appends → 1 event at latency 0, excluded dir reports only its own creation, `RootChanged` id 0 path==root, `sinceWhen` replay ends with `HistoryDone` "in order"; per-operation flag table (3.2) | New C probe on a dispatch queue (`FileEvents|NoDefer|WatchRoot|UseCFTypes`, latency 0): first events at 0.4–12.9 ms; 200 appends → 1 event; `node_modules` excluded → only `node_modules Created|XattrMod|IsDir`; `RootChanged` `id=0` with path==root on both moves, stream kept working; replay stream delivered 8 per-path records **out of id order** and then `HistoryDone` with the latest id. Flags differed from the table (append → `Created|Modified|XattrMod`; post-rename appends → `Renamed|Modified`; `rename(2)` save → no `ChangeOwner`) | holds with correction (flag table marked non-deterministic; "in order" withdrawn; design implication 4 updated) |
| 7 | CLT-only toolchain: `.xcstrings` compiles but returns the key; `Bundle.module` only tries `Bundle.main.bundleURL` + hard-coded `.build` path then `fatalError`; `--arch arm64 --arch x86_64` fails (xcbuild); `--triple x86_64-apple-macosx14.0` + `lipo` works; default triple `arm64-apple-macosx15.0`; `platforms: .v14` gives `minos 14.0`; stray `LC_RPATH` to CLT frameworks (6.1, 6.2, 11) | New package built in 24 s: `String(localized:"hello", bundle:.module)` printed `hello` under `en` and `-AppleLanguages "(ru)"`; generated `resource_bundle_accessor.swift` matches the SwiftPM 6.1 source (`Bundle.main.bundleURL.appendingPathComponent(…)`, literal build path, `Swift.fatalError`); `--arch arm64 --arch x86_64` → "xcbuild executable at '/Library/Developer/SharedFrameworks/XCBuild.framework/…/xcbuild' does not exist"; `--triple` build + `lipo` → `x86_64 arm64`; `swiftc -print-target-info` → `arm64-apple-macosx15.0`; `otool -l` → `minos 14.0 sdk 15.5`, `LC_RPATH` `@loader_path` and `/Library/Developer/CommandLineTools/Library/Developer/Frameworks`; `xcrun --find xcstringstool` → not found; `notarytool`/`stapler` present in CLT `usr/bin` | holds |
| 8 | Homebrew 7.0.4 has no `--[no-]quarantine`; `download.rb` quarantines unconditionally; Sequoia removed Control-click override (2024-08-06); Acceptable Casks requires Gatekeeper pass + developer-published download (6.5) | `brew --version` 7.0.4; `brew help install` and docs.brew.sh/Manpage (both halves) contain no "quarantine"; `download.rb:78,211,254-255` → `Quarantine.cask!`; base `cask/quarantine.rb:193` is a stub, `extend/os/mac/cask/quarantine.rb:57-61` runs unless `available?` is false or already quarantined; no switch in `cask/config.rb`/`installer.rb`/`cmd/install.rb`. Apple news page dated August 6, 2024 quotes "users will no longer be able to Control-click to override Gatekeeper…". Acceptable Casks: "must pass Homebrew's Gatekeeper checks", "published by the developer or by a distribution source the developer publicly endorses"; the page does not use the word "notarized" | holds with correction (mac override + endorsed-source wording added) |
| 9 | Notarization: Developer ID only, hardened runtime, `--timestamp`, no `get-task-allow`, SDK ≥ 10.9; 5 min / 98 % in 15 min; 75 per day; zip and standalone binaries cannot be stapled; Account Holder generates the certificate (6.4) | Apple "Resolving common notarization issues" JSON: "You can only notarize apps that you sign with a Developer ID certificate", hardened runtime, secure timestamp (`timestamp.apple.com`), `get-task-allow`, "older than the 10.9 SDK" all present. "Customizing the notarization workflow" JSON: "most software within 5 minutes, and for 98 percent of software within 15 minutes", "Limit notarizations to 75 per day", zip cannot be stapled directly, "not currently possible to staple tickets to [standalone binaries]". developer.apple.com/developer-id: "you must be the Account Holder of your development team in the Apple Developer Program" | holds |
| 10 | `/usr/bin/git` 118 KB libxcselect shim; CLT git 2.39.5 (Apple Git-154); `xcode-select -p` prints bogus `DEVELOPER_DIR` with exit 0; `--install` opens a dialog (9) | `ls`/`file`/`otool -L`: 118 864 B universal x86_64+arm64e, links `/usr/lib/libxcselect.dylib`; `git --version` 2.39.5 (Apple Git-154); receipt `com.apple.pkg.CLTools_Executables 16.4.0.0.1.1747106510`; `DEVELOPER_DIR=/nonexistent xcode-select -p` → `/nonexistent`, exit 0; `man xcode-select`: "--install Opens a user interface dialog to request automatic installation…". Implicit-dialog-on-shim-exec still not reproducible with CLT installed | holds; implicit dialog stays [likely] |
| 11 | `kill(-pgid, SIGTERM)` reaches the group; SIGTERM-ignoring processes survive; SIGKILL leaves a zombie that `kill(pid,0)` reports alive while `proc_pidinfo` says `ESRCH`; `Foundation.Process` child is its own group leader (10) | C probe (fork + `setpgid(0,0)` + `sh -c "trap '' TERM; sleep 30 & sleep 30 & wait"`): `proc_listchildpids` → 2 children in the group; after `kill(-pgid,SIGTERM)` all three still `SRUN`; after `kill(-pgid,SIGKILL)` children → `ESRCH`, sh → `ESRCH` from `proc_pidinfo` but `kill(sh,0)=0` until `waitpid`, then `ESRCH`. Swift: `Process` child pid 91629 had `pgid 91629` while the parent's pgid was 91598 | holds |
| 12 | `SMAppService` API is macOS 13+; `BundleProgram` only for SMAppService plists (5.2) | `SMAppService.h`: every method/property `API_AVAILABLE(macos(13.0), macCatalyst(16.0))` (only `SMAppServiceErrorDomain` is 15.0); `man launchd.plist`: "BundleProgram … only supported for plists that are installed using SMAppService" | holds |
| 13 | `SettingsLink`/`openSettings` macOS 14+; MenuBarExtra has no show/hide/NSStatusItem API "as of Xcode 26", `.menu` blocks the run loop; forum bugs 14.0 (sheet/alert input) and 14.5 (auto-hide menu bar) (5.3, 5.4) | `SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface`: `@available(macOS 14.0, *)` on `SettingsLink` and `EnvironmentValues.openSettings`. MenuBarExtraAccess README: "lacks 1st-party API to get or set the menu presentation state", "(Still as of Xcode 26)", `.menu` "block[s] the runloop while the menu is open". Thread 740640: macOS 14.0, agent app, `.sheet`/`.alert` ignore input after `TextField`, worked on 13.2, no answer (Oct 2023–Jan 2024). Thread 761204: macOS 14.5, `.window` hides an auto-hidden menu bar, `.menu` unaffected, 0 replies (Aug 2024) | holds; steipete.me-derived 15.5/26 `openSettings` failure modes remain [likely] (secondary source, not re-tested) |
| 14 | System SQLite 3.43.2; WAL-reset bug 3.7.0–3.51.2 fixed in 3.51.3 with 3.44.6/3.50.7 backports; `synchronous=NORMAL` not durable across power loss; `SQLITE_BUSY` still possible in WAL (8) | `sqlite3 --version` and Python `sqlite3.sqlite_version` → 3.43.2 (2023-10-10). sqlite.org/wal.html §11 "The WAL-Reset Bug": "from 3.7.0 (2010-07-21) through 3.51.2 (2026-01-09) … fixed in version 3.51.3 (2026-03-13)", backports 3.44.6 and 3.50.7; §2.3 and §9 match the doc's wording. Two-writer BUSY counts not re-measured | holds (measurements not re-run) |

Not re-checked in this pass (original tags stand): IOPM assertion probe (section 4), MenuBarExtra memory/CPU/thread measurements (5.3), Unix-socket round-trip timings and `NWListener` 0755 mode (7), SQLite two-writer BUSY counts (8), `iconutil` round trip (6.3).
