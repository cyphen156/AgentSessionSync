#requires -Version 5.1
# Codex Finish: app-owned validation, normalization, publication trees and recovery.
# Live desktop visibility and cross-machine restoration require separate verification.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare','Cancel','Complete')][string] $Operation,
    [Parameter(Mandatory)][string] $RunId,
    [string] $BaselineCommit = '',
    [string] $RemoteCommit = '',
    [string] $PublishedCommit = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$script:survey = $false
$script:receipt = $null
$script:archiveTitles = @{}
$script:runRoot = ''
$script:warnings = New-Object 'Collections.Generic.List[string]'
$script:finishWatch = [Diagnostics.Stopwatch]::StartNew()
$script:utf8 = New-Object Text.UTF8Encoding($false, $true)

# All native I/O lives in this entry file. There is no Python or module dependency.
# Git transports bytes only; it never checks out, touches the shared index, or fetches.
function Initialize-Native {
Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class CodexFinishNative {

    // Compare decoded JSON/data values without serializing large unchanged histories.
    static object Unwrap(object value) {
        var wrapper=value as System.Management.Automation.PSObject;
        if(wrapper==null)return value;
        if(wrapper.BaseObject is System.Management.Automation.PSCustomObject)return wrapper;
        return Unwrap(wrapper.BaseObject);
    }
    static Dictionary<string,object> Members(object value) {
        var result=new Dictionary<string,object>(StringComparer.Ordinal);
        var dictionary=value as System.Collections.IDictionary;
        if(dictionary!=null){foreach(System.Collections.DictionaryEntry pair in dictionary)result.Add((string)pair.Key,pair.Value);return result;}
        var wrapper=value as System.Management.Automation.PSObject;
        if(wrapper!=null){foreach(var prop in wrapper.Properties)result.Add(prop.Name,prop.Value);return result;}
        return null;
    }
    static int NumberKind(object value) {
        if(value is byte||value is sbyte||value is short||value is ushort||value is int||value is uint||value is long||value is ulong)return 1;
        if(value is double||value is float||value is decimal)return 2;
        return 0;
    }
    public static bool SameData(object left,object right) {
        left=Unwrap(left);right=Unwrap(right);
        if(left==null||right==null)return left==null&&right==null;
        if(left is string||right is string)return left is string&&right is string&&String.Equals((string)left,(string)right,StringComparison.Ordinal);
        if(left is bool||right is bool)return left is bool&&right is bool&&(bool)left==(bool)right;
        int a=NumberKind(left),b=NumberKind(right);
        if(a!=0||b!=0){if(a!=b)return false;if(a==2)return left.GetType()==right.GetType()&&left.Equals(right);try{return Convert.ToDecimal(left)==Convert.ToDecimal(right);}catch{return false;}}
        var lm=Members(left);var rm=Members(right);
        if(lm!=null||rm!=null){if(lm==null||rm==null||lm.Count!=rm.Count)return false;foreach(var p in lm){object v;if(!rm.TryGetValue(p.Key,out v)||!SameData(p.Value,v))return false;}return true;}
        var le=left as System.Collections.IEnumerable;var re=right as System.Collections.IEnumerable;
        if(le!=null||re!=null){if(le==null||re==null)return false;var l=le.GetEnumerator();var r=re.GetEnumerator();while(true){bool ln=l.MoveNext(),rn=r.MoveNext();if(ln!=rn)return false;if(!ln)return true;if(!SameData(l.Current,r.Current))return false;}}
        // Unknown objects are never evidence for reuse.
        return false;
    }


    public static Dictionary<string,string> JsonBlobs(string repo,string[] ids) {
        var si=new ProcessStartInfo("git","cat-file --batch");
        si.WorkingDirectory=repo;si.UseShellExecute=false;si.CreateNoWindow=true;
        si.RedirectStandardInput=true;si.RedirectStandardOutput=true;si.RedirectStandardError=true;
        using(var p=Process.Start(si)) {
            var errors=p.StandardError.ReadToEndAsync();
            // Drain stdout while feeding requests: either pipe can fill with large blobs.
            var sending=System.Threading.Tasks.Task.Run(() => {
                foreach(string id in ids)p.StandardInput.WriteLine(id);
                p.StandardInput.Close();
            });
            try {
                var result=new Dictionary<string,string>(StringComparer.Ordinal);
                var stream=p.StandardOutput.BaseStream;
                foreach(string id in ids) {
                    var header=new StringBuilder();int c;
                    while((c=stream.ReadByte())!=10){if(c<0||header.Length>256)throw new IOException("Invalid git batch header.");header.Append((char)c);}
                    var parts=header.ToString().Split(' ');int size;
                    if(parts.Length!=3||parts[0]!=id||parts[1]!="blob"||!Int32.TryParse(parts[2],out size)||size<0)throw new IOException("Git batch object is missing or not a blob: "+id);
                    var bytes=new byte[size];int offset=0;
                    while(offset<size){int got=stream.Read(bytes,offset,size-offset);if(got==0)throw new IOException("Truncated git batch blob.");offset+=got;}
                    if(stream.ReadByte()!=10)throw new IOException("Invalid git batch terminator.");
                    result[id]=new UTF8Encoding(false,true).GetString(bytes);
                }
                sending.GetAwaiter().GetResult();p.WaitForExit();string error=errors.GetAwaiter().GetResult();
                if(p.ExitCode!=0)throw new IOException("Git batch failed: "+error);
                return result;
            } catch {try{if(!p.HasExited)p.Kill();}catch{};throw;}
        }
    }

    public static string Quote(string s) {
        StringBuilder b=new StringBuilder("\""); int slashes=0;
        foreach(char c in s) { if(c=='\\') { slashes++; continue; }
            if(c=='\"') { b.Append('\\',slashes*2+1); b.Append(c); }
            else { b.Append('\\',slashes); b.Append(c); } slashes=0; }
        b.Append('\\',slashes*2); b.Append('"'); return b.ToString();
    }
    public static string Git(string repo,string[] args,string input,string output) {
        ProcessStartInfo si=new ProcessStartInfo("git");
        si.WorkingDirectory=repo; si.UseShellExecute=false; si.CreateNoWindow=true;
        si.RedirectStandardOutput=true; si.RedirectStandardError=true; si.RedirectStandardInput=true;
        si.StandardOutputEncoding=Encoding.UTF8; si.StandardErrorEncoding=Encoding.UTF8;
        StringBuilder b=new StringBuilder(); foreach(string a in args) b.Append(Quote(a)).Append(' ');
        si.Arguments=b.ToString();
        using(Process p=Process.Start(si)) {
            var errors=p.StandardError.ReadToEndAsync();
            var reading=String.IsNullOrEmpty(output) ? p.StandardOutput.ReadToEndAsync() : null;
            if(!String.IsNullOrEmpty(input)) { using(var f=File.OpenRead(input)) f.CopyTo(p.StandardInput.BaseStream); }
            p.StandardInput.Close();
            if(!String.IsNullOrEmpty(output)) using(var f=new FileStream(output,FileMode.CreateNew)) p.StandardOutput.BaseStream.CopyTo(f);
            string result=reading==null ? "" : reading.GetAwaiter().GetResult();
            p.WaitForExit(); string err=errors.GetAwaiter().GetResult();
            if(p.ExitCode!=0) throw new IOException("git "+args[0]+" failed: "+err.Trim());
            return result;
        }
    }
    public class Line { public string Text; public long End; }
    public static IEnumerable<Line> Lines(string path) {
        using(FileStream f=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read))
        using(MemoryStream line=new MemoryStream()) {
            long pos=0; int c; bool first=true;
            UTF8Encoding utf=new UTF8Encoding(false,true);
            while((c=f.ReadByte())!=-1) { pos++; if(c!=10) {line.WriteByte((byte)c);continue;}
                string text=utf.GetString(line.ToArray()); line.SetLength(0);
                if(first) text=text.TrimStart('\uFEFF'); first=false;
                yield return new Line {Text=text.TrimEnd('\r'),End=pos}; }
            if(line.Length>0) {string text=utf.GetString(line.ToArray());
                if(first) text=text.TrimStart('\uFEFF'); yield return new Line{Text=text.TrimEnd('\r'),End=pos};}
        }
    }
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_open_v2(byte[] file,out IntPtr db,int flags,IntPtr vfs);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_close(IntPtr db);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern IntPtr sqlite3_errmsg(IntPtr db);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_prepare_v2(IntPtr db,byte[] sql,int n,out IntPtr stmt,IntPtr tail);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_step(IntPtr stmt);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_finalize(IntPtr stmt);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_column_count(IntPtr stmt);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern IntPtr sqlite3_column_name(IntPtr stmt,int col);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_column_type(IntPtr stmt,int col);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern IntPtr sqlite3_column_text(IntPtr stmt,int col);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_column_bytes(IntPtr stmt,int col);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern long sqlite3_column_int64(IntPtr stmt,int col);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern double sqlite3_column_double(IntPtr stmt,int col);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_bind_null(IntPtr stmt,int i);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_bind_int64(IntPtr stmt,int i,long val);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_bind_double(IntPtr stmt,int i,double val);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl)] static extern int sqlite3_bind_text(IntPtr stmt,int i,byte[] val,int n,IntPtr destructor);
    static byte[] Z(string s) {return Encoding.UTF8.GetBytes(s+"\0");}
    static string Text(IntPtr ptr,int n=-1) {if(ptr==IntPtr.Zero)return null;
        if(n<0){n=0;while(Marshal.ReadByte(ptr,n)!=0)n++;} byte[] b=new byte[n];Marshal.Copy(ptr,b,0,n);return Encoding.UTF8.GetString(b);}
    public sealed class Db : IDisposable {
        IntPtr db;
        public Db(string path,bool write) {
            if(!File.Exists(path))throw new FileNotFoundException("Required database missing",path);
            int rc=sqlite3_open_v2(Z(path),out db,write?2:1,IntPtr.Zero);
            if(rc!=0){string msg=Text(sqlite3_errmsg(db));Dispose();throw new IOException(msg);}
        }
        public List<Dictionary<string,object>> Query(string sql,object[] values) {
            IntPtr st; if(sqlite3_prepare_v2(db,Z(sql),-1,out st,IntPtr.Zero)!=0)throw new IOException(Text(sqlite3_errmsg(db)));
            try { for(int i=0;i<values.Length;i++) {object v=values[i]; int rc;
                if(v==null||v==DBNull.Value)rc=sqlite3_bind_null(st,i+1);
                else if(v is double||v is float||v is decimal)rc=sqlite3_bind_double(st,i+1,Convert.ToDouble(v));
                else if(v is long||v is int||v is short||v is bool)rc=sqlite3_bind_int64(st,i+1,Convert.ToInt64(v));
                else {byte[] b=Encoding.UTF8.GetBytes(Convert.ToString(v));rc=sqlite3_bind_text(st,i+1,b,b.Length,new IntPtr(-1));}
                if(rc!=0)throw new IOException(Text(sqlite3_errmsg(db))); }
                var rows=new List<Dictionary<string,object>>();int step;
                while((step=sqlite3_step(st))==100){var row=new Dictionary<string,object>();
                    for(int c=0;c<sqlite3_column_count(st);c++){object v=null;int t=sqlite3_column_type(st,c);
                        if(t==1)v=sqlite3_column_int64(st,c);else if(t==2)v=sqlite3_column_double(st,c);
                        else if(t==3)v=Text(sqlite3_column_text(st,c),sqlite3_column_bytes(st,c));
                        else if(t!=5)throw new IOException("Unsurveyed SQLite value type");
                        row[Text(sqlite3_column_name(st,c))]=v;}rows.Add(row);}
                if(step!=101)throw new IOException(Text(sqlite3_errmsg(db)));return rows;
            } finally{sqlite3_finalize(st);}
        }
        public void Dispose(){if(db!=IntPtr.Zero){sqlite3_close(db);db=IntPtr.Zero;}}
    }
}
"@
}

function Write-FinishProgress([string]$Message) {
    Write-Host ('PROGRESS: {0} +{1:N1}s {2}' -f (Get-Date -Format 'HH:mm:ss'), $script:finishWatch.Elapsed.TotalSeconds, $Message)
}
function Field($Value,[string]$Name,$Default=$null) {
    if ($null -eq $Value) { return $Default }
    if ($Value -is [Collections.IDictionary]) { if ($Value.Keys -contains $Name) { return $Value[$Name] }; return $Default }
    $p=$Value.PSObject.Properties[$Name]; if ($null -ne $p) { return $p.Value }; return $Default
}
function Read-Json([string]$Path) { return Parse-Json ([IO.File]::ReadAllText($Path,$script:utf8)) }
function Parse-Json([string]$Text) {
    if ($PSVersionTable.PSVersion.Major -ge 7 -and (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        return ConvertFrom-Json -InputObject $Text -DateKind String
    }
    return ConvertFrom-Json -InputObject $Text
}
function Json($Value) { return ConvertTo-Json -InputObject $Value -Depth 90 -Compress }
function Write-Json([string]$Path,$Value) {
    $temp=$Path+'.new'; [IO.File]::WriteAllText($temp,(Json $Value),$script:utf8)
    if ([IO.File]::Exists($Path)) { $old=$Path+'.previous'; [IO.File]::Replace($temp,$Path,$old); [IO.File]::Delete($old) }
    else { [IO.File]::Move($temp,$Path) }
}
function Survey([string]$Message) { $script:survey=$true; throw $Message }
function Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Require-Id([string]$Id) { if($Id -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { Survey "Invalid session identifier: $Id" } }
function Get-RolloutComparisonPath([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    # Compare ordinary and extended Windows paths in the same namespace.
    # Keep extended paths intact: do not reinterpret their literal components.
    # This only builds a comparison key; app paths and original bytes stay intact.
    if ($full.StartsWith('\\?\') -or $full.StartsWith('\\.\')) { return $full }
    if ($full.StartsWith('\\')) { return '\\?\UNC\'+$full.Substring(2) }
    return '\\?\'+$full
}
function Resolve-Within([string]$Root,[string]$Relative) {
    if ([IO.Path]::IsPathRooted($Relative)) { throw "Absolute child path is forbidden: $Relative" }
    $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $full=[IO.Path]::GetFullPath((Join-Path $rootFull $Relative))
    if (-not $full.StartsWith($rootFull+'\',[StringComparison]::OrdinalIgnoreCase)) { throw "Path escapes root: $Relative" }
    $cursor=$full
    while($cursor.Length -ge $rootFull.Length) {
        if (Test-Path -LiteralPath $cursor) { if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point is not a safe payload path: $cursor" } }
        $parent=[IO.Path]::GetDirectoryName($cursor); if(-not $parent -or $parent -eq $cursor){break}; $cursor=$parent
    }
    return $full
}
function Git([string[]]$Arguments,[string]$InputFile=$null,[string]$OutputFile=$null) {
    return [CodexFinishNative]::Git($script:repo,$Arguments,$InputFile,$OutputFile).TrimEnd("`r","`n")
}
$script:verifiedObjects=@{}
function Object-Id([string]$Value,[string]$Type) {
    $key=$Value+'/'+$Type;if($script:verifiedObjects.ContainsKey($key)){return}
    if ($Value -notmatch '^[a-f0-9]{40}([a-f0-9]{24})?$' -or (Git @('cat-file','-t',$Value)) -ne $Type) { throw "Invalid $Type object: $Value" }
    $script:verifiedObjects[$key]=$true
}
function Save-Receipt { Write-Json (Join-Path $script:runRoot 'receipt.json') $script:receipt }
function Report([string]$Result,[string]$Reason,[string]$Detail) {
    Write-Output "RESULT: $Result"; Write-Output 'AGENT: Codex'; Write-Output 'PHASE: Finish'
    Write-Output ('REASON: '+($Reason -replace '[\r\n]+',' ')); Write-Output ('DETAIL: '+($Detail -replace '[\r\n]+',' '))
    $pub='NONE'; if($Operation -eq 'Complete' -and $PublishedCommit){$pub=$PublishedCommit}
    Write-Output "PUBLISHED_COMMIT: $pub"; Write-Output "SURVEY_REQUIRED: $script:survey"
}
function Query([string]$Path,[string]$Sql,[object[]]$Values=@()) {
    $db=New-Object CodexFinishNative+Db($Path,$false)
    try { return ,$db.Query($Sql,$Values).ToArray() } finally { $db.Dispose() }
}
function Ordered-Value($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [Collections.IDictionary] -or $Value -is [pscustomobject]) {
        $keys = if ($Value -is [Collections.IDictionary]) { @($Value.Keys) } else { @($Value.PSObject.Properties.Name) }
        $ordered = [ordered]@{}
        foreach ($key in @($keys | Sort-Object -CaseSensitive)) {
            if ($Value -is [Collections.IDictionary]) { $v = $Value[$key] } else { $v = $Value.PSObject.Properties[$key].Value }
            $ordered[$key] = Ordered-Value $v
        }
        return $ordered
    }
    if ($Value -is [array]) {
        $items = [object[]]::new($Value.Count)
        for ($i=0; $i -lt $Value.Count; $i++) { $items[$i] = Ordered-Value $Value[$i] }
        return ,$items
    }
    return $Value
}
function Rows-Equal($Left,$Right) { return (Json (Ordered-Value $Left)) -ceq (Json (Ordered-Value $Right)) }

# Recovery intents are durable before writes. A failed partial Prepare remains cancellable.
function Add-Intent($Intent) {
    $Intent['applied']=$false
    $script:receipt.intents += @($Intent); Save-Receipt
}
function Apply-Intent($Intent) {
    if($Intent.kind-eq'removeFile') {
        if(-not[IO.File]::Exists($Intent.backup)-or(Hash $Intent.backup)-ne$Intent.hash){throw 'Archive backup is missing or changed.'}
        if(-not[IO.File]::Exists($Intent.source)-or(Hash $Intent.source)-ne$Intent.hash){throw 'Original changed after backup; not removed.'}
        [IO.File]::Delete($Intent.source)
        if([IO.File]::Exists($Intent.source)){throw 'Archived original remains in app storage.'}
        return
    }
    if ($Intent.kind -eq 'move') {
        if ([IO.File]::Exists($Intent.destination)) { throw "Archive destination appeared: $($Intent.destination)" }
        if (-not [IO.File]::Exists($Intent.source) -or (Hash $Intent.source) -ne $Intent.hash) {
            throw "Original changed after backup: $($Intent.source)"
        }
        [IO.File]::Move($Intent.source, $Intent.destination)
        if ((Hash $Intent.destination) -ne $Intent.hash) { throw 'Archive byte verification failed.' }
        return
    }
    if ($Intent.kind -eq 'global') {
        if ((Hash $Intent.path) -ne $Intent.beforeHash) { throw 'Global app state changed after backup.' }
        $temp = $Intent.path + '.agent-sync-' + $RunId
        [IO.File]::WriteAllText($temp, $Intent.afterText, $script:utf8)
        try { [IO.File]::Replace($temp, $Intent.path, $Intent.backup + '.replace') }
        finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
        if ((Hash $Intent.path) -ne $Intent.afterHash) { throw 'Global app state write verification failed.' }
        return
    }
    if ($Intent.kind -notin @('sql','sqlRows')) { throw 'Unknown recovery intent.' }
    $db = New-Object CodexFinishNative+Db($Intent.path, $true)
    try {
        $db.Query('BEGIN IMMEDIATE', @()) | Out-Null
        if (-not (Rows-Equal $db.Query($Intent.query, @($Intent.keys)).ToArray() $Intent.before)) {
            throw 'App row changed after validation. Nothing was overwritten.'
        }
        $db.Query($Intent.forward, @($Intent.forwardValues)) | Out-Null
        if (-not (Rows-Equal $db.Query($Intent.query, @($Intent.keys)).ToArray() $Intent.after)) {
            throw 'App row normalization verification failed.'
        }
        if ($Intent.notifyCatalog) {
            $db.Query('UPDATE local_thread_catalog_metadata SET catalog_revision=catalog_revision+1 WHERE id=1', @()) | Out-Null
        }
        $db.Query('COMMIT', @()) | Out-Null
    } catch { try { $db.Query('ROLLBACK', @()) | Out-Null } catch {}; throw }
    finally { $db.Dispose() }
}

function Assert-ArchiveTriggers([string]$Path,[string]$Table) {
    # Definitions read on 2026-09-05. DELETE does not fire these timestamp
    # triggers. Cancel corrects INSERT defaults to the recorded before-image.
    # Never approve a trigger by name alone: changed bodies remain unknown.
    $known=@{
        threads_created_at_ms_after_insert='CREATE TRIGGER threads_created_at_ms_after_insert AFTER INSERT ON threads WHEN NEW.created_at_ms IS NULL BEGIN UPDATE threads SET created_at_ms = NEW.created_at * 1000 WHERE id = NEW.id; END'
        threads_updated_at_ms_after_insert='CREATE TRIGGER threads_updated_at_ms_after_insert AFTER INSERT ON threads WHEN NEW.updated_at_ms IS NULL BEGIN UPDATE threads SET updated_at_ms = NEW.updated_at * 1000 WHERE id = NEW.id; END'
        threads_created_at_ms_after_update='CREATE TRIGGER threads_created_at_ms_after_update AFTER UPDATE OF created_at ON threads WHEN NEW.created_at != OLD.created_at AND NEW.created_at_ms IS OLD.created_at_ms BEGIN UPDATE threads SET created_at_ms = NEW.created_at * 1000 WHERE id = NEW.id; END'
        threads_updated_at_ms_after_update='CREATE TRIGGER threads_updated_at_ms_after_update AFTER UPDATE OF updated_at ON threads WHEN NEW.updated_at != OLD.updated_at AND NEW.updated_at_ms IS OLD.updated_at_ms BEGIN UPDATE threads SET updated_at_ms = NEW.updated_at * 1000 WHERE id = NEW.id; END'
        threads_recency_at_after_insert='CREATE TRIGGER threads_recency_at_after_insert AFTER INSERT ON threads WHEN NEW.recency_at_ms = 0 BEGIN UPDATE threads SET recency_at = NEW.updated_at, recency_at_ms = COALESCE(NEW.updated_at_ms, NEW.updated_at * 1000) WHERE id = NEW.id; END'
    }
    $known['thread_realtime_items_projection_cleanup']='CREATE TRIGGER thread_realtime_items_projection_cleanup AFTER DELETE ON thread_history_projection_state BEGIN DELETE FROM thread_realtime_items WHERE thread_id = OLD.thread_id; END'
    $triggers=Query $Path 'SELECT name,sql FROM sqlite_master WHERE type=? AND tbl_name=?' @('trigger',$Table)
    foreach($trigger in $triggers){
        $name=[string]$trigger['name'];$sql=[regex]::Replace([string]$trigger['sql'],'\s+',' ').Trim()
        if(($Table-ne'threads'-and-not($Table-eq'thread_history_projection_state'-and$name-eq'thread_realtime_items_projection_cleanup'))-or-not$known.ContainsKey($name)-or$sql-cne$known[$name]){
            Survey "Unsurveyed trigger definition on $Table : $name; no app changes made."
        }
    }
}


function Plan-RemovedRows([string]$Path,[string]$Table,[string]$Where,[object[]]$Keys,[bool]$Notify=$false) {
    Assert-ArchiveTriggers $Path $Table
    $query='SELECT rowid AS _sync_rowid,* FROM "'+$Table+'" WHERE '+$Where+' ORDER BY rowid'
    $before=Query $Path $query $Keys
    return [ordered]@{
        kind='sqlRows';path=$Path;table=$Table;query=$query;keys=$Keys
        before=$before;after=@();forward=('DELETE FROM "'+$Table+'" WHERE '+$Where)
        forwardValues=$Keys;notifyCatalog=$Notify
    }
}
function Restore-RemovedRows($Db,$Intent) {
    # Restore exact before-images, including nulls and row ordering. Known
    # INSERT timestamp triggers may fill defaults; correct them before checking.
    foreach($row in @($Intent.before)) {
        $columns=if($row-is[Collections.IDictionary]){@($row.Keys)}else{@($row.PSObject.Properties.Name)}
        $columns=@($columns|Where-Object{$_-ne'_sync_rowid'})
        foreach($column in $columns){if($column-notmatch'^[a-z_][a-z_0-9]*$'){throw 'Invalid recorded column; recovery retained.'}}
        $names=@($columns|ForEach-Object{'"'+$_+'"'})
        $marks=@($columns|ForEach-Object{'?'})
        $values=[object[]]::new($columns.Count+1)
        $values[0]=Field $row '_sync_rowid'
        for($i=0;$i-lt$columns.Count;$i++){$values[$i+1]=Field $row $columns[$i]}
        $Db.Query(('INSERT INTO "'+$Intent.table+'" (rowid,'+($names-join',')+') VALUES (?,'+($marks-join',')+')'),$values)|Out-Null
        $updates=@($names|ForEach-Object{$_+'=?'})
        $correct=[object[]]::new($columns.Count+1)
        for($i=0;$i-lt$columns.Count;$i++){$correct[$i]=$values[$i+1]}
        $correct[$columns.Count]=$values[0]
        $Db.Query(('UPDATE "'+$Intent.table+'" SET '+($updates-join',')+' WHERE rowid=?'),$correct)|Out-Null
    }
}

function Plan-AppRemovals($Local) {
    $plans = New-Object 'Collections.Generic.List[object]'
    $ids = New-Object 'Collections.Generic.List[string]'
    $statePath = Resolve-Within $script:appHome 'state_5.sqlite'
    $catalogPath = Resolve-Within $script:appHome 'sqlite/codex-dev.db'
    $historyPath = Resolve-Within $script:appHome 'thread_history_1.sqlite'
    $lineage=New-Object 'Collections.Generic.HashSet[string]'
    $originals=@{}
    foreach ($session in $Local.Values) {
        if (-not $session.NeedsRemoval) { continue }
        $id=[string]$session.Manifest.canonicalId
        $ids.Add($id)
        Write-FinishProgress ("Vault {2} planned: {0} ({1}); complete app removal after verified backup" -f $id,([string]$session.Manifest.comparison.title -replace '[\r\n]+',' '),$session.RemovalState)
        foreach($ancestor in @($session.Manifest.lineageIds)){[void]$lineage.Add([string]$ancestor)}
        [void]$lineage.Add($id)
        foreach($file in $session.LocalPages) {
            if($originals.ContainsKey($file.Path)){throw 'Two removal targets share an original; nothing changed.'}
            $originals[$file.Path]=$true
            $plans.Add([ordered]@{kind='removeFile';source=$file.Path;hash=$file.Sha256;backup=''})
        }
    }
    if($ids.Count-eq0){return ,@()}
    # Both policies remove the app projection after backup. Vault Archived keeps
    # the complete transport; a native-app archive is the user's delete transit
    # and publishes only Deleted. This code never creates a native archive flag.
    $marks=(@($ids|ForEach-Object{'?'})-join',')
    $keys=$ids.ToArray()
    foreach($table in @('thread_dynamic_tools','thread_artifacts')) {
        $plans.Add((Plan-RemovedRows $statePath $table ('thread_id IN ('+$marks+')') $keys))
    }
    $plans.Add((Plan-RemovedRows $statePath 'thread_spawn_edges' ('parent_thread_id IN ('+$marks+') OR child_thread_id IN ('+$marks+')') @($keys+$keys)))
    # Children first; Cancel restores the parent before its children.
    $plans.Add((Plan-RemovedRows $statePath 'threads' ('id IN ('+$marks+')') $keys))
    $historyKeys=@($lineage|Sort-Object)
    $historyMarks=(@($historyKeys|ForEach-Object{'?'})-join',')
    foreach($table in @('thread_turns','thread_items','thread_realtime_items','thread_history_projection_state')) {
        $plans.Add((Plan-RemovedRows $historyPath $table ('thread_id IN ('+$historyMarks+')') $historyKeys))
    }
    $revision=Db-Table $catalogPath 'local_thread_catalog_metadata' 'WHERE id=1'
    if($revision.Count-ne1-or$null-eq(Field $revision[0] 'catalog_revision')){Survey 'Unsurveyed catalog revision metadata.'}
    $plans.Add((Plan-RemovedRows $catalogPath 'local_thread_catalog' ('thread_id IN ('+$marks+')') $keys $true))
    # Preserve all unrelated index lines, including their original line endings.
    $indexPath=Resolve-Within $script:appHome 'session_index.jsonl'
    if([IO.File]::Exists($indexPath)) {
        $text=[IO.File]::ReadAllText($indexPath,$script:utf8)
        $kept=New-Object Text.StringBuilder
        foreach($line in [regex]::Matches($text,'[^\n]*\n|[^\n]+$')) {
            $body=$line.Value.TrimEnd("`r","`n").TrimStart([char]0xfeff)
            if($body.Trim().Length-eq0-or(Field (Parse-Json $body) 'id')-notin$historyKeys){[void]$kept.Append($line.Value)}
        }
        $afterText=$kept.ToString()
        if($afterText-cne$text){
            $sha=[Security.Cryptography.SHA256]::Create()
            try{$afterHash=([BitConverter]::ToString($sha.ComputeHash($script:utf8.GetBytes($afterText)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
            $plans.Add([ordered]@{kind='global';path=$indexPath;backup='';beforeHash=(Hash $indexPath);afterHash=$afterHash;afterText=$afterText})
        }
    }
    $globalPath = Resolve-Within $script:appHome '.codex-global-state.json'
    if (Test-Path -LiteralPath $globalPath) {
        $global = Read-Json $globalPath
        $atoms = Field $global 'electron-persisted-atom-state'
        $hosts = Field $atoms 'unread-thread-ids-by-host-v1'
        $unread = $null
        if ($null -ne $hosts -and $null -ne $hosts.PSObject.Properties['local']) { $unread = $hosts.PSObject.Properties['local'].Value }
        if ($null -ne $unread) {
            if ($unread -isnot [array] -or @($unread | Where-Object { $_ -isnot [string] }).Count) {
                Survey 'Unsurveyed unread-thread membership format.'
            }
            $remaining = @($unread | Where-Object { $_ -notin $ids.ToArray() })
            if ($remaining.Count -ne $unread.Count) {
                $hosts.local = $remaining
                $afterText = Json $global
                $sha = [Security.Cryptography.SHA256]::Create()
                try { $afterHash = ([BitConverter]::ToString($sha.ComputeHash($script:utf8.GetBytes($afterText)))).Replace('-','').ToLowerInvariant() }
                finally { $sha.Dispose() }
                $plans.Add([ordered]@{kind='global'; path=$globalPath; backup=''; beforeHash=(Hash $globalPath); afterHash=$afterHash; afterText=$afterText})
            }
        }
    }
    # All structure/collision checks have completed. Secure every original and
    # every target row before applying the first mutation.
    foreach ($plan in $plans) {
        if ($plan.kind -in @('move','removeFile','global')) {
            $source = if ($plan.kind -in @('move','removeFile')) { $plan.source } else { $plan.path }
            $expected = if ($plan.kind -in @('move','removeFile')) { $plan.hash } else { $plan.beforeHash }
            $plan.backup = Join-Path $script:runRoot ('backup-'+$script:receipt.intents.Count+'.bin')
            [IO.File]::Copy($source, $plan.backup, $false)
            if ((Hash $plan.backup) -ne $expected -or (Hash $source) -ne $expected) { throw 'Backup does not match validated original.' }
        }
        Add-Intent $plan
    }
    return ,$plans.ToArray()
}
function Restore-Intent($Intent) {
    if($Intent.kind-eq'removeFile') {
        if(-not[IO.File]::Exists($Intent.backup)-or(Hash $Intent.backup)-ne$Intent.hash){throw 'Original backup is missing or changed; recovery retained.'}
        if([IO.File]::Exists($Intent.source)) {
            if((Hash $Intent.source)-ne$Intent.hash){throw 'Cancel refuses to overwrite independently changed original.'}
        } else {
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Intent.source))|Out-Null
            [IO.File]::Copy($Intent.backup,$Intent.source,$false)
        }
        if((Hash $Intent.source)-ne$Intent.hash){throw 'Restored original failed hash verification.'}
        return
    }
    if($Intent.kind -eq 'move') {
        if(-not[IO.File]::Exists($Intent.backup) -or (Hash $Intent.backup) -ne $Intent.hash){throw 'Required original backup is missing or changed.'}
        $source=[IO.File]::Exists($Intent.source);$destination=[IO.File]::Exists($Intent.destination)
        if($source -and (Hash $Intent.source) -ne $Intent.hash){throw "Cancel refuses to overwrite external work: $($Intent.source)"}
        if($destination -and (Hash $Intent.destination) -ne $Intent.hash){throw "Cancel refuses to overwrite external work: $($Intent.destination)"}
        if(-not$source){[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Intent.source))|Out-Null;[IO.File]::Copy($Intent.backup,$Intent.source,$false)}
        if((Hash $Intent.source) -ne $Intent.hash){throw 'Restored original failed hash verification.'}
        if($destination){
            if ($source -and -not (Field $Intent 'applied' $false)) {
                throw 'Both original and archive paths exist without a recorded completed move. Cancel will not delete an unproved copy.'
            }
            [IO.File]::Delete($Intent.destination)
        }
        return
    }
    if ($Intent.kind -eq 'global') {
        if (-not [IO.File]::Exists($Intent.backup) -or (Hash $Intent.backup) -ne $Intent.beforeHash) { throw 'Global-state backup missing or changed.' }
        $current = Hash $Intent.path
        if ($current -eq $Intent.beforeHash) {
            $temp=$Intent.path + '.agent-sync-' + $RunId
            if ([IO.File]::Exists($temp)) {
                if ((Hash $temp) -notin @($Intent.beforeHash,$Intent.afterHash)) { throw 'Recovery temporary file has unexpected bytes; retained.' }
                [IO.File]::Delete($temp)
            }
            return
        }
        if ($current -ne $Intent.afterHash) { throw 'Global app state changed independently. Cancel retains the backup and does not overwrite it.' }
        $temp = $Intent.path + '.agent-sync-' + $RunId
        [IO.File]::Copy($Intent.backup, $temp, $false)
        try { [IO.File]::Replace($temp, $Intent.path, $Intent.backup + '.cancel-replace') }
        finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
        if ((Hash $Intent.path) -ne $Intent.beforeHash) { throw 'Global-state rollback verification failed.' }
        return
    }
    if($Intent.kind -in @('sql','sqlRows')) {
        $db=New-Object CodexFinishNative+Db($Intent.path,$true)
        try {
            $db.Query('BEGIN IMMEDIATE',@())|Out-Null
            $current=$db.Query($Intent.query,@($Intent.keys)).ToArray()
            if(-not(Rows-Equal $current $Intent.before)) {
                if(-not(Rows-Equal $current $Intent.after)){throw 'Cancel found an independently changed app row. Backup retained.'}
                if($Intent.kind-eq'sqlRows'){Restore-RemovedRows $db $Intent}
                else{$db.Query($Intent.reverse,@($Intent.reverseValues))|Out-Null}
                if(-not(Rows-Equal $db.Query($Intent.query,@($Intent.keys)).ToArray() $Intent.before)){throw ('Cancel row verification failed for its recorded target: '+$Intent.query)}
                # This is a notification counter, not a session before-image.
                # Restoring a catalog row notifies readers without rewinding
                # another thread's intervening catalog revisions.
                if ($Intent.notifyCatalog) { $db.Query('UPDATE local_thread_catalog_metadata SET catalog_revision=catalog_revision+1 WHERE id=1', @()) | Out-Null }
            }
            $db.Query('COMMIT',@())|Out-Null
        } catch {try{$db.Query('ROLLBACK',@())|Out-Null}catch{};throw}finally{$db.Dispose()}
        return
    }
    throw 'Unknown recovery intent; retained for inspection.'
}
function Clear-Run {
    # Never follow a junction during cleanup, even in the private run directory.
    $checked=Resolve-Within $script:runsRoot $RunId
    if($checked -ne $script:runRoot){throw 'Run cleanup path mismatch.'}
    foreach($item in Get-ChildItem -LiteralPath $checked -Force -Recurse){
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Run contains a reparse point; cleanup refused.'}
    }
    Remove-Item -LiteralPath $checked -Recurse -Force
}
function Cancel-Run {
    $errors=New-Object 'Collections.Generic.List[string]'
    $items=@($script:receipt.intents)
    for($i=$items.Count-1;$i-ge0;$i--){try{Restore-Intent $items[$i]}catch{$errors.Add($_.Exception.Message)}}
    if($errors.Count){throw ('Cancel incomplete: '+($errors -join '; ')+' Recovery: '+$script:runRoot)}
    $script:receipt.status='cancelled';Save-Receipt
    # Keep the receipt as evidence for idempotent Cancel, but remove backup copies.
    foreach($f in Get-ChildItem -LiteralPath $script:runRoot -File){if($f.Name -notin @('receipt.json')){[IO.File]::Delete($f.FullName)}}
}
function Blob-File([string]$Path) { return Git @('hash-object','-w','--no-filters','--',$Path) }
function Blob-Json($Value) {
    $text=Json $Value;$key=Analysis-Key $text
    if($script:jsonContentIds.ContainsKey($key)){return $script:jsonContentIds[$key]}
    $path=Join-Path $script:runRoot ([guid]::NewGuid().ToString()+'.json')
    [IO.File]::WriteAllText($path,$text,$script:utf8);$oid=Blob-File $path
    $script:jsonContentIds[$key]=$oid
    return $oid
}

$script:madeTrees=@{}

function Entry-Identity($Entries) {
    $lines=New-Object 'Collections.Generic.List[string]'
    foreach($path in @($Entries.Keys|Sort-Object -CaseSensitive)){
        if($path-match '(^/|\\|(^|/)\.\.?(/|$)|[\x00-\x1f])'){throw "Invalid Git payload path: $path"}
        $oid=[string]$Entries[$path]
        if($oid-cnotmatch '^[0-9a-f]{40}([0-9a-f]{24})?$'){throw 'Invalid Git entry identity.'}
        $lines.Add($path+"`0"+$oid+"`0")
    }
    return Analysis-Key ($lines-join '')
}
$script:existingTrees=@{}
$script:reusedTrees=0
function Remember-AppTrees($Entries,$Trees) {
    $sets=@{};$empty=New-Object 'Collections.Generic.List[string]'
    foreach($prefix in $Trees.Keys){
        $children=@{}
        foreach($path in $Entries.Keys){if($path.StartsWith($prefix,[StringComparison]::Ordinal)){$children[$path.Substring($prefix.Length)]=$Entries[$path]}}
        $sets[$prefix]=$children;if(-not$children.Count){$empty.Add($prefix)}
    }
    foreach($prefix in $Trees.Keys){
        $hasEmpty=$false;foreach($missing in $empty){if($missing.StartsWith($prefix,[StringComparison]::Ordinal)){$hasEmpty=$true;break}}
        if(-not$hasEmpty){$script:existingTrees[(Entry-Identity $sets[$prefix])]=$Trees[$prefix]}
    }
}
function Reuse-Json($Value,[string[]]$PriorIds) {
    foreach($oid in @($PriorIds|Where-Object{$_}|Select-Object -Unique)){
        if([CodexFinishNative]::SameData($Value,(Read-BlobJson $oid))){$script:reusedJson++;return $oid}
    }
    return Blob-Json $Value
}
$script:reusedJson=0
$script:reusablePayloads=@{}
function Index-ReusablePayloads($Base,$Remote) {
    $script:reusablePayloads=@{};$lengths=@{}
    foreach($set in @($Base,$Remote)){
        foreach($session in $set.Values){
            if($session.State-eq'Deleted'){continue}
            foreach($payload in @($session.Manifest.payloads)){
                $files=@{}
                $relative=[string]$payload.transportPath
                if($relative.EndsWith('.gz',[StringComparison]::OrdinalIgnoreCase)-or$relative.EndsWith('.gz.parts.json',[StringComparison]::Ordinal)){$files=Get-TransportFiles $session.Entries $session.Prefix $payload}
                else{$files[$relative]=$session.Entries[$session.Prefix+$relative]}
                $key=[string]$payload.path+"`0"+[string]$payload.length+"`0"+[string]$payload.sha256
                $largest=[long]$payload.length
                if($relative.EndsWith('.gz',[StringComparison]::OrdinalIgnoreCase)-or$relative.EndsWith('.gz.parts.json',[StringComparison]::Ordinal)){
                    $largest=0
                    foreach($oid in $files.Values){
                        if(-not$lengths.ContainsKey($oid)){$lengths[$oid]=[long](Transport-Git @('cat-file','-s',$oid))}
                        $largest=[Math]::Max($largest,$lengths[$oid])
                    }
                }
                $script:reusablePayloads[$key]=[pscustomobject]@{Payload=$payload;Files=$files;Largest=$largest}
            }
        }
    }
}

function Make-Tree($Entries) {
    $entryKey=Entry-Identity $Entries
    if($script:existingTrees.ContainsKey($entryKey)){$script:reusedTrees++;return $script:existingTrees[$entryKey]}
    $dirs=@{}; $leaves=@{}
    foreach($path in $Entries.Keys){
        if($path -match '(^/|\\|(^|/)\.\.?(/|$)|[\x00-\x1f])'){throw "Invalid Git payload path: $path"}
        $parts=($path -split '/',2)
        if($parts.Count -eq 1){$leaves[$path]=$Entries[$path]}
        else{if(-not$dirs.ContainsKey($parts[0])){$dirs[$parts[0]]=@{}};$dirs[$parts[0]][$parts[1]]=$Entries[$path]}
    }
    $lines=New-Object 'Collections.Generic.List[string]'
    foreach($name in $leaves.Keys){Object-Id $leaves[$name] 'blob';$lines.Add("100644 blob $($leaves[$name])`t$name`0")}
    foreach($name in $dirs.Keys){if($leaves.ContainsKey($name)){throw 'File/directory collision.'};$tree=Make-Tree $dirs[$name];$lines.Add("040000 tree $tree`t$name`0")}
    $treeKey=Analysis-Key ((@($lines)|Sort-Object -CaseSensitive)-join '')
    if($script:madeTrees.ContainsKey($treeKey)){return $script:madeTrees[$treeKey]}
    $path=Join-Path $script:runRoot ([guid]::NewGuid().ToString()+'.tree')
    [IO.File]::WriteAllText($path,($lines -join ''),$script:utf8)
    $tree=Git @('mktree','-z') $path;$script:madeTrees[$treeKey]=$tree;$script:existingTrees[$entryKey]=$tree;return $tree
}
function Read-AppTree([string]$Commit) {
    $entries=@{}
    if(-not$Commit){return $entries}; Object-Id $Commit 'commit'
    $listing=Git @('ls-tree','-z',$Commit,'--','Codex')
    if(-not$listing){return $entries}
    if($listing -notmatch '^040000 tree ([a-f0-9]+)\tCodex\x00$'){Survey 'Codex is not an app tree in the supplied commit.'}
    $tree=$Matches[1];$trees=@{'/'=$tree}
    foreach($entry in (Git @('ls-tree','-r','-t','-z',$tree)).Split([char]0)){
        if(-not$entry){continue}
        if($entry-match '^040000 tree ([a-f0-9]+)\t(.+)$'){$trees[$Matches[2]+'/']=$Matches[1];continue}
        if($entry -notmatch '^100644 blob ([a-f0-9]+)\t(.+)$'){Survey 'Unsupported app tree entry mode.'}
        $entries[$Matches[2]]=$Matches[1]
    }
    $trees.Remove('/');$trees['']=$tree;Remember-AppTrees $entries $trees
    return $entries
}
# Immutable Git JSON is read and decoded once per invocation. Consumers do not mutate it.
$script:jsonBlobs=@{}
$script:jsonContentIds=@{}
function Read-BlobJson([string]$Oid) {
    if(-not$script:jsonBlobs.ContainsKey($Oid)){Object-Id $Oid 'blob';$text=Git @('cat-file','blob',$Oid);$script:jsonBlobs[$Oid]=Parse-Json $text}
    return $script:jsonBlobs[$Oid]
}

function Prime-JsonBlobs([string[]]$Oids) {
    $pending=@($Oids|Where-Object{-not$script:jsonBlobs.ContainsKey($_)}|Sort-Object -Unique)
    if(-not$pending.Count){return}
    foreach($oid in $pending){if($oid-cnotmatch '^[0-9a-f]{40}([0-9a-f]{24})?$'){throw 'Invalid JSON blob identity.'}}
    $batch=[CodexFinishNative]::JsonBlobs($script:repo,[string[]]$pending)
    foreach($pair in $batch.GetEnumerator()){$script:verifiedObjects[$pair.Key+'/blob']=$true;$script:jsonBlobs[$pair.Key]=Parse-Json $pair.Value;$script:jsonContentIds[(Analysis-Key $pair.Value)]=$pair.Key}
}

function Read-Sessions($Entries) {
    $jsonIds=@($Entries.Keys|Where-Object{$_-match '(^Deleted/[^/]+\.json$|/(manifest|projection)\.json$|\.integrity\.json$|\.gz\.parts\.json$)'}|ForEach-Object{$Entries[$_]})
    Prime-JsonBlobs $jsonIds

    $sessions=@{}
    foreach($path in $Entries.Keys){
        if($path -match '^(Active|Archived)/([^/]+)/manifest.json$') {
            $state=$Matches[1];$id=$Matches[2];Require-Id $id
            if($sessions.ContainsKey($id)){Survey "Session in multiple states: $id"}
            $m=Read-BlobJson $Entries[$path]
            if((Field $m 'schemaVersion') -ne 1 -or (Field $m 'vaultSessionId') -ne $id){Survey "Unknown Codex manifest: $path"}
            Require-Id (Field $m 'canonicalId')
            $sessions[$id]=[pscustomobject]@{State=$state;Manifest=$m;Prefix="$state/$id/";Entries=$Entries}
        } elseif($path -match '^Deleted/([^/]+).json$') {
            $id=$Matches[1];Require-Id $id;$m=Read-BlobJson $Entries[$path]
            if($sessions.ContainsKey($id)){Survey "Session in multiple states: $id"}
            $fields=@($m.PSObject.Properties.Name|Sort-Object)
            if(($fields -join ',') -ne 'deletedAt,lineageIds,schemaVersion,source,vaultSessionId' -or $m.schemaVersion -ne 1 -or $m.vaultSessionId -ne $id){Survey 'Invalid minimal Deleted record.'}
            $sessions[$id]=[pscustomobject]@{State='Deleted';Manifest=$m;Prefix=$path;Entries=$Entries}
        }
    }
    foreach($path in $Entries.Keys){
        $claimed=$false
        foreach($s in $sessions.Values){if(($s.State-eq'Deleted'-and$path-eq$s.Prefix)-or($s.State-ne'Deleted'-and$path.StartsWith($s.Prefix,[StringComparison]::Ordinal))){$claimed=$true;break}}
        if(-not$claimed){Survey "Unexplained Vault payload: $path"}
    }
    return $sessions
}
function Copy-Session($Session,$Output) {
    if($null-eq$Session){return}
    foreach($path in $Session.Entries.Keys){if(($Session.State-eq'Deleted'-and$path-eq$Session.Prefix)-or($Session.State-ne'Deleted'-and$path.StartsWith($Session.Prefix,[StringComparison]::Ordinal))){$Output[$path]=$Session.Entries[$path]}}
}
function Same-Session($A,$B) {
    if($null-eq$A-or$null-eq$B){return $null-eq$A-and$null-eq$B}
    if($A.State-ne$B.State){return $false}
    if($A.State-eq'Deleted'){return Rows-Equal $A.Manifest $B.Manifest}
    return Rows-Equal $A.Manifest.comparison $B.Manifest.comparison
}


# Derived analysis only: local Git refs, never publication/baseline authority.
# Full source hashes also catch predecessor edits with an unchanged latest page.
# Both entry-file hashes invalidate these records when validation code changes.
$script:rolloutAnalysis=@{}
$script:analysedSources=@{}
$script:verifiedStoredPayloads=@{}
$script:analysisRules=''
$script:analysisRefs=$null
function Analysis-Key([string]$Text) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Inspect-Rollout([string]$Path) {
    $before=Get-Item -LiteralPath $Path
    $length=$before.Length;$stamp=$before.LastWriteTimeUtc.Ticks
    $raw=Hash $Path
    $afterHash=Get-Item -LiteralPath $Path
    if($afterHash.Length-ne$length-or$afterHash.LastWriteTimeUtc.Ticks-ne$stamp){throw "Rollout changed during change detection: $Path"}
    if(-not$script:analysisRules){
        $script:analysisRules=Analysis-Key ((Hash (Join-Path $PSScriptRoot 'Start.ps1'))+':'+(Hash (Join-Path $PSScriptRoot 'Finish.ps1')))
    }
    if($null-eq$script:analysisRefs){
        $script:analysisRefs=@{}
        try{
            foreach($line in (Git @('for-each-ref','--format=%(refname) %(objectname)','refs/agent-session-sync/codex-analysis-v1/')).Split("`n")){
                if(-not$line){continue};$parts=$line.Trim().Split(' ')
                if($parts.Count-ne2){throw 'Invalid analysis ref listing.'};$script:analysisRefs[$parts[0]]=$parts[1]
            }
            Prime-JsonBlobs ([string[]]@($script:analysisRefs.Values))
        }catch{$script:analysisRefs=@{};Write-FinishProgress 'Analysis cache could not be read; full validation remains available'}
    }
    $name=[IO.Path]::GetFileName($Path)
    $key=$raw+'/'+(Analysis-Key $name)
    # One ref per physical filename replaces superseded analysis; no ref per append.
    $ref='refs/agent-session-sync/codex-analysis-v1/'+(Analysis-Key $name)
    $page=$null
    if($script:rolloutAnalysis.ContainsKey($key)){$page=$script:rolloutAnalysis[$key]}
    else {
        $oid='';if($script:analysisRefs.ContainsKey($ref)){$oid=$script:analysisRefs[$ref]}
        if($oid){
            try{
                $saved=Read-BlobJson $oid
                if($saved.schemaVersion-ne1-or$saved.rules-cne$script:analysisRules-or$saved.sha256-cne$raw-or[long]$saved.length-ne$length-or$saved.name-cne$name){throw 'Analysis identity differs.'}
                $b=@{};foreach($p in $saved.boundaries.PSObject.Properties){$b[$p.Name]=[long]$p.Value}
                $last=$null;if($saved.last){$last=[DateTimeOffset]::Parse([string]$saved.last,[Globalization.CultureInfo]::InvariantCulture)}
                $page=[pscustomobject]@{Path=$Path;Name=$name;Id=[string]$saved.id;Alias=[string]$saved.alias;Meta=$saved.meta;Last=$last;Boundaries=$b;Texts=@($saved.texts);Length=$length;Sha256=$raw}
            }catch{Write-FinishProgress ("Analysis cache unavailable; validating original: {0}" -f $name)}
        }
    }
    if($null-ne$page){
        $page.Path=$Path
        $script:analysedSources[$Path]=$raw
        $script:rolloutAnalysis[$key]=$page
        Write-FinishProgress ("Reusing verified rollout analysis: {0}" -f $name)
        return $page
    }
    $page=Inspect-RolloutFull $Path
    $after=Get-Item -LiteralPath $Path
    if($page.Sha256-cne$raw-or$after.Length-ne$length-or$after.LastWriteTimeUtc.Ticks-ne$stamp){throw "Rollout changed during analysis: $Path"}
    $saved=[ordered]@{schemaVersion=1;rules=$script:analysisRules;sha256=$raw;length=$length;name=$name;id=$page.Id;alias=$page.Alias;meta=$page.Meta;last=$(if($null-ne$page.Last){$page.Last.ToUniversalTime().ToString('o')}else{$null});boundaries=$page.Boundaries;texts=@($page.Texts)}
    try{$oid=Blob-Json $saved;Git @('update-ref',$ref,$oid)|Out-Null}
    catch{Write-FinishProgress ('Analysis cache could not be saved; original validation still completed: '+$name)}
    $script:rolloutAnalysis[$key]=$page
    $script:analysedSources[$Path]=$raw
    return $page
}

function Inspect-RolloutFull([string]$Path) {
    $types=@('session_meta','event_msg','response_item','world_state','turn_context','compacted','inter_agent_communication_metadata','token_usage_record')
    $versions=@('0.146.0-alpha.9.2','0.147.0-alpha.6.6','0.149.0-alpha.4.3','0.150.0-alpha.8','0.151.0-alpha.7.1','0.151.0-alpha.7.2','0.152.0','0.153.0-alpha.5','0.153.1','0.153.3')
    $meta=$null;$last=$null;$count=0;$boundaries=@{};$userTexts=New-Object 'Collections.Generic.List[string]'
    $lastProgress=$script:finishWatch.Elapsed.TotalSeconds
    foreach($line in [CodexFinishNative]::Lines($Path)) {
        if(-not$line.Text){throw "Empty record in rollout: $Path"}
        try{$record=Parse-Json $line.Text}catch{throw "Invalid JSON record in rollout: $Path, record $count"}
        $type=[string](Field $record 'type');$payload=Field $record 'payload'
        if($type -notin $types){Survey "Unsurveyed record type '$type' in $Path"}
        if($count-eq0){if($type-ne'session_meta'){Survey "Missing initial session_meta: $Path"};$meta=$payload}
        $ordinal=Field $record 'ordinal' $count
        if($ordinal -isnot [int] -and $ordinal -isnot [long]){Survey "Non-integer record ordinal: $Path"}
        $boundaries[[string]$line.End]=[long]$ordinal+1
        $dialogue=$false
        if($type-eq'event_msg'-and(Field $payload 'type')-in@('user_message','agent_message')){
            $dialogue=$true;if((Field $payload 'type')-eq'user_message'){$userTexts.Add([string](Field $payload 'message' ''))}
        }
        if($type-eq'response_item'-and(Field $payload 'type')-eq'message'-and(Field $payload 'role')-in@('user','assistant')){
            $dialogue=$true
            if((Field $payload 'role')-eq'user'){foreach($part in @(Field $payload 'content' @())){if((Field $part 'type')-in@('input_text','text')){$userTexts.Add([string](Field $part 'text' ''))}}}
        }
        if($dialogue){
            $stamp=[string](Field $record 'timestamp' '')
            $parsed=[DateTimeOffset]::MinValue
            if(-not[DateTimeOffset]::TryParse($stamp,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$parsed)){throw "Dialogue timestamp missing or invalid: $Path"}
            if($null-eq$last-or$parsed-gt$last){$last=$parsed}
        }
        $count++
        if($count%2000-eq0-and($script:finishWatch.Elapsed.TotalSeconds-$lastProgress)-ge5){
            Write-FinishProgress ("Reading original: {0}; records={1}; bytes={2}" -f [IO.Path]::GetFileName($Path),$count,$line.End)
            $lastProgress=$script:finishWatch.Elapsed.TotalSeconds
        }
    }
    if($null-eq$meta){throw "Empty rollout: $Path"};$id=[string](Field $meta 'id');Require-Id $id
    $version=[string](Field $meta 'cli_version')
    if($version-notin$versions){$script:warnings.Add("Previously unlisted rollout version: $version ($Path). Storage may have changed; version alone does not block this run. Actual structure checks still apply.")}
    $mode=[string](Field $meta 'history_mode' 'legacy');if($mode-notin@('legacy','paginated')){Survey "Unsurveyed history mode: $mode"}
    $source=[string](Field $meta 'thread_source' 'user')
    if($source-notin@('user','agent_created_thread','guardian_review')){Survey "Unsurveyed thread source: $source"}
    $session=[string](Field $meta 'session_id' $id)
    if($source-ne'guardian_review'-and$session-ne$id){Survey "Contradictory canonical/session identity: $Path"}
    if($source-eq'guardian_review'-and(Field $meta 'parent_thread_id')-ne$session){Survey "Contradictory guardian parent: $Path"}
    $name=[IO.Path]::GetFileNameWithoutExtension($Path)
    if($name-notmatch '([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})$'){Survey "Unrecognised physical rollout name: $Path"}
    return [pscustomobject]@{Path=$Path;Name=[IO.Path]::GetFileName($Path);Id=$id.ToLowerInvariant();Alias=$Matches[1].ToLowerInvariant();Meta=$meta;Last=$last;Boundaries=$boundaries;Texts=$userTexts.ToArray();Length=(Get-Item -LiteralPath $Path).Length;Sha256=(Hash $Path)}
}
function Assert-History($Pages) {
    $aliases=@{}
    foreach($page in $Pages){if($aliases.ContainsKey($page.Alias)){Survey "Duplicate physical page identifier: $($page.Alias)"};$aliases[$page.Alias]=$page}
    foreach($page in $Pages){
        $h=Field $page.Meta 'history_base';if($null-eq$h){continue}
        $pred=[string](Field $h 'thread_id');Require-Id $pred
        if(-not$aliases.ContainsKey($pred)){throw "Missing predecessor $pred required by $($page.Name)"}
        $previous=$aliases[$pred];if($previous.Id-ne$page.Id-or$pred-eq$page.Alias){throw "Contradictory history predecessor for $($page.Name)"}
        $offset=[string](Field $h 'end_byte_offset');$ordinal=Field $h 'end_ordinal_exclusive'
        if(-not$previous.Boundaries.ContainsKey($offset)-or$previous.Boundaries[$offset]-ne$ordinal){throw "History byte/ordinal boundary mismatch: $($page.Name) -> $pred ($offset, $ordinal)"}
        $seen=@{};$cursor=$page
        while($null-ne(Field $cursor.Meta 'history_base')){
            if($seen.ContainsKey($cursor.Alias)){throw 'Cyclic predecessor chain.'};$seen[$cursor.Alias]=$true
            $ref=[string](Field (Field $cursor.Meta 'history_base') 'thread_id')
            if(-not$aliases.ContainsKey($ref)){throw "Missing predecessor: $ref"};$cursor=$aliases[$ref]
        }
    }
}
function Db-Table([string]$Path,[string]$Table,[string]$Where='',[object[]]$Values=@()) {
    if($Table-notmatch '^[a-z_][a-z_0-9]*$'){throw 'Invalid table name.'}
    $found=Query $Path 'SELECT name FROM sqlite_master WHERE type=? AND name=?' @('table',$Table)
    if($found.Count-ne1){Survey "Required surveyed table missing: $Table ($Path)"}
    $known = @{
        threads='id rollout_path created_at updated_at source model_provider cwd title sandbox_policy approval_mode tokens_used has_user_event archived archived_at git_sha git_branch git_origin_url cli_version first_user_message agent_nickname agent_role memory_mode model reasoning_effort agent_path created_at_ms updated_at_ms thread_source preview recency_at recency_at_ms history_mode name is_pinned thread_section_id section_position section_entered_at_ms project_id'
        local_thread_catalog='host_id thread_id display_title source_created_at source_updated_at cwd source_kind source_detail model_provider git_branch observation_sequence missing_candidate thread_source source_recency_at pending_observed_title project_id conversation_origin'
        local_thread_catalog_metadata='id catalog_revision'
    }
    if ($known.ContainsKey($Table)) {
        $columns=Query $Path ('PRAGMA table_info("'+$Table+'")')
        foreach($column in $columns){if($column['name'] -notin $known[$Table].Split(' ')){Survey "Unsurveyed $Table column: $($column['name'])"}}
    }
    return ,(Query $Path ('SELECT * FROM "'+$Table+'" '+$Where) $Values)
}
# Walk a snapshot once. Retain matching ancestors so selection preserves the
# original recursive rule: a selected property owns its whole subtree.
function Add-GlobalReferenceEntries($Value,$KnownIds,[string]$Path,[string[]]$Blockers,$Entries) {
    if($null-eq$Value){return}
    if($Value-is[pscustomobject]){
        foreach($property in $Value.PSObject.Properties){
            $next=$Path+'/'+($property.Name.Replace('~','~0').Replace('/','~1'))
            $childBlockers=$Blockers
            if($KnownIds.Contains($property.Name)){
                $Entries.Add([pscustomobject]@{Id=$property.Name;Pointer=$next;Value=$property.Value;Blockers=$Blockers})
                $childBlockers=@($Blockers)+@($property.Name)
            }
            Add-GlobalReferenceEntries $property.Value $KnownIds $next $childBlockers $Entries
        }
    }elseif($Value-is[array]){
        for($i=0;$i-lt$Value.Count;$i++){Add-GlobalReferenceEntries $Value[$i] $KnownIds ($Path+'/'+$i) $Blockers $Entries}
    }elseif($Value-is[string]-and$KnownIds.Contains($Value)){
        $Entries.Add([pscustomobject]@{Id=$Value;Pointer=$Path;Value=$Value;Blockers=$Blockers})
    }
}
function New-GlobalReferenceIndex($Value,[string[]]$Ids) {
    $known=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($id in $Ids){[void]$known.Add($id)}
    $entries=New-Object 'Collections.Generic.List[object]'
    Add-GlobalReferenceEntries $Value $known '' @() $entries
    return ,$entries.ToArray()
}
function Selected-Global($Index,[string[]]$Ids) {
    $wanted=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($id in $Ids){[void]$wanted.Add($id)}
    $result=New-Object 'Collections.Generic.List[object]'
    foreach($entry in $Index){
        if(-not$wanted.Contains($entry.Id)){continue}
        $blocked=$false
        foreach($ancestor in $entry.Blockers){if($wanted.Contains($ancestor)){$blocked=$true;break}}
        if(-not$blocked){$result.Add([ordered]@{pointer=$entry.Pointer;value=$entry.Value})}
    }
    return ,$result.ToArray()
}
$script:transportRaw=@{}
$script:transportSources=@{}
function Transport-Git([string[]]$Arguments,[string]$InputFile=$null) {
    return Git $Arguments $InputFile
}
function Transport-Json($Value) { return ConvertTo-Json -InputObject $Value -Depth 30 -Compress }
function Transport-Blob($Value) {
    $file=Join-Path $script:runRoot ([guid]::NewGuid().ToString('N')+'.marker')
    try{[IO.File]::WriteAllText($file,(Transport-Json $Value),(New-Object Text.UTF8Encoding($false)));return Transport-Git @('hash-object','-w','--no-filters','--',$file)}finally{if([IO.File]::Exists($file)){[IO.File]::Delete($file)}}
}
function Transport-Tree($Entries) {
    $dirs=@{};$leaves=@{}
    foreach($path in $Entries.Keys){
        if(-not$path-or$path-match'(^/|\\|(^|/)\.\.?(/|$)|[\x00-\x1f])'){throw "Unsafe transport marker path: $path"}
        $pieces=$path-split'/',2
        if($pieces.Count-eq1){$leaves[$path]=$Entries[$path]}else{if(-not$dirs.ContainsKey($pieces[0])){$dirs[$pieces[0]]=@{}};$dirs[$pieces[0]][$pieces[1]]=$Entries[$path]}
    }
    $lines=New-Object 'Collections.Generic.List[string]'
    foreach($name in $leaves.Keys){$oid=[string]$leaves[$name];if($oid-cnotmatch'^[0-9a-f]{40,64}$'){throw 'Invalid transport blob ID.'};$lines.Add("100644 blob $oid`t$name`0")}
    foreach($name in $dirs.Keys){if($leaves.ContainsKey($name)){throw 'Transport path collision.'};$tree=Transport-Tree $dirs[$name];$lines.Add("040000 tree $tree`t$name`0")}
    $file=Join-Path $script:runRoot ([guid]::NewGuid().ToString('N')+'.tree')
    try{[IO.File]::WriteAllText($file,($lines-join''),(New-Object Text.UTF8Encoding($false)));return Transport-Git @('mktree','-z') $file}finally{if([IO.File]::Exists($file)){[IO.File]::Delete($file)}}
}
function Get-TransportMarkerRef($Payload) {
    if([string]$Payload.sha256-cnotmatch'^[0-9a-f]{64}$'-or[long]$Payload.length-lt0){throw 'Invalid transport marker raw identity.'}
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$pathKey=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(([string]$Payload.sha256+"`n"+$Payload.length+"`n"+$Payload.path)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    return 'refs/agent-session-sync/codex-gzip-v1/'+$pathKey
}
function Get-TransportFiles($Entries,[string]$Prefix,$Payload) {
    $relative=[string]$Payload.transportPath;$files=@{}
    $names=New-Object 'Collections.Generic.List[string]';$names.Add($relative)
    if($relative.EndsWith('.gz.parts.json',[StringComparison]::Ordinal)){
        if(-not$Entries.ContainsKey($Prefix+$relative)){throw "Transport descriptor missing: $relative"}
        $meta=Read-BlobJson $Entries[$Prefix+$relative]
        $parts=$meta.PSObject.Properties['parts'].Value
        if($parts-isnot[Array]-or$parts.Count-lt2){throw "Invalid split transport parts: $relative"}
        $baseName=$relative.Substring(0,$relative.Length-'.parts.json'.Length)
        if($Entries.ContainsKey($Prefix+$baseName)){throw 'Single and split transport coexist.'}
        for($i=0;$i-lt$parts.Count;$i++){
            $expected=$baseName+('.part{0:D6}'-f($i+1))
            if($parts[$i].path-cne$expected){throw "Invalid split transport order: $relative"}
            $names.Add($expected)
        }
        foreach($entry in $Entries.Keys){
            if($entry.StartsWith($Prefix+$baseName+'.part',[StringComparison]::Ordinal)-and$entry-cne$Prefix+$relative-and-not$names.Contains($entry.Substring($Prefix.Length))){throw "Unlisted split transport part: $entry"}
        }
    }elseif($relative.EndsWith('.gz',[StringComparison]::OrdinalIgnoreCase)){$names.Add($relative+'.integrity.json')}else{throw 'A gzip marker cannot describe raw transport.'}
    foreach($name in $names){
        if(-not$name-or$name-match'(^/|\\|(^|/)\.\.?(/|$)|[\x00-\x1f])'){throw "Unsafe transport marker path: $name"}
        if(-not$Entries.ContainsKey($Prefix+$name)){throw "Transport part or integrity record missing: $Prefix$name"}
        $files[$name]=$Entries[$Prefix+$name]
    }
    return $files
}
function New-TransportMarkerTree($Entries,[string]$Prefix,$Payload) {
    $files=Get-TransportFiles $Entries $Prefix $Payload
    $marker=[ordered]@{schemaVersion=1;codec='gzip-split-v1';payload=[ordered]@{path=[string]$Payload.path;transportPath=[string]$Payload.transportPath;length=[long]$Payload.length;sha256=[string]$Payload.sha256}}
    $tree=@{'marker.json'=(Transport-Blob $marker)}
    foreach($path in $files.Keys){$tree['data/'+$path]=$files[$path]}
    return Transport-Tree $tree
}
function Test-TransportMarker($Entries,[string]$Prefix,$Payload) {
    $ref=Get-TransportMarkerRef $Payload
    $stored=Transport-Git @('for-each-ref','--format=%(objectname)',$ref)
    if(-not$stored){return $false}
    return $stored-ceq(New-TransportMarkerTree $Entries $Prefix $Payload)
}
function Save-TransportMarker($Entries,[string]$Prefix,$Payload,[string]$RawPath='') {
    # A local marker binds the verified raw identity AND every transport blob.
    # The ref keeps cached blobs reachable across Cancel/GC; it is never pushed.
    $ref=Get-TransportMarkerRef $Payload;$tree=New-TransportMarkerTree $Entries $Prefix $Payload
    [void](Transport-Git @('update-ref',$ref,$tree))
    if($RawPath){$script:transportRaw[$ref]=$RawPath}
}
function Get-CachedTransport($Payload,[long]$Ceiling,$Entries) {
    $ref=Get-TransportMarkerRef $Payload;$tree=Transport-Git @('for-each-ref','--format=%(objectname)',$ref)
    if(-not$tree){return $null}
    $cached=@{}
    foreach($line in (Transport-Git @('ls-tree','-r','-z',$tree)).Split([char]0)){
        if(-not$line){continue};if($line-cnotmatch'^100644 blob ([0-9a-f]+)\t(.+)$'){throw 'Invalid transport cache entry.'};$cached[$Matches[2]]=$Matches[1]
    }
    if(-not$cached.ContainsKey('marker.json')){return $null}
    $marker=Read-BlobJson $cached['marker.json'];$p=$marker.payload
    if($marker.schemaVersion-ne1-or$marker.codec-cne'gzip-split-v1'-or$p.path-cne$Payload.path-or$p.sha256-cne$Payload.sha256-or[long]$p.length-ne[long]$Payload.length){return $null}
    $files=@{};foreach($name in $cached.Keys){if($name.StartsWith('data/')){$files[$name.Substring(5)]=$cached[$name]}}
    if(-not(Test-TransportMarker $files '' $p)){return $null}
    foreach($name in $files.Keys){if([long](Transport-Git @('cat-file','-s',$files[$name]))-gt$Ceiling){return $null}}
    foreach($name in $files.Keys){$Entries[$name]=$files[$name]}
    return [ordered]@{path=[string]$p.path;transportPath=[string]$p.transportPath;length=[long]$p.length;sha256=[string]$p.sha256}
}

function Expand-SplitGzip($Entries,[string]$Prefix,[string]$Relative,$Allowed=$null) {
    # Parts are bytes of ONE gzip stream, never separately recompressed.
    Resolve-Within $script:runRoot $Relative|Out-Null
    $descriptorPath=$Prefix+$Relative
    if(-not$Relative.EndsWith('.gz.parts.json',[StringComparison]::Ordinal)-or-not$Entries.ContainsKey($descriptorPath)){throw "Split gzip descriptor missing: $descriptorPath"}
    $meta=Read-BlobJson $Entries[$descriptorPath]
    if((@($meta.PSObject.Properties.Name|Sort-Object)-join ',')-cne'encoding,gzipLength,gzipSha256,parts,partSize,rawLength,rawSha256,schemaVersion'-or$meta.schemaVersion-ne1-or$meta.encoding-cne'gzip'){throw "Unknown split gzip descriptor: $descriptorPath"}
    foreach($key in @('partSize','rawLength','gzipLength')){
        $v=$meta.PSObject.Properties[$key].Value
        if(($v-isnot[int]-and$v-isnot[long])-or$v-le0){throw "Invalid split gzip length: $descriptorPath/$key"}
    }
    if($meta.partSize-gt99614720){throw "Split part size exceeds transport ceiling: $descriptorPath"}
    foreach($key in @('rawSha256','gzipSha256')){if($meta.PSObject.Properties[$key].Value-isnot[string]-or$meta.PSObject.Properties[$key].Value-cnotmatch'^[0-9a-f]{64}$'){throw "Invalid split gzip hash: $descriptorPath/$key"}}
    $parts=$meta.PSObject.Properties['parts'].Value
    if($parts-isnot[Array]-or$parts.Count-lt2-or$parts.Count-ne[Math]::Ceiling([double]$meta.gzipLength/[long]$meta.partSize)){throw "Invalid split gzip part count: $descriptorPath"}
    $gzipName=$Relative.Substring(0,$Relative.Length-'.parts.json'.Length)
    if($Entries.ContainsKey($Prefix+$gzipName)){throw "Split and single gzip coexist: $descriptorPath"}
    $joined=Join-Path $script:runRoot ([guid]::NewGuid().ToString('N')+'.joined.gz')
    $raw=$joined+'.raw';$sink=$null
    try {
        $sink=[IO.File]::Create($joined)
        for($i=0;$i-lt$parts.Count;$i++){
            $part=$parts[$i];$expected=$gzipName+('.part{0:D6}'-f($i+1))
            $expectedLength=[Math]::Min([long]$meta.partSize,[long]$meta.gzipLength-([long]$i*[long]$meta.partSize))
            if((@($part.PSObject.Properties.Name|Sort-Object)-join ',')-cne'length,path,sha256'-or$part.path-cne$expected-or($part.length-isnot[int]-and$part.length-isnot[long])-or$part.length-ne$expectedLength-or$part.sha256-isnot[string]-or$part.sha256-cnotmatch'^[0-9a-f]{64}$'){throw "Invalid split gzip part/order: $descriptorPath part $($i+1)"}
            $entryPath=$Prefix+$expected
            if(-not$Entries.ContainsKey($entryPath)){throw "Split gzip part missing: $entryPath"}
            if($null-ne$Allowed){[void]$Allowed.Add($entryPath)}
            $piece=Join-Path $script:runRoot ([guid]::NewGuid().ToString('N')+'.piece')
            try {
                Git @('cat-file','blob',$Entries[$entryPath]) $null $piece|Out-Null
                if((Get-Item -LiteralPath $piece).Length-ne$expectedLength-or(Hash $piece)-cne$part.sha256){throw "Split gzip part integrity failure: $entryPath"}
                $stream=[IO.File]::OpenRead($piece)
                try{$stream.CopyTo($sink)}finally{$stream.Dispose()}
            }finally{if([IO.File]::Exists($piece)){[IO.File]::Delete($piece)}}
        }
        $sink.Dispose();$sink=$null
        if((Get-Item -LiteralPath $joined).Length-ne[long]$meta.gzipLength-or(Hash $joined)-cne$meta.gzipSha256){throw "Reassembled gzip integrity failure: $descriptorPath"}
        $stream=[IO.File]::OpenRead($joined);$destination=[IO.File]::Create($raw)
        try{$gzip=New-Object IO.Compression.GZipStream($stream,[IO.Compression.CompressionMode]::Decompress,$true);try{$gzip.CopyTo($destination)}finally{$gzip.Dispose()}}finally{$stream.Dispose();$destination.Dispose()}
        if((Get-Item -LiteralPath $raw).Length-ne[long]$meta.rawLength-or(Hash $raw)-cne$meta.rawSha256){throw "Split gzip raw integrity failure: $descriptorPath"}
        return $raw
    }catch{if([IO.File]::Exists($raw)){[IO.File]::Delete($raw)};throw}
    finally{if($null-ne$sink){$sink.Dispose()};if([IO.File]::Exists($joined)){[IO.File]::Delete($joined)}}
}

function New-TransportGzip([string]$Source) {
    # Use the same deterministic gzip executable under PS 5.1 and PS 7.
    $gitPath=(Get-Command git.exe -ErrorAction Stop).Source
    $gitRoot=Split-Path (Split-Path $gitPath -Parent) -Parent
    $gzipTool=Join-Path $gitRoot 'usr/bin/gzip.exe'
    if(-not[IO.File]::Exists($gzipTool)){throw 'Git for Windows gzip.exe is required for deterministic transport.'}
    $target=Join-Path $script:runRoot ([guid]::NewGuid().ToString('N')+'.gz')
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$gzipTool
    $info.Arguments='-n -9 -c -- "'+$Source+'"'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process;$process.StartInfo=$info
    try{[void]$process.Start();$errors=$process.StandardError.ReadToEndAsync();$sink=[IO.File]::Create($target)
        try{$process.StandardOutput.BaseStream.CopyTo($sink)}finally{$sink.Dispose()}
        $process.WaitForExit();$message=$errors.GetAwaiter().GetResult()
        if($process.ExitCode-ne0){throw "gzip failed: $message"}
    }finally{$process.Dispose()}
    return $target
}

function Add-SplitGzip([string]$Transport,[string]$Name,[long]$RawLength,[string]$RawHash,$Entries,[long]$PartSize) {
    $size=(Get-Item -LiteralPath $Transport).Length
    if($PartSize-le0-or$PartSize-gt99614720-or$size-le$PartSize){throw 'Invalid split transport boundary.'}
    $parts=New-Object 'Collections.Generic.List[object]'
    $buffer=New-Object byte[] 1048576
    $stream=[IO.File]::OpenRead($Transport)
    try{
        while($stream.Position-lt$stream.Length){
            $path=$Name+('.part{0:D6}'-f($parts.Count+1))
            $piece=Join-Path $script:runRoot ([guid]::NewGuid().ToString('N')+'.part')
            try{
                $sink=[IO.File]::Create($piece);[long]$written=0
                try{while($written-lt$PartSize-and$stream.Position-lt$stream.Length){
                    $n=$stream.Read($buffer,0,[int][Math]::Min($buffer.Length,$PartSize-$written))
                    if($n-le0){throw 'Unexpected end while splitting gzip.'}
                    $sink.Write($buffer,0,$n);$written+=$n
                }}finally{$sink.Dispose()}
                $Entries[$path]=Blob-File $piece
                $parts.Add([ordered]@{path=$path;length=$written;sha256=(Hash $piece)})
            }finally{if([IO.File]::Exists($piece)){[IO.File]::Delete($piece)}}
        }
    }finally{$stream.Dispose()}
    $descriptor=$Name+'.parts.json'
    $Entries[$descriptor]=Blob-Json ([ordered]@{schemaVersion=1;encoding='gzip';partSize=$PartSize;rawLength=$RawLength;rawSha256=$RawHash;gzipLength=$size;gzipSha256=(Hash $Transport);parts=$parts.ToArray()})
    # Verify the stored blobs, order, concatenated stream and original bytes.
    $verified=Expand-SplitGzip $Entries '' $descriptor
    [IO.File]::Delete($verified)
    return $descriptor
}

function Package-Payload([string]$Source,[string]$Relative,$Entries) {
    $safe=Resolve-Within $script:appHome $Source.Substring($script:appHome.Length).TrimStart('\','/')
    if($safe-ne$Source){throw 'Payload path normalization mismatch.'}
    $length=(Get-Item -LiteralPath $Source).Length;$raw=Hash $Source;$transport=$Source
    if($script:analysedSources.ContainsKey($Source)-and$script:analysedSources[$Source]-cne$raw){throw "Rollout changed after analysis: $Source"}
    $ceiling=[Math]::Min([long]$script:limit,99614720);if($ceiling-le0){throw 'Invalid transport limit.'}
    $identity=[ordered]@{path=$Relative;length=$length;sha256=$raw}
    $script:transportSources[$raw+'-'+$length]=$Source
    $reuseKey=$Relative+"`0"+[string]$length+"`0"+$raw
    if($script:reusablePayloads.ContainsKey($reuseKey)-and$script:reusablePayloads[$reuseKey].Largest-le$ceiling){
        $saved=$script:reusablePayloads[$reuseKey]
        foreach($entry in $saved.Files.Keys){$Entries[$entry]=$saved.Files[$entry]}
        if((Get-Item -LiteralPath $Source).Length-ne$length-or(Hash $Source)-ne$raw){throw "Source changed while preparing: $Source"}
        return [ordered]@{path=[string]$saved.Payload.path;transportPath=[string]$saved.Payload.transportPath;length=[long]$saved.Payload.length;sha256=[string]$saved.Payload.sha256}
    }
    $name=$Relative
    if($length-gt$ceiling){
        $cached=Get-CachedTransport $identity $ceiling $Entries
        if($null-ne$cached){
            Write-Host ("PROGRESS: Reusing verified gzip marker; no compression/decompression: {0}" -f $Relative)
            if((Get-Item -LiteralPath $Source).Length-ne$length-or(Hash $Source)-ne$raw){throw "Source changed while preparing: $Source"}
            return $cached
        }
        Write-FinishProgress ("Compressing and verifying {0} ({1:N1} MiB)" -f $Relative,($length/1MB))
        $transport=New-TransportGzip $Source
        $name+='.gz'
        if((Get-Item -LiteralPath $transport).Length-gt$ceiling){
            $name=Add-SplitGzip $transport $name $length $raw $Entries $ceiling
            if((Get-Item -LiteralPath $Source).Length-ne$length-or(Hash $Source)-ne$raw){throw "Source changed while preparing: $Source"}
            $payload=[ordered]@{path=$Relative;transportPath=$name;length=$length;sha256=$raw}
            Save-TransportMarker $Entries '' $payload
            return $payload
        }
        $check=Join-Path $script:runRoot ([guid]::NewGuid().ToString()+'.raw')
        $input=[IO.File]::OpenRead($transport);$output=[IO.File]::Create($check)
        try{$gzip=New-Object IO.Compression.GZipStream($input,[IO.Compression.CompressionMode]::Decompress,$true);try{$gzip.CopyTo($output)}finally{$gzip.Dispose()}}finally{$input.Dispose();$output.Dispose()}
        if((Get-Item -LiteralPath $check).Length-ne$length-or(Hash $check)-ne$raw){throw 'gzip round-trip verification failed.'}
        $Entries[$name+'.integrity.json']=Blob-Json ([ordered]@{rawLength=$length;rawSha256=$raw;gzipLength=(Get-Item -LiteralPath $transport).Length;gzipSha256=(Hash $transport)})
    }
    $Entries[$name]=Blob-File $transport
    if((Get-Item -LiteralPath $Source).Length-ne$length-or(Hash $Source)-ne$raw){throw "Source changed while preparing: $Source"}
    $payload=[ordered]@{path=$Relative;transportPath=$name;length=$length;sha256=$raw}
    if($name.EndsWith('.gz',[StringComparison]::OrdinalIgnoreCase)){Save-TransportMarker $Entries '' $payload}
    return $payload
}
function Get-DeleteRequest($Row) {
    $flag=Field $Row 'archived'
    if(($flag-isnot[int]-and$flag-isnot[long])-or$flag-notin@(0,1)){Survey 'Unsurveyed native archive flag.'}
    if($flag-eq0){return $null}
    # User contract: native Codex Archived is only the deletion transit.
    # It is not the independent 30-day Vault preservation tier.
    $at=Field $Row 'archived_at'
    if(($at-isnot[int]-and$at-isnot[long])-or$at-le0){Survey 'Native deletion transit has no valid app archive timestamp.'}
    $archiveRoot=(Resolve-Within $script:appHome 'archived_sessions').TrimEnd('\','/')+'\'
    $latest=[IO.Path]::GetFullPath([string](Field $Row 'rollout_path'))
    if(-not$latest.StartsWith($archiveRoot,[StringComparison]::OrdinalIgnoreCase)){Survey 'Native deletion transit contradicts its rollout location.'}
    try{return [DateTimeOffset]::FromUnixTimeSeconds([long]$at).ToUniversalTime().ToString('o')}
    catch{Survey 'Native deletion transit timestamp is outside the supported range.'}
}

function Prepare-Local($Base,$Remote) {
    Index-ReusablePayloads $Base $Remote
    $pages=New-Object 'Collections.Generic.List[object]'
    $originals=New-Object 'Collections.Generic.List[object]'
    foreach($relative in @('sessions','archived_sessions')){
        $root=Resolve-Within $script:appHome $relative
        if(Test-Path -LiteralPath $root){foreach($f in Get-ChildItem -LiteralPath $root -Filter '*.jsonl' -File -Recurse){$originals.Add($f)}}
    }
    $originalNumber=0
    foreach($f in $originals){
        $originalNumber++
        Write-FinishProgress ("Checking original {0}/{1}: {2} ({3:N1} MiB)" -f $originalNumber,$originals.Count,$f.Name,($f.Length/1MB))
        Resolve-Within $script:appHome $f.FullName.Substring($script:appHome.Length).TrimStart('\','/')|Out-Null
        $pages.Add((Inspect-Rollout $f.FullName))
    }
    Write-FinishProgress 'Checking lineage connections and database integrity'
    Assert-History $pages.ToArray()
    $statePath=Resolve-Within $script:appHome 'state_5.sqlite'
    $historyPath=Resolve-Within $script:appHome 'thread_history_1.sqlite'
    $catalogPath=Resolve-Within $script:appHome 'sqlite/codex-dev.db'
    foreach($path in @($statePath,$historyPath,$catalogPath)){
        $check=Query $path 'PRAGMA quick_check';if($check.Count-ne1-or(Field $check[0] 'quick_check')-ne'ok'){throw "Database integrity check failed: $path"}
    }
    $threads=Db-Table $statePath 'threads';$byId=@{}
    foreach($row in $threads){$id=[string]$row['id'];Require-Id $id;if($byId.ContainsKey($id)){Survey "Duplicate canonical thread: $id"};$byId[$id]=$row}
    $groups=@{}
    foreach($p in $pages){if(-not$groups.ContainsKey($p.Id)){$groups[$p.Id]=New-Object 'Collections.Generic.List[object]'};$groups[$p.Id].Add($p)}
    $globalPath=Resolve-Within $script:appHome '.codex-global-state.json';$global=$null
    if(Test-Path -LiteralPath $globalPath){$global=Read-Json $globalPath}
    Write-FinishProgress 'Indexing global references once for this local snapshot'
    $referenceIds=@($pages|ForEach-Object{$_.Id;$_.Alias})
    $globalIndex=New-GlobalReferenceIndex $global $referenceIds
    $indexPath=Resolve-Within $script:appHome 'session_index.jsonl';$index=New-Object 'Collections.Generic.List[object]'
    if(Test-Path -LiteralPath $indexPath){foreach($line in [CodexFinishNative]::Lines($indexPath)){if($line.Text){$index.Add((Parse-Json $line.Text))}}}
    $attachmentPath=Resolve-Within $script:appHome 'attachments/pasted-text-attachments.json';$attachmentIndex=$null
    if(Test-Path -LiteralPath $attachmentPath){$attachmentIndex=Read-Json $attachmentPath}
    $result=@{}
    $sessionNumber=0
    foreach($id in @($groups.Keys|Sort-Object)){
        $sessionNumber++
        Write-FinishProgress ("Preparing session {0}/{1}: {2}" -f $sessionNumber,$groups.Count,$id)
        if(-not$byId.ContainsKey($id)){throw "Rollout has no canonical state row: $id"}
        $row=$byId[$id];$sessionPages=@($groups[$id].ToArray()|Sort-Object Name)
        $deleteAt=Get-DeleteRequest $row
        $latest=[IO.Path]::GetFullPath([string]$row['rollout_path'])
        $latestKey=Get-RolloutComparisonPath $latest
        if(@($sessionPages|Where-Object{[string]::Equals((Get-RolloutComparisonPath $_.Path),$latestKey,[StringComparison]::OrdinalIgnoreCase)}).Count-ne1){throw "Canonical latest path does not resolve to a collected original: $id"}
        $last=$null;foreach($page in $sessionPages){if($null-ne$page.Last-and($null-eq$last-or$page.Last-gt$last)){$last=$page.Last}}
        if ($null -eq $last -and (Field $sessionPages[0].Meta 'thread_source') -eq 'guardian_review') {
            $parent=[string](Field $sessionPages[0].Meta 'parent_thread_id')
            if ($groups.ContainsKey($parent)) {
                # A guardian with no dialogue uses real dialogue in its explicitly
                # linked parent conversation. Its own canonical identity is retained.
                foreach ($parentPage in $groups[$parent]) { if ($null -ne $parentPage.Last -and ($null -eq $last -or $parentPage.Last -gt $last)) { $last=$parentPage.Last } }
            }
        }
        if($null-eq$last-and-not$deleteAt){throw "No valid dialogue timestamp for $id or its surveyed parent conversation; cannot apply the configured 30-day rule."}
        $state='Active';if($null-ne$last-and$last-lt$script:now.AddDays(-$script:days)){$state='Archived'}
        $vaultId=$id
        foreach($collection in @($Base,$Remote)){
            foreach($entry in $collection.GetEnumerator()){
                if($entry.Value.State-ne'Deleted'-and$entry.Value.Manifest.canonicalId-eq$id){
                    if($vaultId-ne$id-and$vaultId-ne$entry.Key){throw "Ambiguous Vault identity: $id"};$vaultId=$entry.Key
                }
            }
        }
        # An existing local Archived basis is retained unless Reactivate has changed it.
        if(-not$deleteAt-and$Base.ContainsKey($vaultId)-and$Base[$vaultId].State-eq'Archived'){
            if($state-eq'Active'){throw "Session conflict: local activity in archived session $vaultId. No automatic Reactivate."}
            $state='Archived'
        }
        $files=@{};$inventory=New-Object 'Collections.Generic.List[object]'
        foreach($page in $sessionPages){$inventory.Add((Package-Payload $page.Path ('rollouts/'+$page.Name) $files))}
        $ids=@($sessionPages|ForEach-Object{$_.Alias})
        if($id-notin$ids){$ids+=@($id)};$ids=@($ids|Sort-Object -Unique)
        $history=[ordered]@{}
        foreach($table in @('thread_turns','thread_items','thread_history_projection_state','thread_realtime_items')){
            $rows=New-Object 'Collections.Generic.List[object]'
            foreach($key in $ids){foreach($item in (Db-Table $historyPath $table 'WHERE thread_id=? ORDER BY rowid' @($key))){$rows.Add($item)}}
            $history[$table]=$rows.ToArray()
        }
        $catalog=Db-Table $catalogPath 'local_thread_catalog' 'WHERE thread_id=? ORDER BY host_id' @($id)
        if($catalog.Count-gt1){throw "Ambiguous catalog host mapping for $id"}
        if([long]$row['archived']-eq0-and$catalog.Count-eq0-and(Field $sessionPages[0].Meta 'thread_source')-ne'guardian_review'){throw "Active thread has no app catalog mapping: $id"}
        $display=@($index.ToArray()|Where-Object{(Field $_ 'id')-eq$id})
        $title=[string]$row['title']
        if ($catalog.Count) { $title=[string]$catalog[0]['display_title'] }
        elseif ($script:archiveTitles.ContainsKey($id)) { $title=$script:archiveTitles[$id] }
        elseif ($Base.ContainsKey($vaultId) -and $Base[$vaultId].State -eq 'Archived') { $title=[string]$Base[$vaultId].Manifest.comparison.title }
        elseif ($display.Count) {
            $savedTitle=Field $display[-1] 'thread_name' (Field $display[-1] 'title')
            if ($savedTitle) { $title=[string]$savedTitle }
        }
        $portableState=[ordered]@{}
        foreach($key in @('id','created_at','updated_at','source','model_provider','cwd','title','name','tokens_used','has_user_event','archived','archived_at','git_sha','git_branch','git_origin_url','cli_version','first_user_message','agent_nickname','agent_role','agent_path','created_at_ms','updated_at_ms','thread_source','preview','recency_at','recency_at_ms','history_mode','is_pinned','thread_section_id','section_position','section_entered_at_ms','project_id')){
            if($row.ContainsKey($key)){$portableState[$key]=$row[$key]}
        }
        $portableState['latestRollout']=[IO.Path]::GetFileName($latest)
        $extras=[ordered]@{}
        foreach($table in @('thread_dynamic_tools','thread_artifacts')){$extras[$table]=Db-Table $statePath $table 'WHERE thread_id=? ORDER BY rowid' @($id)}
        $extras['thread_spawn_edges']=Db-Table $statePath 'thread_spawn_edges' 'WHERE parent_thread_id=? OR child_thread_id=? ORDER BY child_thread_id' @($id,$id)
        foreach($table in @('projects','thread_sections')){
            $foreign=if($table-eq'projects'){Field $row 'project_id'}else{Field $row 'thread_section_id'}
            $extras[$table]=@();if($foreign){$extras[$table]=Db-Table $statePath $table 'WHERE id=?' @($foreign);if($extras[$table].Count-ne1){throw "Missing $table relationship: $id"}}
        }
        $owned=New-Object 'Collections.Generic.List[string]'
        foreach($path in @(Field $attachmentIndex 'attachmentPaths' @())){
            $used=$false;foreach($page in $sessionPages){foreach($text in $page.Texts){if($text.Contains([string]$path)){$used=$true;break}}}
            if($used){$full=[IO.Path]::GetFullPath([string]$path);$relative=$full.Substring($script:appHome.Length).TrimStart('\','/');Resolve-Within $script:appHome $relative|Out-Null
                if(-not(Test-Path -LiteralPath $full -PathType Leaf)){throw "Missing owned attachment for $id : $path"}
                $owned.Add([string]$path);$inventory.Add((Package-Payload $full ('attachments/'+$relative.Replace('\','/')) $files))}
        }
        $browser=Resolve-Within $script:appHome ('browser/sessions/'+$id+'.toml')
        if(Test-Path -LiteralPath $browser){$inventory.Add((Package-Payload $browser ('browser/'+$id+'.toml') $files))}
        $visualRoot=Resolve-Within $script:appHome 'visualizations'
        if(Test-Path -LiteralPath $visualRoot){foreach($dir in Get-ChildItem -LiteralPath $visualRoot -Directory -Recurse|Where-Object{$_.Name-in$ids}){
            foreach($f in Get-ChildItem -LiteralPath $dir.FullName -File -Recurse){$rel=$f.FullName.Substring($visualRoot.Length).TrimStart('\','/').Replace('\','/');$inventory.Add((Package-Payload $f.FullName ('visualizations/'+$rel) $files))}
        }}
        $projection=[ordered]@{state=$portableState;history=$history;catalog=$catalog;sessionIndex=$display;relations=$extras;globalReferences=(Selected-Global $globalIndex $ids);attachmentReferences=$owned.ToArray()}
        $priorProjections=@();$priorManifests=@()
        foreach($set in @($Base,$Remote)){
            if($set.ContainsKey($vaultId)-and$set[$vaultId].State-ne'Deleted'){
                $prior=$set[$vaultId]
                $priorProjections+=@($prior.Entries[$prior.Prefix+'projection.json'])
                $priorManifests+=@($prior.Entries[$prior.Prefix+'manifest.json'])
            }
        }
        $files['projection.json']=Reuse-Json $projection $priorProjections
        $selectedRefs=Selected-Global $globalIndex @($id)
        $placement=@($selectedRefs | Where-Object { $_.pointer -match '^/(thread-project-assignments|sidebar-project-thread-orders|thread-writable-roots)/' })
        $comparison=[ordered]@{canonicalId=$id;title=$title;metadata=[ordered]@{name=(Field $row 'name');pinned=(Field $row 'is_pinned');projectId=(Field $row 'project_id');sectionId=(Field $row 'thread_section_id');sectionPosition=(Field $row 'section_position');placement=$placement};payloads=@($inventory.ToArray()|Sort-Object path|ForEach-Object{[ordered]@{path=$_.path;length=$_.length;sha256=$_.sha256}})}
        $manifest=[ordered]@{schemaVersion=1;vaultSessionId=$vaultId;canonicalId=$id;lineageIds=$ids;lastActivityAt=$(if($null-ne$last){$last.ToUniversalTime().ToString('o')}else{$null});comparison=$comparison;payloads=$inventory.ToArray()}
        $files['manifest.json']=Reuse-Json $manifest $priorManifests
        $entries=@{};foreach($path in $files.Keys){$entries["$state/$vaultId/$path"]=$files[$path]}
        $result[$vaultId]=[pscustomobject]@{State=$state;Manifest=$manifest;Prefix="$state/$vaultId/";Entries=$entries;LocalPages=$sessionPages;NeedsRemoval=($state-eq'Archived');RemovalState=$state;DeleteRequested=($null-ne$deleteAt);DeleteAt=$deleteAt}
    }
    foreach($id in $byId.Keys){if(-not$groups.ContainsKey($id)){throw "Incomplete local session: state row $id has no rollout. This is not deletion evidence."}}
    return $result
}

function Verify-StoredSessions($Sessions) {
    foreach($s in $Sessions.Values){
        if($s.State-eq'Deleted'){continue}
        $projection=$s.Prefix+'projection.json'
        if(-not$s.Entries.ContainsKey($projection)){throw "Stored session projection missing: $($s.Prefix)"}
        Read-BlobJson $s.Entries[$projection] | Out-Null
        foreach($payload in @(Field $s.Manifest 'payloads' @())){
            $relative=[string](Field $payload 'transportPath');Resolve-Within $script:runRoot $relative|Out-Null
            $path=$s.Prefix+$relative
            if(-not$s.Entries.ContainsKey($path)){throw "Stored session payload missing: $path"}
            $compressed=$relative.EndsWith('.gz',[StringComparison]::OrdinalIgnoreCase)-or$relative.EndsWith('.gz.parts.json',[StringComparison]::Ordinal)
            $verifiedKey=[string]$s.Entries[$path]+'/'+[string]$payload.length+'/'+[string]$payload.sha256
            if(-not$compressed-and$script:verifiedStoredPayloads.ContainsKey($verifiedKey)){continue}
            if($compressed-and(Test-TransportMarker $s.Entries $s.Prefix $payload)){continue}
            if($relative.EndsWith('.gz.parts.json',[StringComparison]::Ordinal)){
                $restored=Expand-SplitGzip $s.Entries $s.Prefix $relative
                if((Get-Item -LiteralPath $restored).Length-ne[long]$payload.length-or(Hash $restored)-ne[string]$payload.sha256){throw "Stored split raw integrity failure: $path"}
                Save-TransportMarker $s.Entries $s.Prefix $payload $restored
                continue
            }
            $file=Join-Path $script:runRoot ([guid]::NewGuid().ToString()+'.verify')
            Git @('cat-file','blob',$s.Entries[$path]) $null $file | Out-Null
            $raw=$file
            if($relative.EndsWith('.gz')){
                $integrityPath=$path+'.integrity.json'
                if(-not$s.Entries.ContainsKey($integrityPath)){throw "Missing gzip integrity metadata: $path"}
                $integrity=Read-BlobJson $s.Entries[$integrityPath]
                if((Get-Item -LiteralPath $file).Length-ne$integrity.gzipLength-or(Hash $file)-ne$integrity.gzipSha256){throw "Stored gzip integrity failure: $path"}
                $raw=$file+'.raw';$input=[IO.File]::OpenRead($file);$output=[IO.File]::Create($raw)
                try{$gzip=New-Object IO.Compression.GZipStream($input,[IO.Compression.CompressionMode]::Decompress,$true);try{$gzip.CopyTo($output)}finally{$gzip.Dispose()}}finally{$input.Dispose();$output.Dispose()}
                if((Get-Item -LiteralPath $raw).Length-ne$integrity.rawLength-or(Hash $raw)-ne$integrity.rawSha256){throw "Stored decompression integrity failure: $path"}
            }
            if((Get-Item -LiteralPath $raw).Length-ne$payload.length-or(Hash $raw)-ne$payload.sha256){throw "Stored raw integrity failure: $path"}
            if($compressed){Save-TransportMarker $s.Entries $s.Prefix $payload $raw}
            else{$script:verifiedStoredPayloads[$verifiedKey]=$true}
        }
    }
}
function Select-Contributions($base, $remote, $local) {
    $prepared=@{};$basis=@{};$all=@{}
    foreach($collection in @($base,$remote,$local)){foreach($id in $collection.Keys){$all[$id]=$true}}
    foreach($id in @($all.Keys|Sort-Object)){
        $b=$null;$r=$null;$l=$null
        if($base.ContainsKey($id)){$b=$base[$id]};if($remote.ContainsKey($id)){$r=$remote[$id]};if($local.ContainsKey($id)){$l=$local[$id]}
        if($null-eq$l){
            if($null-ne$b-and$b.State-eq'Active'-and($null-eq$r-or$r.State-ne'Deleted')){
                throw "Accepted Active session is missing from this PC without a verifiable deletion transit: $id. Review required; no deletion was inferred and no stale Active copy was silently retained for publication."
            }
            if($null-ne$b-and$null-eq$r){throw "Published session disappeared from the remote without a Deleted record: $id. Review required."}
            Copy-Session $r $prepared
            if($null-ne$r-and$r.State-eq'Deleted'){Copy-Session $r $basis}
            elseif($null-ne$r-and$r.State-eq'Active'){$script:warnings.Add("Remote Active session has no accepted local copy: $id; retained remote state without inferring deletion.")}
            continue
        }
        if($null-ne$r-and$r.State-eq'Deleted'){
            throw "Remote Deleted session is still present in the local Codex store: $id; basis=$BaselineCommit; remote=$RemoteCommit. Review required, even if the local conversation is unchanged. Nothing was republished or automatically deleted."
        }
        if($l.DeleteRequested){
            if($null-ne$b-and$null-eq$r){throw "Deletion request refers to a session missing from the remote without a Deleted record: $id. Review required."}
            if($null-ne$r){
                if($null-ne$b){
                    if(-not(Same-Session $r $b)){throw "Session conflict: local deletion requested but the remote changed since the accepted basis: $id. Nothing was removed."}
                }elseif(-not(Rows-Equal $l.Manifest.comparison $r.Manifest.comparison)){
                    throw "Session conflict: deletion has no accepted basis and differs from the remote: $id. Nothing was removed."
                }
                $deleted=[ordered]@{schemaVersion=1;vaultSessionId=$id;lineageIds=@($r.Manifest.lineageIds);deletedAt=$l.DeleteAt;source='verified-app-delete'}
                $path="Deleted/$id.json";$blob=Blob-Json $deleted
                $prepared[$path]=$blob;$basis[$path]=$blob
            }
            # Never-published conversations need no Vault tombstone, but the
            # user's native deletion transit is still completed with rollback.
            $l.NeedsRemoval=$true;$l.RemovalState='Deleted'
            continue
        }
        Copy-Session $l $basis
        if(Same-Session $l $r){Copy-Session $r $prepared}
        elseif(Same-Session $l $b){Copy-Session $r $prepared}
        elseif(Same-Session $r $b){Copy-Session $l $prepared}
        else{throw "Session conflict: $id; basis=$BaselineCommit; remote=$RemoteCommit; local=$($l.State); remoteState=$(if($r){$r.State}else{'Absent'}). Neither side was changed. User resolution required."}
    }
    return @{Prepared=$prepared; Basis=$basis}
}

function Prepare-Run {
    Write-FinishProgress 'Checking accepted and remote Vault snapshots'
    $base = Read-Sessions (Read-AppTree $BaselineCommit)
    $remote = Read-Sessions (Read-AppTree $RemoteCommit)
    Verify-StoredSessions $base
    Verify-StoredSessions $remote
    $local = Prepare-Local $base $remote
    $selection = Select-Contributions $base $remote $local
    Write-FinishProgress 'Session comparison passed; securing Archive/Delete recovery material'
    foreach($session in $local.Values) {
        # A remote Reactivate can win the comparison. Never remove an app
        # session unless this publication actually keeps it in Vault Archived.
        if(-not$session.DeleteRequested-and$session.NeedsRemoval-and-not$selection.Prepared.ContainsKey($session.Prefix+'manifest.json')){$session.NeedsRemoval=$false}
    }
    $plans = Plan-AppRemovals $local
    Write-FinishProgress ("Applying {0} recorded app changes" -f $plans.Count)
    foreach ($plan in $plans) { Apply-Intent $plan; $plan['applied']=$true; Save-Receipt }
    # Keep complete Archived transport or the minimal Deleted record selected
    # before app removal. The basis retains Deleted, but drops removed Archived
    # app snapshots. Re-reading absence must not resurrect the old remote.
    foreach($session in $local.Values) {
        if(-not$session.NeedsRemoval){continue}
        if($session.RemovalState-eq'Deleted'){
            $script:warnings.Add(("Native deletion transit completed: {0}; app-local session removed with rollback backup; no Active/Archived payload will be published." -f $session.Manifest.canonicalId))
        }else{
            $script:warnings.Add(("Vault Archive prepared: {0}; full session retained in the publication tree, app-local session removed with rollback backup." -f $session.Manifest.canonicalId))
        }
        foreach($path in @($selection.Basis.Keys)) {
            if($path.StartsWith($session.Prefix,[StringComparison]::Ordinal)){$selection.Basis.Remove($path)}
        }
    }
    foreach($plan in $plans) {
        if($plan.kind-eq'removeFile'-and[IO.File]::Exists($plan.source)){throw 'Removed original reappeared before preparation completed.'}
        if($plan.kind-eq'sqlRows'-and-not(Rows-Equal (Query $plan.path $plan.query @($plan.keys)) $plan.after)){throw 'Removed app rows remain after normalization.'}
    }
    if($plans.Count) {
        # Removing unread-list elements shifts other sessions' JSON pointers;
        # removing an edge also affects its surviving endpoint. Refresh only
        # these measured metadata fields, without rescanning/recompressing raw.
        $remainingIds=@($local.Values|Where-Object{-not$_.NeedsRemoval}|ForEach-Object{$_.Manifest.lineageIds}|Sort-Object -Unique)
        $globalPath=Resolve-Within $script:appHome '.codex-global-state.json'
        $global=$null;if([IO.File]::Exists($globalPath)){$global=Read-Json $globalPath}
        $globalIndex=New-GlobalReferenceIndex $global $remainingIds
        foreach($session in $local.Values) {
            if($session.NeedsRemoval){continue}
            $path=$session.Prefix+'projection.json';$old=$selection.Basis[$path]
            $projection=Parse-Json (Json (Read-BlobJson $old))
            $projection.globalReferences=Selected-Global $globalIndex @($session.Manifest.lineageIds)
            $id=[string]$session.Manifest.canonicalId
            $projection.relations.thread_spawn_edges=Db-Table (Resolve-Within $script:appHome 'state_5.sqlite') 'thread_spawn_edges' 'WHERE parent_thread_id=? OR child_thread_id=? ORDER BY child_thread_id' @($id,$id)
            $updated=Blob-Json $projection
            $selection.Basis[$path]=$updated
            if($selection.Prepared.ContainsKey($path)-and$selection.Prepared[$path]-eq$old){$selection.Prepared[$path]=$updated}
        }
    }
    Write-FinishProgress 'Building prepared and local comparison trees'
    $script:receipt.preparedTree = Make-Tree $selection.Prepared
    $script:receipt.localBaseTree = Make-Tree $selection.Basis
    Write-FinishProgress ("Reused result objects: {0}; existing trees: {1}" -f $script:reusedJson,$script:reusedTrees)
    $script:receipt.status = 'prepared'
    Save-Receipt
}

try {
    Initialize-Native
    $parsedRun=[guid]::Empty
    if(-not[guid]::TryParseExact($RunId,'D',[ref]$parsedRun)){throw 'RunId must be a GUID in D format.'}
    $script:repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $gitRoot=Git @('rev-parse','--show-toplevel')
    if([IO.Path]::GetFullPath($gitRoot)-ne$script:repo){throw 'This script must run from the installation Launchers/Codex directory.'}
    $gitDir=Git @('rev-parse','--absolute-git-dir')
    $script:runsRoot=Join-Path $gitDir 'agent-session-sync/Codex'
    $script:runRoot=Resolve-Within $script:runsRoot $RunId
    $receiptPath=Join-Path $script:runRoot 'receipt.json'
    if($Operation-eq'Prepare'){
        if(Test-Path -LiteralPath $script:runRoot){throw 'RunId already exists; Cancel or Complete its recorded attempt first.'}
        [IO.Directory]::CreateDirectory($script:runRoot)|Out-Null
        $script:receipt=[ordered]@{schemaVersion=1;runId=$RunId;repository=$script:repo;status='checking';baseline=$BaselineCommit;remote=$RemoteCommit;preparedTree='';localBaseTree='';intents=@()}
        Save-Receipt
        $config=Import-PowerShellDataFile -LiteralPath (Join-Path $script:repo 'AgentSessionSync.config.psd1')
        if(-not$config.ContainsKey('Codex')-or-not$config.Codex.Enabled){throw 'Codex was not selected as a registered app.'}
        $script:appHome=[IO.Path]::GetFullPath([string]$config.Codex.Home).TrimEnd('\','/')
        if(-not(Test-Path -LiteralPath $script:appHome -PathType Container)){throw 'Configured Codex Home does not exist.'}
        if($script:appHome-eq$script:repo-or$script:appHome.StartsWith($script:repo+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'App Home must not be inside its transport repository.'}
        $script:receipt['appHome']=$script:appHome;Save-Receipt
        $script:days=[int]$config.ActiveWindowDays;$script:limit=[long]$config.TransportFileLimitBytes;$script:now=[DateTimeOffset]::UtcNow
        if($script:days-ne30-or$script:limit-ne99614720){throw 'Expected the agreed 30 days and 99614720-byte transport threshold.'}
        foreach($path in @('Codex/Active/probe.jsonl','Codex/Archived/probe.jsonl.gz','Codex/Deleted/probe.json')){
            $attributes=Git @('check-attr','text','working-tree-encoding','filter','ident','--',$path)
            foreach($line in $attributes.Split("`n")){if($line-notmatch ': unset\r?$'){throw "Unsafe effective Git attribute: $line"}}
            $ignored=& git.exe -C $script:repo check-ignore --no-index -- $path 2>$null
            if($LASTEXITCODE-eq0){throw "Private payload path is ignored: $path"};if($LASTEXITCODE-ne1){throw 'Cannot check private payload paths.'}
        }
        if($RemoteCommit){Object-Id $RemoteCommit 'commit'};if($BaselineCommit){Object-Id $BaselineCommit 'commit'}
        foreach ($other in Get-ChildItem -LiteralPath $script:runsRoot -Directory) {
            if ($other.Name -eq $RunId) { continue }
            $otherReceipt = Join-Path $other.FullName 'receipt.json'
            if ([IO.File]::Exists($otherReceipt)) {
                $pending = Read-Json $otherReceipt
                if ($pending.status -ne 'cancelled' -and @($pending.intents).Count -gt 0) {
                    throw "Another run retains unfinished app changes: $($other.Name). Review its publication and recovery before preparing again."
                }
            }
        }
        Prepare-Run
        Report 'Success' 'Codex preparation completed' ($script:warnings -join '; ')
        Write-Output "PREPARED_TREE: $($script:receipt.preparedTree)"
        Write-Output "LOCAL_BASE_TREE: $($script:receipt.localBaseTree)"
    } else {
        if(-not[IO.File]::Exists($receiptPath)){throw 'No recovery receipt proves what this RunId did. No-op success cannot be assumed.'}
        $script:receipt=Read-Json $receiptPath
        if($script:receipt.runId-ne$RunId-or$script:receipt.repository-ne$script:repo-or$script:receipt.schemaVersion-ne1){throw 'Run receipt identity mismatch.'}
        if (@($script:receipt.intents).Count) {
            $storedHome=[string](Field $script:receipt 'appHome')
            if (-not $storedHome -or -not [IO.Path]::IsPathRooted($storedHome)) { throw 'Recovery receipt has no absolute app home.' }
            foreach ($intent in @($script:receipt.intents)) {
                foreach ($field in @('source','destination','path')) {
                    $target=[string](Field $intent $field '')
                    if ($target) {
                        $absolute=[IO.Path]::GetFullPath($target)
                        if (-not $absolute.StartsWith($storedHome+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Recovery target escapes recorded app home.' }
                        Resolve-Within $storedHome $absolute.Substring($storedHome.Length).TrimStart('\','/') | Out-Null
                    }
                }
                $backup=[string](Field $intent 'backup' '')
                if ($backup -and -not [IO.Path]::GetFullPath($backup).StartsWith($script:runRoot+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Recovery backup escapes this run.' }
            }
        }
        if($Operation-eq'Cancel'){
            if($script:receipt.status-ne'cancelled'){Cancel-Run}
            Report 'Success' 'Codex attempt cancelled' 'This attempt is restored. No remote, checkout or baseline ref was changed.'
        }else{
            if($script:receipt.status-ne'prepared'){throw 'Only a successfully prepared attempt can be completed.'}
            Object-Id $PublishedCommit 'commit'
            $publishedTree=Git @('rev-parse',($PublishedCommit+':Codex'))
            if($publishedTree-ne$script:receipt.preparedTree){throw 'Published commit does not contain this RunId prepared contribution. Recovery material retained.'}
            Clear-Run
            Report 'Success' 'Codex publication cleanup completed' 'Only this run private material was removed; app data was not normalized again.'
        }
    }
    exit 0
} catch {
    $detail=$_.Exception.Message
    if($script:runRoot-and(Test-Path -LiteralPath $script:runRoot)){$detail+=' Recovery material: '+$script:runRoot}
    Report 'Failure' 'Codex Finish could not complete' $detail
    exit 1
}
