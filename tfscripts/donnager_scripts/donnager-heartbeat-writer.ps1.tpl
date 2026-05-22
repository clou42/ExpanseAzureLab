# MCRN Fleet Heartbeat writer.
# Runs on a schedule as the privileged Tycho DB admin login (SQL auth).
# Reads connection details from HKLM:\SOFTWARE\Expanse (populated by donnager_secrets_provision).
#
# Auto-pause aware. tycho-db is GP_S_Gen5_1 Serverless with
# auto_pause_delay_in_minutes=60. Two interacting concerns:
#
#   1. Never *wake* a paused DB. The ARM control plane is queried first to
#      check pause state; SKIP if not Online (ARM reads do NOT count as
#      activity for auto-pause).
#   2. Never *pin* an Online DB awake. Any SQL INSERT counts as activity
#      and resets the 60-min idle clock. So once a player wakes the DB,
#      naive 5-min heartbeats would keep it Online forever, even after
#      the player leaves. We fix this by treating each Paused -> Online
#      transition as a "session" and only writing heartbeats during the
#      first HEARTBEAT_WINDOW_MINUTES of that session. After the window
#      expires the writer stops firing, the auto-pause clock runs down
#      naturally from whatever the player's last activity was, and the
#      DB pauses normally. Once paused, we're back at concern (1).
#
# A tiny JSON state file on disk (C:\ExpanseLab\heartbeat-state.json) is
# enough to track this; we can't use the DB itself because reading from
# the DB would itself reset the auto-pause clock.

$ErrorActionPreference = 'Stop'

# How long after each Paused -> Online transition we'll keep writing
# heartbeats. 30 min = 6 ticks at the default 5-min interval, which
# gives a slow player ample chance to plant their trigger and see it
# fire at least once.
$HEARTBEAT_WINDOW_MINUTES = 30

$registryPath = 'HKLM:\SOFTWARE\Expanse'
$sqlServerFqdn = (Get-ItemProperty -Path $registryPath -Name 'SQLServer').SQLServer
$sqlDatabase   = (Get-ItemProperty -Path $registryPath -Name 'SQLDatabase').SQLDatabase
$sqlUser       = (Get-ItemProperty -Path $registryPath -Name 'SQLAdminUser').SQLAdminUser
$sqlPass       = (Get-ItemProperty -Path $registryPath -Name 'SQLAdminPass').SQLAdminPass
$jovianOid     = (Get-ItemProperty -Path $registryPath -Name 'DonnagerMIPrincipalID').DonnagerMIPrincipalID

# Logical server name = first label of FQDN (e.g. "tycho-94212.database.windows.net" -> "tycho-94212").
$sqlServerName = $sqlServerFqdn.Split('.')[0]

# Subscription id and resource group come from this VM's instance metadata.
$inst = Invoke-RestMethod -UseBasicParsing -Headers @{ Metadata = 'true' } `
    -Uri 'http://169.254.169.254/metadata/instance?api-version=2021-02-01'
$subId = $inst.compute.subscriptionId
$rg    = $inst.compute.resourceGroupName

# ARM token for the jovian_access UAMI (which has Reader on tycho-db).
$tok = Invoke-RestMethod -UseBasicParsing -Headers @{ Metadata = 'true' } `
    -Uri "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/&object_id=$jovianOid"
$armToken = $tok.access_token

# Control-plane status check. Does NOT wake the database.
$dbUrl = "https://management.azure.com/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Sql/servers/$sqlServerName/databases/$sqlDatabase" + "?api-version=2023-05-01-preview"
$db = Invoke-RestMethod -UseBasicParsing -Headers @{ Authorization = "Bearer $armToken" } -Uri $dbUrl
$status = $db.properties.status

# Load (or initialize) session state.
$stateFile = 'C:\ExpanseLab\heartbeat-state.json'
$state = $null
if (Test-Path $stateFile) {
    try { $state = Get-Content $stateFile -Raw | ConvertFrom-Json } catch { $state = $null }
}
if (-not $state) {
    $state = [pscustomobject]@{ last_arm_status = $null; first_online_at_utc = $null }
}

function Save-State { param($s) ($s | ConvertTo-Json -Compress) | Set-Content -Path $stateFile -Encoding ASCII -Force }

# Case 1: DB not Online -- record status, do nothing else.
if ($status -ne 'Online') {
    $state.last_arm_status = $status
    $state.first_online_at_utc = $null
    Save-State $state
    Write-Output "tycho-db status='$status' (skipping heartbeat to let auto-pause hold)"
    exit 0
}

# Case 2: DB Online. Detect transition vs. continuation.
$nowUtc = (Get-Date).ToUniversalTime()
if ($state.last_arm_status -ne 'Online' -or -not $state.first_online_at_utc) {
    # Paused -> Online transition: new session.
    $state.first_online_at_utc = $nowUtc.ToString('o')
}
$state.last_arm_status = 'Online'

$sessionStart = [DateTime]::Parse($state.first_online_at_utc).ToUniversalTime()
$elapsedMin   = ($nowUtc - $sessionStart).TotalMinutes

if ($elapsedMin -ge $HEARTBEAT_WINDOW_MINUTES) {
    Save-State $state
    Write-Output ("tycho-db Online but session is {0:N1} min old (>={1} min window) - skipping so auto-pause can hold" -f $elapsedMin, $HEARTBEAT_WINDOW_MINUTES)
    exit 0
}

# Case 2a: Within window -- write heartbeat.
$connString = "Server=tcp:$sqlServerFqdn,1433;Database=$sqlDatabase;User ID=$sqlUser;Password=$sqlPass;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"

$notes = @(
    'All hands at station.',
    'Reactor at nominal output.',
    'Patrol of Jovian moons complete.',
    'PDC drills concluded, no anomalies.',
    'Comm laser handshake with Tycho verified.',
    'Torpedo magazine inventory reconciled.',
    'Drive plume telemetry within tolerance.'
)
$note         = Get-Random -InputObject $notes
$writeStatus  = 'Nominal'

$conn = New-Object System.Data.SqlClient.SqlConnection $connString
$conn.Open()
try {
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "INSERT INTO dbo.fleet_heartbeat (ship, status, note) VALUES (@ship, @status, @note);"
    $null = $cmd.Parameters.AddWithValue('@ship',   'Donnager')
    $null = $cmd.Parameters.AddWithValue('@status', $writeStatus)
    $null = $cmd.Parameters.AddWithValue('@note',   $note)
    $null = $cmd.ExecuteNonQuery()
} finally {
    $conn.Close()
}

Save-State $state
Write-Output ("tycho-db heartbeat written ({0:N1} min into session)" -f $elapsedMin)
