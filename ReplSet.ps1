[CmdletBinding()]
param(
	[string]$BasePath = $PSScriptRoot,
	[string]$ReplicaSetName = "rs0",
	[string]$PrimaryHost = "127.0.0.1",
	[int]$PrimaryPort = 27017,
	[int]$SecondaryPort = 27018,
	[int]$ArbiterPort = 27019,
	[int]$StartupTimeoutSec = 120,
	[switch]$SkipServiceInstall
)

$ErrorActionPreference = "Stop"

$NormalizedPrimaryHost = if ($PrimaryHost -eq "localhost") { "127.0.0.1" } else { $PrimaryHost }

$Script:LogFile = Join-Path $BasePath "replset-setup.log"

function Write-Log {
	param(
		[Parameter(Mandatory = $true)][string]$Message,
		[ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")][string]$Level = "INFO"
	)

	$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
	$line = "[$timestamp] [$Level] $Message"
	Write-Host $line
	Add-Content -Path $Script:LogFile -Value $line
}

function Get-IsAdministrator {
	$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
	$principal = New-Object Security.Principal.WindowsPrincipal($identity)
	return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ExecutablePath {
	param(
		[Parameter(Mandatory = $true)][string]$Name,
		[string[]]$FallbackPaths
	)

	$cmd = Get-Command $Name -ErrorAction SilentlyContinue
	if ($cmd) {
		return $cmd.Source
	}

	foreach ($candidate in $FallbackPaths) {
		if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate)) {
			return $candidate
		}
	}

	$checked = ($FallbackPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ", "
	throw "Cannot find $Name. Please add MongoDB bin to PATH or verify one of these files exists: $checked"
}

function Invoke-MongoShell {
	param(
		[Parameter(Mandatory = $true)][string]$MongoShPath,
		[Parameter(Mandatory = $true)][string]$NodeHost,
		[Parameter(Mandatory = $true)][int]$Port,
		[Parameter(Mandatory = $true)][string]$Eval,
		[int]$Retries = 1,
		[int]$RetryDelaySec = 2
	)

	for ($attempt = 1; $attempt -le $Retries; $attempt++) {
		$output = & $MongoShPath --quiet --host $NodeHost --port $Port --eval $Eval 2>&1
		if ($LASTEXITCODE -eq 0) {
			return ($output | Out-String).Trim()
		}

		if ($attempt -lt $Retries) {
			Start-Sleep -Seconds $RetryDelaySec
		}
	}

	throw "mongosh command failed on $NodeHost`:$Port. Output: $($output | Out-String)"
}

function Wait-NodeReady {
	param(
		[Parameter(Mandatory = $true)][string]$MongoShPath,
		[Parameter(Mandatory = $true)][string]$NodeHost,
		[Parameter(Mandatory = $true)][int]$Port,
		[Parameter(Mandatory = $true)][int]$TimeoutSec
	)

	$deadline = (Get-Date).AddSeconds($TimeoutSec)
	while ((Get-Date) -lt $deadline) {
		try {
			$out = Invoke-MongoShell -MongoShPath $MongoShPath -NodeHost $NodeHost -Port $Port -Eval "db.adminCommand({ ping: 1 }).ok"
			if ($out -match "1") {
				return $true
			}
		}
		catch {
		}
		Start-Sleep -Seconds 2
	}

	return $false
}

function Test-TcpPort {
	param(
		[Parameter(Mandatory = $true)][string]$NodeHost,
		[Parameter(Mandatory = $true)][int]$Port,
		[int]$TimeoutMs = 1200
	)

	$client = New-Object System.Net.Sockets.TcpClient
	try {
		$asyncResult = $client.BeginConnect($NodeHost, $Port, $null, $null)
		$connected = $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
		if (-not $connected) {
			return $false
		}

		$client.EndConnect($asyncResult)
		return $true
	}
	catch {
		return $false
	}
	finally {
		$client.Close()
	}
}

function Wait-PortReady {
	param(
		[Parameter(Mandatory = $true)][string]$NodeHost,
		[Parameter(Mandatory = $true)][int]$Port,
		[Parameter(Mandatory = $true)][int]$TimeoutSec
	)

	$deadline = (Get-Date).AddSeconds($TimeoutSec)
	while ((Get-Date) -lt $deadline) {
		if (Test-TcpPort -NodeHost $NodeHost -Port $Port) {
			return $true
		}

		Start-Sleep -Seconds 2
	}

	return $false
}

function Get-NodeReplicationInfo {
	param(
		[Parameter(Mandatory = $true)][string]$MongoShPath,
		[Parameter(Mandatory = $true)][string]$NodeHost,
		[Parameter(Mandatory = $true)][int]$Port
	)

	$eval = "try { var h = db.hello(); var replicationEnabled = !!(h && (h.isreplicaset || h.setName)); var setName = (h && h.setName) ? h.setName : null; print(EJSON.stringify({ ok: 1, replicationEnabled: replicationEnabled, setName: setName })); } catch (e) { print(EJSON.stringify({ ok: 0, errmsg: e.message })); }"
	$raw = Invoke-MongoShell -MongoShPath $MongoShPath -NodeHost $NodeHost -Port $Port -Eval $eval

	try {
		$obj = $raw | ConvertFrom-Json
	}
	catch {
		throw "Cannot parse getCmdLineOpts output from $NodeHost`:${Port}: $raw"
	}

	if ($obj.ok -ne 1) {
		throw "Failed to read replication info on $NodeHost`:${Port}: $raw"
	}

	return $obj
}

function Stop-MongodByPort {
	param([Parameter(Mandatory = $true)][int]$Port)

	$connections = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
	if (-not $connections) {
		Write-Log "No listening process found on port $Port." "WARN"
		return
	}

	$pids = $connections | Select-Object -ExpandProperty OwningProcess -Unique
	foreach ($pidValue in $pids) {
		try {
			$proc = Get-Process -Id $pidValue -ErrorAction Stop
			if ($proc.ProcessName -ieq "mongod") {
				Stop-Process -Id $pidValue -Force -ErrorAction Stop
				Write-Log "Stopped mongod PID $pidValue listening on port $Port." "INFO"
			}
			else {
				Write-Log "Port $Port is used by PID $pidValue ($($proc.ProcessName)); not stopping automatically." "WARN"
			}
		}
		catch {
			Write-Log "Failed to stop process PID $pidValue on port ${Port}: $($_.Exception.Message)" "WARN"
		}
	}
}

function Install-ServiceIfNeeded {
	param(
		[Parameter(Mandatory = $true)][string]$MongodPath,
		[Parameter(Mandatory = $true)][string]$ConfigPath,
		[Parameter(Mandatory = $true)][string]$ServiceName,
		[Parameter(Mandatory = $true)][string]$ServiceDisplayName
	)

	$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
	if ($existing) {
		Write-Log "Service $ServiceName already exists. Skipping install step." "WARN"
		return
	}

	Write-Log "Installing service $ServiceName ($ServiceDisplayName)" "INFO"
	& $MongodPath --config $ConfigPath --serviceName $ServiceName --serviceDisplayName $ServiceDisplayName --install
	if ($LASTEXITCODE -ne 0) {
		throw "Failed to install service $ServiceName."
	}
	Write-Log "Service $ServiceName installed successfully." "SUCCESS"
}

function Start-ServiceSafe {
	param([Parameter(Mandatory = $true)][string]$ServiceName)

	$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
	if (-not $svc) {
		throw "Cannot find service $ServiceName to start."
	}

	if ($svc.Status -eq "Running") {
		Write-Log "Service $ServiceName is already running." "INFO"
		return
	}

	Start-Service -Name $ServiceName
	$svc.WaitForStatus("Running", [TimeSpan]::FromSeconds(30))
	Write-Log "Service $ServiceName is now running." "SUCCESS"
}

function Stop-TempNode {
	param(
		[Parameter(Mandatory = $true)][string]$MongoShPath,
		[Parameter(Mandatory = $true)][string]$NodeHost,
		[Parameter(Mandatory = $true)][int]$Port
	)

	try {
		& $MongoShPath --quiet --host $NodeHost --port $Port --eval "db.adminCommand({shutdown:1, force:true})" 2>$null | Out-Null
		Write-Log "Sent shutdown command to node $NodeHost`:$Port" "INFO"
	}
	catch {
		Write-Log "Could not shut down node $NodeHost`:$Port via mongosh (it may already be stopped)." "WARN"
	}
}

function Stop-TempNodeProcessByConfig {
	param(
		[Parameter(Mandatory = $true)][string]$ConfigPath,
		[Parameter(Mandatory = $true)][int]$Port
	)

	$configEscaped = [Regex]::Escape($ConfigPath)
	$targetProcesses = Get-CimInstance Win32_Process -Filter "Name = 'mongod.exe'" |
		Where-Object { $_.CommandLine -match $configEscaped }

	if (-not $targetProcesses) {
		Write-Log "No temporary mongod process found for port $Port (config match)." "WARN"
		return
	}

	foreach ($proc in $targetProcesses) {
		try {
			Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
			Write-Log "Stopped temporary mongod process PID $($proc.ProcessId) for port $Port." "INFO"
		}
		catch {
			Write-Log "Failed to stop temporary mongod PID $($proc.ProcessId) for port ${Port}: $($_.Exception.Message)" "WARN"
		}
	}
}

$nodePorts = @($PrimaryPort, $SecondaryPort, $ArbiterPort)
$nodeConfigs = @{
	$PrimaryPort   = Join-Path $BasePath "$PrimaryPort\bin\mongod.conf"
	$SecondaryPort = Join-Path $BasePath "$SecondaryPort\bin\mongod.conf"
	$ArbiterPort   = Join-Path $BasePath "$ArbiterPort\bin\mongod.conf"
}

$mongoBin = Join-Path $BasePath "27017\bin"
$serverRoot = Split-Path -Parent $BasePath
$serverBin = Join-Path $serverRoot "bin"
$envHomes = @($env:MONGO_HOME, $env:MONGODB_HOME, $env:MONGODB_BIN)
$envBins = @()

foreach ($envHomePath in $envHomes) {
	if ([string]::IsNullOrWhiteSpace($envHomePath)) {
		continue
	}

	if ((Split-Path -Leaf $envHomePath).ToLowerInvariant() -eq "bin") {
		$envBins += $envHomePath
	}
	else {
		$envBins += (Join-Path $envHomePath "bin")
	}
}

$fallbackBins = @($serverBin) + $envBins + @($mongoBin)
$fallbackBins = $fallbackBins | Select-Object -Unique

$mongodFallbacks = @($fallbackBins | ForEach-Object { Join-Path $_ "mongod.exe" })
$mongoshFallbacks = @($fallbackBins | ForEach-Object { Join-Path $_ "mongosh.exe" })

Write-Log "===== STARTING REPLICA SET SETUP: $ReplicaSetName =====" "INFO"
Write-Log "BasePath: $BasePath" "INFO"
Write-Log "Log file: $Script:LogFile" "INFO"
if ($NormalizedPrimaryHost -ne $PrimaryHost) {
	Write-Log "PrimaryHost 'localhost' normalized to '$NormalizedPrimaryHost' to avoid IPv6 loopback issues." "WARN"
}
Write-Log "Executable candidate bins: $($fallbackBins -join '; ')" "INFO"

foreach ($cfg in $nodeConfigs.Values) {
	if (-not (Test-Path $cfg)) {
		throw "Config file not found: $cfg"
	}
}

$mongodPath = Get-ExecutablePath -Name "mongod" -FallbackPaths $mongodFallbacks
$mongoshPath = $null
$hasMongoShell = $true

try {
	$mongoshPath = Get-ExecutablePath -Name "mongosh" -FallbackPaths $mongoshFallbacks
}
catch {
	$hasMongoShell = $false
	Write-Log "mongosh was not found. Replica set initiate/status checks will be skipped." "WARN"
}

Write-Log "mongod: $mongodPath" "INFO"
if ($hasMongoShell) {
	Write-Log "mongosh: $mongoshPath" "INFO"
}

Write-Log "Step 1 - Ensure all 3 nodes are running" "INFO"
foreach ($port in $nodePorts) {
	$isReady = $false
	$cfg = $nodeConfigs[$port]
	$shouldStartOrRestart = $false

	if ($hasMongoShell) {
		$isReady = Wait-NodeReady -MongoShPath $mongoshPath -NodeHost $NormalizedPrimaryHost -Port $port -TimeoutSec 5
	}
	else {
		$isReady = Wait-PortReady -NodeHost $NormalizedPrimaryHost -Port $port -TimeoutSec 5
	}

	if ($isReady) {
		Write-Log "Node $NormalizedPrimaryHost`:$port is already running." "SUCCESS"

		if ($hasMongoShell) {
			$nodeReplicationInfo = Get-NodeReplicationInfo -MongoShPath $mongoshPath -NodeHost $NormalizedPrimaryHost -Port $port
			$setName = $nodeReplicationInfo.setName
			if ((-not $nodeReplicationInfo.replicationEnabled) -or ($setName -and $setName -ne $ReplicaSetName)) {
				Write-Log "Node $NormalizedPrimaryHost`:$port is not in expected replica-set mode (replicationEnabled=$($nodeReplicationInfo.replicationEnabled), setName='$setName'). Restarting node with --replSet." "WARN"
				Stop-MongodByPort -Port $port
				Start-Sleep -Seconds 2
				$shouldStartOrRestart = $true
			}
		}

		if (-not $shouldStartOrRestart) {
			continue
		}
	}

	if (-not $isReady) {
		Write-Log "Node $NormalizedPrimaryHost`:$port is not running. Starting with config $cfg" "INFO"
	}
	else {
		Write-Log "Starting node $NormalizedPrimaryHost`:$port with config $cfg" "INFO"
	}
	Start-Process -FilePath $mongodPath -ArgumentList @("--config", $cfg, "--replSet", $ReplicaSetName) -WindowStyle Hidden | Out-Null

	$isReadyAfterStart = $false
	if ($hasMongoShell) {
		$isReadyAfterStart = Wait-NodeReady -MongoShPath $mongoshPath -NodeHost $NormalizedPrimaryHost -Port $port -TimeoutSec $StartupTimeoutSec
	}
	else {
		$isReadyAfterStart = Wait-PortReady -NodeHost $NormalizedPrimaryHost -Port $port -TimeoutSec $StartupTimeoutSec
	}

	if (-not $isReadyAfterStart) {
		throw "Node $NormalizedPrimaryHost`:$port is not ready after $StartupTimeoutSec seconds."
	}

	if ($hasMongoShell) {
		$nodeReplicationInfo = Get-NodeReplicationInfo -MongoShPath $mongoshPath -NodeHost $NormalizedPrimaryHost -Port $port
		if (-not $nodeReplicationInfo.replicationEnabled) {
			throw "Node $NormalizedPrimaryHost`:$port is running but replication is still disabled after restart."
		}

		if ($nodeReplicationInfo.setName -and $nodeReplicationInfo.setName -ne $ReplicaSetName) {
			throw "Node $NormalizedPrimaryHost`:$port has unexpected setName '$($nodeReplicationInfo.setName)' after restart."
		}
	}

	Write-Log "Node $NormalizedPrimaryHost`:$port is ready." "SUCCESS"
}

if ($hasMongoShell) {
	Write-Log "Step 2 - Check current replica set status" "INFO"
	$rsStatusRaw = Invoke-MongoShell -MongoShPath $mongoshPath -NodeHost $NormalizedPrimaryHost -Port $PrimaryPort -Eval "try { print(EJSON.stringify(rs.status())); } catch(e) { print(EJSON.stringify({ ok: 0, errmsg: e.message })); }"
	$rsStatus = $null

	try {
		$rsStatus = $rsStatusRaw | ConvertFrom-Json
	}
	catch {
		throw "Cannot parse rs.status() output: $rsStatusRaw"
	}

	$needsInit = $true
	if ($rsStatus.ok -eq 1 -and $rsStatus.set -eq $ReplicaSetName) {
		$needsInit = $false
		Write-Log "Replica set $ReplicaSetName already exists." "WARN"
	}

	if ($needsInit) {
		Write-Log "Step 3 - Initialize replica set" "INFO"
		$rsConfigJson = @"
{
  _id: '$ReplicaSetName',
  members: [
	{ _id: 0, host: '${NormalizedPrimaryHost}:$PrimaryPort', priority: 2 },
	{ _id: 1, host: '${NormalizedPrimaryHost}:$SecondaryPort', priority: 1 },
	{ _id: 2, host: '${NormalizedPrimaryHost}:$ArbiterPort', arbiterOnly: true }
  ]
}
"@

		$initRaw = Invoke-MongoShell -MongoShPath $mongoshPath -NodeHost $NormalizedPrimaryHost -Port $PrimaryPort -Eval "try { print(EJSON.stringify(rs.initiate($rsConfigJson))); } catch(e) { print(EJSON.stringify({ ok: 0, errmsg: e.message })); }"
		$initObj = $initRaw | ConvertFrom-Json
		if ($initObj.ok -ne 1) {
			throw "rs.initiate failed: $initRaw"
		}
		Write-Log "rs.initiate completed successfully." "SUCCESS"
	}

	Write-Log "Step 4 - Wait for replica set to become stable" "INFO"
	$verifyDeadline = (Get-Date).AddSeconds($StartupTimeoutSec)
	$stable = $false
	while ((Get-Date) -lt $verifyDeadline) {
		$statusRaw = Invoke-MongoShell -MongoShPath $mongoshPath -NodeHost $NormalizedPrimaryHost -Port $PrimaryPort -Eval "try { print(EJSON.stringify(rs.status())); } catch(e) { print(EJSON.stringify({ ok: 0, errmsg: e.message })); }"
		$statusObj = $statusRaw | ConvertFrom-Json

		if ($statusObj.ok -eq 1) {
			$primaryUp = $statusObj.members | Where-Object { $_.name -eq "$NormalizedPrimaryHost`:$PrimaryPort" -and $_.stateStr -eq "PRIMARY" }
			$secondaryUp = $statusObj.members | Where-Object { $_.name -eq "$NormalizedPrimaryHost`:$SecondaryPort" -and $_.stateStr -eq "SECONDARY" }
			$arbiterUp = $statusObj.members | Where-Object { $_.name -eq "$NormalizedPrimaryHost`:$ArbiterPort" -and $_.stateStr -eq "ARBITER" }

			if ($primaryUp -and $secondaryUp -and $arbiterUp) {
				$stable = $true
				break
			}
		}

		Start-Sleep -Seconds 2
	}

	if (-not $stable) {
		throw "Replica set did not reach PRIMARY/SECONDARY/ARBITER state within timeout."
	}

Write-Log "Replica set state is correct: $PrimaryPort=PRIMARY, $SecondaryPort=SECONDARY, $ArbiterPort=ARBITER" "SUCCESS"
	Write-Log "Step 5 - Quick verification: rs.status().ok" "INFO"
	$okValue = Invoke-MongoShell -MongoShPath $mongoshPath -NodeHost $NormalizedPrimaryHost -Port $PrimaryPort -Eval "rs.status().ok"
	Write-Log "Verification result rs.status().ok = $okValue" "SUCCESS"
}
else {
	Write-Log "Step 2-5 skipped because mongosh is unavailable. mongod nodes can still be started and installed as services." "WARN"
}

if ($SkipServiceInstall) {
	Write-Log "Service installation skipped because -SkipServiceInstall was provided." "WARN"
	Write-Log "===== REPLICA SET SETUP COMPLETED =====" "SUCCESS"
	exit 0
}

Write-Log "Step 6 - Check Administrator privileges for service installation" "INFO"
if (-not (Get-IsAdministrator)) {
	throw "Please run PowerShell as Administrator to install/start services."
}

Write-Log "Step 7 - Stop temporary node processes before installing services" "INFO"
foreach ($port in $nodePorts) {
	if ($hasMongoShell) {
		Stop-TempNode -MongoShPath $mongoshPath -NodeHost $NormalizedPrimaryHost -Port $port
	}
	else {
		Stop-TempNodeProcessByConfig -ConfigPath $nodeConfigs[$port] -Port $port
	}
}

Start-Sleep -Seconds 3

Write-Log "Step 8 - Install services for all 3 nodes" "INFO"
Install-ServiceIfNeeded -MongodPath $mongodPath -ConfigPath $nodeConfigs[$PrimaryPort] -ServiceName "mongo-primary" -ServiceDisplayName "MongoDB Primary"
Install-ServiceIfNeeded -MongodPath $mongodPath -ConfigPath $nodeConfigs[$SecondaryPort] -ServiceName "mongo-secondary" -ServiceDisplayName "MongoDB Secondary"
Install-ServiceIfNeeded -MongodPath $mongodPath -ConfigPath $nodeConfigs[$ArbiterPort] -ServiceName "mongo-arbiter" -ServiceDisplayName "MongoDB Arbiter"

Write-Log "Step 9 - Start all 3 services" "INFO"
Start-ServiceSafe -ServiceName "mongo-primary"
Start-ServiceSafe -ServiceName "mongo-secondary"
Start-ServiceSafe -ServiceName "mongo-arbiter"

Write-Log "Step 10 - Verify replica set after starting services" "INFO"
if ($hasMongoShell) {
	if (-not (Wait-NodeReady -MongoShPath $mongoshPath -NodeHost $NormalizedPrimaryHost -Port $PrimaryPort -TimeoutSec $StartupTimeoutSec)) {
		throw "Primary is not ready after starting services."
	}

	$finalRaw = Invoke-MongoShell -MongoShPath $mongoshPath -NodeHost $NormalizedPrimaryHost -Port $PrimaryPort -Eval "try { print(EJSON.stringify(rs.status())); } catch(e) { print(EJSON.stringify({ ok: 0, errmsg: e.message })); }"
	$finalObj = $finalRaw | ConvertFrom-Json
	if ($finalObj.ok -ne 1) {
		throw "Final verification failed: $finalRaw"
	}
}
else {
	if (-not (Wait-PortReady -NodeHost $NormalizedPrimaryHost -Port $PrimaryPort -TimeoutSec $StartupTimeoutSec)) {
		throw "Primary TCP port is not ready after starting services."
	}
	Write-Log "Replica set status verification was skipped (mongosh unavailable)." "WARN"
}

Write-Log "Replica set and services were configured successfully." "SUCCESS"
Write-Log "===== FULL SETUP COMPLETED =====" "SUCCESS"
