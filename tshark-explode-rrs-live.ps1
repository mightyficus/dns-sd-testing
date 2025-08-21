# # Capture mDNS answers and print one RR per line with Name/Type/TTL
# tshark -i Wi-Fi -Y "udp.port==5353 && dns.flags.response==1" `
#   -T fields -E header=y -E separator=`t -E occurrence=a `
#   -e frame.number -e ip.src -e ipv6.src -e dns.resp.name -e dns.resp.type -e dns.resp.ttl |
#   ForEach-Object {
#     $f = $_ -split "`t"
#     $names = ($f[3] -split ",")
#     $types = ($f[4] -split ",")
#     $ttls  = ($f[5] -split ",")
#     for ($i=0; $i -lt $names.Count; $i++) {
#       [pscustomobject]@{
#         Frame = $f[0]
#         Src   = if ($f[1]) { $f[1] } else { $f[2] }  # v4 or v6
#         Name  = $names[$i]
#         Type  = $types[$i]
#         TTL   = $ttls[$i]
#       }
#     }
#   } | Format-Table -AutoSize

# tshark -i Wi-Fi -l -Y "udp.port==5353 && dns.flags.response==1" `
#   -T fields -E header=y -E separator=`t -E occurrence=a `
#   -e frame.number -e dns.resp.name -e dns.resp.type -e dns.resp.ttl |
# ForEach-Object {
#   $f = $_ -split "`t"
#   $names = $f[1] -split ","
#   $types = $f[2] -split ","
#   $ttls  = $f[3] -split ","
#   for ($i=0; $i -lt $names.Count; $i++) {
#     [pscustomobject]@{
#       Frame = [int]$f[0]
#       Name  = $names[$i]
#       Type  = [int]$types[$i]
#       TTL   = [int]$ttls[$i]
#     }
#   }
# } | Format-Table Frame,Type,TTL,Name -Wrap   # <-- no -AutoSize, streams row-by-row

# Map DNS type codes to names
$typeMap = @{
  1='A'; 2='NS'; 5='CNAME'; 6='SOA'; 12='PTR'; 15='MX'; 16='TXT'; 28='AAAA';
  33='SRV'; 41='OPT'; 43='DS'; 46='RRSIG'; 47='NSEC'; 48='DNSKEY'; 255='ANY'
}

tshark -i Wi-Fi -l -Y "udp.port==5353 && dns.flags.response==1" `
  -T fields -E header=y -E separator=`t -E occurrence=a -E header=n `
  -e frame.number -e dns.resp.name -e dns.resp.type -e dns.resp.ttl -a "duration:60" |
ForEach-Object {
  $f = $_ -split "`t"
  $names = $f[1] -split ","
  $types = $f[2] -split ","
  $ttls  = $f[3] -split ","
  for ($i=0; $i -lt $names.Count; $i++) {
    $code = [int]$types[$i]
    $t    = if ($typeMap.ContainsKey($code)) { $typeMap[$code] } else { $code.ToString() }
    [pscustomobject]@{
      Frame = [int]$f[0]
      Type  = $t
      TTL   = [int]$ttls[$i]
      Name  = $names[$i]
    }
  }
} | Format-Table -AutoSize -Wrap