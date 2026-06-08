# One-shot installer for the MCRN Fleet Heartbeat scheduled task.
# Drops the heartbeat writer onto disk and registers a Windows Scheduled
# Task that runs it every ${interval_minutes} minute(s) as SYSTEM.
#
# Uses schtasks.exe rather than New-ScheduledTaskTrigger because
# `-Once -RepetitionInterval` without `-RepetitionDuration` is unreliable
# across Windows builds (sometimes errors, sometimes fires only once).

$ErrorActionPreference = 'Stop'

$labRoot = 'C:\ExpanseLab'
New-Item -ItemType Directory -Path $labRoot -Force | Out-Null

$writerPath  = Join-Path $labRoot 'donnager-heartbeat-writer.ps1'
$writerBytes = [System.Convert]::FromBase64String('${writer_b64}')
$writerText  = [System.Text.Encoding]::UTF8.GetString($writerBytes)
Set-Content -Path $writerPath -Value $writerText -Encoding UTF8 -Force

$taskName = 'MCRN-FleetHeartbeat'
# $writerPath is under C:\ExpanseLab (no spaces), so no inner quoting needed.
$taskCmd  = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $writerPath"

# Replace any prior version so re-runs are idempotent. On first install the
# task doesn't exist yet; schtasks writes "task not found" to stderr, and PS
# 5.1 with $ErrorActionPreference=Stop turns any native-command stderr into a
# terminating NativeCommandError (the 2>$null redirect routes the bytes but
# doesn't suppress the error). Swallow via try/catch and reset $LASTEXITCODE.
try { & schtasks.exe /Delete /TN $taskName /F 2>&1 | Out-Null } catch { }
$Global:LASTEXITCODE = 0

& schtasks.exe /Create `
    /TN $taskName `
    /TR $taskCmd `
    /SC MINUTE `
    /MO ${interval_minutes} `
    /RU SYSTEM `
    /RL HIGHEST `
    /F | Out-Null

if ($LASTEXITCODE -ne 0) {
    throw "schtasks /Create failed with exit code $LASTEXITCODE"
}

# Kick off an immediate first run so the table starts filling without
# waiting for the first scheduled tick.
& schtasks.exe /Run /TN $taskName | Out-Null
