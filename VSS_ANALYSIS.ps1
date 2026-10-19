# ============================================================================
# VSS Error 0x80042301 Troubleshooting Script
# Timeout in BackupComplete Phase
# ============================================================================

# Run as Administrator!
if (-not ([Security.Principal.WindowsIdentity]::GetCurrent().Groups -match "S-1-5-32-544")) {
    Write-Host "ERROR: Run as Administrator!" -ForegroundColor Red
    exit 1
}

Write-Host "`n=== VSS Error 0x80042301 Analysis ===" -ForegroundColor Cyan
Write-Host "Error: BackupComplete timeout (5400000 ms = 1.5 hours)`n" -ForegroundColor Yellow

# 1. Check SQL Writer Service Status
Write-Host "[1] Checking SQL Writer Service Status..." -ForegroundColor Cyan
$sqlWriter = Get-Service SQLWRITER -ErrorAction SilentlyContinue
if ($sqlWriter) {
    Write-Host "Status: $($sqlWriter.Status)" -ForegroundColor Green
    Write-Host "Start Type: $($sqlWriter.StartType)" -ForegroundColor Green
} else {
    Write-Host "ERROR: SQL Writer service not found!" -ForegroundColor Red
}

# 2. Check VSS Service
Write-Host "`n[2] Checking VSS Service Status..." -ForegroundColor Cyan
$vss = Get-Service VSS -ErrorAction SilentlyContinue
if ($vss) {
    Write-Host "Status: $($vss.Status)" -ForegroundColor Green
} else {
    Write-Host "ERROR: VSS service not found!" -ForegroundColor Red
}

# 3. Parse SqlWriterLogger.txt for BackupComplete errors
Write-Host "`n[3] Analyzing SqlWriterLogger.txt for BackupComplete events..." -ForegroundColor Cyan
$logPath = "C:\Program Files\Microsoft SQL Server\90\Shared\SqlWriterLogger.txt"

if (Test-Path $logPath) {
    $logContent = Get-Content $logPath -Tail 1000
    
    # Find BackupComplete events
    $backupCompleteEvents = $logContent | Select-String -Pattern "BackupComplete|OnBackupComplete"
    Write-Host "BackupComplete events found: $($backupCompleteEvents.Count)" -ForegroundColor Yellow
    
    if ($backupCompleteEvents.Count -gt 0) {
        Write-Host "`nLast 5 BackupComplete events:" -ForegroundColor Yellow
        $backupCompleteEvents | Select-Object -Last 5 | ForEach-Object {
            Write-Host "  $_" -ForegroundColor Gray
        }
    }
    
    # Find 0x80042301 errors
    $errorLines = $logContent | Select-String -Pattern "0x80042301|incorrect state|BackupComplete.*timeout"
    if ($errorLines.Count -gt 0) {
        Write-Host "`n0x80042301 ERROR INSTANCES:" -ForegroundColor Red
        $errorLines | Select-Object -Last 10 | ForEach-Object {
            Write-Host "  $_" -ForegroundColor Red
        }
    }
    
    # Find OnFreeze/OnThaw events to see timing
    $freezeEvents = $logContent | Select-String -Pattern "OnFreeze|OnThaw"
    Write-Host "`nFreeze/Thaw events: $($freezeEvents.Count)" -ForegroundColor Cyan
    
} else {
    Write-Host "ERROR: SqlWriterLogger.txt not found at $logPath" -ForegroundColor Red
}

# 4. Check Windows Event Log for correlated errors
Write-Host "`n[4] Checking Windows Event Log for SQLWRITER errors..." -ForegroundColor Cyan
try {
    $events = Get-WinEvent -FilterHashtable @{
        LogName = 'Application'
        ProviderName = 'SQLWRITER'
        StartTime = (Get-Date).AddHours(-24)
    } -ErrorAction SilentlyContinue | Sort-Object TimeCreated -Descending
    
    if ($events) {
        Write-Host "Found $($events.Count) SQLWRITER events in last 24 hours" -ForegroundColor Yellow
        $events | Select-Object -First 5 | ForEach-Object {
            Write-Host "  [$($_.TimeCreated)] ID: $($_.Id) - $(($_.Message -split "`n")[0])" -ForegroundColor Gray
        }
    }
} catch {
    Write-Host "Could not access Event Log: $_" -ForegroundColor Yellow
}

# 5. Check system resources during the failure timeframe
Write-Host "`n[5] Current System Resources..." -ForegroundColor Cyan
$cpuUsage = (Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 1).CounterSamples[0].CookedValue
$mem = Get-CimInstance Win32_OperatingSystem
$memUsagePercent = [math]::Round(($mem.TotalVisibleMemorySize - $mem.FreePhysicalMemory) / $mem.TotalVisibleMemorySize * 100, 2)

Write-Host "  CPU Usage: $([math]::Round($cpuUsage, 2))%" -ForegroundColor $(if ($cpuUsage -gt 80) { "Red" } else { "Green" })
Write-Host "  Memory Usage: $memUsagePercent%" -ForegroundColor $(if ($memUsagePercent -gt 85) { "Red" } else { "Green" })
Write-Host "  Available Memory: $([math]::Round($mem.FreePhysicalMemory/1MB, 2)) MB" -ForegroundColor Green

# 6. Disk space on backup volumes
Write-Host "`n[6] Disk Space on Backup Volumes..." -ForegroundColor Cyan
Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
    $freePercent = [math]::Round($_.FreeSpace / $_.Size * 100, 2)
    $color = if ($freePercent -lt 20) { "Red" } else { "Green" }
    Write-Host "  $($_.Name): $freePercent% free ($([math]::Round($_.FreeSpace/1GB, 2)) GB)" -ForegroundColor $color
}

# 7. Check for stuck backup processes
Write-Host "`n[7] Checking for stuck VSS processes..." -ForegroundColor Cyan
$vssProcs = Get-Process | Where-Object { $_.Name -like "*backup*" -or $_.Name -like "*vss*" -or $_.Name -like "*writer*" }
if ($vssProcs) {
    $vssProcs | ForEach-Object {
        Write-Host "  $($_.Name): $($_.Id) - Memory: $([math]::Round($_.WorkingSet/1MB, 2))MB" -ForegroundColor Yellow
    }
} else {
    Write-Host "  No VSS-related processes found" -ForegroundColor Green
}

# 8. Check SQL Server for active transactions or locks
Write-Host "`n[8] Checking SQL Server Status..." -ForegroundColor Cyan
try {
    # Import SQL Module if available
    Import-Module SQLPS -ErrorAction SilentlyContinue
    
    # Try to connect to local SQL Server
    $sqlConnection = New-Object System.Data.SqlClient.SqlConnection
    $sqlConnection.ConnectionString = "Server=.;Integrated Security=true;Connection Timeout=5"
    $sqlConnection.Open()
    
    if ($sqlConnection.State -eq "Open") {
        Write-Host "  SQL Server: Connected" -ForegroundColor Green
        
        $cmd = $sqlConnection.CreateCommand()
        $cmd.CommandText = "SELECT COUNT(*) FROM sys.dm_exec_requests WHERE session_id > 50"
        $activeRequests = $cmd.ExecuteScalar()
        Write-Host "  Active requests (excluding system): $activeRequests" -ForegroundColor Yellow
        
        $sqlConnection.Close()
    }
} catch {
    Write-Host "  Could not connect to SQL Server: $_" -ForegroundColor Yellow
}

# 9. Display recommendations
Write-Host "`n" + "="*80 -ForegroundColor Cyan
Write-Host "RECOMMENDATIONS FOR VSS ERROR 0x80042301 (BackupComplete Timeout)" -ForegroundColor Cyan
Write-Host "="*80 -ForegroundColor Cyan

$recommendations = @(
    @{
        Priority = "CRITICAL"
        Action = "Increase BackupComplete timeout threshold"
        Details = "5400000 ms (1.5 hrs) is the current timeout. This is likely insufficient for your database size/system load."
        Steps = @(
            "1. Modify backup software timeout settings (backup job configuration)"
            "2. If using Windows Server Backup: Increase VSS timeout in registry"
            "   HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\BackupRestore\VSS"
            "3. Increase SqlWriterConfig.ini timeout if available"
        )
    },
    @{
        Priority = "HIGH"
        Action = "Verify database file scope is complete"
        Details = "Incomplete file snapshot can cause BackupComplete to fail (torn database scenario)"
        Steps = @(
            "Run this SQL query to list all DB files:"
            "SELECT name, physical_name FROM sys.master_files WHERE database_id > 4"
            "Ensure ALL drives containing files are included in VSS backup"
        )
    },
    @{
        Priority = "HIGH"
        Action = "Reduce system load during backup window"
        Details = "High CPU/Memory/Disk I/O during BackupComplete can cause timeout"
        Steps = @(
            "1. Move backup to off-peak hours with minimal database activity"
            "2. Stop non-critical services during backup"
            "3. Monitor with: Get-Counter '\PhysicalDisk(_Total)\% Disk Time' -Continuous"
        )
    },
    @{
        Priority = "MEDIUM"
        Action = "Enable detailed SQL Writer logging"
        Details = "Get more granular timeout location information"
        Steps = @(
            "1. Edit: C:\Program Files\Microsoft SQL Server\90\Shared\SqlWriterConfig.ini"
            "2. Change: TraceLevel=DEFAULT to TraceLevel=MINIMAL"
            "3. Restart-Service SQLWRITER -Force"
            "4. Run backup again and review expanded SqlWriterLogger.txt"
        )
    },
    @{
        Priority = "MEDIUM"
        Action = "Check for blocking SQL transactions"
        Details = "Long-running queries during backup finalization"
        Steps = @(
            "Run this during backup to find blockers:"
            "SELECT session_id, blocking_session_id, command FROM sys.dm_exec_requests"
            "Kill long-running non-essential queries: KILL <session_id>"
        )
    },
    @{
        Priority = "LOW"
        Action = "Verify SQL Writer/VSS service health"
        Details = "Service crashes during BackupComplete"
        Steps = @(
            "Restart-Service SQLWRITER -Force"
            "Restart-Service VSS -Force"
            "Verify: Get-Service SQLWRITER, VSS | Select Status"
        )
    }
)

foreach ($rec in $recommendations) {
    Write-Host "`n[$($rec.Priority)] $($rec.Action)" -ForegroundColor $(
        if ($rec.Priority -eq "CRITICAL") { "Red" }
        elseif ($rec.Priority -eq "HIGH") { "Yellow" }
        else { "Cyan" }
    )
    Write-Host "  Why: $($rec.Details)" -ForegroundColor Gray
    Write-Host "  How:" -ForegroundColor Gray
    $rec.Steps | ForEach-Object {
        Write-Host "    $_" -ForegroundColor Gray
    }
}

Write-Host "`n" + "="*80 -ForegroundColor Cyan
Write-Host "Script execution completed at $(Get-Date)" -ForegroundColor Green