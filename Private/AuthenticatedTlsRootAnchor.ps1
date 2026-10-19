#Requires -Version 7.2
# Lazy native read leases only; importing the module does not open a root.
function Initialize-LabTlsRootAnchorType {
    if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) { throw 'TLS_ANCHOR_WINDOWS_REQUIRED' }
    $existing='SqlServerLab.TlsReadAnchor' -as [type]
    if ($existing) {
        if($script:LabTlsReadAnchorType -ne $existing){throw 'TLS_ANCHOR_TYPE_UNBOUND'}
        return
    }
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;
namespace SqlServerLab {
    // This lease pins only the selected read namespace, never a VM or a writer.
    public sealed class TlsReadAnchor : IDisposable {
        [StructLayout(LayoutKind.Sequential)] struct Info {
            public uint Attr;
            public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        sealed class Entry {
            internal SafeFileHandle Handle;
            internal string Path, Id;
            internal bool Directory;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool GetFileInformationByHandle(SafeFileHandle handle,out Info info);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle,StringBuilder path,uint length,uint flags);
        readonly List<Entry> entries=new List<Entry>();
        readonly Dictionary<string,Entry> files=new Dictionary<string,Entry>(StringComparer.Ordinal);
        readonly object gate=new object();
        readonly int process=Environment.ProcessId;
        readonly string actor=Actor();
        string root, nativeRoot;
        bool disposed;
        TlsReadAnchor() {}
        static string Actor() { using(var id=WindowsIdentity.GetCurrent()){return id.User.Value;} }
        static Exception Bad() { return new InvalidOperationException("TLS_ANCHOR_INVALID"); }
        static string[] Segments(string text) {
            if(String.IsNullOrEmpty(text) || text.Length>4096) throw Bad();
            string[] parts=text.Replace('/','\\').Split('\\');
            if(parts.Length>32) throw Bad();
            foreach(string p in parts) {
                if(p.Length==0 || p=="." || p==".." || p.EndsWith(".") || p.EndsWith(" ") || p.IndexOfAny(new[]{':','<','>','"','|','?','*'})>=0) throw Bad();
                foreach(char c in p) if(c<32 || c==127) throw Bad();
                string stem=p.Split('.')[0];
                if(System.Text.RegularExpressions.Regex.IsMatch(stem,@"\A(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\z",System.Text.RegularExpressions.RegexOptions.IgnoreCase)) throw Bad();
            }
            return parts;
        }
        static string Final(SafeFileHandle h) {
            var b=new StringBuilder(32768);
            uint n=GetFinalPathNameByHandleW(h,b,(uint)b.Capacity,1); // VOLUME_NAME_GUID
            if(n==0 || n>=b.Capacity) throw Bad();
            return b.ToString().TrimEnd('\\');
        }
        static Info CheckedInfo(SafeFileHandle h,bool directory) {
            Info i;
            if(h.IsClosed || h.IsInvalid || !GetFileInformationByHandle(h,out i) || (i.Attr&0x400)!=0 || ((i.Attr&0x10)!=0)!=directory || (!directory && i.Links!=1)) throw Bad();
            return i;
        }
        static string Id(Info i) { return i.Volume.ToString("X8")+":"+i.IndexHigh.ToString("X8")+i.IndexLow.ToString("X8"); }
        Entry OpenEntry(string path,bool directory) {
            if(entries.Count>=64) throw Bad();
            // No write/delete sharing. Existing writers/mappings must also be compatible.
            var h=CreateFileW(path,directory?0x80u:0x80000000u,1,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
            try {
                Info info=CheckedInfo(h,directory);
                var e=new Entry {Handle=h,Path=Final(h),Id=Id(info),Directory=directory};
                entries.Add(e);return e;
            } catch {h.Dispose();throw;}
        }
        public static TlsReadAnchor Open(string path) {
            if(!RuntimeInformation.IsOSPlatform(OSPlatform.Windows) || path==null || !System.Text.RegularExpressions.Regex.IsMatch(path,@"\A[A-Za-z]:[\\/]")) throw Bad();
            string normalized=path.Replace('/','\\');
            if(normalized.Length>4096 || normalized.EndsWith("\\")) throw Bad();
            string[] parts=Segments(normalized.Substring(3));
            string drive=normalized.Substring(0,3);
            var d=new DriveInfo(drive);
            if(d.DriveType!=DriveType.Fixed || !String.Equals(d.DriveFormat,"NTFS",StringComparison.OrdinalIgnoreCase)) throw Bad();
            var lease=new TlsReadAnchor();
            try {
                var top=lease.OpenEntry(drive,true);
                if(!top.Path.StartsWith(@"\\?\Volume{",StringComparison.OrdinalIgnoreCase)) throw Bad();
                string cursor=top.Path;
                foreach(string p in parts) {
                    cursor+="\\"+p;
                    var entry=lease.OpenEntry(cursor,true);
                    if(!String.Equals(entry.Path,cursor,StringComparison.Ordinal)) throw Bad();
                }
                lease.root=normalized;lease.nativeRoot=cursor;
                Verify(lease);return lease;
            } catch {lease.Dispose();throw;}
        }
        void Check() {
            if(disposed || Environment.ProcessId!=process || !String.Equals(Actor(),actor,StringComparison.Ordinal)) throw Bad();
            foreach(var e in entries) if(Id(CheckedInfo(e.Handle,e.Directory))!=e.Id || !String.Equals(Final(e.Handle),e.Path,StringComparison.Ordinal)) throw Bad();
            // A drive-letter alias change cannot silently redirect a later caller.
            using(var h=CreateFileW(root,0x80,1,IntPtr.Zero,3,0x02200000,IntPtr.Zero)) {
                CheckedInfo(h,true);
                if(!String.Equals(Final(h),nativeRoot,StringComparison.Ordinal)) throw Bad();
            }
        }
        public static void Verify(TlsReadAnchor lease) { if(lease==null) throw Bad();lock(lease.gate){lease.Check();} }
        public static byte[] Read(TlsReadAnchor lease,string relative,int maximumBytes) {
            if(lease==null || maximumBytes<1 || maximumBytes>4194304) throw Bad();
            string[] parts=Segments(relative);
            lock(lease.gate) {
                lease.Check();string cursor=lease.nativeRoot;
                for(int n=0;n<parts.Length-1;n++) {
                    cursor+="\\"+parts[n];
                    bool found=false;
                    foreach(var e in lease.entries) if(e.Directory && String.Equals(e.Path,cursor,StringComparison.Ordinal)){found=true;break;}
                    if(!found && !String.Equals(lease.OpenEntry(cursor,true).Path,cursor,StringComparison.Ordinal)) throw Bad();
                }
                cursor+="\\"+parts[parts.Length-1];Entry file;
                if(!lease.files.TryGetValue(cursor,out file)) {
                    file=lease.OpenEntry(cursor,false);
                    if(!String.Equals(file.Path,cursor,StringComparison.Ordinal)) throw Bad();
                    lease.files.Add(cursor,file);
                }
                Info before=CheckedInfo(file.Handle,false);
                ulong size=((ulong)before.SizeHigh<<32)|before.SizeLow;
                if(size<1 || size>(ulong)maximumBytes) throw Bad();
                var bytes=new byte[(int)size];int offset=0;
                while(offset<bytes.Length) {
                    int read=RandomAccess.Read(file.Handle,bytes.AsSpan(offset),offset);
                    if(read==0) throw Bad();offset+=read;
                }
                Info after=CheckedInfo(file.Handle,false);
                if(before.SizeHigh!=after.SizeHigh || before.SizeLow!=after.SizeLow || before.Written.dwHighDateTime!=after.Written.dwHighDateTime || before.Written.dwLowDateTime!=after.Written.dwLowDateTime) throw Bad();
                lease.Check();return bytes;
            }
        }
        public void Dispose() { lock(gate){if(disposed)return;disposed=true;for(int n=entries.Count-1;n>=0;n--)entries[n].Handle.Dispose();} }
    }
}
'@
    $script:LabTlsReadAnchorType='SqlServerLab.TlsReadAnchor' -as [type]
}

function Open-LabTlsRootAnchor {
    [CmdletBinding()]
    param([object]$Path)
    Initialize-LabTlsRootAnchorType
    if ($Path -isnot [string]) { throw 'TLS_ANCHOR_INVALID' }
    return [SqlServerLab.TlsReadAnchor]::Open($Path)
}

function Read-LabTlsAnchoredFile {
    [CmdletBinding()]
    param([object]$Anchor,[object]$RelativePath,[ValidateRange(1,4194304)][int]$MaximumBytes=4194304)
    Initialize-LabTlsRootAnchorType
    if ($Anchor -isnot [SqlServerLab.TlsReadAnchor] -or $RelativePath -isnot [string]) { throw 'TLS_ANCHOR_INVALID' }
    return ,([SqlServerLab.TlsReadAnchor]::Read($Anchor,$RelativePath,$MaximumBytes))
}
