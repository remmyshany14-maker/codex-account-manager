$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent $PSScriptRoot
$accounts = @(
    [pscustomobject]@{ Key = 'A'; Home = Join-Path $env:USERPROFILE '.codex' },
    [pscustomobject]@{ Key = 'B'; Home = Join-Path $env:USERPROFILE '.codex-account-b' },
    [pscustomobject]@{ Key = 'C'; Home = Join-Path $env:USERPROFILE '.codex-account-c' }
)

$rmType = Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CodexRestartManager {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct RM_PROCESS_INFO {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string strServiceShortName;
        public int ApplicationType; public uint AppStatus; public uint TSSessionId; [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
    }
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] public static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] public static extern int RmRegisterResources(uint dwSessionHandle, uint nFiles, string[] rgsFilenames, uint nApplications, IntPtr rgApplications, uint nServices, string[] rgsServiceNames);
    [DllImport("rstrtmgr.dll")] public static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo, [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);
    [DllImport("rstrtmgr.dll")] public static extern int RmEndSession(uint pSessionHandle);
    public static int[] Query(string path, out int status, out string stage) {
        uint session; stage = "RmStartSession"; status = RmStartSession(out session, 0, Guid.NewGuid().ToString("N"));
        if (status != 0) return new int[0];
        try {
            stage = "RmRegisterResources"; status = RmRegisterResources(session, 1, new string[] { path }, 0, IntPtr.Zero, 0, null);
            if (status != 0) return new int[0];
            uint needed = 0, count = 0, reasons = 0;
            stage = "RmGetList(size)"; status = RmGetList(session, out needed, ref count, null, ref reasons);
            if (status != 234 && status != 0) return new int[0];
            if (needed == 0) return new int[0];
            var info = new RM_PROCESS_INFO[needed]; count = needed;
            stage = "RmGetList(data)"; status = RmGetList(session, out needed, ref count, info, ref reasons);
            if (status != 0) return new int[0];
            var pids = new int[count]; for (int i = 0; i < count; i++) pids[i] = info[i].Process.dwProcessId;
            return pids;
        } finally { RmEndSession(session); }
    }
}
'@ -PassThru
$restartManagerAvailable = $null -ne $rmType

function Test-FileLocked([string]$Path) {
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        return [pscustomobject]@{
            Locked = $false
            ExclusiveOpenSucceeded = $true
            FailureCategory = $null
            ExceptionType = $null
            HResult = $null
            Win32ErrorCode = $null
            Win32ErrorName = $null
            Error = $null
        }
    } catch {
        $exception = $_.Exception
        while ($exception.InnerException) { $exception = $exception.InnerException }
        $hresult = [int64]$exception.HResult
        $hresultUnsigned = [uint64]($hresult -band 0xffffffffL)
        $isHresultFromWin32 = (($hresultUnsigned -band 0xffff0000L) -eq 0x80070000L)
        $win32Code = $null
        $win32Name = $null
        if ($isHresultFromWin32) {
            $win32Code = [int]($hresultUnsigned -band 0xffffL)
            try { $win32Name = ([System.ComponentModel.Win32Exception]::new($win32Code)).NativeErrorCode.ToString() + ': ' + ([System.ComponentModel.Win32Exception]::new($win32Code)).Message } catch { }
        }
        $category = if ($win32Code -eq 32) { 'SHARING_CONFLICT' } elseif ($win32Code -eq 5) { 'ACCESS_DENIED' } elseif ($isHresultFromWin32) { 'OTHER_IO_ERROR' } else { 'UNKNOWN_FAILURE' }
        return [pscustomobject]@{
            Locked = ($category -eq 'SHARING_CONFLICT')
            ExclusiveOpenSucceeded = $false
            FailureCategory = $category
            ExceptionType = $exception.GetType().FullName
            HResult = ('0x{0:X8}' -f $hresultUnsigned)
            Win32ErrorCode = $win32Code
            Win32ErrorName = $win32Name
            Error = $exception.Message
        }
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Get-ProcessInfoSafe([int]$ProcessId) {
    $gp = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    $path = $null; $start = $null
    if ($gp) {
        try { $path = $gp.Path } catch { }
        try { $start = $gp.StartTime.ToString('o') } catch { }
    }
    $cim = $null; $parent = $null
    try { $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop } catch { }
    if ($cim) { try { $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($cim.ParentProcessId)" -ErrorAction Stop } catch { } }
    [pscustomobject]@{
        PID = $ProcessId
        Name = if ($gp) { $gp.ProcessName } elseif ($cim) { [IO.Path]::GetFileNameWithoutExtension($cim.Name) } else { 'Unknown' }
        ExecutablePath = if ($path) { $path } elseif ($cim) { $cim.ExecutablePath } else { 'UNAVAILABLE (permission or exited)' }
        CommandLine = if ($cim -and $cim.CommandLine) { $cim.CommandLine } else { 'UNAVAILABLE (permission)' }
        ParentPID = if ($cim) { $cim.ParentProcessId } else { 'UNAVAILABLE (permission)' }
        ParentName = if ($parent) { $parent.Name } else { 'UNAVAILABLE (permission)' }
        ParentPath = if ($parent -and $parent.ExecutablePath) { $parent.ExecutablePath } else { 'UNAVAILABLE (permission)' }
        StartTime = if ($start) { $start } else { 'UNAVAILABLE (permission or exited)' }
    }
}

$sqlite = foreach ($account in $accounts) {
    if (-not (Test-Path -LiteralPath $account.Home -PathType Container)) {
        [pscustomobject]@{ Account = $account.Key; Path = $account.Home; Exists = $false; Locked = $null; LockError = $null; OwnerPID = 'NOT_FOUND / UNAVAILABLE' }
        continue
    }
    Get-ChildItem -LiteralPath $account.Home -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '\.(sqlite|sqlite3|db|sqlite-wal|sqlite-shm)$' } |
        ForEach-Object {
            $lock = Test-FileLocked $_.FullName
            $owners = @()
            $rmStatus = $null
            $rmStage = $null
            if ($lock.Locked -and $restartManagerAvailable) {
                try { $owners = @( [CodexRestartManager]::Query($_.FullName, [ref]$rmStatus, [ref]$rmStage) ) } catch { $rmStatus = -1; $rmStage = 'PowerShell/PInvoke exception' }
            }
            $ownerDetails = foreach ($ownerPid in $owners) {
                $info = Get-ProcessInfoSafe ([int]$ownerPid)
                [pscustomobject]@{ PID = $info.PID; Name = $info.Name; ExecutablePath = $info.ExecutablePath }
            }
            [pscustomobject]@{ Account = $account.Key; Path = $_.FullName; Exists = $true; Locked = $lock.Locked; ExclusiveOpenSucceeded = $lock.ExclusiveOpenSucceeded; FailureCategory = $lock.FailureCategory; ExceptionType = $lock.ExceptionType; HResult = $lock.HResult; Win32ErrorCode = $lock.Win32ErrorCode; Win32ErrorName = $lock.Win32ErrorName; LockError = $lock.Error; RestartManagerStage = $rmStage; RestartManagerStatus = $rmStatus; OwnerProcesses = @($ownerDetails); OwnerPID = if ($lock.Locked -and $owners.Count -eq 0) { 'UNKNOWN' } elseif ($owners.Count -gt 0) { @($owners) } else { $null } }
        }
}

$arg0 = foreach ($account in $accounts) {
    $path = Join-Path $account.Home 'tmp\arg0-windows'
    $items = if (Test-Path -LiteralPath $path -PathType Container) { @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue) } else { @() }
    [pscustomobject]@{ Account = $account.Key; Path = $path; Exists = (Test-Path -LiteralPath $path -PathType Container); ItemCount = $items.Count; Items = @($items | ForEach-Object { $_.Name }); LockFiles = @($items | Where-Object Name -eq '.lock' | ForEach-Object { $_.FullName }) }
}

$processes = @(Get-Process -Name codex,ChatGPT -ErrorAction SilentlyContinue | ForEach-Object { Get-ProcessInfoSafe $_.Id } | Sort-Object PID -Unique)
$appServers = @($processes | Where-Object { $_.Name -ieq 'codex' -and $_.CommandLine -match '\bapp-server\b' } | ForEach-Object {
    $matched = @($accounts | Where-Object { $_.Home -and $_.CommandLine -like "*$($_.Home)*" })
    [pscustomobject]@{ Process = $_; AccountMatch = if ($matched.Count -eq 1) { $matched[0].Key } elseif ($matched.Count -gt 1) { 'AMBIGUOUS' } else { 'UNKNOWN (command line unavailable or no CODEX_HOME match)' } }
})

$focusPids = @(19548) + @($appServers | ForEach-Object { $_.Process.PID })
$processRelations = foreach ($focusPid in ($focusPids | Sort-Object -Unique)) {
    $info = Get-ProcessInfoSafe ([int]$focusPid)
    $parentInfo = 'UNKNOWN'
    if ($info.ParentPID -is [int] -or $info.ParentPID -is [long]) {
        $parentInfo = Get-ProcessInfoSafe ([int]$info.ParentPID)
    }
    [pscustomobject]@{
        PID = $info.PID
        Exists = ($info.Name -ne 'Unknown')
        ProcessName = $info.Name
        ExecutablePath = $info.ExecutablePath
        CommandLine = $info.CommandLine
        StartTime = $info.StartTime
        Parent = if ($parentInfo -is [string]) { $parentInfo } else { $parentInfo }
        DesktopTreeRelation = if ($parentInfo -is [string]) { 'UNKNOWN (parent unavailable)' } elseif ($parentInfo.Name -eq 'ChatGPT') { 'DIRECT_PARENT_IS_CHATGPT' } else { 'NOT_ESTABLISHED' }
    }
}

[pscustomobject]@{
    GeneratedAt = (Get-Date).ToString('o')
    Scope = 'Read-only; auth.json and token content not accessed'
    SQLite = @($sqlite)
    Arg0Directories = @($arg0)
    CodexProcesses = @($processes)
    AppServers = @($appServers)
    ProcessRelations = @($processRelations)
    RestartManagerAvailable = $restartManagerAvailable
    Notes = @(
        'A locked file proves an open/share conflict but does not identify the owning PID without a handle query tool or equivalent OS API.',
        'UNAVAILABLE means PowerShell/CIM could not read the field; it is not an inference.'
    )
} | ConvertTo-Json -Depth 8
