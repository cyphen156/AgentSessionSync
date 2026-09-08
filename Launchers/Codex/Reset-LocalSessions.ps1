#requires -Version 5.1
# One-time local session disposal. No receive, publication, or Git ref changes.
# Never invoked by Start, Finish, Initialize, or the workbench adapter.
[CmdletBinding()]
param([switch]$ConfirmDiscard)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2
$script:survey=$false
$script:surveyRequired=$false
$script:mutating=$false
$script:runRoot=''
$script:utf8=New-Object Text.UTF8Encoding($false,$true)
$vaultRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
function Assert-AppClosed($App) {
    $names=@($App.ProcessNames)
    if($names.Count-eq0){throw 'Initialize must configure app ProcessNames before local reset.'}
    foreach($name in $names){
        if($name-isnot[string]-or$name-notmatch '^[A-Za-z0-9_.-]+$'){throw 'Invalid configured process name.'}
        $found=@(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($name)) -ErrorAction SilentlyContinue)
        if($found.Count){throw "Close the configured app before resetting sessions: $name. No process was stopped."}
    }
}
function Report-Reset([string]$Result,[string]$Detail) {
    Write-Output "RESULT: $Result"
    Write-Output 'AGENT: Codex'
    Write-Output 'PHASE: ResetLocalSessions'
    Write-Output 'REASON: Manual local session reset'
    Write-Output "DETAIL: $Detail"
    Write-Output 'PUBLISHED_COMMIT: NONE'
    Write-Output ('SURVEY_REQUIRED: '+[string]($script:survey-or$script:surveyRequired))
}
function Clear-ResetScratch {
    if(-not$script:runRoot){return}
    $full=[IO.Path]::GetFullPath($script:runRoot)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
    if([IO.Path]::GetDirectoryName($full)-ne$parent-or[IO.Path]::GetFileName($full)-notmatch '^ass-reset-[0-9a-f]{32}$'){throw 'Unsafe reset scratch path.'}
    if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
function Initialize-Native {
Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class CodexResetNative {
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

function Survey([string]$Message) { $script:survey=$true; throw $Message }

function Require-Id([string]$Id) { if($Id -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { Survey "Invalid session identifier: $Id" } }

function Query([string]$Path,[string]$Sql,[object[]]$Values=@()) {
    $db=New-Object CodexResetNative+Db($Path,$false)
    try { return ,$db.Query($Sql,$Values).ToArray() } finally { $db.Dispose() }
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

function Quote-SqlName([string]$Name) {
    if ($Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "Unsafe SQL identifier: $Name" }
    return '"' + $Name + '"'
}

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

function New-LocalResetPlan {
    $tables=[ordered]@{
        'state_5.sqlite'=@('thread_dynamic_tools','thread_artifacts','thread_spawn_edges','threads')
        'thread_history_1.sqlite'=@('thread_turns','thread_items','thread_history_projection_state','thread_realtime_items')
        'sqlite/codex-dev.db'=@('local_thread_catalog','local_thread_catalog_metadata')
    }
    $ids=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($relative in $tables.Keys){
        $path=Assert-ReceivePath (Join-Path $script:appHome $relative)
        foreach($suffix in @('-wal','-shm')){Assert-ReceivePath ($path+$suffix)|Out-Null}
        $check=Query $path 'PRAGMA quick_check';if($check.Count-ne1-or(Field $check[0] 'quick_check')-ne'ok'){throw "Database integrity check failed: $path"}
        foreach($table in $tables[$relative]){
            $rows=Db-Table $path $table
            foreach($row in $rows){if($table-eq'local_thread_catalog'-and(Field $row 'host_id')-ne'local'){continue};foreach($key in @('id','thread_id','parent_thread_id','child_thread_id')){
                if($table-eq'local_thread_catalog_metadata'){continue}
                if($row.ContainsKey($key)-and($key-eq'thread_id'-or($table-eq'threads'-and$key-eq'id'))){$id=[string]$row[$key];Require-Id $id;[void]$ids.Add($id)}
            }}
        }
    }
    $catalog=Join-Path $script:appHome 'sqlite/codex-dev.db'
    $existing=@((Query $catalog "SELECT name FROM sqlite_master WHERE type='table'")|ForEach-Object{$_['name']})
    foreach($optional in @('thread_timeline_ledger','local_thread_catalog_scan_entries')){
        if($optional-in$existing){$columns=@((Query $catalog ('PRAGMA table_info('+ $optional +')'))|ForEach-Object{$_['name']});if('host_id'-notin$columns-or'thread_id'-notin$columns){Survey "Unknown $optional schema"};$tables['sqlite/codex-dev.db']+=@($optional)}
    }
    if('automations'-in$existing){foreach($row in (Query $catalog "SELECT target_thread_id FROM automations WHERE status='ACTIVE' AND target_thread_id IS NOT NULL")){if($ids.Contains([string]$row['target_thread_id'])){throw 'An active automation targets a session selected for reset. Disable or reassign that automation before discarding its conversation.'}}}
    $files=New-Object 'Collections.Generic.List[string]'
    foreach($relative in @('sessions','archived_sessions')){
        $root=Assert-ReceivePath (Join-Path $script:appHome $relative)
        if(-not[IO.Directory]::Exists($root)){continue}
        $pending=New-Object 'Collections.Generic.Queue[string]';$pending.Enqueue($root)
        while($pending.Count){$directory=$pending.Dequeue();foreach($item in Get-ChildItem -LiteralPath $directory -Force){
            Assert-ReceivePath $item.FullName|Out-Null
            if($item.PSIsContainer){$pending.Enqueue($item.FullName);continue}
            if($item.Extension-ne'.jsonl'){throw "Unknown file in the session reset area: $($item.FullName)"}
            if($item.Name-notmatch '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$'){throw "Unknown rollout filename: $($item.Name)"}
            [void]$ids.Add($Matches[1]);$files.Add($item.FullName)
        }}
    }
    Assert-ReceivePath (Join-Path $script:appHome 'session_index.jsonl')|Out-Null
    return [pscustomobject]@{Tables=$tables;Ids=@($ids);Files=$files.ToArray()}
}

function Invoke-LocalSessionReset($Plan) {
    Write-Host 'Discarding approved local session state without backup; DB schema and settings are retained'
    foreach($relative in $Plan.Tables.Keys){
        $db=New-Object CodexResetNative+Db((Join-Path $script:appHome $relative),$true)
        try{$db.Query('BEGIN IMMEDIATE',@())|Out-Null
            foreach($table in $Plan.Tables[$relative]){
                if($table-eq'local_thread_catalog_metadata'){$db.Query('UPDATE local_thread_catalog_metadata SET catalog_revision=catalog_revision+1 WHERE id=1',@())|Out-Null}
                elseif($table-in@('local_thread_catalog','thread_timeline_ledger','local_thread_catalog_scan_entries')) {foreach($id in $Plan.Ids){$db.Query(('DELETE FROM '+(Quote-SqlName $table)+' WHERE thread_id=? AND host_id=?'),@($id,'local'))|Out-Null}}
                else{$db.Query(('DELETE FROM '+(Quote-SqlName $table)),@())|Out-Null}
            };$db.Query('COMMIT',@())|Out-Null
        }catch{try{$db.Query('ROLLBACK',@())|Out-Null}catch{};throw}finally{$db.Dispose()}
    }
    foreach($file in $Plan.Files){[IO.File]::Delete((Assert-ReceivePath $file))}
    $index=Join-Path $script:appHome 'session_index.jsonl';if([IO.File]::Exists($index)){[IO.File]::Delete($index)}
}
function New-ResetMetadataPlan([string[]]$RemovedIds) {
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
    return [pscustomobject]@{Path=$globalPath;Text=(Json $global);Changed=((Json $global)-cne$before)}
}
try {
    if(-not$ConfirmDiscard){throw 'Explicit -ConfirmDiscard is required. This standalone tool discards existing local sessions WITHOUT BACKUP; it does not receive remote sessions.'}
    $config=Import-PowerShellDataFile -LiteralPath (Join-Path $vaultRoot 'AgentSessionSync.config.psd1')
    if(-not$config.ContainsKey('Codex')){throw 'The app is not configured. Run Initialize first.'}
    Assert-AppClosed $config.Codex
    $script:appHome=[IO.Path]::GetFullPath([string]$config.Codex.Home).TrimEnd('\','/')
    if(-not[IO.Directory]::Exists($script:appHome)){throw 'Configured Codex Home is missing.'}
    Initialize-Native
    Write-Host 'PROGRESS: Inspecting the configured local Codex session stores'
    $plan=New-LocalResetPlan
    $metadata=New-ResetMetadataPlan $plan.Ids
    Assert-AppClosed $config.Codex
    $script:mutating=$true
    Invoke-LocalSessionReset $plan
    if($metadata.Changed){
        $temporary=$metadata.Path+'.reset-'+[guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText($temporary,$metadata.Text,$script:utf8)
        if([IO.File]::Exists($metadata.Path)){[IO.File]::Replace($temporary,$metadata.Path,[NullString]::Value)}else{[IO.File]::Move($temporary,$metadata.Path)}
        if([IO.File]::ReadAllText($metadata.Path,$script:utf8)-cne$metadata.Text){throw 'Reset metadata verification failed.'}
    }
    $remaining=New-LocalResetPlan
    if($remaining.Ids.Count-or$remaining.Files.Count){throw 'Codex session data remains after reset.'}
    Clear-ResetScratch
    Report-Reset 'Success' 'Local session reset finished. Login, settings and project definitions were retained. No Vault content, baton, baseline or remote was changed. Run ordinary Start separately to receive the Vault.'
    exit 0
} catch {
    $detail=$_.Exception.Message
    if($script:mutating){$detail+=' Reset may be incomplete. No rollback or backup is available. Do not run Finish; resolve this failure before running Start.'}
    else{$detail+=' No app state was changed.'}
    if($script:runRoot){$detail+=' Inspection scratch: '+$script:runRoot}
    Report-Reset 'Failure' $detail
    exit 1
}
