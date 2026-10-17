# Observe a running AIUsageBar process and its descendants without reading secrets.
param([Parameter(Mandatory=$true)][int]$AppProcessId, [int]$Seconds = 600)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
public static class UsageBarWindowObserver {
    delegate void Callback(IntPtr hook, uint evt, IntPtr hwnd, int obj, int child, uint thread, uint time);
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min,uint max,IntPtr mod,Callback cb,uint process,uint thread,uint flags);
    [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr hook);
    [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd,StringBuilder name,int count);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint process);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access,bool inherit,uint pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr handle,int info,IntPtr buffer,int size,out int returned);
    public static List<string> ConsoleEvents = new List<string>();
    public static HashSet<int> Descendants = new HashSet<int>();
    public static List<string> DescendantNames = new List<string>();
    static int root;
    static Callback cb;
    static IntPtr hook;
    static int Parent(int pid) {
        IntPtr h=OpenProcess(0x1000,false,(uint)pid);
        if(h==IntPtr.Zero) return 0;
        IntPtr b=Marshal.AllocHGlobal(IntPtr.Size*6);
        try { int returned; if(NtQueryInformationProcess(h,0,b,IntPtr.Size*6,out returned)!=0) return 0;
            return (int)Marshal.ReadIntPtr(b,IntPtr.Size*5).ToInt64();
        } finally { Marshal.FreeHGlobal(b); CloseHandle(h); }
    }
    static bool Related(int pid) {
        var visited=new HashSet<int>();
        for(int i=0;i<16 && pid>0 && visited.Add(pid);i++) {
            if(pid==root || Descendants.Contains(pid)) return true;
            pid=Parent(pid);
        }
        return false;
    }
    public static void Scan() {
        foreach(var process in Process.GetProcesses()) {
            try { int pid=process.Id;
                if(pid!=root && !Descendants.Contains(pid) && Related(pid)) {
                    Descendants.Add(pid); DescendantNames.Add(process.ProcessName);
                }
            } catch {} finally { process.Dispose(); }
        }
    }
    public static void Start(int pid) {
        root=pid;
        cb=(h,e,w,o,c,t,time)=> {
            if(o!=0 || c!=0 || (e!=0x8000 && e!=0x8002)) return;
            var name=new StringBuilder(256); GetClassName(w,name,256);
            if(name.ToString()!="ConsoleWindowClass" && name.ToString()!="CASCADIA_HOSTING_WINDOW_CLASS") return;
            uint owner; GetWindowThreadProcessId(w,out owner);
            if(Related((int)owner)) ConsoleEvents.Add("event="+e+" process="+owner+" class="+name);
        };
        hook=SetWinEventHook(0x8000,0x8002,IntPtr.Zero,cb,0,0,2);
        if(hook==IntPtr.Zero) throw new Exception("Window event hook failed");
    }
    public static void Stop() { UnhookWinEvent(hook); }
}
'@
[UsageBarWindowObserver]::Start($AppProcessId)
$start = [DateTime]::UtcNow
$nextScan = $start
$nextReport = $start.AddSeconds(60)
try {
    while (([DateTime]::UtcNow - $start).TotalSeconds -lt $Seconds) {
        [System.Windows.Forms.Application]::DoEvents()
        if ([DateTime]::UtcNow -ge $nextScan) {
            [UsageBarWindowObserver]::Scan()
            $nextScan = [DateTime]::UtcNow.AddMilliseconds(250)
        }
        if ([DateTime]::UtcNow -ge $nextReport) {
            if (-not (Get-Process -Id $AppProcessId -ErrorAction SilentlyContinue)) { throw 'AIUsageBar exited during observation' }
            Write-Output ("Observed {0}s; related console events={1}; descendants={2}" -f
                [int]([DateTime]::UtcNow - $start).TotalSeconds, [UsageBarWindowObserver]::ConsoleEvents.Count,
                [UsageBarWindowObserver]::Descendants.Count)
            $nextReport = [DateTime]::UtcNow.AddSeconds(60)
        }
        Start-Sleep -Milliseconds 10
    }
    [pscustomobject]@{
        ObservedSeconds = $Seconds
        RelatedConsoleCreateOrShowEvents = [UsageBarWindowObserver]::ConsoleEvents.Count
        ObservedDescendantProcesses = [UsageBarWindowObserver]::Descendants.Count
        DescendantNames = @([UsageBarWindowObserver]::DescendantNames)
    } | ConvertTo-Json -Compress
    if ([UsageBarWindowObserver]::ConsoleEvents.Count -gt 0) { exit 1 }
} finally { [UsageBarWindowObserver]::Stop() }
