<# -----------------------------------------------------------
 DNS-SD discovery (Bonjour) — Windows PowerShell
 Enumerate all service types, browse instances, resolve Host/Port/TXT.
 Similar to unix 'avahi-browse -at'
 Requires: dns-sd.exe (Bonjour)
 ----------------------------------------------------------- #>

# Many dns-sd.exe commands (like dns-sd.exe -B) run forever in order to catch when devices announce/reannounce themselves
# To make this script-friendly, we use this wrapper to run the dns-sd.exe command with a timeout
function Invoke-DnsSdJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]] $ArgArray, # e.g. @('-B','_services._dns-sd._udp','local')
        [int] $Seconds = 5
    )

    # Resolve full path to dns-sd.exe for the child process
    $exe = (Get-Command dns-sd.exe -ErrorAction Stop).Source

    # Creates a background job that actually runs dns-sd.exe
    $job = Start-Job -ScriptBlock {
        param($exePath, $argsArray)
        # Run dns-sd.exe with proper argument array (string splitting/joining)
        & $exePath @argsArray
    } -ArgumentList $exe, $ArgArray

    # Wait up to $Seconds seconds (5 by default) then collect whatever has been output
    $null = Wait-Job -Id $job.Id -Timeout $Seconds
    $out = Receive-Job -Id $job.Id -Keep

    # If the job is still running, kill it cleanly
    if ((Get-Job -Id $job.Id).State -ne 'Completed') {
        Stop-Job -Id $job.Id
    }
    Remove-Job -Id $job.Id

    return $out
}

# Extract service types like "_http._tcp" from text
function Get-DnsSdTypes {
    param(
        [string]$Domain='local',
        [int]$Seconds=5
    )

    $out = Invoke-DnsSdJob -ArgArray @('-B', '_services._dns-sd._udp', $Domain)

    $types = $out |
        ForEach-Object {
        $line = $_
        # Find protocol in “Service Type” column and instance label at the end of the line
        if ($line -match '(?im)_(?<proto>tcp|udp)\.local\.\s+(?<inst>_[A-Za-z0-9-]+)\s*$') {
            "$($matches['inst'])._$($matches['proto'])"
        }
        } |
        Where-Object { $_ } |
        # Filter out browse helpers / non-browseable types
        Where-Object { $_ -notmatch '^_(services|dns-sd|mdns|sub)\._' } |
        Sort-Object -Unique
    
    # $types | ForEach-Object { Write-Host $_}
    return $types
}

# Extract instance names for a given type
function Get-DnsSdInstances {
    param(
        [string]$Type,
        [string]$Domain='local',
        [int]$Seconds=6
    )

    $out = Invoke-DnsSdJob -ArgArray @('-B', $Type, $Domain) -Seconds $Seconds
    # Write-Verbose "Browse Output for type '$Type' and domain $Domain"
    # $out | ForEach-Object {Write-Host $_ }
    
    # Sometimes entries will have "Rmv" in the A/R column, meaning Bonjour has told the browser that a previously 
    # seen service is no longer present (service times out, interface goes away, app/device deregisters w/ goodbye)
    # Because of this, we want to exclude devices that have been removed (as long as it isn't present on *any* interface)
    # So we track instance by last-seen state (inst|type|domain|ifIndex)
    $byKey = @{}
    # Regex should capture any line that has a tcp/udp protocol, and capture the add/remove state (ar), interface (if), 
    # domain (domain), service type (stype), protocol (proto), and instance name (inst) 
    foreach ($line in $out) {
        # Write-Verbose "Line was parsed by foreach loop:"
        # Write-Host $line
        if ($line -match '^\s*\d{1,2}:\d{2}:\d{2}\.\d{3}\s+(?<ar>Add|Rmv)\s+\d+\s+(?<if>\d+)\s+(?<domain>\S+)\s+(?<stype>_[A-Za-z0-9-]+)\._(?<proto>tcp|udp)\.\s+(?<inst>.+)$') {
            # Get each value we'll be using for the composite key
            $inst   = $matches['inst'].Trim()
            $stype  = $matches['stype']
            $proto  = $matches['proto']
            $domain = $matches['domain'].TrimEnd('.')
            $ifIdx  = [int]$matches['if']

            # Builds a composite string key
            $key = "$inst|$stype._$proto|$domain|$ifIdx"

            # If the value for the instance state is "Add", this adds "$true" at that key, and "$false" otherwise
            $byKey[$key] = ($matches['ar'] -eq 'Add')
        }
    }

    # Collapse across interfaces: keep instance if any interface is still "Add"
    $alive = @{}
    foreach ($k in $byKey.Keys) {
        $parts = $k -split '\|', 5
        $inst = $parts[0]
        # Builds grouping key ignoring interface (type|domain)
        # We'll aggregate all interfaces under this one grouping key so that "Any interface alive = keep"
        $typeDom = $parts[1] + '|' + $parts[2] 
        if ($byKey[$k]) { 
            $alive["$inst|$typeDom"] = $true
        } elseif (-not $alive.ContainsKey("$inst|$typeDom")) {
            $alive["$inst|$typeDom"] = $false
        }
    }

    $alive.GetEnumerator() |
    Where-Object { $_.Value } |
    ForEach-Object { ($_.Key -split '\|', 3)[0] } |
    Sort-Object -Unique
}

# Resolve one instance to Host/Port/TXT
function Resolve-DnsSdInstance {
    param (
        [string]$Instance,
        [string]$Type,
        [string]$Domain='local',
        [int]$Seconds=5
    )

    # Get the instance, and if it it doesn't return anything, return early
    $out = Invoke-DnsSdJob -ArgArray @('-L', $Instance, $Type, $Domain) -Seconds $Seconds
    if (-not $out) { return $null}
    
    $text = ($out -join [System.Environment]::NewLine)

    # Example line: "... can be reached at myhost.local.:1234"
    $instanceHostname = $null; $port = $null
    foreach ($line in $text) {
        if ($line -match 'can be reached at\s+(?<host>[^\s:]+)\.?:?(?<port>\d+)') {
            $instanceHostname = $matches['host'].TrimEnd('.')
            $port = [int]$matches['port']
            break
        }
    }

    # Find host IP by querying the instance for its A record
    $hostIp = Invoke-DnsSdJob -ArgArray @('-Q', $InstanceHostname, 'A') -Seconds $Seconds
    foreach ($line in $hostIp){
        if ($line -match '(Add|Rmv)\s+\d+\s+\d+\s+(?<hostname>\S+?)\.(?<domain>\S+?)\.\s+\d+\s+\d+\s(?<hostip>[\d\.]+)'){
            $hIp = $matches['hostip']
            break
        }
    }

    # Get TXT records (Can return multiple)
    $txtLines = @()
    foreach ($line in $out) {
        # Write-Host $line
        if ($line -match '^\s*TXT record:\s*(.+)$') {
            # Write-Verbose "Line Matched!"
            $txtLines += $matches[1]
            continue
        }
        # Windows will usually print TXT records as an indented list of tokens
        elseif ($line -match '^\s*(?:\S+=\S.*)(?:\s+\S+=\S.*)*\s*$') {
            $txtLines += $matches[0].Trim()
            continue
        }
    }

    $txtRaw = ($txtLines -join ' ').Trim()

    # Parse records into a key/value map (handles quoted values)
    $txtKv = @{}
    if ($txtRaw) {
        # Tokenizes on spaces but preserves quoted segments: "key=val with spaces"
        $tokenRx = '(?:"((?:[^"\\]|\\.)*)"|(\S+))'
        foreach ($m in [regex]::Matches($txtRaw, $tokenRx)) {
            $token = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
            if ($token -match '^(?<k>[^=]+)=(?<v>.*)$') {
                $txtKv[$matches['k']] = $matches['v']
            } else {
                #Boolean-style TXT string (Rare but allowed)
                $txtKv[$token] = $true
            }
        }
    }

    # Parse _adisk nested TXT (dkN= and sys=)
    $adisk = [PSCustomObject]@{
        System = @{}
        Disks = @()
    }

    # Parse system-wide options (sys=adVF=...,waMA=...)
    if ($txtKv.ContainsKey('sys')) {
        foreach ($p in ($txtKv['sys'] -split '\s*,\s*')) {
            if ($p -match '^(?<k>[^=]+)=(?<v>.*)$') {
                $adisk.System[$matches.k] = $matches.v
            }
        }
    }

    # Parse per-disk entries (dk0=adVN=...,adVF=0x82[,adVU=uuid])
    foreach ($kv in $txtKv.GetEnumerator()) {
        if ($kv.Key -match '^dk(?<idx>\d+)$') {
            $disk = @{ Index = [int]$matches.idx }
            foreach ($p in ($kv.Value -split '\s*,\s*')) {
                if ($p -match '^(?<k>[^=]+)=(?<v>.*)$') {
                    $disk[$matches.k] = $matches.v
                }
            }
            $adisk.Disks += [pscustomobject]$disk
        }
    }

    # Create a print-friendly flattened txt string out of the parsed txt records
    $txtDisplay = ($txtKv.GetEnumerator() | 
                    Sort-Object Key | 
                    ForEach-Object {
                        $k = $_.Key
                        $v = [string]$_.Value
                        # Quote strings that contain spaces or quotes
                        if ($v -match '[\s"]') {
                            $v = '"' + ($v -replace '"','\"') + '"'
                        }
                        "$k=$v"
                    }) -join ' '

    # Build a friendly volumes string and SystemFlags string (only for _adisk._tcp)
    $adiskVolumes = $null
    $adiskSysFlags = $null
    if ($Type -eq '_adisk._tcp' -and $adisk.Disks.Count -gt 0) {
        $adiskVolumes = ($adisk.Disks | ForEach-Object {
            $name = $_.adVN
            $flags = $_.adVF
            if ($name) {
                "{0} (flags {1})" -f $name, $flags
            } else {
                $null
            }
        } | Where-Object { $_ }) -join '; '
    }
    if ($Type -eq '_adisk._tcp' -and $adisk.System.ContainsKey('adVF')) {
        $adiskSysFlags = $adisk.System['adVF']
    }

    # Exit early if host, port, and txt are null
    if (-not $instanceHostname -and -not $port -and $txtKv.Count -eq 0) { return $null }

    # Creates a custom PS object that represents the instance
    [PSCustomObject]@{
        Type        = $Type
        Instance    = $Instance
        Domain      = $Domain
        Host        = $instanceHostname
        IP          = $hIp
        Port        = $port
        TXT         = $txtDisplay       # For tables/CSV
        TXTMap      = $txtKv            # For programmatic parsing
        #_adisk convenience, make sure all objects have these properties
        Volumes     = if ($Type -eq '_adisk._tcp' -and $adisk.Disks.Count) { $adiskVolumes } else { $null }
        TMFlags     = if ($Type -eq '_adisk._tcp' -and $adisk.System['adVF']) { $adiskSysFlags } else { $null }
    }
}

# Orchestrator - Discover everything
function Find-DnsSd {
    [CmdletBinding()]
    param(
        [string]$Domain='local',
        [int]$BrowseSeconds=5,      # Timeout for -B calls
        [int]$ResolveSeconds=3      # Timeout for -L calls
    )
    
    Write-Verbose "Enumerating service types in '$Domain'..."
    # Write-Output "Resolving Services, Instances, and Hostnames on domain $Domain"
    $types = Get-DnsSdTypes -Domain $Domain -Seconds $BrowseSeconds
    # Write-Verbose "Found Services:"
    # if ($types) { $types | ForEach-Object { Write-Host $_} }
    # else {Write-Host "types is empty!"}
    # $types #| ForEach-Object { Write-Output $_ }

    $all = New-Object System.Collections.Generic.List[object] 

    # For each service (type) we find, get the instances
    foreach ($t in $types) {
        Write-Verbose "Browsing $t ..."
        $instances = Get-DnsSdInstances -Type $t -Domain $Domain -Seconds $BrowseSeconds

        # Resolve each instance we find
        foreach ($inst in $instances) {
            Write-Verbose "Resolving '$inst' ($t)..."
            $rec = Resolve-DnsSdInstance -Instance $inst -Type $t -Domain $Domain -Seconds $ResolveSeconds
            if ($rec) { $all.Add($rec) }
        }
    }

    # Output all instances as a list of objects
    $all
}

# Get-DnsSdTypes -Seconds 10
# Get-DnsSdInstances -Type _airplay._tcp -Seconds 6 -Verbose
# Resolve-DnsSdInstance -Instance shellyplus2pm-10061cc9b44c -Type _shelly._tcp | Sort-Object Type, Instance | Format-Table -AutoSize

# Resolve-DnsSdInstance -Instance UNAS-Pro -Type _adisk._tcp | Format-Table -Wrap -AutoSize
# Resolve-DnsSdInstance -Instance UNAS-Pro -Type _adisk._tcp | # $results | 
#     Select-Object Type, Instance, Host, Port,
#                     @{N='TXT';E={$_.TXT}},
#                     @{N='Volumes';E={ if ($_.Type -eq '_adisk._tcp') { $_.Volumes } }},
#                     @{N='TMFlags';E={ if ($_.Type -eq '_adisk._tcp') { $_.TMFlags } }} |
#     Sort-Object Type, Instance |
#     Format-Table -Wrap -AutoSize

# Example usage

# # 1) Discover Everything (Default timeout)
$results = Find-DnsSd -ResolveSeconds 2 -Verbose

# # 2) View results in a table
$results | Format-Table -Property Type,Instance,Host,Port,Volumes,TMFlags,TXT -Wrap -AutoSize

# 3) Save to CSV
# $results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path ".\dns-sd-inventory.csv"