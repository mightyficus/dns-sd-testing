# mDNS Discovery and Packet Generation Windows with dns-sd.exe

## mDNS Discovery - discover-dns-sd.ps1
This script uses dns-sd to discover all services and service instances discoverable on all network interfaces of the Windows computer running the script. It does so with the following functions:
1. `Invoke-DnsSdJob`
    * Takes an array of dns-sd arguments (For example: `@('-B', '_services._dns-sd._udp', $Domain)`), a dns-sd Domain, and a timeout period (seconds)
    * Returns any raw output the dns-sd command generated before it exited
    * Many dns-sd commands on Windows do not exit automatically
    * We create a dns-sd process using provided arguments, wait, kill the process, and collect the results
    We will assume going forward that the provided domain is `local`
2. `Get-DnsSdTypes`
    * Takes a dns-sd Domain and a timeout period (seconds)
    * Returns a list of found services
    * Invokes `dns-sd.exe -B _services._dns-sd._udp local`
    * Extracts the service types in the form `<_service._protocol>` using regex
3. `Get-DnsSdInstances`
    * Takes a service type, mDNS Domain, and timeout period (seconds)
    * Returns a list of active instances broadcasting that service
    * Some instances can return with a 'Rmv' flag, meaning they've sent a "goodbye"
    * We filter these out as long as they aren't present on _any_ interface
4. `Resolve-DnsSdInstance`
    * Takes one instance, a service type, an mDNS domain, and a timeout period (seconds)
    * Returns a custom object containing the service type, instance name, instance hostname, instance IP address, port service is running on, any TXT records (both as a string and a dictionary), and if it's a file share (type '_adisk._tcp'), its volumes and system flags
    * First it gets the raw output from the `dns-sd.exe -L <instance> <serviceType> <domain>` command, which looks up (resolves) a service instance
    * Next it puts that output through a filter to retrieve the port the service is running on
    * Next it resolves the instance's IP address using a dns-sd query for the instance's A record (`dns-sd.exe -Q <instanceHostname> A`)
    * Then it extracts and formats the TXT records in a way that can be printed (string) and a way in which it can be iterated (hash table)
        * This requires several steps, mostly because some records (namely _adisk._tcp) returns TXT records with nested information
    * Finally it creates and returns a custom object containing all of this information
5. `Find-DnsSd`
    * Acts as an orchestrator script for finding and resolving all mDNS instances on a network
    * Takes an mDNS domain and a timeout period (seconds) for both browsing and resolution/query commands
    * Returns a list of instance objects
    * It does this by first finding all service types with `Get-DnsSdTypes`
    * Next it loops over each service type returned, and for each service type, it retreives all instances for that type with `Get-DnsSdInstances`
    * Then it iterates over each of those instances, resolves it, and retrieves pertinent information as an object with `Resolve-DnsSdInstance` and puts that object into a list
    * It returns the list of the resolved information for each instance

Each of these functions can be used independantly, but with the orchestrator function it essentially returns all of the information that the linux command `avahi-browse -at` would. With the list of objects that the orchestrator returns, the instance information can be displayed as an easy-to-read table, exported as a csv/json file, or manipulated further to pass information into some other command chain.

## mDNS Service emulation and multicast stress testing - create-bonjour-storm.ps1
This script uses dns-sd to emulate, broadcast, and browse mDNS objects in order to ultimately stress test networks using multicast traffic. It can create instances of any service, create text records for that instance of variable size (populated with junk data), and create instance browsers that essentially force mDNS instances to announce themselves, all at a controlled rate. This should probably only be used on a machine with high processing power and a high-throughput NIC, because each service instance and browser requires a separate process, and each service instance and browser will be sending/receiving traffic. If this isn't enough, we can create a Python script with the zeroconf library to register services programatically in-process (cheaper than current script's one process per advertisement)

### Potential failure points this script tests:
* AP/Controller multicast traffic handling (multicast-unicast conversion, rate limiting)
* Switch CPU/IGMP Snooping paths
* mDNS gateway functionality
* Client cache pressure and query latency when there are thousands of PTR/SRV/TXT/A records
* WiFi airtime burn from frequent mDNS packet bursts

### Variables we can manipulate
* Count/Rate: Number of services generated and how quickly they're generated
* Types vs instances: large number of service types with only a few instances or only a few types with a lot of instances
* TXT Size: 50-1200 bytes (near the max safe mDNS payload size). Larger TXT -> larger UDP packets -> possible fragmentation on WiFi -> worse airtime/resource strain
* Query pressure: Number of broswers in parallel
* Churn: Periodically kill and restart some of the ads to generate goodbye + new announce storms
* Interfaces: advertise on aired and WiFi simultaneously, AP/controller may behave differently per SSID/VLAN

### What we can measure
* Packets/sec on udp/5353 and %airtime on WLAN
* Discovery latency (time from start to first "Add" seen by a broswer)
* Drop Rate/missed announcements
* Gateway/snooper CPU and memory (especially if using a mDNS gateway across VLANs)
* Switch/AP logs for multicast throttling or buffer exhaustion

### Caveats
* mDNS is link-local: to test cross-subnet use, involve the mDNS gateway feature or run proxy ads (-P) on both sides and browse from each side
* Killing thousands of ads at once can create a goodbye broadcast storm, or if forcibly terminated, slow cleanup by TTL expiry - plan cleanup carefully
* Bonjour may coalesce answers and apply known-answer supression. Good equipment should handle this, but be aware that the traffic isn't "one packet per record"