$ErrorActionPreference = 'Stop'
$type = Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RmSmokeTest {
 [StructLayout(LayoutKind.Sequential)] public struct U { public int pid; public System.Runtime.InteropServices.ComTypes.FILETIME start; }
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct I { public U p; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=256)] public string app; [MarshalAs(UnmanagedType.ByValTStr,SizeConst=64)] public string service; public int type; public uint status; public uint session; [MarshalAs(UnmanagedType.Bool)] public bool restart; }
 [DllImport("rstrtmgr.dll",CharSet=CharSet.Unicode)] public static extern int RmStartSession(out uint h,int f,string key);
 [DllImport("rstrtmgr.dll",CharSet=CharSet.Unicode)] public static extern int RmRegisterResources(uint h,uint n,string[] files,uint a,IntPtr apps,uint s,string[] services);
 [DllImport("rstrtmgr.dll")] public static extern int RmGetList(uint h,out uint need,ref uint count,[In,Out] I[] info,ref uint reasons);
 [DllImport("rstrtmgr.dll")] public static extern int RmEndSession(uint h);
 public static int[] Query(string file,out int registerStatus,out int listStatus){uint h;registerStatus=RmStartSession(out h,0,Guid.NewGuid().ToString("N"));listStatus=-1;if(registerStatus!=0)return new int[0];try{registerStatus=RmRegisterResources(h,1,new[]{file},0,IntPtr.Zero,0,null);if(registerStatus!=0)return new int[0];uint need=0,count=0,reasons=0;listStatus=RmGetList(h,out need,ref count,null,ref reasons);if(listStatus!=234&&listStatus!=0)return new int[0];if(need==0)return new int[0];var x=new I[need];count=need;listStatus=RmGetList(h,out need,ref count,x,ref reasons);if(listStatus!=0)return new int[0];var p=new int[count];for(int i=0;i<count;i++)p[i]=x[i].p.pid;return p;}finally{RmEndSession(h);}}
}
'@ -PassThru
$file = Join-Path $env:TEMP ('restart-manager-smoke-' + [guid]::NewGuid().ToString('N') + '.txt')
[IO.File]::WriteAllText($file, 'Restart Manager smoke test')
$stream = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    $rs = 0; $ls = 0; $pids = [RmSmokeTest]::Query($file, [ref]$rs, [ref]$ls)
    [pscustomobject]@{ File = $file; HoldingPID = $PID; RmRegisterResourcesStatus = $rs; RmGetListStatus = $ls; OwnerPIDs = @($pids); APIUsable = ($rs -eq 0) }
} finally { $stream.Dispose() }
