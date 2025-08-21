
function Get-ExplodedRRs {
    [CmdletBinding()]
    param (
        # Get capturefile as argument
        [Parameter(Mandatory)][string]$CapFile
    )

    if (-not (Test-Path $CapFile)) { throw "Capture file not found: $CapFile" }
    if (-not (Get-Command tshark -ErrorAction SilentlyContinue)) { throw "tshark not found in PATH." }

    $typeMap = @{   1='A'; 2='NS'; 5='CNAME'; 6='SOA'; 
                    12='PTR'; 15='MX'; 16='TXT'; 28='AAAA'; 
                    33='SRV'; 41='OPT'; 47='NSEC'; 255='ANY' 
                }

    # Unit separator, unlikely to appear in any names
    $agg = [char]31

    tshark -r "$CapFile" -Y "udp.port==5353 && dns.flags.response==1" `
        -T fields -E header=n -E separator=`t -E occurrence=a -E ("aggregator=$agg") `
        -e frame.number -e dns.resp.name -e dns.resp.type -e dns.resp.ttl |
    Where-Object { $_ -and $_.Trim() } |
    ForEach-Object {
    $f=$_ -split "`t"
    if ($f.Count -lt 4) { return }

    $names = $f[1] -split [regex]::Escape("$agg")
    $types = $f[2] -split [regex]::Escape("$agg")
    $ttls =  $f[3] -split [regex]::Escape("$agg")

    $frame = 0; [void][int]::TryParse($f[0], [ref]$frame)
    $n = [Math]::Min($names.Count, [Math]::Min($types.Count, $ttls.Count))

    for($i=0; $i -lt $n; $i++) {
        $code=$null; [void][int]::TryParse($f[0], [ref]$frame)
        $typeName = if ( $null -ne $code -and $typeMap.ContainsKey($code)) { $typeMap[$code] } else { $types[$i] }

        $ttl = $null; [void][int]::TryParse($ttls[$i], [ref]$ttl)

        [pscustomobject]@{ 
            Frame = $frame
            Type = $typeName
            TTL = $ttl
            Name = $names[$i]
        }
    }
    } | Sort-Object Frame | Format-Table Frame,Type,TTL,Name -Wrap
}