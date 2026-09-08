#requires -Version 5.1
# Codex Start: apply one pinned remote app tree to the closed local Codex store.
# UI behavior and cross-version interpretation remain observable only after launch.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RunId,
    [string] $BaselineCommit = '',
    [Parameter(Mandatory)][string] $RemoteCommit,
    [switch] $DiscardLocalChanges
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
$script:survey = $false
$script:discardRequired = $false
$script:receipt = $null
$script:archiveTitles = @{}
$script:runRoot = ''
$script:warnings = New-Object 'Collections.Generic.List[string]'
$script:receiveConfig=@{}
$script:receiveMetadata=$null
$script:utf8 = New-Object Text.UTF8Encoding($false, $true)

# All native I/O lives in this entry file. There is no Python or module dependency.
# Git transports bytes only; it never checks out, touches the shared index, or fetches.
$script:startWatch = [Diagnostics.Stopwatch]::StartNew()
function Write-CodexStartProgress([string]$Message) {
    Write-Host ('PROGRESS: {0} +{1:N1}s {2}' -f (Get-Date -Format 'HH:mm:ss'), $script:startWatch.Elapsed.TotalSeconds, $Message)
}
function Initialize-Native {
Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class CodexStartNative {

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
    return [CodexStartNative]::Git($script:repo,$Arguments,$InputFile,$OutputFile).TrimEnd("`r","`n")
}
$script:verifiedObjects=@{}
function Object-Id([string]$Value,[string]$Type) {
    $key=$Value+'/'+$Type;if($script:verifiedObjects.ContainsKey($key)){return}
    if ($Value -notmatch '^[a-f0-9]{40}([a-f0-9]{24})?$' -or (Git @('cat-file','-t',$Value)) -ne $Type) { throw "Invalid $Type object: $Value" }
    $script:verifiedObjects[$key]=$true
}
function Save-Receipt { Write-Json (Join-Path $script:runRoot 'receipt.json') $script:receipt }
function Report([string]$Result,[string]$Reason,[string]$Detail) {
    Write-Output "RESULT: $Result"; Write-Output 'AGENT: Codex'; Write-Output 'PHASE: Start'
    Write-Output ('REASON: '+($Reason -replace '[\r\n]+',' ')); Write-Output ('DETAIL: '+($Detail -replace '[\r\n]+',' '))
    Write-Output 'PUBLISHED_COMMIT: NONE'; Write-Output "SURVEY_REQUIRED: $script:survey"
}
function Query([string]$Path,[string]$Sql,[object[]]$Values=@()) {
    $db=New-Object CodexStartNative+Db($Path,$false)
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
        if([CodexStartNative]::SameData($Value,(Read-BlobJson $oid))){$script:reusedJson++;return $oid}
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
    $batch=[CodexStartNative]::JsonBlobs($script:repo,[string[]]$pending)
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

# Only keyed collections are unordered. Do not sort transcript records, lineage,
# or other arrays whose order carries app meaning.
function Comparable-SessionData($Comparison) {
    $copy=Parse-Json (Json $Comparison)
    $payloads=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach($payload in @($copy.payloads)){
        $key=[string]$payload.path
        if(-not$key){throw 'Invalid comparison payload path.'}
        if($payloads.ContainsKey($key)){
            # Older Start bases counted slash aliases twice. Only identical
            # attachment descriptors are redundant; conflicting bytes still fail.
            if($key.StartsWith('attachments/',[StringComparison]::Ordinal)-and(Rows-Equal $payloads[$key] $payload)){continue}
            throw 'Conflicting or duplicate comparison payload path.'
        }
        $payloads.Add($key,$payload)
    }
    $copy.payloads=$payloads
    $placement=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach($entry in @($copy.metadata.placement)){
        $key=[string]$entry.pointer
        if(-not$key-or$placement.ContainsKey($key)){throw 'Invalid or duplicate comparison placement pointer.'}
        $placement.Add($key,$entry.value)
    }
    $copy.metadata.placement=$placement
    return $copy
}
function Same-Comparison($Left,$Right) {
    return Rows-Equal (Comparable-SessionData $Left) (Comparable-SessionData $Right)
}
# This witness belongs only to the existing local basis tree, never publication.
# Local edits are compared to actual applied state; remote edits to received state.
function Remote-Witness($Session) {
    if($null-eq$Session){return $null}
    if($Session.State-eq'Deleted'){throw 'Deleted uses its existing minimal record, not a comparison witness.'}
    return [pscustomobject]@{state=$Session.State;comparison=$Session.Manifest.comparison}
}
function Accepted-RemoteWitness($Basis) {
    if($null-eq$Basis-or$Basis.State-eq'Deleted'){return $null}
    $witness=Field $Basis.Manifest 'acceptedRemoteComparison'
    if($null-eq$witness){return $null}
    if((@($witness.PSObject.Properties.Name|Sort-Object)-join ',')-ne'comparison,state'-or
        $witness.state-notin@('Active','Archived')-or
        [string]$witness.comparison.canonicalId-cne[string]$Basis.Manifest.canonicalId){
        throw 'Invalid accepted remote comparison in local basis.'
    }
    return $witness
}
function Copy-LocalBasis($Session,$Witness,$Output) {
    Copy-Session $Session $Output
    if($null-eq$Session-or$Session.State-eq'Deleted'-or$null-eq$Witness){return}
    $manifest=Parse-Json (Json $Session.Manifest)
    $manifest|Add-Member -NotePropertyName acceptedRemoteComparison -NotePropertyValue $Witness -Force
    $Output[$Session.Prefix+'manifest.json']=Blob-Json $manifest
}

function Copy-Session($Session,$Output) {
    if($null-eq$Session){return}
    foreach($path in $Session.Entries.Keys){if(($Session.State-eq'Deleted'-and$path-eq$Session.Prefix)-or($Session.State-ne'Deleted'-and$path.StartsWith($Session.Prefix,[StringComparison]::Ordinal))){$Output[$path]=$Session.Entries[$path]}}
    if($Session.State-ne'Deleted'-and($null-ne(Field $Session.Manifest 'acceptedRemoteComparison')-or$null-ne(Field $Session.Manifest 'confirmedAppDeletion'))){
        $manifest=Parse-Json (Json $Session.Manifest)
        $manifest.PSObject.Properties.Remove('acceptedRemoteComparison')
        $manifest.PSObject.Properties.Remove('confirmedAppDeletion')
        $Output[$Session.Prefix+'manifest.json']=Blob-Json $manifest
    }

}
function Same-LocalSnapshot($A,$B) {
    if((Field $A 'Incomplete' $false)-or(Field $B 'Incomplete' $false)){return $false}
    if($null-eq$A-or$null-eq$B){return $null-eq$A-and$null-eq$B}
    if($A.State-eq'Deleted'-or$B.State-eq'Deleted'){
        if($A.State-ne$B.State){return $false}
        return Rows-Equal $A.Manifest $B.Manifest
    }
    # The Vault tier follows sync policy; it is not the native app archive flag.
    # Compare the actual app state recorded by Finish with the app state now.
    $aArchived=Field (Field (Get-Projection $A) 'state') 'archived'
    $bArchived=Field (Field (Get-Projection $B) 'state') 'archived'
    foreach($flag in @($aArchived,$bArchived)){
        if(($flag-isnot[int]-and$flag-isnot[long])-or$flag-notin@(0,1)){Survey 'Local comparison projection lacks the surveyed archive flag.'}
    }
    if($aArchived-ne$bArchived){return $false}
    return Same-Comparison $A.Manifest.comparison $B.Manifest.comparison
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
        }catch{$script:analysisRefs=@{};Write-CodexStartProgress 'Analysis cache could not be read; full validation remains available'}
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
            }catch{Write-CodexStartProgress ("Analysis cache unavailable; validating original: {0}" -f $name)}
        }
    }
    if($null-ne$page){
        $page.Path=$Path
        $script:analysedSources[$Path]=$raw
        $script:rolloutAnalysis[$key]=$page
        Write-CodexStartProgress ("Reusing verified rollout analysis: {0}" -f $name)
        return $page
    }
    $page=Inspect-RolloutFull $Path
    $after=Get-Item -LiteralPath $Path
    if($page.Sha256-cne$raw-or$after.Length-ne$length-or$after.LastWriteTimeUtc.Ticks-ne$stamp){throw "Rollout changed during analysis: $Path"}
    $saved=[ordered]@{schemaVersion=1;rules=$script:analysisRules;sha256=$raw;length=$length;name=$name;id=$page.Id;alias=$page.Alias;meta=$page.Meta;last=$(if($null-ne$page.Last){$page.Last.ToUniversalTime().ToString('o')}else{$null});boundaries=$page.Boundaries;texts=@($page.Texts)}
    try{$oid=Blob-Json $saved;Git @('update-ref',$ref,$oid)|Out-Null}
    catch{Write-CodexStartProgress ('Analysis cache could not be saved; original validation still completed: '+$name)}
    $script:rolloutAnalysis[$key]=$page
    $script:analysedSources[$Path]=$raw
    return $page
}

function Inspect-RolloutFull([string]$Path) {
    $types=@('session_meta','event_msg','response_item','world_state','turn_context','compacted','inter_agent_communication_metadata','token_usage_record')
    $versions=@('0.146.0-alpha.9.2','0.147.0-alpha.6.6','0.149.0-alpha.4.3','0.150.0-alpha.8','0.151.0-alpha.7.1','0.151.0-alpha.7.2','0.152.0','0.153.0-alpha.5','0.153.1','0.153.3')
    Write-CodexStartProgress ("Inspecting rollout: {0}" -f [IO.Path]::GetFileName($Path))
    $scanWatch=[Diagnostics.Stopwatch]::StartNew();$nextScanNotice=5
    $meta=$null;$last=$null;$count=0;$boundaries=@{};$userTexts=New-Object 'Collections.Generic.List[string]'
    foreach($line in [CodexStartNative]::Lines($Path)) {
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
        if($scanWatch.Elapsed.TotalSeconds-ge$nextScanNotice){
            Write-CodexStartProgress ("Rollout {0}: {1} records checked, {2:N1} MiB read" -f [IO.Path]::GetFileName($Path),$count,($line.End/1MB))
            $nextScanNotice=$scanWatch.Elapsed.TotalSeconds+5
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
function Get-TransportedAttachmentRelative($Session,[string]$Reference) {
    $normal=$Reference.Replace('\','/');$found=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach($payload in @($Session.Manifest.payloads)){
        $logical=[string]$payload.path
        if(-not$logical.StartsWith('attachments/attachments/',[StringComparison]::Ordinal)){continue}
        $relative=$logical.Substring('attachments/'.Length)
        if($normal.EndsWith('/'+$relative,[StringComparison]::OrdinalIgnoreCase)){
            if($found.ContainsKey($relative)){
                if(-not(Rows-Equal $found[$relative] $payload)){throw "Conflicting attachment transport descriptors: $Reference"}
            }else{$found.Add($relative,$payload)}
        }
    }
    if($found.Count-ne1){throw "Attachment reference has no unique relative transport path: $Reference"}
    return @($found.Keys)[0]
}
function Find-AttachmentSourceReference([string]$Path,$Pages,$Base,$Remote,[string]$VaultId) {
    $candidates=New-Object 'Collections.Generic.List[string]';$candidates.Add($Path)
    $full=[IO.Path]::GetFullPath($Path)
    if(-not$full.StartsWith($script:appHome+'\attachments\',[StringComparison]::OrdinalIgnoreCase)){throw "Attachment index path escapes configured Home: $Path"}
    $relative=$full.Substring($script:appHome.Length).TrimStart('\','/').Replace('\','/')
    foreach($set in @($Base,$Remote)){
        if(-not$set.ContainsKey($VaultId)-or$set[$VaultId].State-eq'Deleted'){continue}
        $session=$set[$VaultId];$projection=Read-BlobJson $session.Entries[$session.Prefix+'projection.json']
        foreach($reference in @(Field $projection 'attachmentReferences' @())){
            if((Get-TransportedAttachmentRelative $session ([string]$reference))-ceq$relative-and-not$candidates.Contains([string]$reference)){$candidates.Add([string]$reference)}
        }
    }
    foreach($reference in $candidates){foreach($page in $Pages){foreach($text in $page.Texts){if($text.Contains($reference)){return $reference}}}}
    return $null
}
function New-IncompleteLocalSession([string]$Id,$Pages,[string]$Issue,$Base,$Remote) {
    # An inventory item, never a publishable or accepted snapshot. Only app-issued
    # canonical identity is used; missing bytes are not fabricated from metadata.
    $vaultId=$Id
    $mapped=@{}
    foreach($set in @($Base,$Remote)){foreach($entry in $set.GetEnumerator()){
        if($entry.Value.State-ne'Deleted'-and$entry.Value.Manifest.canonicalId-eq$Id){$mapped[$entry.Key]=$true}
    }}
    if($mapped.Count-gt1){throw "Ambiguous Vault identity for incomplete local session: $Id"}
    if($mapped.Count){$vaultId=[string]@($mapped.Keys)[0]}
    $lineage=@(@($Id)+@($Pages|ForEach-Object{$_.Alias})|Sort-Object -Unique)
    $remoteState=if($Remote.ContainsKey($vaultId)){$Remote[$vaultId].State}else{'Absent'}
    Write-CodexStartProgress ("Local session {0}: {1}; remote={2}. Inventory only; no local data changed." -f $Id,$Issue,$remoteState)
    return [pscustomobject]@{
        State='Active';Incomplete=$true;Issue=$Issue;Prefix="Active/$vaultId/";Entries=@{};
        Manifest=[pscustomobject]@{vaultSessionId=$vaultId;canonicalId=$Id;lineageIds=$lineage};
        LocalPages=@($Pages);NeedsArchive=$false
    }
}
function Prepare-Local($Base,$Remote,[switch]$InventoryIncomplete) {
    Index-ReusablePayloads $Base $Remote
    $pages=New-Object 'Collections.Generic.List[object]'
    foreach($relative in @('sessions','archived_sessions')){
        $root=Resolve-Within $script:appHome $relative
        if(Test-Path -LiteralPath $root){foreach($f in Get-ChildItem -LiteralPath $root -Filter '*.jsonl' -File -Recurse){Resolve-Within $script:appHome $f.FullName.Substring($script:appHome.Length).TrimStart('\','/')|Out-Null;$pages.Add((Inspect-Rollout $f.FullName))}}
    }
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
    Write-CodexStartProgress 'Indexing global references once for this local snapshot'
    $referenceIds=@($pages|ForEach-Object{$_.Id;$_.Alias})
    $globalIndex=New-GlobalReferenceIndex $global $referenceIds
    $indexPath=Resolve-Within $script:appHome 'session_index.jsonl';$index=New-Object 'Collections.Generic.List[object]'
    if(Test-Path -LiteralPath $indexPath){foreach($line in [CodexStartNative]::Lines($indexPath)){if($line.Text){$index.Add((Parse-Json $line.Text))}}}
    $attachmentPath=Resolve-Within $script:appHome 'attachments/pasted-text-attachments.json';$attachmentIndex=$null
    if(Test-Path -LiteralPath $attachmentPath){$attachmentIndex=Read-Json $attachmentPath}
    $result=@{}
    $sessionNumber=0
    foreach($id in @($groups.Keys|Sort-Object)){
        $sessionNumber++
        Write-CodexStartProgress ("Building local comparison {0}/{1}: {2}" -f $sessionNumber,$groups.Count,$id)
        if(-not$byId.ContainsKey($id)){
            $issue='Rollout has no canonical state row'
            if(-not$InventoryIncomplete){throw "$issue : $id"}
            $item=New-IncompleteLocalSession $id $groups[$id].ToArray() $issue $Base $Remote
            $result[$item.Manifest.vaultSessionId]=$item;continue
        }
        $row=$byId[$id];$sessionPages=@($groups[$id].ToArray()|Sort-Object Name)
        $latest=[IO.Path]::GetFullPath([string]$row['rollout_path'])
        $latestKey=Get-RolloutComparisonPath $latest
        if(@($sessionPages|Where-Object{[string]::Equals((Get-RolloutComparisonPath $_.Path),$latestKey,[StringComparison]::OrdinalIgnoreCase)}).Count-ne1){
            if(-not$InventoryIncomplete){throw "Canonical latest path does not resolve to a collected original: $id"}
            $item=New-IncompleteLocalSession $id $sessionPages 'Canonical latest path has no collected original' $Base $Remote
            $result[$item.Manifest.vaultSessionId]=$item;continue
        }
        $last=$null;foreach($page in $sessionPages){if($null-ne$page.Last-and($null-eq$last-or$page.Last-gt$last)){$last=$page.Last}}
        if ($null -eq $last -and (Field $sessionPages[0].Meta 'thread_source') -eq 'guardian_review') {
            $parent=[string](Field $sessionPages[0].Meta 'parent_thread_id')
            if ($groups.ContainsKey($parent)) {
                # A guardian with no dialogue uses real dialogue in its explicitly
                # linked parent conversation. Its own canonical identity is retained.
                foreach ($parentPage in $groups[$parent]) { if ($null -ne $parentPage.Last -and ($null -eq $last -or $parentPage.Last -gt $last)) { $last=$parentPage.Last } }
            }
        }
        if($null-eq$last){throw "No valid dialogue timestamp for $id or its surveyed parent conversation; cannot apply the configured 30-day rule."}
        $vaultId=$id
        foreach($collection in @($Base,$Remote)){
            foreach($entry in $collection.GetEnumerator()){
                if($entry.Value.State-ne'Deleted'-and$entry.Value.Manifest.canonicalId-eq$id){
                    if($vaultId-ne$id-and$vaultId-ne$entry.Key){throw "Ambiguous Vault identity: $id"};$vaultId=$entry.Key
                }
            }
        }

        # The native archive flag is app metadata, not a Vault tier decision.
        # Before applying, retain the accepted tier (or the received tier on a
        # first Start). After applying, both inputs are the received snapshot.
        # An untracked local session is inventoried as Active; Start does not
        # make the Finish age-policy decision or infer deletion from this flag.
        $state='Active'
        foreach($collection in @($Base,$Remote)){
            if($collection.ContainsKey($vaultId)-and$collection[$vaultId].State-ne'Deleted'){
                $state=$collection[$vaultId].State
                break
            }
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
        $ownedPaths=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach($path in @(Field $attachmentIndex 'attachmentPaths' @())){
            $reference=Find-AttachmentSourceReference ([string]$path) $sessionPages $Base $Remote $vaultId
            if($reference){$full=[IO.Path]::GetFullPath([string]$path);$relative=$full.Substring($script:appHome.Length).TrimStart('\','/');Resolve-Within $script:appHome $relative|Out-Null
                if(-not(Test-Path -LiteralPath $full -PathType Leaf)){throw "Missing owned attachment for $id : $path"}
                # Index entries may spell the same Windows file with either separator.
                # Keep original transcript text; package each physical path once.
                if(-not$ownedPaths.Add($full)){continue}
                $owned.Add([string]$reference);$inventory.Add((Package-Payload $full ('attachments/'+$relative.Replace('\','/')) $files))}
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
        $manifest=[ordered]@{schemaVersion=1;vaultSessionId=$vaultId;canonicalId=$id;lineageIds=$ids;lastActivityAt=$last.ToUniversalTime().ToString('o');comparison=$comparison;payloads=$inventory.ToArray()}
        $files['manifest.json']=Reuse-Json $manifest $priorManifests
        $entries=@{};foreach($path in $files.Keys){$entries["$state/$vaultId/$path"]=$files[$path]}
        $result[$vaultId]=[pscustomobject]@{State=$state;Manifest=$manifest;Prefix="$state/$vaultId/";Entries=$entries;LocalPages=$sessionPages;NeedsArchive=($state-eq'Archived'-and[long]$row['archived']-eq0)}
    }
    foreach($id in $byId.Keys){if(-not$groups.ContainsKey($id)){
        if(-not$InventoryIncomplete){throw "Incomplete local session: state row $id has no rollout. This is not deletion evidence."}
        $item=New-IncompleteLocalSession $id @() 'State row has no rollout; this is not deletion evidence' $Base $Remote
        $result[$item.Manifest.vaultSessionId]=$item
    }}
    return $result
}

function Verify-StoredSessions($Sessions) {
    $verifiedNumber=0
    foreach($s in $Sessions.Values){
        $verifiedNumber++
        Write-CodexStartProgress ("Verifying stored session {0}/{1}: {2}" -f $verifiedNumber,$Sessions.Count,$s.Prefix)
        if($s.State-eq'Deleted'){continue}
        $projection=$s.Prefix+'projection.json'
        if(-not$s.Entries.ContainsKey($projection)){throw "Stored session projection missing: $($s.Prefix)"}
        Read-BlobJson $s.Entries[$projection] | Out-Null
        Get-StoredCatalogRows $s | Out-Null
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

function Quote-SqlName([string]$Name) {
    if ($Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "Unsafe SQL identifier: $Name" }
    return '"' + $Name + '"'
}

function Insert-Row($Db,[string]$Table,$Row,[hashtable]$Overrides=@{}) {
    $values=[ordered]@{}
    foreach($property in $Row.PSObject.Properties){$values[$property.Name]=$property.Value}
    foreach($key in $Overrides.Keys){$values[$key]=$Overrides[$key]}
    $columns=@($values.Keys)
    if($columns.Count-eq0){return}
    $names=@($columns|ForEach-Object{Quote-SqlName $_}) -join ','
    $marks=@($columns|ForEach-Object{'?'}) -join ','
    $parameters=[object[]]::new($columns.Count)
    for($i=0;$i-lt$columns.Count;$i++){$parameters[$i]=$values[$columns[$i]]}
    $Db.Query(('INSERT INTO '+(Quote-SqlName $Table)+' ('+$names+') VALUES ('+$marks+')'),$parameters)|Out-Null
}
function New-StartReceipt {
    $script:receipt=[ordered]@{schemaVersion=1;runId=$RunId;repository=$script:repo;appHome=$script:appHome;status='checking';backups=@()}
    Save-Receipt
}
function Find-Backup([string]$Path) {
    foreach($item in @($script:receipt.backups)){if([string]::Equals([string]$item.path,$Path,[StringComparison]::OrdinalIgnoreCase)){return $item}}
    return $null
}
function Backup-Path([string]$Path,[string]$ExpectedAfterHash='') {
    $absolute=[IO.Path]::GetFullPath($Path)
    if(-not$absolute.StartsWith($script:appHome+'\',[StringComparison]::OrdinalIgnoreCase)){throw "Backup target escapes app home: $absolute"}
    $existing=Find-Backup $absolute
    if($null-ne$existing){if($ExpectedAfterHash){$existing.expectedAfterHash=$ExpectedAfterHash;Save-Receipt};return}
    $item=[ordered]@{path=$absolute;existed=[IO.File]::Exists($absolute);beforeHash='';backup='';expectedAfterHash=$ExpectedAfterHash}
    if($item.existed){
        $item.beforeHash=Hash $absolute;$item.backup=Join-Path $script:runRoot ('backup-'+@($script:receipt.backups).Count+'.bin')
        [IO.File]::Copy($absolute,$item.backup,$false)
        if((Hash $item.backup)-ne$item.beforeHash){throw "Backup verification failed: $absolute"}
    }
    $script:receipt.backups+=@($item);Save-Receipt
}
function Restore-Start {
    $errors=New-Object 'Collections.Generic.List[string]'
    $items=@($script:receipt.backups)
    for($i=$items.Count-1;$i-ge0;$i--){
        $item=$items[$i]
        try{
            $path=[IO.Path]::GetFullPath([string]$item.path)
            if(-not$path.StartsWith($script:appHome+'\',[StringComparison]::OrdinalIgnoreCase)){throw "Recovery target escapes app home: $path"}
            if($item.existed){
                if(-not[IO.File]::Exists([string]$item.backup)-or(Hash ([string]$item.backup))-ne[string]$item.beforeHash){throw "Recovery backup is missing or corrupt: $path"}
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))|Out-Null
                [IO.File]::Copy([string]$item.backup,$path,$true)
                if((Hash $path)-ne[string]$item.beforeHash){throw "Recovery verification failed: $path"}
            }elseif([IO.File]::Exists($path)){
                $expected=[string](Field $item 'expectedAfterHash' '')
                if(-not$expected-or(Hash $path)-ne$expected){throw "Unproved file at a previously absent path was retained: $path"}
                [IO.File]::Delete($path)
            }
        }catch{$errors.Add($_.Exception.Message)}
    }
    if($errors.Count){throw ('Start recovery incomplete: '+($errors -join '; ')+' Recovery material: '+$script:runRoot)}
    $script:receipt.status='restored';Save-Receipt
}
function Clear-StartReceipt {
    if(Test-Path -LiteralPath $script:runRoot){Remove-Item -LiteralPath $script:runRoot -Recurse -Force}
}
function Stage-Blob([string]$Oid,[string]$Name) {
    Object-Id $Oid 'blob'
    $path=Join-Path $script:runRoot $Name
    Git @('cat-file','blob',$Oid) $null $path|Out-Null
    return $path
}
function Materialize-Payload($Session,$Payload) {
    $relative=[string](Field $Payload 'transportPath');if(-not$relative){throw 'Payload transport path is missing.'}
    $markerRef=Get-TransportMarkerRef $Payload
    if($script:transportRaw.ContainsKey($markerRef)){
        $ready=$script:transportRaw[$markerRef]
        if([IO.File]::Exists($ready)-and(Get-Item -LiteralPath $ready).Length-eq[long]$Payload.length-and(Hash $ready)-ceq[string]$Payload.sha256){return $ready}
    }
    $sourceKey=[string]$Payload.sha256+'-'+$Payload.length
    if($script:transportSources.ContainsKey($sourceKey)){
        $local=$script:transportSources[$sourceKey]
        if([IO.File]::Exists($local)-and(Get-Item -LiteralPath $local).Length-eq[long]$Payload.length-and(Hash $local)-ceq[string]$Payload.sha256){
            # Keep this copy independent of later app-local removal/replacement.
            $ready=Join-Path $script:runRoot ([guid]::NewGuid().ToString('N')+'.local-raw')
            [IO.File]::Copy($local,$ready);$script:transportRaw[$markerRef]=$ready;return $ready
        }
    }
    $entryPath=$Session.Prefix+$relative
    if(-not$Session.Entries.ContainsKey($entryPath)){throw "Payload blob is missing: $entryPath"}
    if($relative.EndsWith('.gz.parts.json',[StringComparison]::Ordinal)){
        $restored=Expand-SplitGzip $Session.Entries $Session.Prefix $relative
        if((Get-Item -LiteralPath $restored).Length-ne[long]$Payload.length-or(Hash $restored)-ne[string]$Payload.sha256){throw "Split payload verification failed: $entryPath"}
        Save-TransportMarker $Session.Entries $Session.Prefix $Payload $restored
        return $restored
    }
    $transport=Stage-Blob $Session.Entries[$entryPath] ([guid]::NewGuid().ToString()+'.transport')
    $raw=$transport
    if($relative.EndsWith('.gz',[StringComparison]::OrdinalIgnoreCase)){
        $integrityPath=$entryPath+'.integrity.json'
        if(-not$Session.Entries.ContainsKey($integrityPath)){throw "Gzip integrity record is missing: $entryPath"}
        $integrity=Read-BlobJson $Session.Entries[$integrityPath]
        if((Get-Item -LiteralPath $transport).Length-ne[long]$integrity.gzipLength-or(Hash $transport)-ne[string]$integrity.gzipSha256){throw "Gzip transport verification failed: $entryPath"}
        $raw=Join-Path $script:runRoot ([guid]::NewGuid().ToString()+'.raw')
        $input=[IO.File]::OpenRead($transport);$output=[IO.File]::Create($raw)
        try{$gzip=New-Object IO.Compression.GZipStream($input,[IO.Compression.CompressionMode]::Decompress,$true);try{$gzip.CopyTo($output)}finally{$gzip.Dispose()}}finally{$input.Dispose();$output.Dispose()}
        if((Get-Item -LiteralPath $raw).Length-ne[long]$integrity.rawLength-or(Hash $raw)-ne[string]$integrity.rawSha256){throw "Gzip round-trip verification failed: $entryPath"}
    }
    if((Get-Item -LiteralPath $raw).Length-ne[long]$Payload.length-or(Hash $raw)-ne[string]$Payload.sha256){throw "Payload verification failed: $entryPath"}
    if($relative.EndsWith('.gz',[StringComparison]::OrdinalIgnoreCase)){Save-TransportMarker $Session.Entries $Session.Prefix $Payload $raw}
    return $raw
}
function Get-RolloutDestination($Session,[string]$Source,[string]$Name) {
    $first=$null
    $reader=New-Object IO.StreamReader($Source,$script:utf8,$true)
    try{while($null-ne($line=$reader.ReadLine())){if($line){$first=Parse-Json $line;break}}}finally{$reader.Dispose()}
    if($null-eq$first-or(Field $first 'type')-ne'session_meta'){throw "Restored rollout has no initial session_meta: $Name"}
    $stamp=[DateTimeOffset]::MinValue
    if(-not[DateTimeOffset]::TryParse([string](Field (Field $first 'payload') 'timestamp'),[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$stamp)){throw "Restored rollout timestamp is invalid: $Name"}
    if($Session.State-eq'Archived'-or(Get-NativeArchiveFlag $Session)-eq1){return Resolve-Within $script:appHome ('archived_sessions/'+$Name)}
    return Resolve-Within $script:appHome ('sessions/'+$stamp.UtcDateTime.ToString('yyyy/MM/dd',[Globalization.CultureInfo]::InvariantCulture)+'/'+$Name)
}
function Write-PreparedFile([string]$Source,[string]$Destination) {
    $hash=Hash $Source;Backup-Path $Destination $hash
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination))|Out-Null
    $temp=$Destination+'.agent-session-sync-'+$RunId
    [IO.File]::Copy($Source,$temp,$false)
    try{
        if([IO.File]::Exists($Destination)){$replaceBackup=Join-Path $script:runRoot ([guid]::NewGuid().ToString()+'.replace');[IO.File]::Replace($temp,$Destination,$replaceBackup);[IO.File]::Delete($replaceBackup)}
        else{[IO.File]::Move($temp,$Destination)}
    }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
    if((Hash $Destination)-ne$hash){throw "Applied file verification failed: $Destination"}
}
function Remove-BackedFile([string]$Path) {
    if(-not[IO.File]::Exists($Path)){return}
    Backup-Path $Path
    [IO.File]::Delete($Path)
}
function Get-Projection($Session) {
    $path=$Session.Prefix+'projection.json'
    if(-not$Session.Entries.ContainsKey($path)){throw "Projection is missing: $($Session.Prefix)"}
    return Read-BlobJson $Session.Entries[$path]
}
function Get-NativeArchiveFlag($Session) {
    $flag=Field (Field (Get-Projection $Session) 'state') 'archived'
    if(($flag-isnot[int]-and$flag-isnot[long])-or$flag-notin@(0,1)){Survey 'Stored app projection lacks the surveyed archive flag.'}
    return [int]$flag
}
function Get-StoredCatalogRows($Session) {
    $id=[string]$Session.Manifest.canonicalId
    $projection=Get-Projection $Session
    $archived=Get-NativeArchiveFlag $Session
    $source=[string](Field (Field $projection 'state') 'thread_source')
    if($source-notin@('user','agent_created_thread','guardian_review')){Survey "Unsurveyed stored thread source: $id"}
    $rows=@(Field $projection 'catalog' @())
    if($rows.Count-gt1){throw "Ambiguous portable catalog records: $id"}
    if($rows.Count-eq0){
        # Finish already accepts native archived threads and guardian review
        # threads without a desktop catalog row. Preserve that observed absence.
        if($archived-eq0-and$source-ne'guardian_review'){throw "Active session has no unambiguous portable catalog record: $id"}
    }elseif([string](Field $rows[0] 'thread_id')-ne$id){throw "Portable catalog identifies another thread: $id"}
    return ,$rows
}
function Assert-TargetMappings($Remote,$Current) {
    # Metadata is now prepared for the target, not required to pre-exist per thread.
    $activeIds=@($Remote.Values|Where-Object{$_.State-eq'Active'}|ForEach-Object{[string]$_.Manifest.canonicalId})
    $removedIds=@($Current.Values|ForEach-Object{[string]$_.Manifest.canonicalId}|Where-Object{$_-notin$activeIds})
    $script:receiveMetadata=New-ReceiveMetadataPlan $Remote $removedIds
    foreach($session in $Remote.Values){if($session.State-ne'Active'){continue}
        $projection=Get-Projection $session
        foreach($pair in @(@('project_id','projects'),@('thread_section_id','thread_sections'))){
            $foreign=Field $projection.state $pair[0]
            if($pair[0]-eq'project_id'-and$foreign){$foreign=Get-ReceiveProjectId ([string]$foreign)}
            if($foreign-and(Query (Join-Path $script:appHome 'state_5.sqlite') ('SELECT id FROM '+$pair[1]+' WHERE id=?') @($foreign)).Count-ne1){throw "Target $($pair[1]) mapping missing: $foreign. No app data was removed."}
        }
    }
}
# Receive placement uses the environment configured by Initialize.
function Assert-ReceivePath([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    if(-not$full.StartsWith($script:appHome+'\',[StringComparison]::OrdinalIgnoreCase)){throw "Receive path escapes Codex Home: $full"}
    $cursor=$full
    while($cursor-and$cursor.Length-ge$script:appHome.Length){
        if(Test-Path -LiteralPath $cursor){if((Get-Item -LiteralPath $cursor -Force).Attributes-band[IO.FileAttributes]::ReparsePoint){throw "Receive path is a reparse point: $cursor"}}
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
    return $full
}
function Set-ReceiveMember($Object,[string]$Name,$Value) {
    $prop=$Object.PSObject.Properties[$Name]
    if($null-ne$prop){$prop.Value=$Value}else{$Object|Add-Member -MemberType NoteProperty -Name $Name -Value $Value}
}
function Receive-Object($Parent,[string]$Key) {
    $prop=$Parent.PSObject.Properties[$Key]
    if($null-eq$prop){$value=[pscustomobject]@{};Set-ReceiveMember $Parent $Key $value;return $value}
    if($prop.Value-isnot[pscustomobject]){Survey "Unknown target object shape: $Key"}
    return $prop.Value
}
function Get-ReceiveProjectId([string]$Id) {
    if($script:receiveConfig.ContainsKey('ProjectIdMappings')-and$script:receiveConfig.ProjectIdMappings.ContainsKey($Id)){return [string]$script:receiveConfig.ProjectIdMappings[$Id]}
    return $Id
}
function Get-ReceiveProject([string]$Id,$Global) {
    $mapped=Get-ReceiveProjectId $Id
    $projects=Field $Global 'local-projects'
    if($mapped-eq$Id-and-not($script:receiveConfig.ContainsKey('ProjectIdMappings')-and$script:receiveConfig.ProjectIdMappings.ContainsKey($Id))-and$projects-and$null-eq$projects.PSObject.Properties[$mapped]-and$script:receiveCwd){
        $targetCwd=Get-RolloutComparisonPath (Get-ReceivePathValue $script:receiveCwd)
        $matching=@($projects.PSObject.Properties|Where-Object {
            $found=$false
            foreach($root in @(Field $_.Value 'rootPaths' @())){
                if($root-is[string]-and[IO.Path]::IsPathRooted($root)-and
                    [string]::Equals((Get-RolloutComparisonPath $root).TrimEnd('\'),$targetCwd.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)){$found=$true}
            }
            $found
        })
        if($matching.Count-gt1){throw "Multiple target projects match the received workspace for $Id. Configure Codex.ProjectIdMappings; no session was discarded."}
        if($matching.Count-eq1){$mapped=$matching[0].Name}
    }
    if($null-eq$projects-or$null-eq$projects.PSObject.Properties[$mapped]){
        $workspace=if($script:receiveCwd){Get-ReceivePathValue $script:receiveCwd}else{'not supplied'}
        $registered=if($projects){@($projects.PSObject.Properties.Name)-join', '}else{'none'}
        throw "Target project registration is missing: $Id. Target workspace=$workspace; requested target ID=$mapped; registered IDs=$registered. Register it on this PC or configure Codex.ProjectIdMappings; no session was discarded."
    }
    $project=$projects.PSObject.Properties[$mapped].Value
    $roots=$project.PSObject.Properties['rootPaths']
    if($null-eq$roots-or$roots.Value-isnot[Array]-or$roots.Value.Count-eq0){Survey "Unknown target project roots: $mapped"}
    foreach($root in $roots.Value){if($root-isnot[string]-or-not[IO.Path]::IsPathRooted($root)-or-not[IO.Directory]::Exists($root)){throw "Target project root is unavailable: $root"}}
    return $mapped
}
function Get-ReceivePathValue([string]$Path) {
    if(-not[IO.Path]::IsPathRooted($Path)){throw "Unrooted source placement path: $Path"}
    $full=[IO.Path]::GetFullPath($Path)
    if($script:receiveConfig.ContainsKey('PathMappings')){
        # Use the same Windows comparison namespace as rollout identity. Extended
        # paths are compared without stripping their literal path semantics.
        $pathKey=Get-RolloutComparisonPath $full
        $prefixes=@{}
        foreach($source in $script:receiveConfig.PathMappings.Keys){
            $prefix=(Get-RolloutComparisonPath ([string]$source)).TrimEnd('\')
            $target=[IO.Path]::GetFullPath([string]$script:receiveConfig.PathMappings[$source])
            if($prefixes.ContainsKey($prefix)-and-not[string]::Equals((Get-RolloutComparisonPath $prefixes[$prefix]),(Get-RolloutComparisonPath $target),[StringComparison]::OrdinalIgnoreCase)){
                throw 'Equivalent Codex.PathMappings source prefixes have conflicting destinations.'
            }
            $prefixes[$prefix]=$target
        }
        foreach($prefix in @($prefixes.Keys|Sort-Object Length -Descending)){
            if([string]::Equals($pathKey,$prefix,[StringComparison]::OrdinalIgnoreCase)-or$pathKey.StartsWith($prefix+'\',[StringComparison]::OrdinalIgnoreCase)){
                $suffix=$pathKey.Substring($prefix.Length)
                if(-not$suffix){return $prefixes[$prefix]}
                return $prefixes[$prefix].TrimEnd('\','/')+$suffix
            }
        }
    }
    return $full
}
function Set-ReceiveUnreadMembership($Global,$Remote,[string[]]$RemovedIds,[string[]]$Incoming) {
    # The surveyed local unread array is membership, not a portable array slot.
    # Other host buckets and references outside this receive scope survive.
    $affected=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($id in $RemovedIds){[void]$affected.Add($id)}
    foreach($session in $Remote.Values){
        foreach($id in @($session.Manifest.lineageIds)){[void]$affected.Add([string]$id)}
        if($session.State-ne'Deleted'){[void]$affected.Add([string]$session.Manifest.canonicalId)}
    }
    $electron=Field $Global 'electron-persisted-atom-state'
    if($null-ne$electron-and$electron-isnot[pscustomobject]){Survey 'Unknown target electron state shape.'}
    $hosts=Field $electron 'unread-thread-ids-by-host-v1'
    if($null-ne$hosts-and$hosts-isnot[pscustomobject]){Survey 'Unknown target unread host map.'}
    $property=if($null-ne$hosts){$hosts.PSObject.Properties['local']}else{$null}
    $old=@()
    if($null-ne$property){
        if($property.Value-isnot[Array]){Survey 'Unknown target local unread membership.'}
        foreach($id in $property.Value){if($id-isnot[string]){Survey 'Unknown target local unread member.'}}
        $old=$property.Value
    }
    if($null-eq$property-and$Incoming.Count-eq0){return}
    $wanted=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($id in $Incoming){[void]$wanted.Add($id)}
    $next=New-Object 'Collections.Generic.List[string]'
    foreach($id in $old){
        if(-not$affected.Contains($id)){$next.Add($id)}
        elseif($wanted.Contains($id)-and-not$next.Contains($id)){$next.Add($id)}
    }
    foreach($id in @($Incoming|Sort-Object -CaseSensitive -Unique)){if(-not$next.Contains($id)){$next.Add($id)}}
    $target=Receive-Object (Receive-Object $Global 'electron-persisted-atom-state') 'unread-thread-ids-by-host-v1'
    Set-ReceiveMember $target 'local' $next.ToArray()
}
function New-ReceiveMetadataPlan($Remote,[string[]]$RemovedIds) {
    $globalPath=Assert-ReceivePath (Join-Path $script:appHome '.codex-global-state.json')
    $global=if([IO.File]::Exists($globalPath)){Read-Json $globalPath}else{[pscustomobject]@{}}
    if($global-isnot[pscustomobject]){Survey 'Unknown Codex global-state root.'}
    $before=Json $global
    $perThread=@('prompt-history','thread-descriptions-v1')
    # Only measured session placement/content keys are removed. Permissions,
    # writable roots, project registrations and unrelated app preferences survive.
    foreach($id in $RemovedIds){
        foreach($key in @('thread-project-assignments','thread-workspace-root-hints','thread-projectless-output-directories')){
            $map=Field $global $key;if($null-ne$map){if($map-isnot[pscustomobject]){Survey "Unknown $key shape"};$map.PSObject.Properties.Remove($id)}
        }
        $electron=Field $global 'electron-persisted-atom-state'
        foreach($key in $perThread){$map=Field $electron $key;if($null-ne$map){if($map-isnot[pscustomobject]){Survey "Unknown $key shape"};$map.PSObject.Properties.Remove($id)}}
        $bindings=Field $electron 'client-thread-bindings-v1'
        if($bindings){foreach($prop in @($bindings.PSObject.Properties)){if($prop.Value-eq$id){$bindings.PSObject.Properties.Remove($prop.Name)}}}
    }
    $orders=Field $global 'sidebar-project-thread-orders'
    if($orders){foreach($prop in @($orders.PSObject.Properties)){
        $value=$prop.Value;$ids=$value.PSObject.Properties['threadIds']
        if($null-eq$ids-or$ids.Value-isnot[Array]){Survey 'Unknown sidebar project order shape.'}
        $ids.Value=@($ids.Value|Where-Object{$_-notin$RemovedIds})
    }}
    $projectless=$global.PSObject.Properties['projectless-thread-ids']
    if($null-ne$projectless){if($projectless.Value-isnot[Array]){Survey 'Unknown projectless thread list.'};$projectless.Value=@($projectless.Value|Where-Object{$_-notin$RemovedIds})}
    $ordered=@{};$sourceAttachments=New-Object 'Collections.Generic.List[string]'
    $unreadIds=New-Object 'Collections.Generic.List[string]'
    foreach($session in $Remote.Values){
        if($session.State-ne'Active'){continue}
        $id=[string]$session.Manifest.canonicalId;$projection=Get-Projection $session
        $script:receiveCwd=[string](Field $projection.state 'cwd' '')
        foreach($ref in @(Field $projection 'globalReferences' @())){
            $pointer=[string]$ref.pointer;$value=$ref.value
            if($pointer-eq('/electron-persisted-atom-state/heartbeat-thread-permissions-by-id/'+$id)-or$pointer-eq('/thread-writable-roots/'+$id)){continue}
            if($pointer-like '/electron-persisted-atom-state/client-thread-bindings-v1/*'-or$pointer-eq('/electron-remote-hosted-pip-task-visibility-state/'+$id)){continue}
            if($pointer-eq('/electron-persisted-atom-state/prompt-history/'+$id)-or$pointer-eq('/electron-persisted-atom-state/thread-descriptions-v1/'+$id)){
                $key=($pointer-split'/')[2];$map=Receive-Object (Receive-Object $global 'electron-persisted-atom-state') $key
                if(($key-eq'prompt-history'-and$value-isnot[Array])-or($key-eq'thread-descriptions-v1'-and$value-isnot[string])){Survey "Unknown remote $key value"}
                Set-ReceiveMember $map $id $value;continue
            }
            if($pointer-match '^/electron-persisted-atom-state/unread-thread-ids-by-host-v1/local/[0-9]+$'){
                if($value-isnot[string]-or$value-cne$id){Survey 'Invalid local unread thread reference.'}
                $unreadIds.Add($id);continue
            }
            if($pointer-match '^/app-server-migrated-pinned-thread-ids-by-host/[^/]+/[0-9]+$'){
                # Surveyed host migration completion, not portable pinned state.
                # The app keys markThreadMigrated/getMigratedThreadIds by host.
                # Preserve the target marker; do not mark source work done here.
                if($value-isnot[string]-or$value-ne$id){Survey 'Invalid host migration thread reference.'}
                continue
            }
            if($pointer-eq('/thread-project-assignments/'+$id)){
                if((Field $value 'projectKind')-ne'local'){Survey "Unknown project assignment kind for $id"}
                $project=Get-ReceiveProject ([string]$value.projectId) $global
                Set-ReceiveMember (Receive-Object $global 'thread-project-assignments') $id ([pscustomobject]@{projectKind='local';projectId=$project});continue
            }
            if($pointer-match '^/sidebar-project-thread-orders/([^/]+)/threadIds/([0-9]+)$'){
                $sourceProject=$Matches[1].Replace('~1','/').Replace('~0','~');$position=[int]$Matches[2]
                $project=Get-ReceiveProject $sourceProject $global
                if([string]$value-ne$id){throw 'Sidebar reference points to a different session.'}
                if(-not$ordered.ContainsKey($project)){$ordered[$project]=New-Object 'Collections.Generic.List[object]'}
                $ordered[$project].Add([pscustomobject]@{Id=$id;Position=$position});continue
            }
            if($pointer-match '^/projectless-thread-ids/[0-9]+$'){
                if([string]$value-ne$id){throw 'Projectless reference points to a different session.'}
                $ids=@(Field $global 'projectless-thread-ids' @());Set-ReceiveMember $global 'projectless-thread-ids' @($ids|Where-Object{$_-ne$id})
                $global.PSObject.Properties['projectless-thread-ids'].Value+=@($id);continue
            }
            if($pointer-eq('/thread-workspace-root-hints/'+$id)-or$pointer-eq('/thread-projectless-output-directories/'+$id)){
                $path=Get-ReceivePathValue ([string]$value)
                $key=($pointer-split'/')[1];Set-ReceiveMember (Receive-Object $global $key) $id $path;continue
            }
            Survey "Unsurveyed portable global reference: $pointer"
        }
        foreach($path in @(Field $projection 'attachmentReferences' @())){
            # The original mentions this absolute path. Never rewrite a rollout
            # or silently claim an attachment at another path is equivalent.
            $relative=Get-TransportedAttachmentRelative $session ([string]$path)
            $absolute=Assert-ReceivePath (Join-Path $script:appHome $relative)
            if(-not$absolute.StartsWith($script:appHome+'\attachments\',[StringComparison]::OrdinalIgnoreCase)){throw "Unsupported attachment destination: $path"}
            $logical='attachments/'+$absolute.Substring($script:appHome.Length+1).Replace('\','/')
            if(@($session.Manifest.payloads|Where-Object{$_.path-ceq$logical}).Count-ne1){throw "Attachment reference has no unique transported payload: $path"}
            if(-not$sourceAttachments.Contains($absolute)){$sourceAttachments.Add($absolute)}
        }
    }
    Set-ReceiveUnreadMembership $global $Remote $RemovedIds $unreadIds.ToArray()
    foreach($project in $ordered.Keys){
        $order=Receive-Object (Receive-Object $global 'sidebar-project-thread-orders') $project
        $old=@(Field $order 'threadIds' @());$incoming=@($ordered[$project]|Sort-Object Position,Id|ForEach-Object{$_.Id}|Select-Object -Unique)
        Set-ReceiveMember $order 'threadIds' @($incoming+@($old|Where-Object{$_-notin$incoming}))
    }
    $indexPath=Assert-ReceivePath (Join-Path $script:appHome 'attachments/pasted-text-attachments.json')
    $index=if([IO.File]::Exists($indexPath)){Read-Json $indexPath}else{[pscustomobject]@{attachmentPaths=@()}}
    $indexBefore=Json $index
    $paths=$index.PSObject.Properties['attachmentPaths'];if($null-eq$paths-or$paths.Value-isnot[Array]){Survey 'Unknown pasted-text attachment index shape.'}
    $seenPaths=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $uniquePaths=New-Object 'Collections.Generic.List[string]'
    foreach($path in @($paths.Value)+$sourceAttachments.ToArray()){
        if($path-isnot[string]-or-not[IO.Path]::IsPathRooted($path)){Survey 'Unknown pasted-text attachment index path.'}
        if($seenPaths.Add([IO.Path]::GetFullPath($path))){$uniquePaths.Add($path)}
    }
    # Retain the first spelling: other index fields may key cached text by it.
    $paths.Value=$uniquePaths.ToArray()
    return [pscustomobject]@{GlobalPath=$globalPath;Global=$global;GlobalChanged=((Json $global)-cne$before);IndexPath=$indexPath;Index=$index;IndexChanged=((Json $index)-cne$indexBefore)}
}
function Apply-ReceiveMetadata($Plan) {
    foreach($kind in @('Global','Index')){
        if(-not$Plan.($kind+'Changed')){continue}
        $file=Join-Path $script:runRoot ('receive-'+$kind+'.json');[IO.File]::WriteAllText($file,(Json $Plan.$kind),$script:utf8)
        Write-PreparedFile $file $Plan.($kind+'Path')
    }
}
function Assert-ReceiveDestinations($Remote) {
    $destinations=@{}
    foreach($session in $Remote.Values){if($session.State-ne'Active'){continue}
        foreach($payload in @($session.Manifest.payloads)){
            $logical=[string]$payload.path;$source=Materialize-Payload $session $payload
            if($logical.StartsWith('rollouts/')){$destination=Get-RolloutDestination $session $source ([IO.Path]::GetFileName($logical))}
            elseif($logical.StartsWith('attachments/')){$relative=$logical.Substring(12);if($relative.StartsWith('attachments/')){$relative=$relative.Substring(12)};$destination=Resolve-Within $script:appHome ('attachments/'+$relative)}
            elseif($logical.StartsWith('browser/')){$destination=Resolve-Within $script:appHome ('browser/sessions/'+[IO.Path]::GetFileName($logical))}
            elseif($logical.StartsWith('visualizations/')){$destination=Resolve-Within $script:appHome $logical}
            else{throw "Unsupported app payload path: $logical"}
            $destination=Assert-ReceivePath $destination
            if($destinations.ContainsKey($destination)-and$destinations[$destination]-ne[string]$payload.sha256){throw "Two payloads disagree at destination: $destination"}
            $destinations[$destination]=[string]$payload.sha256
        }
        $projection=Get-Projection $session
        foreach($table in @('thread_turns','thread_items','thread_history_projection_state','thread_realtime_items')){
            $columns=@((Query (Join-Path $script:appHome 'thread_history_1.sqlite') ('PRAGMA table_info('+$table+')'))|ForEach-Object{$_['name']}|Sort-Object)
            if($columns.Count-eq0){Survey "Required history table is missing: $table"}
            foreach($row in @(Field $projection.history $table @())){if((@($row.PSObject.Properties.Name|Sort-Object)-join',')-cne($columns-join',')){Survey "Stored history schema differs: $table"}}
        }
    }
}
function Assert-LocalDiscard($Base,$Remote,$Local) {
    foreach($id in $Base.Keys){
        if(-not$Remote.ContainsKey($id)){throw "Published basis session disappeared without an Active, Archived or Deleted record: $id. Nothing was removed."}
    }
    foreach($id in $Remote.Keys){
        if($Remote[$id].State-ne'Deleted'-or-not$Local.ContainsKey($id)){continue}
        if(-not$Base.ContainsKey($id)-or$Base[$id].State-eq'Deleted'){throw "Deleted state has no proved local identity mapping: $id. Nothing was removed."}
    }
    $changed=New-Object 'Collections.Generic.List[string]'
    $all=@{};foreach($set in @($Base,$Local)){foreach($id in $set.Keys){$all[$id]=$true}}
    foreach($id in $all.Keys){
        $b=$null;$l=$null;if($Base.ContainsKey($id)){$b=$Base[$id]};if($Local.ContainsKey($id)){$l=$Local[$id]}
        # Local absence alone is not unpublished work and not deletion proof.
        # The verified remote supplies missing state; no data is discarded here.
        if($null-eq$l){continue}
        if($Remote.ContainsKey($id)-and(Same-LocalSnapshot $l $Remote[$id])){continue}
        if(-not(Same-LocalSnapshot $b $l)){$changed.Add($id)}
    }
    if($changed.Count-and-not$DiscardLocalChanges){
        $script:discardRequired=$true
        throw ('Local-only, changed or incomplete Codex sessions would be replaced: '+(($changed|Sort-Object)-join', ')+'. Missing originals were not reconstructed as local work. Approve discard to apply the verified remote; decline to retain local state for separately instructed reconciliation.')
    }
}
function Backup-DatabaseFamily([string]$Path) {
    foreach($candidate in @($Path,($Path+'-wal'),($Path+'-shm'))){Backup-Path $candidate}
}
function Remove-Rows($Db,[string]$Table,[string]$Column,[string[]]$Ids) {
    foreach($id in @($Ids|Sort-Object -Unique)){$Db.Query(('DELETE FROM '+(Quote-SqlName $Table)+' WHERE '+(Quote-SqlName $Column)+'=?'),@($id))|Out-Null}
}
function Clear-AppProjection($Current,$Remote) {
    $statePath=Resolve-Within $script:appHome 'state_5.sqlite'
    $historyPath=Resolve-Within $script:appHome 'thread_history_1.sqlite'
    $catalogPath=Resolve-Within $script:appHome 'sqlite/codex-dev.db'
    foreach($path in @($statePath,$historyPath,$catalogPath)){Backup-DatabaseFamily $path}
    $ids=New-Object 'Collections.Generic.HashSet[string]'
    $lineage=New-Object 'Collections.Generic.HashSet[string]'
    foreach($set in @($Current,$Remote)){
        foreach($session in $set.Values){
            if($session.State-eq'Deleted'){continue}
            [void]$ids.Add([string]$session.Manifest.canonicalId)
            foreach($id in @($session.Manifest.lineageIds)){[void]$lineage.Add([string]$id)}
        }
    }
    $state=New-Object CodexStartNative+Db($statePath,$true)
    try{
        $state.Query('BEGIN IMMEDIATE',@())|Out-Null
        Remove-Rows $state 'thread_dynamic_tools' 'thread_id' @($ids)
        Remove-Rows $state 'thread_artifacts' 'thread_id' @($ids)
        foreach($id in @($ids)){$state.Query('DELETE FROM thread_spawn_edges WHERE parent_thread_id=? OR child_thread_id=?',@($id,$id))|Out-Null}
        Remove-Rows $state 'threads' 'id' @($ids)
        $state.Query('COMMIT',@())|Out-Null
    }catch{try{$state.Query('ROLLBACK',@())|Out-Null}catch{};throw}finally{$state.Dispose()}
    $history=New-Object CodexStartNative+Db($historyPath,$true)
    try{
        $history.Query('BEGIN IMMEDIATE',@())|Out-Null
        foreach($table in @('thread_turns','thread_items','thread_history_projection_state','thread_realtime_items')){Remove-Rows $history $table 'thread_id' @($lineage)}
        $history.Query('COMMIT',@())|Out-Null
    }catch{try{$history.Query('ROLLBACK',@())|Out-Null}catch{};throw}finally{$history.Dispose()}
    $catalog=New-Object CodexStartNative+Db($catalogPath,$true)
    try{
        $catalog.Query('BEGIN IMMEDIATE',@())|Out-Null
        Remove-Rows $catalog 'local_thread_catalog' 'thread_id' @($ids)
        $catalog.Query('UPDATE local_thread_catalog_metadata SET catalog_revision=catalog_revision+1 WHERE id=1',@())|Out-Null
        $catalog.Query('COMMIT',@())|Out-Null
    }catch{try{$catalog.Query('ROLLBACK',@())|Out-Null}catch{};throw}finally{$catalog.Dispose()}
}
function Restore-HistoryProjection($Remote) {
    # thread/read reconstructs state metadata, but does not rebuild paginated
    # history. Restore the measured, transported rows, including predecessor
    # physical aliases. Originals have already passed byte verification.
    $path=Resolve-Within $script:appHome 'thread_history_1.sqlite'
    $db=New-Object CodexStartNative+Db($path,$true)
    try {
        $db.Query('BEGIN IMMEDIATE',@())|Out-Null
        foreach($session in @($Remote.Values|Where-Object{$_.State-eq'Active'})) {
            $id=[string]$session.Manifest.canonicalId
            $history=Field (Get-Projection $session) 'history'
            foreach($table in @('thread_turns','thread_items','thread_history_projection_state','thread_realtime_items')) {
                $property=$history.PSObject.Properties[$table]
                if($null-eq$property-or$property.Value-isnot[Array]){Survey "Stored history table is not an array: $id/$table"}
                $columns=@($db.Query(('PRAGMA table_info('+(Quote-SqlName $table)+')'),@())|ForEach-Object{[string]$_['name']}|Sort-Object)
                foreach($row in $property.Value) {
                    if([string](Field $row 'thread_id')-notin@($session.Manifest.lineageIds)){throw "Stored history belongs to another lineage: $id/$table"}
                    $names=@($row.PSObject.Properties.Name|Sort-Object)
                    if(($names-join ',')-cne($columns-join ',')){Survey "Stored history columns differ from the measured target: $id/$table"}
                    Insert-Row $db $table $row
                }
            }
        }
        $db.Query('COMMIT',@())|Out-Null
    } catch {try{$db.Query('ROLLBACK',@())|Out-Null}catch{};throw} finally {$db.Dispose()}
}
function Assert-HistoryProjection($Remote) {
    $path=Resolve-Within $script:appHome 'thread_history_1.sqlite'
    $db=New-Object CodexStartNative+Db($path,$false)
    try {
        foreach($session in @($Remote.Values|Where-Object{$_.State-eq'Active'})) {
            $id=[string]$session.Manifest.canonicalId
            $history=Field (Get-Projection $session) 'history'
            foreach($table in @('thread_turns','thread_items','thread_history_projection_state','thread_realtime_items')) {
                $columns=@($db.Query(('PRAGMA table_info('+(Quote-SqlName $table)+')'),@())|ForEach-Object{[string]$_['name']}|Sort-Object)
                $expected=New-Object 'Collections.Generic.List[string]'
                $actual=New-Object 'Collections.Generic.List[string]'
                foreach($row in $history.PSObject.Properties[$table].Value) {
                    $values=[ordered]@{};foreach($column in $columns){$values[$column]=Field $row $column}
                    $expected.Add((Json $values))
                }
                foreach($key in @($session.Manifest.lineageIds|Select-Object -Unique)) {
                    foreach($row in $db.Query(('SELECT * FROM '+(Quote-SqlName $table)+' WHERE thread_id=?'),@([string]$key))) {
                        $values=[ordered]@{};foreach($column in $columns){$values[$column]=Field $row $column}
                        $actual.Add((Json $values))
                    }
                }
                if($expected.Count-ne$actual.Count-or((@($expected|Sort-Object -CaseSensitive)-join "`n")-cne(@($actual|Sort-Object -CaseSensitive)-join "`n"))){throw "Applied conversation history differs from the verified source: $id/$table"}
            }
        }
    } finally {$db.Dispose()}
}
function Get-CodexExecutable {
    $candidates=New-Object 'Collections.Generic.List[string]'
    foreach($command in @(Get-Command codex.exe -All -ErrorAction SilentlyContinue)){if($command.Source){$candidates.Add([string]$command.Source)}}
    # The desktop prepends its materialized backend to its own PATH; Explorer
    # does not. WindowsApps package files can be readable yet not executable.
    # Discover the app-owned materialized copy without changing PATH or ACLs.
    # Match its bytes to the registered package, never pick a cache by folder
    # name, timestamp or version (older materializations can coexist).
    $materialized=@()
    $binRoot=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'OpenAI/Codex/bin'
    if(Test-Path -LiteralPath $binRoot -PathType Container){
        $materialized=@(Get-ChildItem -LiteralPath $binRoot -Directory | ForEach-Object {
            $file=Join-Path $_.FullName 'codex.exe'
            if(Test-Path -LiteralPath $file -PathType Leaf){Get-Item -LiteralPath $file}
        })
    }
    $materializedHashes=@{}
    if($null-ne(Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)){
        foreach($package in @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue)){
            foreach($relative in @('app/resources/codex.exe','app/resources/codex')){
                $path=Join-Path $package.InstallLocation $relative
                if(-not(Test-Path -LiteralPath $path -PathType Leaf)){continue}
                try{
                    $size=(Get-Item -LiteralPath $path).Length
                    $sameSize=@($materialized | Where-Object {$_.Length-eq$size})
                    if($sameSize.Count){
                        Write-CodexStartProgress ("Matching app-owned backend against installed package: {0}" -f $path)
                        $packageHash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
                        foreach($file in $sameSize){
                            if(-not$materializedHashes.ContainsKey($file.FullName)){$materializedHashes[$file.FullName]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash}
                            if($materializedHashes[$file.FullName]-eq$packageHash){$candidates.Add($file.FullName)}
                        }
                    }
                }catch{Write-CodexStartProgress ("Could not match materialized backend: {0}" -f $_.Exception.Message)}
                $candidates.Add($path)
            }
        }
    }
    $failures=New-Object 'Collections.Generic.List[string]'
    foreach($candidate in @($candidates.ToArray()|Select-Object -Unique)) {
        Write-CodexStartProgress ("Checking app-server executable: {0}" -f $candidate)
        $process=New-Object Diagnostics.Process
        $process.StartInfo.FileName=$candidate;$process.StartInfo.Arguments='--version'
        $process.StartInfo.UseShellExecute=$false;$process.StartInfo.CreateNoWindow=$true
        $process.StartInfo.RedirectStandardOutput=$true;$process.StartInfo.RedirectStandardError=$true
        try {
            [void]$process.Start()
            $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
            if(-not$process.WaitForExit(10000)){
                $process.Kill();$process.WaitForExit()
                throw 'Version probe exceeded 10 seconds.'
            }
            $version=$stdout.GetAwaiter().GetResult().Trim();$errorText=$stderr.GetAwaiter().GetResult().Trim()
            if($process.ExitCode-ne0-or$version-notmatch '^codex-cli\s+\S+$'){throw ("Invalid version response (exit {0}): {1} {2}" -f $process.ExitCode,$version,$errorText)}
            if($version-notin@('codex-cli 0.153.1','codex-cli 0.153.3')){$script:warnings.Add("Codex backend version differs from the recorded survey: $version. Version alone does not block Start; structure and app-server operation checks still apply.")}
            Write-CodexStartProgress ("Using {0}: {1}" -f $candidate,$version)
            return $candidate
        } catch {
            $reason="${candidate}: $($_.Exception.Message)";$failures.Add($reason)
            Write-CodexStartProgress ("Executable unavailable; trying remaining candidates. {0}" -f $reason)
        } finally { $process.Dispose() }
    }
    throw ('No installed Codex app-server executable returned a valid version response; app data was not changed. '+($failures -join '; '))
}
function Invoke-CodexRead([string]$Executable,[string[]]$Ids) {
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$Executable;$info.Arguments='app-server';$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.Encoding]::UTF8;$info.StandardErrorEncoding=[Text.Encoding]::UTF8
    $info.EnvironmentVariables['CODEX_HOME']=$script:appHome;$info.EnvironmentVariables['CODEX_SQLITE_HOME']=$script:appHome
    $process=New-Object Diagnostics.Process;$process.StartInfo=$info;[void]$process.Start()
    $stderrTask=$process.StandardError.ReadToEndAsync()
    $requestId=1
    function Send-Request($Object,[int]$Expected) {
        $process.StandardInput.WriteLine((Json $Object));$process.StandardInput.Flush()
        while($true){
            $read=$process.StandardOutput.ReadLineAsync();if(-not$read.Wait(30000)){throw 'Codex app-server reconstruction response timed out.'};$line=$read.Result;if($null-eq$line){throw 'Codex app-server exited before reconstruction completed.'}
            try{$message=Parse-Json $line}catch{continue}
            if((Field $message 'id')-eq$Expected){if($null-ne(Field $message 'error')){throw ('Codex app-server error: '+(Json (Field $message 'error')))};return $message}
        }
    }
    try{
        Send-Request ([ordered]@{id=$requestId;method='initialize';params=[ordered]@{clientInfo=[ordered]@{name='AgentSessionSync';title='AgentSessionSync';version='2'};capabilities=[ordered]@{}}}) $requestId|Out-Null
        $process.StandardInput.WriteLine((Json ([ordered]@{method='initialized';params=[ordered]@{}})));$process.StandardInput.Flush()
        foreach($id in @($Ids|Sort-Object -Unique)){Write-CodexStartProgress ("Reconstructing app state: {0}" -f $id);$requestId++;Send-Request ([ordered]@{id=$requestId;method='thread/read';params=[ordered]@{threadId=$id;includeTurns=$true}}) $requestId|Out-Null}
    }finally{
        try{$process.StandardInput.Close()}catch{}
        if(-not$process.WaitForExit(10000)){try{$process.Kill()}catch{};throw 'Codex app-server did not stop after reconstruction.'}
        $stderr=$stderrTask.GetAwaiter().GetResult();$exitCode=$process.ExitCode;$process.Dispose()
        if($exitCode-ne0){throw ('Codex app-server reconstruction failed: '+$stderr)}
    }
}
function Restore-Index($Current,$Remote) {
    $path=Resolve-Within $script:appHome 'session_index.jsonl';Backup-Path $path
    $remove=@{};foreach($s in $Current.Values){$remove[[string]$s.Manifest.canonicalId]=$true};foreach($s in $Remote.Values){if($s.State-ne'Deleted'){$remove[[string]$s.Manifest.canonicalId]=$true}}
    $rows=New-Object 'Collections.Generic.List[object]'
    if([IO.File]::Exists($path)){foreach($line in [CodexStartNative]::Lines($path)){if(-not$line.Text){continue};$row=Parse-Json $line.Text;if(-not$remove.ContainsKey([string](Field $row 'id'))){$rows.Add($row)}}}
    foreach($session in @($Remote.Values|Where-Object{$_.State-ne'Deleted'})){foreach($row in @(Field (Get-Projection $session) 'sessionIndex' @())){$rows.Add($row)}}
    $text='';if($rows.Count){$text=(@($rows.ToArray()|ForEach-Object{Json $_})-join"`n")+"`n"}
    $temp=Join-Path $script:runRoot 'session-index.new';[IO.File]::WriteAllText($temp,$text,$script:utf8);Write-PreparedFile $temp $path
}
function Restore-PortableStateMetadata($Remote) {
    $statePath=Resolve-Within $script:appHome 'state_5.sqlite'
    $db=New-Object CodexStartNative+Db($statePath,$true)
    try {
        $db.Query('BEGIN IMMEDIATE',@())|Out-Null
        foreach($session in @($Remote.Values|Where-Object{$_.State-ne'Deleted'})) {
            $id=[string]$session.Manifest.canonicalId
            $comparison=Field $session.Manifest 'comparison'
            $metadata=Field $comparison 'metadata'
            $title=Field $comparison 'title'
            $name=Field $metadata 'name'
            $pinned=Field $metadata 'pinned'; if($null-eq$pinned){$pinned=0}
            $portable=Field (Get-Projection $session) 'state'
            # Vault Active controls transport eligibility, not the app's native
            # archive flag. Reapply the source state after thread/read rebuilds it.
            if($session.State-eq'Active'){
                $db.Query('UPDATE threads SET archived=?, archived_at=? WHERE id=?',@((Get-NativeArchiveFlag $session),(Field $portable 'archived_at'),$id))|Out-Null
            }
            $projectId=Field $portable 'project_id';$sectionId=Field $portable 'thread_section_id'
            if($projectId){$projectId=Get-ReceiveProjectId ([string]$projectId)}
            $cwd=Field $portable 'cwd';if($cwd){$db.Query('UPDATE threads SET cwd=? WHERE id=?',@((Get-ReceivePathValue ([string]$cwd)),$id))|Out-Null}
            if($projectId-and($db.Query('SELECT id FROM projects WHERE id=?',@($projectId))).Count-ne1){throw "Target project mapping is missing: $id -> $projectId"}
            if($sectionId-and($db.Query('SELECT id FROM thread_sections WHERE id=?',@($sectionId))).Count-ne1){throw "Target section mapping is missing: $id -> $sectionId"}
            $db.Query('UPDATE threads SET title=?, name=?, is_pinned=?, project_id=?, thread_section_id=?, section_position=?, section_entered_at_ms=? WHERE id=?',@($title,$name,$pinned,$projectId,$sectionId,(Field $portable 'section_position'),(Field $portable 'section_entered_at_ms'),$id))|Out-Null
            $relations=Field (Get-Projection $session) 'relations'
            foreach($row in @(Field $relations 'thread_dynamic_tools' @())){Insert-Row $db 'thread_dynamic_tools' $row}
            foreach($row in @(Field $relations 'thread_artifacts' @())){Insert-Row $db 'thread_artifacts' $row}
            foreach($row in @(Field $relations 'thread_spawn_edges' @())){Insert-Row $db 'thread_spawn_edges' $row}
        }
        $db.Query('COMMIT',@())|Out-Null
    } catch { try{$db.Query('ROLLBACK',@())|Out-Null}catch{};throw } finally { $db.Dispose() }
}
function Restore-Catalog($Remote) {
    $statePath=Resolve-Within $script:appHome 'state_5.sqlite';$catalogPath=Resolve-Within $script:appHome 'sqlite/codex-dev.db'
    $catalog=New-Object CodexStartNative+Db($catalogPath,$true)
    try{
        $catalog.Query('BEGIN IMMEDIATE',@())|Out-Null
        foreach($session in @($Remote.Values|Where-Object{$_.State-eq'Active'})){
            Write-CodexStartProgress ("Restoring catalog entry: {0}" -f $session.Manifest.canonicalId)
            $id=[string]$session.Manifest.canonicalId;$saved=Get-StoredCatalogRows $session
            if($saved.Count-eq0){continue}
            $state=Query $statePath 'SELECT cwd,created_at,updated_at,model_provider,git_branch,thread_source,recency_at,project_id FROM threads WHERE id=?' @($id)
            if($state.Count-ne1){throw "Target state is missing before catalog reconstruction: $id"}
            $row=$state[0]
            Insert-Row $catalog 'local_thread_catalog' $saved[0] @{
                host_id='local';cwd=$row['cwd'];source_created_at=$row['created_at'];source_updated_at=$row['updated_at'];
                model_provider=$row['model_provider'];git_branch=$row['git_branch'];thread_source=$row['thread_source'];
                source_recency_at=$row['recency_at'];project_id=$row['project_id']
            }
        }
        $catalog.Query('UPDATE local_thread_catalog_metadata SET catalog_revision=catalog_revision+1 WHERE id=1',@())|Out-Null
        $catalog.Query('COMMIT',@())|Out-Null
    }catch{try{$catalog.Query('ROLLBACK',@())|Out-Null}catch{};throw}finally{$catalog.Dispose()}
}

function Same-AppliedEntries($Local,$Remote) {
    if($null-eq$Local-or$null-eq$Remote-or$Remote.State-ne'Active'-or$Local.State-ne$Remote.State){return $false}
    $left=@{};$right=@{};Copy-Session $Local $left;Copy-Session $Remote $right
    if($left.Count-ne$right.Count){return $false}
    foreach($path in $left.Keys){
        $other=$Remote.Prefix+$path.Substring($Local.Prefix.Length)
        if(-not$right.ContainsKey($other)-or$right[$other]-cne$left[$path]){return $false}
    }
    return $true
}
function Same-ApplicationTarget($Local,$Remote,$Basis) {
    if(Field $Local 'Incomplete' $false){return $false}
    if(Same-AppliedEntries $Local $Remote){return $true}
    # A received projection contains source-machine metadata that thread/read
    # derives again. Require the ENTIRE actual local snapshot to still match its
    # accepted basis before comparing the fields Start applies from the remote.
    if(-not(Same-AppliedEntries $Local $Basis)-or$Remote.State-ne'Active'){return $false}
    $lc=Parse-Json (Json $Local.Manifest.comparison);$rc=Parse-Json (Json $Remote.Manifest.comparison)
    $lc.metadata.PSObject.Properties.Remove('placement');$rc.metadata.PSObject.Properties.Remove('placement')
    if($rc.metadata.projectId){$rc.metadata.projectId=Get-ReceiveProjectId ([string]$rc.metadata.projectId)}
    if((Json $lc)-cne(Json $rc)){return $false}
    $lp=Get-Projection $Local;$rp=Get-Projection $Remote
    foreach($key in @('history','sessionIndex','relations','attachmentReferences')){
        if((Json (Field $lp $key))-cne(Json (Field $rp $key))){return $false}
    }
    foreach($key in @('id','latestRollout','archived','archived_at','section_entered_at_ms')){
        if(-not(Rows-Equal (Field $lp.state $key) (Field $rp.state $key))){return $false}
    }
    # These exact catalog fields are derived from target state in Restore-Catalog.
    $derived=@('host_id','cwd','source_created_at','source_updated_at','model_provider','git_branch','thread_source','source_recency_at','project_id')
    $catalogs=New-Object 'Collections.Generic.List[string]'
    foreach($projection in @($lp,$rp)){
        $rows=New-Object 'Collections.Generic.List[object]'
        foreach($row in @(Field $projection 'catalog' @())){
            $values=[ordered]@{};foreach($prop in @($row.PSObject.Properties|Sort-Object Name)){if($prop.Name-notin$derived){$values[$prop.Name]=$prop.Value}}
            $rows.Add($values)
        }
        $catalogs.Add((Json $rows.ToArray()))
    }
    if($catalogs[0]-cne$catalogs[1]){return $false}
    if($null-eq$script:receiveMetadata){return $false}
    return (-not$script:receiveMetadata.GlobalChanged-and-not$script:receiveMetadata.IndexChanged)
}
function Select-ApplicationChanges($Current,$Remote,$Base) {
    $local=@{};$desired=@{};$all=@{};$unchanged=0
    foreach($set in @($Current,$Remote)){foreach($id in $set.Keys){$all[$id]=$true}}
    foreach($id in $all.Keys){
        if($Current.ContainsKey($id)-and$Remote.ContainsKey($id)-and(Same-ApplicationTarget $Current[$id] $Remote[$id] $Base[$id])){$unchanged++;continue}
        if(-not$Current.ContainsKey($id)-and$Remote.ContainsKey($id)-and$Remote[$id].State-ne'Active'){$unchanged++;continue}
        if($Current.ContainsKey($id)){$local[$id]=$Current[$id]}
        if($Remote.ContainsKey($id)){$desired[$id]=$Remote[$id]}
    }
    Write-CodexStartProgress ("Application selection: {0} unchanged; {1} local and {2} remote targets require application" -f $unchanged,$local.Count,$desired.Count)
    return [pscustomobject]@{Current=$local;Remote=$desired}
}

function Apply-Remote($Current,$Remote) {
    $desired=@{};$activeIds=New-Object 'Collections.Generic.List[string]'
    foreach($session in @($Remote.Values|Where-Object{$_.State-eq'Active'})){
        Write-CodexStartProgress ("Preparing local placement: {0}" -f $session.Manifest.canonicalId)
        $activeIds.Add([string]$session.Manifest.canonicalId)
        foreach($payload in @($session.Manifest.payloads)){
            $logical=[string]$payload.path;$source=Materialize-Payload $session $payload
            if($logical.StartsWith('rollouts/')){$destination=Get-RolloutDestination $session $source ([IO.Path]::GetFileName($logical))}
            elseif($logical.StartsWith('attachments/')){
                # Finish stores attachment payloads below an app-specific transport
                # prefix.  Strip that prefix once before restoring under CODEX_HOME.
                $relative=$logical.Substring('attachments/'.Length)
                if($relative.StartsWith('attachments/')){$relative=$relative.Substring('attachments/'.Length)}
                $destination=Resolve-Within $script:appHome ('attachments/'+$relative)
            }
            elseif($logical.StartsWith('browser/')){$destination=Resolve-Within $script:appHome ('browser/sessions/'+[IO.Path]::GetFileName($logical))}
            elseif($logical.StartsWith('visualizations/')){$destination=Resolve-Within $script:appHome $logical}
            else{throw "Unsupported app payload path: $logical"}
            $desired[$destination]=$source
        }
    }
    foreach($session in $Current.Values){
        foreach($page in @($session.LocalPages)){if(-not$desired.ContainsKey($page.Path)){Remove-BackedFile $page.Path}}
    }
    foreach($destination in $desired.Keys){Write-PreparedFile $desired[$destination] $destination}
    Restore-Index $Current $Remote
    Clear-AppProjection $Current $Remote
    Write-CodexStartProgress 'Restoring transported conversation history, including predecessor pages'
    Restore-HistoryProjection $Remote
    if($activeIds.Count){Invoke-CodexRead $script:codexExecutable $activeIds.ToArray()}
    Restore-PortableStateMetadata $Remote
    Restore-Catalog $Remote
}
function Validate-Applied($Remote,$Current) {
    Assert-HistoryProjection $Remote
    $statePath=Resolve-Within $script:appHome 'state_5.sqlite'
    foreach($session in $Remote.Values){
        if($session.State-eq'Deleted'){
            $vaultId=[string]$session.Manifest.vaultSessionId
            if($Current.ContainsKey($vaultId)){
                $deletedId=[string]$Current[$vaultId].Manifest.canonicalId
                if((Query $statePath 'SELECT id FROM threads WHERE id=?' @($deletedId)).Count){throw "Deleted session state remains after Start: $deletedId"}
                foreach($page in @($Current[$vaultId].LocalPages)){if([IO.File]::Exists($page.Path)){throw "Deleted session payload remains after Start: $deletedId"}}
            }
            continue
        }
        $id=[string]$session.Manifest.canonicalId
        if($session.State-eq'Archived'){
            if((Query $statePath 'SELECT id FROM threads WHERE id=?' @($id)).Count){throw "Archived session remains in the local active store after Start: $id"}
            continue
        }
        $rows=Query $statePath 'SELECT id,rollout_path,archived FROM threads WHERE id=?' @($id)
        if($rows.Count-ne1){throw "Codex did not reconstruct exactly one state row: $id"}
        $expected=Get-NativeArchiveFlag $session
        if([long]$rows[0]['archived']-ne$expected){throw "Codex reconstructed the wrong survival state: $id"}
        $path=[string]$rows[0]['rollout_path'];if(-not[IO.File]::Exists($path)){throw "Codex reconstructed a missing rollout path: $id"}
        $latest=[string](Field (Get-Projection $session) 'state' | ForEach-Object {Field $_ 'latestRollout'})
        if([IO.Path]::GetFileName($path)-ne$latest){throw "Codex reconstructed the wrong latest rollout: $id"}
    }
}

try {
    Initialize-Native
    $parsedRun=[guid]::Empty;if(-not[guid]::TryParseExact($RunId,'D',[ref]$parsedRun)){throw 'RunId must be a GUID in D format.'}
    $script:repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    if([IO.Path]::GetFullPath((Git @('rev-parse','--show-toplevel')))-ne$script:repo){throw 'This script must run from the installation Launchers/Codex directory.'}
    $gitDir=Git @('rev-parse','--absolute-git-dir');$script:runsRoot=Join-Path $gitDir 'agent-session-sync/CodexStart';$script:runRoot=Resolve-Within $script:runsRoot $RunId
    if(Test-Path -LiteralPath $script:runRoot){throw 'RunId already exists.'};[IO.Directory]::CreateDirectory($script:runRoot)|Out-Null
    $config=Import-PowerShellDataFile -LiteralPath (Join-Path $script:repo 'AgentSessionSync.config.psd1')
    if(-not$config.ContainsKey('Codex')-or-not$config.Codex.Enabled){throw 'Codex was not selected as a registered app.'}
    $script:receiveConfig=$config.Codex
    foreach($key in @('PathMappings','ProjectIdMappings')){
        if(-not$script:receiveConfig.ContainsKey($key)){continue}
        $map=$script:receiveConfig[$key];if($map-isnot[hashtable]){throw "Codex.$key must be a map in this PC's configuration."}
        foreach($source in $map.Keys){
            if($source-isnot[string]-or-not$source-or$map[$source]-isnot[string]-or-not$map[$source]){throw "Codex.$key requires nonempty string pairs."}
            if($key-eq'PathMappings'-and(-not[IO.Path]::IsPathRooted($source)-or-not[IO.Path]::IsPathRooted($map[$source])-or-not[IO.Directory]::Exists($map[$source]))){throw 'Codex.PathMappings requires absolute prefixes and existing target directories.'}
        }
    }
    $script:appHome=[IO.Path]::GetFullPath([string]$config.Codex.Home).TrimEnd('\','/');if(-not(Test-Path -LiteralPath $script:appHome -PathType Container)){throw 'Configured Codex Home does not exist.'}
    $script:days=[int]$config.ActiveWindowDays;$script:limit=[long]$config.TransportFileLimitBytes;$script:now=[DateTimeOffset]::UtcNow
    if($script:days-ne30-or$script:limit-ne99614720){throw 'Expected the agreed 30 days and 99614720-byte transport threshold.'}
    New-StartReceipt;$script:receipt.status='validating';Save-Receipt
    Object-Id $RemoteCommit 'commit';if($BaselineCommit){Object-Id $BaselineCommit 'commit'}
    Write-CodexStartProgress 'Reading pinned remote and local comparison trees'
    $base=Read-Sessions (Read-AppTree $BaselineCommit);$remote=Read-Sessions (Read-AppTree $RemoteCommit)
    # Resolve the backend before expensive validation, and before any app writes.
    $activeRemote=@($remote.Values|Where-Object{$_.State-eq'Active'})
    $script:codexExecutable=if($activeRemote.Count){Get-CodexExecutable}else{''}
    Write-CodexStartProgress 'Verifying stored payloads and transport markers'
    Verify-StoredSessions $base;Verify-StoredSessions $remote
    Write-CodexStartProgress 'Inspecting current local originals and comparison metadata'
    $current=Prepare-Local $base $remote -InventoryIncomplete
    Assert-TargetMappings $remote $current
    $changes=Select-ApplicationChanges $current $remote $base
    Assert-ReceiveDestinations $changes.Remote
    Assert-LocalDiscard $base $remote $current
    Write-CodexStartProgress 'Validation passed; applying remote state with app-owned backups'
    $script:receipt.status='applying';Save-Receipt
    if($changes.Current.Count-or$changes.Remote.Count){Apply-Remote $changes.Current $changes.Remote}
    Apply-ReceiveMetadata $script:receiveMetadata
    Write-CodexStartProgress 'Checking applied app state'
    Validate-Applied $changes.Remote $changes.Current
    # The local basis records what this target machine actually received.  It
    # deliberately keeps target-derived app metadata rather than pretending
    # that a source machine's portable projection was installed byte-for-byte.
    Write-CodexStartProgress 'Recording the actual applied local comparison basis'
    $applied=if($changes.Current.Count-or$changes.Remote.Count-or$script:receiveMetadata.GlobalChanged-or$script:receiveMetadata.IndexChanged){Prepare-Local $remote $remote}else{$current}
    $basis=@{}
    foreach($session in $remote.Values){if($session.State-eq'Deleted'){Copy-Session $session $basis}}
    foreach($session in $applied.Values){
        $id=[string]$session.Manifest.vaultSessionId
        $witness=$null
        if($remote.ContainsKey($id)-and$remote[$id].State-ne'Deleted'){$witness=Remote-Witness $remote[$id]}
        Copy-LocalBasis $session $witness $basis
    }
    $tree=Make-Tree $basis;Object-Id $tree 'tree'
    Write-CodexStartProgress ("Reused result objects: {0}; existing trees: {1}" -f $script:reusedJson,$script:reusedTrees)
    Write-CodexStartProgress 'Application verified; releasing this Start backup and scratch'
    $script:receipt.status='applied';Save-Receipt;Clear-StartReceipt
    Report 'Success' 'Pinned Codex state applied' "Known structure and payload integrity passed. UI and future app interpretation are not claimed."
    Write-Output "LOCAL_BASE_TREE: $tree"
    exit 0
} catch {
    $detail=$_.Exception.Message
    $retain=$false
    if($script:receipt-and$script:receipt.status-eq'applying'){
        try{Restore-Start;$detail+=' This Start attempt was restored.'}catch{$detail+=' '+$_.Exception.Message;$retain=$true}
    }
    if(-not$retain-and$script:runRoot){try{Clear-StartReceipt}catch{$detail+=' Scratch cleanup failed: '+$_.Exception.Message}}
    Report 'Failure' 'Codex Start could not complete' $detail
    if($script:discardRequired-and-not$retain){Write-Output 'DISCARD_REQUIRED: True'}
    exit 1
}
