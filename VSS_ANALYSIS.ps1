#Requires -RunAsAdministrator
param(
    [int]$LastHours = 24,
    [string]$LogPath = 'C:\Program Files\Microsoft SQL Server\90\Shared\SqlWriterLogger.txt',
    [string]$CoveLogPath = 'C:\ProgramData\MXB\Backup Manager\logs',
    [string]$OutputPath = 'C:\Temp\VSS_Analysis_Report.html'
)

$now    = Get-Date
$cutoff = $now.AddHours(-$LastHours)
$hrRx   = '0x8[0-9A-Fa-f]{7}'
$tz     = [TimeZoneInfo]::Local
$hrMeaning = @{
    '0x80042301' = 'VSS_E_BAD_STATE: a call was made while the object was in an incorrect state for that function.'
    '0x800423F2' = 'VSS_E_WRITERERROR_TIMEOUT: a writer did not respond in time.'
    '0x80042302' = 'VSS_E_OBJECT_NOT_FOUND: shadow copy or object not found.'
    '0x80070005' = 'E_ACCESSDENIED: permission problem.'
}

function Enc($s) { [System.Net.WebUtility]::HtmlEncode([string]$s) }
function Tbl($items, [string[]]$props) {
    $body = New-Object System.Text.StringBuilder
    $n = 0
    foreach ($i in $items) {
        $n++
        $cells = foreach ($p in $props) { $v = [string]$i.$p; "<td>$(Enc $v)</td>" }
        [void]$body.Append('<tr>' + ($cells -join '') + '</tr>')
    }
    if ($n -eq 0) { return '<p class="none">None found.</p>' }
    $head = ($props | ForEach-Object { "<th>$(Enc $_)</th>" }) -join ''
    "<table><tr>$head</tr>$($body.ToString())</table>"
}
function Stamp($s) {
    $t = [datetime]::MinValue
    if ([datetime]::TryParse([string]$s, [Globalization.CultureInfo]'en-US', [Globalization.DateTimeStyles]::None, [ref]$t)) { return $t }
    return $null
}
function Fmt($t) { if ($t) { ([datetime]$t).ToString('yyyy-MM-dd HH:mm:ss.fff') } else { '' } }

# ---- 1. Backup jobs (Backup Manager events)
$bm = @(Get-WinEvent -FilterHashtable @{ LogName='Application'; ProviderName='Backup Manager'; StartTime=$cutoff } -ErrorAction SilentlyContinue | Sort-Object TimeCreated)
$jobs = @(); $openJobs = @{}
foreach ($e in $bm) {
    $m = [string]$e.Message
    if ($m -match 'Backup started for data source (\S+?)\.?\s*$') {
        $openJobs[$Matches[1]] = $e.TimeCreated
    }
    elseif ($m -match 'Backup finished for data source (\S+?) with session status (\w+)') {
        $src = $Matches[1]; $status = $Matches[2]
        $errs = 0
        if ($m -match 'Errors count: (\d+)') { $errs = [int]$Matches[1] }
        $start = $openJobs[$src]
        if ($openJobs.ContainsKey($src)) { $openJobs.Remove($src) }
        $dur = $null
        if ($start) { $dur = [math]::Round(($e.TimeCreated - $start).TotalMinutes, 1) }
        $jobs += [pscustomobject]@{ Source=$src; Start=$start; End=$e.TimeCreated; Minutes=$dur; Status=$status; Errors=$errs }
    }
}
$failed = @($jobs | Where-Object { $_.Status -ne 'Completed' })

# ---- 2. Cove log: [yyyy-MM-dd HH:mm:ss.ffffff] [L|W|E] [thread] message
$cove = @(); $coveFiles = 0
if (Test-Path -LiteralPath $CoveLogPath) {
    $files = @(Get-ChildItem -LiteralPath $CoveLogPath -Recurse -File -ErrorAction SilentlyContinue |
               Where-Object { $_.LastWriteTime -ge $cutoff } | Sort-Object LastWriteTime | Select-Object -Last 100)
    $coveFiles = $files.Count
    foreach ($cf in $files) {
        foreach ($ln in @(Get-Content -LiteralPath $cf.FullName -ErrorAction SilentlyContinue)) {
            if ($ln -match '^\[(?<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)\]\s+\[(?<lvl>\w)\]\s+\[(?<tid>\d+)\]\s*(?<msg>.*)$') {
                $ts = $Matches['ts']; $lvl = $Matches['lvl']; $tid = $Matches['tid']; $msg = $Matches['msg'].Trim()
                $t = Stamp $ts
                if (-not $t -or $t -lt $cutoff) { continue }
                $isJob = $msg -match '^Backup (started|finished) for data source'
                $isVss = $msg -match 'vss|timed out|Failed to finalize|0x8[0-9A-Fa-f]{7}'
                if ($isJob -or ($lvl -ne 'L' -and $isVss)) {
                    $cove += [pscustomobject]@{ Time=$t; Level=$lvl; TID=$tid; File=$cf.Name; Msg=$msg }
                }
            }
        }
    }
}
$cove = @($cove | Sort-Object Time)

# ---- 3. SQL Writer log
$wl = @()
if (Test-Path -LiteralPath $LogPath) {
    foreach ($line in Get-Content -LiteralPath $LogPath) {
        if ($line -match '^\[(?<ts>[^,]+),\s*TID\s*(?<tid>\w+)\]\s*(?<msg>.*)$') {
            $ts = $Matches['ts']; $tid = $Matches['tid']; $msg = $Matches['msg'].Trim()
            $t = Stamp $ts
            if ($t -and $t -ge $cutoff) { $wl += [pscustomobject]@{ Time=$t; TID=$tid; Msg=$msg } }
        }
    }
}
$wl = @($wl | Sort-Object @{ Expression = { $_.Time } }, @{ Expression = {
    if ($_.Msg -match 'OnFreeze') { 0 } elseif ($_.Msg -match 'OnPostSnapshot') { 1 } elseif ($_.Msg -match 'OnThaw') { 2 } else { 1 }
} })

# Snapshot sets: pair each BEGIN with the next END in order (the ID is a thread ID and differs between BEGIN and END)
$q = @(); $sets = @()
foreach ($w in $wl) {
    if ($w.Msg -match 'VSS SQL BACKUP BEGIN - ID: (\w+)') {
        $q += [pscustomobject]@{ Begin=$w.Time; BeginId=$Matches[1] }
    }
    elseif ($w.Msg -match 'VSS SQL BACKUP END - ID: (\w+)') {
        $endId = $Matches[1]
        if ($q.Count -gt 0) {
            $s = $q[0]; $q = @($q | Select-Object -Skip 1)
            $sets += [pscustomobject]@{ Begin=$s.Begin; BeginId=$s.BeginId; End=$w.Time; EndId=$endId }
        }
    }
}
foreach ($s in $q) { $sets += [pscustomobject]@{ Begin=$s.Begin; BeginId=$s.BeginId; End=$null; EndId='' } }

$setRows = @(); $n = 0
foreach ($s in @($sets | Sort-Object Begin)) {
    $n++
    $upper = $now; if ($s.End) { $upper = $s.End }
    $inSet = @($wl | Where-Object { $_.Time -ge $s.Begin -and $_.Time -le $upper })
    $fr   = @($inSet | Where-Object { $_.Msg -match 'OnFreeze' }) | Select-Object -First 1
    $thaw = @($inSet | Where-Object { $_.Msg -match 'OnThaw' }) | Select-Object -First 1
    $bc   = @($inSet | Where-Object { $_.Msg -match 'OnBackupComplete' }) | Select-Object -First 1
    $dm   = @($inSet | Where-Object { $_.Msg -match 'Database count from metadata is (\d+)' }) | Select-Object -First 1
    $dbs = ''; if ($dm -and $dm.Msg -match 'is (\d+)') { $dbs = $Matches[1] }
    $frSec = $null; if ($fr -and $thaw) { $frSec = [math]::Round(($thaw.Time - $fr.Time).TotalSeconds, 1) }
    $bcMin = $null; if ($bc -and $s.End) { $bcMin = [math]::Round(($s.End - $bc.Time).TotalMinutes, 1) }
    $status = 'Complete'; if (-not $s.End) { $status = 'No END logged' }
    $setRows += [pscustomobject]@{ Set=$n; Begin=(Fmt $s.Begin); Databases=$dbs; FreezeToThawSec=$frSec; BackupComplete=(Fmt $bc.Time); End=(Fmt $s.End); BCtoEndMin=$bcMin; Status=$status; BcTime=$bc.Time; EndTime=$s.End }
}

# ---- 4. Windows events (VSS and shadow copy related, idle-timeout shutdowns excluded)
$ev = @()
foreach ($ln in 'Application','System') {
    foreach ($x in @(Get-WinEvent -FilterHashtable @{ LogName=$ln; StartTime=$cutoff } -ErrorAction SilentlyContinue)) {
        $msg = [string]$x.Message; $prov = [string]$x.ProviderName
        $rel = ($prov -match 'VSS|SQLWRITER|volsnap') -or ($msg -match 'Shadow Copy|SqlServerWriter')
        if (-not $rel -or $msg -match 'idle timeout') { continue }
        $ev += [pscustomobject]@{ Time=$x.TimeCreated; Source="$ln/$prov"; Id=$x.Id; Level=$x.LevelDisplayName; Text=(($msg -split "`r?`n")[0]) }
    }
}

# ---- 5. Timeouts
$timeouts = @(); $seenT = @{}
foreach ($c in $cove) {
    if ($c.Msg -match 'VSS operation (\w+) timed out after (\d+) ms') {
        $op = $Matches[1]; $ms = [int64]$Matches[2]
        $key = "$op|$ms|$($c.Time.ToString('yyyyMMddHHmmss'))"
        if ($seenT.ContainsKey($key)) { continue }
        $seenT[$key] = $true
        $timeouts += [pscustomobject]@{ Time=$c.Time; Operation=$op; Ms=$ms; Minutes=[math]::Round($ms/60000,1); TimerStart=$c.Time.AddMilliseconds(-$ms); File=$c.File; Line=$c.Msg }
    }
}

# ---- 6. Error codes (Cove, events, writer log), de-duplicated by code, file and second
$errRows = @()
foreach ($c in $cove) { foreach ($h in @([regex]::Matches($c.Msg, $hrRx) | ForEach-Object Value | Select-Object -Unique)) { $errRows += [pscustomobject]@{ Time=$c.Time; Code=$h; Source="Cove $($c.File)"; Text=$c.Msg } } }
foreach ($x in $ev)   { foreach ($h in @([regex]::Matches($x.Text, $hrRx) | ForEach-Object Value | Select-Object -Unique)) { $errRows += [pscustomobject]@{ Time=$x.Time; Code=$h; Source=$x.Source; Text=$x.Text } } }
foreach ($w in $wl)   { foreach ($h in @([regex]::Matches($w.Msg, $hrRx) | ForEach-Object Value | Select-Object -Unique)) { $errRows += [pscustomobject]@{ Time=$w.Time; Code=$h; Source='SqlWriterLogger'; Text=$w.Msg } } }
$errView = @()
foreach ($g in @($errRows | Sort-Object Time | Group-Object { "$($_.Code)|$($_.Source)|$($_.Time.ToString('yyyyMMddHHmmss'))" })) {
    $first = $g.Group[0]
    $meaning = 'See log text; no lookup entry.'
    if ($hrMeaning.ContainsKey($first.Code)) { $meaning = $hrMeaning[$first.Code] }
    $errView += [pscustomobject]@{ Time=(Fmt $first.Time); Code=$first.Code; Meaning=$meaning; Source=$first.Source; Count=$g.Count; Text=$first.Text; TimeRaw=$first.Time }
}

# ---- 7. Root cause per failed job
$rc = @(); $next = @(); $tl = @(); $timeCheck = 'No failed job to check.'
foreach ($f in $failed) {
    $wS = $f.Start.AddMinutes(-1); $wE = $f.End.AddMinutes(1)

    # Verify Cove log time against the event log
    $cf = @($cove | Where-Object { $_.Msg -match ('Backup finished for data source ' + [regex]::Escape($f.Source)) }) | Select-Object -Last 1
    if ($cf) {
        $diff = [math]::Abs(($cf.Time - $f.End).TotalSeconds)
        if ($diff -le 5) { $timeCheck = "Cove log and event log agree for $($f.Source) finish (difference $([math]::Round($diff,1)) s). All times local." }
        else { $timeCheck = "WARNING: Cove log and event log differ by $([math]::Round($diff/60,1)) min for $($f.Source) finish. Cove times may not be local." }
    }

    foreach ($t in @($timeouts | Where-Object { $_.Time -ge $wS -and $_.Time -le $wE })) {
        $rc += "Cause: $($t.Line) logged $(Fmt $t.Time) in $($t.File). Limit $($t.Ms) ms ($($t.Minutes) min). The Cove [Vss] component enforces this limit."
        $rc += "Timer start (timeout time minus limit): $(Fmt $t.TimerStart)."
        $tl += [pscustomobject]@{ TimeRaw=$t.TimerStart; Basis='computed'; Source='Timeout - limit'; Event="BackupComplete timer started (timeout time minus $($t.Ms) ms)" }

        $match = @($setRows | Where-Object { $_.BcTime -and [math]::Abs(($_.BcTime - $t.TimerStart).TotalSeconds) -le 120 }) | Select-Object -First 1
        if ($match) {
            $delta = [math]::Round(($match.BcTime - $t.TimerStart).TotalSeconds, 0)
            $rc += "Verified: SQL Writer set $($match.Set) logged OnBackupComplete at $($match.BackupComplete), $delta s after the computed timer start."
            if ($match.EndTime) {
                $late = [math]::Round(($match.EndTime - $t.Time).TotalMinutes, 1)
                $rc += "SQL Writer set $($match.Set) END at $($match.End): $($match.BCtoEndMin) min after OnBackupComplete, $late min after Cove timed out. The writer was still finishing BackupComplete when Cove gave up."
                $next += "Find what delayed SQL Writer BackupComplete between $($match.BackupComplete) and $($match.End): SQL Server ERRORLOG, blocking and long-running sessions, and backup history (msdb.dbo.backupset) for that period."
            } else {
                $rc += "SQL Writer set $($match.Set) has no END logged."
                $next += "Check whether SQL Server is still processing BackupComplete (sys.dm_exec_requests) and review the SQL Server ERRORLOG."
            }
        } else {
            $rc += 'No SQL Writer OnBackupComplete found within 2 min of the computed timer start.'
        }
    }
    foreach ($c in @($cove | Where-Object { $_.Time -ge $wS -and $_.Time -le $wE -and $_.Msg -match 'occurred during backup/restore of node' })) {
        if ($c.Msg -match 'Error "(?<text>.*?)" \(Shared:(?<code>\d+)\) occurred during backup/restore of node "(?<node>.*?)" in session #(?<sess>\d+)') {
            if ($Matches['node']) {
                $rc += "Node: $($Matches['node']) (session #$($Matches['sess']))."
                $next += "Review database and file named in the failing node: $($Matches['node'])."
            }
        }
    }
    foreach ($e in @($errView | Where-Object { $_.TimeRaw -ge $wS -and $_.TimeRaw -le $wE -and $_.Source -like 'Cove*' })) {
        $first = @($timeouts | Where-Object { $_.Time -ge $wS -and $_.Time -le $wE }) | Select-Object -First 1
        if ($first) {
            $after = [math]::Round(($e.TimeRaw - $first.Time).TotalSeconds, 2)
            $rc += "Follow-on error: $($e.Code) logged $after s after the timeout. $($e.Meaning)"
        } else {
            $rc += "Error: $($e.Code) at $($e.Time). $($e.Meaning)"
        }
    }

    # Timeline: Cove lines, key writer lines, VSS error events
    foreach ($c in @($cove | Where-Object { $_.Time -ge $wS -and $_.Time -le $wE })) {
        $tl += [pscustomobject]@{ TimeRaw=$c.Time; Basis='Cove log (local)'; Source=$c.File; Event=$c.Msg }
    }
    $tlEnd = $wE
    foreach ($sr in $setRows) { if ($sr.EndTime -and $sr.BcTime -and $sr.BcTime -ge $wS -and $sr.BcTime -le $wE -and $sr.EndTime -gt $tlEnd) { $tlEnd = $sr.EndTime.AddMinutes(1) } }
    foreach ($w in @($wl | Where-Object { $_.Time -ge $wS -and $_.Time -le $tlEnd -and $_.Msg -match 'BACKUP BEGIN|OnFreeze|OnThaw|OnPostSnapshot|OnBackupComplete|BACKUP END' })) {
        $tl += [pscustomobject]@{ TimeRaw=$w.Time; Basis='writer log (local)'; Source="SQL Writer TID $($w.TID)"; Event=$w.Msg }
    }
    foreach ($x in @($ev | Where-Object { $_.Time -ge $wS -and $_.Time -le $tlEnd -and $_.Level -in @('Error','Warning','Critical') })) {
        $tl += [pscustomobject]@{ TimeRaw=$x.Time; Basis='event log (local)'; Source=$x.Source; Event=$x.Text }
    }
}
if ($failed.Count -eq 0) { $rc += 'No failed backup job in the window.' }
elseif ($rc.Count -eq 0) {
    $rc += 'No timeout, error code, or writer fault was found for the failed job. Open the Cove log around the finish time.'
}
if ($next.Count -eq 0 -and $failed.Count -gt 0) { $next += 'Review the Cove log around the job finish time for the first error.' }
$tl = @($tl | Where-Object { $_.TimeRaw } | Sort-Object TimeRaw | ForEach-Object {
    [pscustomobject]@{ Time=(Fmt $_.TimeRaw); Basis=$_.Basis; Source=$_.Source; Event=$_.Event }
})

# ---- 8. Report
$verdict      = if ($failed.Count -gt 0) { 'FAILED BACKUP FOUND' } else { 'NO FAILED BACKUPS IN WINDOW' }
$verdictStyle = if ($failed.Count -gt 0) { '' } else { 'background:#e8f5e9;color:#2e7d32' }
$bcValue      = if ($timeouts.Count -gt 0) { "$($timeouts[0].Ms) ms ($($timeouts[0].Minutes) min), logged by Cove" } else { 'not logged in the scanned logs' }
$rcHtml   = ($rc   | ForEach-Object { "<li>$(Enc $_)</li>" }) -join ''
$nextHtml = (@($next | Select-Object -Unique) | ForEach-Object { "<li>$(Enc $_)</li>" }) -join ''

$css = @'
body{font-family:Segoe UI,Tahoma,sans-serif;margin:24px;color:#222;background:#f5f7fa}
h1{color:#0a4f8a;margin-bottom:4px} h2{color:#0a4f8a;border-bottom:2px solid #0078d4;padding-bottom:4px;margin-top:24px}
table{border-collapse:collapse;width:100%;font-size:12px;background:#fff;margin-bottom:12px}
th{background:#0078d4;color:#fff;text-align:left;padding:6px} td{border-bottom:1px solid #ddd;padding:5px;vertical-align:top}
.verdict{font-size:18px;font-weight:bold;padding:10px;border-radius:4px;background:#fde7e9;color:#b00020}
.note{color:#555;font-size:12px} .none{color:#666;font-style:italic}
'@

$html = @"
<!DOCTYPE html><html><head><meta charset='UTF-8'><title>VSS Analysis</title><style>$css</style></head><body>
<h1>VSS / SQL Writer Analysis</h1>
<p class="note">Host: $(Enc $env:COMPUTERNAME) | Generated: $(Enc ($now.ToString('yyyy-MM-dd HH:mm:ss'))) | Time zone: $(Enc $tz.StandardName) | Window: last $LastHours h | Cove files scanned: $coveFiles</p>
<p class="note">Time check: $(Enc $timeCheck)</p>
<div class="verdict" style="$verdictStyle">$(Enc $verdict)</div>
<h2>Failed Backup Jobs</h2>
$(Tbl $failed @('Source','Start','End','Minutes','Status','Errors'))
<h2>Root Cause</h2>
<ul>$rcHtml</ul>
<h2>Next Steps</h2>
<ul>$nextHtml</ul>
<h2>Error Codes</h2>
$(Tbl $errView @('Time','Code','Meaning','Source','Count','Text'))
<h2>SQL Writer Snapshot Sets</h2>
$(Tbl $setRows @('Set','Begin','Databases','FreezeToThawSec','BackupComplete','End','BCtoEndMin','Status'))
<h2>Timeline</h2>
$(Tbl $tl @('Time','Basis','Source','Event'))
<h2>VSS Timeout Reference</h2>
<table><tr><th>Phase</th><th>Value</th><th>Source</th></tr>
<tr><td>Freeze to Thaw</td><td>60 seconds default; writers can override. An Abort is generated if exceeded.</td><td>Microsoft Learn, CVssWriter::OnFreeze</td></tr>
<tr><td>BackupComplete</td><td>No default found in the Microsoft Learn pages reviewed. Value in this environment: $(Enc $bcValue).</td><td>Cove log</td></tr>
</table>
</body></html>
"@

$outDir = Split-Path -Parent $OutputPath
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$html | Out-File -FilePath $OutputPath -Encoding UTF8 -Force

Write-Host "VERDICT: $verdict"
foreach ($f in $failed) { Write-Host "Failed: $($f.Source) ended $($f.End) (status $($f.Status), errors $($f.Errors))" -ForegroundColor Red }
foreach ($r in $rc) { Write-Host $r }
Write-Host "Time check: $timeCheck"
Write-Host "Report: $OutputPath" -ForegroundColor Green