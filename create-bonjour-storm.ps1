<# -----------------------------------------------------------
 DNS-SD (Bonjour) Stress Testing — Windows PowerShell
 Broadcast several different services at the same time, and
 see how the environment responds
 Requires: dns-sd.exe (Bonjour)
 ----------------------------------------------------------- #>

Set-StrictMode -Version Latest

# Only resolve dns-sd.exe once
$script:DnsSdExe = (Get-Command dns-sd.exe -ErrorAction Stop)

# Heavier TXT to inflate packet sizes
function New-TxtPayload {
    [CmdletBinding()]
    param (
        [ValidateRange(1,4096)][int]$bytes = 900
    )
    $pool = 48..57 + 65..90 + 97..122
    $blob = -join (1..$Bytes | ForEach-Object { [char]($pool | Get-Random) })
    return "blob=$blob"
}

function New-TxtForType {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string]$Type,    # e.g. _http._tcp
        [int]$BlobMinBytes = 50,
        [int]$BlobMaxBytes = 900,
        [int]$BlobPercent = 70                  # % of instances that also get a blob
    )

    # Base tokens by type (short & realistic)
    $kv = switch ($TYPE) {
        '_http._tcp'    { @('path=/', 'status=load') }
        '_ssh._tcp'     { @('os=Windows', 'user=demo') }
        '_ipp._tcp'     { @('rp=printers/q', 'ty="Load Printer"', 'note="lab"') }
        '_airplay._tcp' { 
            $id = -join ((0..5) | ForEach-Object { '{0:X2}' -f (Get-Random -Minimum 0 -Maximum 256) }) -replace '(.{2})(?=.)', '$1'
            @("model=AppleTV3,2", "srcvers=220.68", "deviceid=$id")
        }
        '_raop._tcp'    { @('am=AirPortExpress,1', 'cn=0,1', 'et=0,3,5,6', 'tp=UDP', 'vn=65537') }
        default         { @('status=loadtest') }
    }

    # Randomly add blob to vary total TXT size
    if ((Get-Random -Minimum 1 -Maximum 101) -le $BlobPercent) {
        $sz = Get-Random -Minimum $BlobMinBytes -Maximum $BlobMaxBytes
        $kv += (New-TxtPayload -Bytes $sz)
    }

    # Quote values that contain spaces
    ($kv | ForEach-Object {
        if ($_ -match '^(?<k>[^=]+)=(?<v>.*)$') {
            $k = $matches["k"]
            $v = $matches["v"]
            if ($v -match '[\s"]') {
                $v = '"' + ($v -replace '"', '\"') + '"'
            }
            "$k=$v"
        } else { $_ }
    }) -join ' '
}

# Validate and build cumulative weights
function New-WeightedServiceMix {
    param(
        [Parameter(Mandatory)][hashtable[]]$ServiceMix
    )
    $cumulative = 0
    $weighted = foreach ($cfg in $ServiceMix) {
        foreach ($req in 'Type', 'NameBase', 'Weight') {
            if (-not $cfg.ContainsKey($req)) {
                throw "ServiceMix missing '$req' key: $($cfg | Out-String)"
            }
        }
        if ($cfg.Type -notmatch '^_[A-Za-z0-9-]+\._(tcp|udp)$') {
             throw "Bad type: $($cfg.Type)" 
        }
        $w = [int]$cfg.Weight; if ($w -le 0) { 
            throw "Weight must be > 0 for $($cfg.Type)" 
        }
        $cumulative += $w
        [PSCustomObject]@{
            Cumulative = $cumulative
            Config = $cfg
        }
    }
    if ($cumulative -le 0) {
        throw "ServiceMix weights must be greater than 0"
    }
    [pscustomobject]@{
        Weighted = $weighted
        Total = $cumulative
    }
}

# Start with N ads of a given type at R per second. Returns process objects
function Start-DnsSdAds {
    [CmdletBinding()]
    param(
        [ValidateRange(1,100000)][int]$Count        = 100,
        [Parameter(Mandatory)][string]$Type         = '_http._tcp',
        [string]$Domain                             = 'local',
        [ValidateRange(1,10000)][int]$RatePerSec    = 10, # How fast to ramp
        [string]$NameBase                           = 'emu',
        [string]$txt                                = 'status=loadtest',
        [int]$PortMin                               = 10000,
        [int]$PortMax                               = 60000
    )

    $list = New-Object 'System.Collections.Generic.List[System.Diagnostics.Process]'
    $delayMs = if ($RatePerSec -gt 0) { [int](1000 / $RatePerSec) } else { 0 }

    for ($i = 1; $i -le $Count; $i++) {
        $name = "{0}-{1:00000}" -f $NameBase, $i
        $port = Get-Random -Minimum $PortMin -Maximum $PortMax
        $procArgs = @('-R', $name, $Type, $Domain, $port, $Txt)

        $p = Start-Process  -FilePath $script:DnsSdExe `
                            -ArgumentList $procArgs `
                            -WindowStyle Hidden -PassThru
        # $procs.Add($p) | Out-Null
        $null = $list.Add($p)
        if ($delayMs -gt 0) { Start-Sleep -Milliseconds $delayMs }
    }

    # Return an array for easy += or AddRange
    return $list.ToArray()
}

# Start 1 browser per type, return process objects
function Start-DnsSdBrowsers {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][string[]]$Types,
        [string]$Domain = 'local'
    )
    $procs = foreach ($t in $Types) {
        Start-Process   -FilePath $script:DnsSdExe `
                        -ArgumentList @('-B', $t, $Domain) `
                        -WindowStyle Hidden -PassThru
    }
    ,$procs # Force array
}

# Weighted, mixed type ad starter
function Start-DnsSdSoakAds {
    [CmdletBinding()]
    param (
        [ValidateRange(1,100000)][int]$TotalCount   = 1000,
        [ValidateRange(0,10000)][int]$RatePerSec    = 50,
        [string]$Domain = 'local',

        # Array of hashtables with Type, NameBase, Weight, optional Port scriptblock
        [Parameter(Mandatory)][hashtable[]]$ServiceMix,

        [int]$BlobMinBytes  = 50,
        [int]$BlobMaxBytes  = 900,
        [int]$BlobPercent   = 70
    )

    $exe = if ($script:DnsSdExe) { $script:DnsSdExe } else { (Get-Command dns-sd.exe -ErrorAction Stop).Source }
    $procs = New-Object 'System.Collections.Generic.List[System.Diagnostics.Process]'
    $delayMs = if ($RatePerSec -gt 0) { [int](1000 / $RatePerSec) } else { 0 }

    # Precompute weighted selection
    $weights = $ServiceMix | ForEach-Object { $_.Weight }
    $totalW = ($weights | Measure-Object -Sum).Sum
    if (-not $totalW) { throw "ServiceMix weights must be > 0" }

    # Per-type counters to make human-readable instance names
    $counters = @{}
    foreach ($cfg in $ServiceMix) { $counters[$cfg.Type] = 0 }

    for ($i = 1; $i -le $TotalCount; $i++) {
        # Pick a type by weight
        $pick = Get-Random -Minimum 1 -Maximum ($totalW + 1)
        $acc = 0
        $cfg = $null
        foreach ($c in $ServiceMix) {
            $acc += [int]$c.Weight
            if ($pick -le $acc) { $cfg = $c; break}
        }
        if (-not $cfg) { $cfg = $ServiceMix[-1] }

        $type = $cfg.Type 
        $counters[$type]++
        $seq = '{0:00000}' -f $counters[$type]

        # Instance name
        $name = '{0}-{1}' -f $cfg.NameBase, $seq
        # RAOP name convention is <id>@<name>, but technically not required
        if ($type -eq '_raop._tcp') {
            $id = -join ((1..12) | ForEach-Object { '{0:X}' -f (Get-Random -Minimum 0 -Maximum 16) })
            $name = '{0}@{1}-{2}' -f $id, $cfg.NameBase, $seq
        }

        # Port (allow a scriptblock per type, else random ephemeral)
        $port = if ($cfg.ContainsKey('Port') -and $cfg.Port -is [scriptblock]) { & $cfg.Port } else { Get-Random -Minimum 10000 -Maximum 60000 }

        # TXT record for this instance
        $txt = New-TxtForType -Type $type -BlobMinBytes $BlobMinBytes -BlobMaxBytes $BlobMaxBytes -BlobPercent $BlobPercent

        # Start the ad
        $dnsSdArgs = @('-R', $name, $type, $Domain, $Port, $txt)
        $p = Start-Process -FilePath $exe -ArgumentList $dnsSdArgs -WindowStyle Hidden -PassThru
        $null = $procs.Add($p)
        if ($i % 100 -eq 0) {
            Write-Verbose ("Started {0}/{1} ads (last: {2} {3} port {4})" -f $i,$TotalCount,$type,$name,$port)
        }
        if ($delayMs -gt 0) { Start-Sleep -Milliseconds $delayMs }
    }

    return $procs.ToArray()
}

function Add-DnsSdBatch {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][pscustomobject]$WeightedMix,      # from New-WeightedServiceMix
        [Parameter(Mandatory)][hashtable]$Counters,              # per-type name counters
        [Parameter(Mandatory)][hashtable[]]$ServiceMix,          # original mix (for Port blocks)
        [int]$Count = 100,
        [int]$RatePerSec = 20,
        [string]$Domain = 'local',
        [int]$BlobMinBytes = 50,
        [int]$BlobMaxBytes = 900,
        [int]$BlobPercent  = 70
    )
    $exe = if ($script:DnsSdExe) { $script:DnsSdExe } else { (Get-Command dns-sd.exe -ErrorAction Stop).Source }
    $list = New-Object 'System.Collections.Generic.List[System.Diagnostics.Process]'
    $delay = if ($RatePerSec -gt 0) { [int](1000 / $RatePerSec) } else { 0 }

    for ($i = 1; $i -le $Count; $i++) {
        # Pick a type by weight
        $pick = Get-Random -Minimum 1 -Maximum ($WeightedMix.Total + 1)
        $cfg = ($WeightedMix.Weighted | Where-Object { $_.Cumulative -ge $pick } | Select-Object -First 1).Config

        $type = $cfg.Type
        $Counters[$type] = 1 + ($Counters[$type] | ForEach-Object { $_ }) # Init/increment
        $seq = '{0:00000}' -f $Counters[$type]

        # Instance name (RAOP naming is convention but not necessary)
        $name = '{0}-{1}' -f $cfg.NameBase, $seq
        if ($type -eq '_raop._tcp') {
            $id = -join (1..12 | ForEach-Object { '{0:X}' -f (Get-Random -Minimum 0 -Maximum 16) })
            $name = '{0}@{1}-{2}' -f $id, $cfg.NameBase, $seq
        }

        # Port - Use per-type scriptblock if provided, else use random ephemeral
        $port = if ($cfg.ContainsKey('Port') -and $cfg.Port -is [scriptblock]) {
            & $cfg.Port 
        } else {
            Get-Random -Minimum 10000 -Maximum 60000
        }

        # TXT record for this instance - varies size/content
        $txt = New-TxtForType -Type $type -BlobMinBytes $BlobMinBytes -BlobMaxBytes $BlobMaxBytes -BlobPercent $BlobPercent

        # Launch 1 advertiser
        $procArgs = @('-R', $name, $type, $Domain, $port, $txt)
        $p = Start-Process -FilePath $exe -ArgumentList $procArgs -WindowStyle Hidden -PassThru
        $null = $list.Add($p)

        if ($delay) { Start-Sleep -Milliseconds $delay }
    }
    return $list.ToArray()
}

# Stops processes gracefully by closing windows and letting dns-sd send "goodbye" (TTL=0) naturally on Ctrl+C
# From script, Stop-Process may be abrupt (doesn't always send goodbye), but caches will eventually expire anyways
function Stop-DnsSdProcs {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline)]$Proc
    )

    process {
        if ($Proc -is [System.Diagnostics.Process] -and -not $Proc.HasExited) {
            try {
                Stop-Process -Id $Proc.Id -Force -ErrorAction Stop
            } catch { }
        }
    }
}

# Batched teardown (reduces goodbye storms)
function Stop-DnsSdProcsInBatches {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][System.Diagnostics.Process[]]$Procs,
        [ValidateRange(1,10000)][int]$BatchSize     = 50,
        [ValidateRange(1, 60000)][int]$IntervalMs   = 500,
        [ValidateRange(0, 5000)][int]$JitterMaxMs   = 150
    )
    # Prune any processes that have already exited
    $alive = @($Procs | Where-Object { $_ -is [System.Diagnostics.Process] -and -not $_.HasExited })
    for ($i = 0; $i -lt $alive.Count; $i += $BatchSize) {
        $end = [Math]::Min($i + $BatchSize - 1, $alive.Count - 1)
        for ($j = $i; $j -le $end; $j++) {
            try {
                Stop-Process -Id $alive[$j].Id -Force -ErrorAction Stop
            } catch { }
        }
        $sleep = $IntervalMs + (Get-Random -Minimum 0 -Maximum $JitterMaxMs)
        if ($sleep -gt 0) { 
            Start-Sleep -Milliseconds $sleep
        }
    }
}

$mix = @(
    @{ Type='_http._tcp';       NameBase='http-emu';    Weight=3; Port={ @(80,8080,     (Get-Random -Minimum 10000 -Maximum 60000)) | Get-Random } }
    @{ Type='_ssh._tcp';        NameBase='ssh-emu';     Weight=2; Port={ @(22,2222,     (Get-Random -Minimum 10000 -Maximum 60000)) | Get-Random } }
    @{ Type='_ipp._tcp';        NameBase='ipp-emu';     Weight=2; Port={ @(631,         (Get-Random -Minimum 10000 -Maximum 60000)) | Get-Random } }
    @{ Type='_airplay._tcp';    NameBase='airplay-emu'; Weight=1; Port={ @(7000,        (Get-Random -Minimum 10000 -Maximum 60000)) | Get-Random } }
    @{ Type='_raop._tcp';       NameBase='raop-emu';    Weight=1; Port={ @(5000,        (Get-Random -Minimum 10000 -Maximum 60000)) | Get-Random } }
)

# # Spin up a mixed load (e.g. 1200 total at 40/sec; 50-1000 byte blobs 70% of the time)
# $ads = Start-DnsSdSoakAds -TotalCount 750 -RatePerSec 40 -Domain 'local' `
#         -ServiceMix $mix -BlobMinBytes 50 -BlobMaxBytes 1000 -BlobPercent 70 -Verbose

# # Optional: Force replies by browsing a list of types (in hidden windows)
# # Makes the script more "Noisy" by forcing services to broadcast
# $br = Start-DnsSdBrowsers -Types ($mix.Type | Select-Object -Unique)

# # Various ways to run the test:

# # Fixed-duration test (simple soak test)

# try {
#     $testSeconds = 300 #5 minutes
#     Write-Host "Soaking for $testSeconds seconds with $($ads.Count) ads ..."
#     for ($t = 0; $t -lt $testSeconds; $t++) {
#         # Optional: Live status
#         $aliveAds = ($ads | Where-Object { $_ -and -not $_.HasExited }).Count
#         Write-Progress -Activity "DNS-SD load test" -Status "$aliveAds ads alive" -PercentComplete (($t/$testSeconds)*100)
#         Start-Sleep -Seconds 1
#     }
# } finally { # Finally block ensures cleanup, even on Ctrl+C
#     # Kill browsers first, quiet period, then batched ads
#     $br | Stop-DnsSdProcs
#     Start-Sleep -Seconds 2
#     Stop-DnsSdProcsInBatches -Procs $ads -BatchSize 50 -IntervalMs 500 -JitterMaxMs 150
# }

# # Step ramp inside window (add more ads every t seconds) - Good for finding breaking point

# Pre-compute Weighted selection and init per-type counters
$weightInfo = New-WeightedServiceMix -ServiceMix $mix
$counters = @{}
foreach ($cfg in $mix) {
    $counters[$cfg.Type] = 0
}

# Start Browsers to force replies
$br = Start-DnsSdBrowsers -Types ($mix.Type | Select-Object -Unique)

# Ramp parameters
$initial            = 0     # Start with some ads if wanted
$stepCount          = 100   # X more services with each step
$stepIntervalSec    = 15    # Y seconds between steps
$maxSteps           = 15    # How many times to ramp up
$ratePerSec         = 40    # Within each batch, how fast to add

# Keep track of all processes for cleanup
$ads = @()

try {
    if ($initial -gt 0) {
        $ads += Add-DnsSdBatch -WeightedMix $weightInfo -Counters $counters `
                            -ServiceMix $mix -Count $initial -RatePerSec $ratePerSec `
                            -BlobMinBytes 50 -BlobMaxBytes 1000 -BlobPercent 70
        Write-Host "Started initial $initial ads"
        Start-Sleep -Seconds $stepIntervalSec
    }

    for ($s = 1; $s -le $maxSteps; $s++) {
        $t0 = Get-Date
        $ads += Add-DnsSdBatch -WeightedMix $weightInfo -Counters $counters `
            -ServiceMix $mix -Count $stepCount -RatePerSec $ratePerSec `
            -BlobMinBytes 50 -BlobMaxBytes 1000 -BlobPercent 70

        $alive = ($ads | Where-Object { $_ -and -not $_.HasExited }).Count
        Write-Host ("Step {0}/{1}: +{2} (alive {3})" -f $s, $maxSteps, $stepCount, $alive)

        $elapsed = (Get-Date) - $t0
        $sleep = [math]::Max(0, $stepIntervalSec - [int]$elapsed.TotalSeconds)
        if ($s -lt $maxSteps -and $sleep -gt 0) { Start-Sleep -Seconds $sleep }
    }
} finally {
    # Browsers -> quiet -> batch stop
    $br | Stop-DnsSdProcs
    Start-Sleep -Seconds 2
    Stop-DnsSdProcsInBatches -Procs $ads -BatchSize 50 -IntervalMs 500 -JitterMaxMs 150
}

# # Churn/Flap during the window (remove and re-add a slice) - Good for testing stability under change
# $cycleSeconds = 20
# $churnCount = 50

# try {
#     while ($true) {
#         Start-Sleep -Seconds $cycleSeconds

#         # Kill a slice
#         $slice = @($ads | Where-Object { $_ -and -not $_.HasExited } | Select-Object -First $churnCount)
#         $slice | Stop-DnsSdProcs

#         # re-add the same amount
#         $ads.AddRange( (Start-DnsSdAds -Count $churnCount -Type '_ssh._tcp' -RatePerSec 50 -NameBase "ssh-churn" -Txt (New-TxtPayload 400)) )
#     }
# } finally {
#     $br | Stop-DnsSdProcs
#     Start-Sleep -Seconds 2
#     Stop-DnsSdProcsInBatches -Procs $ads.ToArray()
# }

