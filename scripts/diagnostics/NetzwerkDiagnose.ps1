<#
.SYNOPSIS
    Creates a readable Windows network diagnostics HTML report.

.DESCRIPTION
    Network diagnostic tool for Windows clients and servers.
    It makes no assumptions about private IP ranges, router vendors, subnet sizes, NAS vendors,
    domains, or gateway addresses. Local infrastructure targets are detected from Windows where
    possible or provided by parameter.

    The script is diagnostic only:
    - no adapter changes
    - no firewall changes
    - no registry changes
    - no ipconfig /release or /renew
    - no automatic repairs

.PARAMETER OutputPath
    Output folder. Default: C:\Temp\NetzwerkDiagnose

.PARAMETER LocalTargets
    Optional local targets such as NAS, server, printer, or custom hostnames.

.PARAMETER TcpTargets
    Optional TCP targets in host:port format, for example nas:445.

.PARAMETER DnsTestNames
    Optional DNS names to resolve. Defaults are google.de, microsoft.com, dns.msftncsi.com.

.PARAMETER LanSpeedTarget
    Optional iperf3 server host/IP. iperf3.exe is used only if available.

.PARAMETER SmbTestPath
    Optional UNC path, for example \\nas\share.

.PARAMETER SmbTestSizeMB
    SMB read/write test size. Default: 256 MB.

.PARAMETER PingCount
    Ping count per target. Default: 10.

.PARAMETER EventHours
    Event log lookback in hours when IncludeEventLogs is used. Default: 24.

.PARAMETER IncludeEventLogs
    Include relevant network event logs.

.PARAMETER IncludeRawData
    Include raw text sections and write a JSON raw data file.

.PARAMETER IncludeTraceroute
    Include traceroute tests.

.PARAMETER IncludeMtuTest
    Include IPv4 MTU probing.

.PARAMETER IncludeSpeedtest
    Include internet speed test when speedtest.exe is available, otherwise a small HTTP download probe.

.PARAMETER IncludeSubnetDiscovery
    Include cautious ping/ARP discovery for the primary directly connected subnet. Skips large subnets.

.PARAMETER NoInternetTest
    Disable public internet tests.

.PARAMETER NoWriteTests
    Disable SMB write/read throughput tests.

.PARAMETER OpenReport
    Open the generated HTML report at the end.

.EXAMPLE
    .\NetzwerkDiagnose.ps1 -OpenReport

.EXAMPLE
    .\NetzwerkDiagnose.ps1 `
      -LocalTargets "nas","server","drucker" `
      -TcpTargets "nas:445","server:3389","drucker:9100" `
      -DnsTestNames "google.de","microsoft.com","nas" `
      -IncludeEventLogs `
      -IncludeTraceroute `
      -OpenReport

.EXAMPLE
    .\NetzwerkDiagnose.ps1 `
      -SmbTestPath "\\nas\freigabe" `
      -SmbTestSizeMB 256 `
      -OpenReport

.EXAMPLE
    .\NetzwerkDiagnose.ps1 `
      -LanSpeedTarget "iperf-server" `
      -OpenReport

.EXAMPLE
    .\NetzwerkDiagnose.ps1 `
      -LocalTargets "nas","server","drucker" `
      -TcpTargets "nas:445","server:3389","drucker:9100","microsoft.com:443" `
      -DnsTestNames "google.de","microsoft.com","nas" `
      -LanSpeedTarget "iperf-server" `
      -SmbTestPath "\\nas\freigabe" `
      -IncludeEventLogs `
      -IncludeTraceroute `
      -IncludeMtuTest `
      -IncludeRawData `
      -OpenReport
#>

[CmdletBinding()]
param(
    [string]$OutputPath = "C:\Temp\NetzwerkDiagnose",
    [string[]]$LocalTargets = @(),
    [string[]]$TcpTargets = @(),
    [string[]]$DnsTestNames = @("google.de", "microsoft.com", "dns.msftncsi.com"),
    [string]$LanSpeedTarget = "",
    [string]$SmbTestPath = "",
    [int]$SmbTestSizeMB = 256,
    [int]$PingCount = 10,
    [int]$EventHours = 24,
    [switch]$IncludeEventLogs,
    [switch]$IncludeRawData,
    [switch]$IncludeTraceroute,
    [switch]$IncludeMtuTest,
    [switch]$IncludeSpeedtest,
    [switch]$IncludeSubnetDiscovery,
    [switch]$NoInternetTest,
    [switch]$NoWriteTests,
    [switch]$OpenReport
)

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
$ToolName = "NetzwerkDiagnose"
$ToolVersion = "1.0"
$Started = Get-Date
$ComputerSafe = ($env:COMPUTERNAME -replace '[\\/:*?"<>| ]', '_')
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$HtmlPath = Join-Path $OutputPath ("NetzwerkDiagnose_{0}_{1}.html" -f $ComputerSafe, $Timestamp)
$JsonPath = Join-Path $OutputPath ("NetzwerkDiagnose_{0}_{1}_RawData.json" -f $ComputerSafe, $Timestamp)

$script:Results = New-Object System.Collections.Generic.List[object]
$script:RawData = [ordered]@{}
$script:Sections = [ordered]@{}

function Get-ResultRows {
    if ($null -eq $script:Results) { return @() }
    return @($script:Results.ToArray())
}

function Write-Step {
    param([string]$Text)
    Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Text) -ForegroundColor Cyan
}

function Test-IsAdmin {
    try {
        $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Escape-Html {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return "" }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Add-Result {
    param(
        [string]$Category,
        [string]$Test,
        [string]$Role = "",
        [string]$Target = "",
        [string]$InterfaceAlias = "",
        [string]$Result = "",
        [ValidateSet("OK","Warning","Error","Info")][string]$Severity = "Info",
        [string]$Value = "",
        [string]$Details = "",
        [string]$Recommendation = ""
    )

    [void]$script:Results.Add([PSCustomObject]@{
        Category       = $Category
        Test           = $Test
        Role           = $Role
        Target         = $Target
        InterfaceAlias = $InterfaceAlias
        Result         = $Result
        Severity       = $Severity
        Value          = $Value
        Details        = $Details
        Recommendation = $Recommendation
    })
}

function Invoke-Capture {
    param(
        [string]$Name,
        [scriptblock]$ScriptBlock,
        $Default = @()
    )

    try {
        return & $ScriptBlock
    } catch {
        Add-Result -Category "Collection" -Test $Name -Severity "Info" -Result "Skipped" -Details $_.Exception.Message -Recommendation "This section can be skipped when the cmdlet, permission, or provider is unavailable."
        return $Default
    }
}

function ConvertTo-Number {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim() -replace ',', '.'
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $number = 0.0
    if ([double]::TryParse($text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return $number
    }
    return $null
}

function Convert-LinkSpeedToMbps {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $text = $Value.Trim()
    $num = ConvertTo-Number (($text -replace '[^\d\.,]', ''))
    if ($null -eq $num) { return $null }
    if ($text -match '(?i)Gbps|Gbit|G\s*bit') { return [double]($num * 1000) }
    if ($text -match '(?i)Mbps|Mbit|M\s*bit') { return [double]$num }
    if ($text -match '(?i)Kbps|Kbit') { return [double]($num / 1000) }
    return [double]$num
}

function Get-FirstProperty {
    param([object]$Object, [string[]]$Names)
    foreach ($name in $Names) {
        if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $name) {
            return $Object.$name
        }
    }
    return $null
}

function New-ResultTable {
    param([object[]]$Rows, [string[]]$Columns)

    $items = @($Rows)
    if ($items.Count -eq 0) {
        return '<div class="empty">No data collected.</div>'
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('<div class="table-wrap"><table>')
    [void]$sb.AppendLine('<thead><tr>')
    foreach ($col in $Columns) {
        [void]$sb.AppendLine(("<th>{0}</th>" -f (Escape-Html $col)))
    }
    [void]$sb.AppendLine('</tr></thead><tbody>')

    foreach ($row in $items) {
        [void]$sb.AppendLine('<tr>')
        foreach ($col in $Columns) {
            $value = ""
            if ($row.PSObject.Properties.Name -contains $col) {
                $value = [string]$row.$col
            }
            if ($col -eq "Severity") {
                $class = ("sev-" + $value.ToLowerInvariant())
                [void]$sb.AppendLine(("<td><span class=""badge {0}"">{1}</span></td>" -f $class, (Escape-Html $value)))
            } else {
                [void]$sb.AppendLine(("<td>{0}</td>" -f (Escape-Html $value)))
            }
        }
        [void]$sb.AppendLine('</tr>')
    }

    [void]$sb.AppendLine('</tbody></table></div>')
    return $sb.ToString()
}

function Add-Target {
    param(
        [ref]$Targets,
        [string]$Role,
        [string]$Target,
        [string]$InterfaceAlias = "",
        [string]$Source = "AutoDetected",
        [bool]$TestPing = $true,
        [bool]$TestDns = $false,
        [int[]]$TcpPorts = @(),
        [string]$TargetType = "Local"
    )

    if ([string]::IsNullOrWhiteSpace($Target)) { return }
    $key = "{0}|{1}|{2}|{3}" -f $Role, $Target, $InterfaceAlias, ($TcpPorts -join ",")
    if ($Targets.Value.Keys -contains $key) { return }

    $Targets.Value[$key] = [PSCustomObject]@{
        Role           = $Role
        Target         = $Target
        InterfaceAlias = $InterfaceAlias
        Source         = $Source
        TestPing       = [bool]$TestPing
        TestDns        = [bool]$TestDns
        TcpPorts       = @($TcpPorts)
        TargetType     = $TargetType
    }
}

function Resolve-TargetAddress {
    param([string]$Target)
    if ([string]::IsNullOrWhiteSpace($Target)) { return "" }
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($Target, [ref]$ip)) { return $Target }

    try {
        $entry = [System.Net.Dns]::GetHostEntry($Target)
        $addr = @($entry.AddressList | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | Select-Object -First 1)
        if ($addr.Count -gt 0) { return [string]$addr[0].IPAddressToString }
    } catch {}
    return ""
}

function Test-PingTarget {
    param(
        [object]$TargetRow,
        [int]$Count
    )

    $target = [string]$TargetRow.Target
    $role = [string]$TargetRow.Role
    $type = [string]$TargetRow.TargetType
    $resolved = Resolve-TargetAddress -Target $target
    $times = @()
    $success = 0

    $ping = $null
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        for ($i = 0; $i -lt $Count; $i++) {
            try {
                $reply = $ping.Send($target, 1200)
                if ($reply -and $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $times += [double]$reply.RoundtripTime
                    $success++
                }
            } catch {}
        }
    } catch {
    } finally {
        if ($ping) { $ping.Dispose() }
    }

    $sent = [Math]::Max(1, $Count)
    $loss = [math]::Round((($sent - $success) / $sent) * 100, 2)
    $min = if ($times.Count -gt 0) { [math]::Round((($times | Measure-Object -Minimum).Minimum), 2) } else { "" }
    $max = if ($times.Count -gt 0) { [math]::Round((($times | Measure-Object -Maximum).Maximum), 2) } else { "" }
    $avg = if ($times.Count -gt 0) { [math]::Round((($times | Measure-Object -Average).Average), 2) } else { "" }
    $jitter = if ($times.Count -gt 0) { [math]::Round(([double]$max - [double]$min), 2) } else { "" }

    $severity = "OK"
    $result = "Reachable"
    $recommendation = "No action required."

    if ($success -eq 0) {
        $severity = "Error"
        $result = "Not reachable"
        $recommendation = "Check cabling, Wi-Fi, gateway, route, firewall, DNS, or whether the target is online."
    } elseif ($loss -gt 0 -and $type -eq "Local") {
        $severity = "Error"
        $result = "Packet loss"
        $recommendation = "Packet loss inside the local network usually points to Wi-Fi quality, cabling, switch port, adapter, driver, or target availability."
    } elseif ($loss -gt 2) {
        $severity = "Warning"
        $result = "Packet loss"
        $recommendation = "Packet loss to internet targets can be ISP, routing, Wi-Fi, or local gateway related. Compare with gateway ping."
    } elseif ($role -match 'Gateway' -and $TargetRow.InterfaceAlias -match 'Wi-Fi|WLAN|Wireless') {
        if ($avg -ne "" -and [double]$avg -gt 20) {
            $severity = "Warning"
            $result = "High gateway latency"
            $recommendation = "Gateway latency is high for Wi-Fi. Check signal, channel, interference, and roaming."
        }
    } elseif ($role -match 'Gateway') {
        if ($avg -ne "" -and [double]$avg -gt 5) {
            $severity = "Warning"
            $result = "High gateway latency"
            $recommendation = "Gateway latency is high for wired LAN. Check cable, switch port, duplex/autonegotiation, and adapter driver."
        }
    } elseif ($type -eq "Internet") {
        if ($avg -ne "" -and [double]$avg -gt 100) {
            $severity = "Warning"
            $result = "High internet latency"
            $recommendation = "High latency to public targets can be ISP, routing, VPN, Wi-Fi, or gateway related."
        }
    }

    if ($jitter -ne "" -and [double]$jitter -gt 50 -and $severity -eq "OK") {
        $severity = "Warning"
        $result = "High jitter"
        $recommendation = "High jitter can affect gaming, voice, video calls, RDP, and streaming. Compare local gateway and internet targets."
    }

    $row = [PSCustomObject]@{
        Role = $role
        Target = $target
        ResolvedAddress = $resolved
        InterfaceAlias = [string]$TargetRow.InterfaceAlias
        Sent = $sent
        Successful = $success
        LossPercent = $loss
        MinMs = $min
        AvgMs = $avg
        MaxMs = $max
        JitterMs = $jitter
        Severity = $severity
        Result = $result
        Recommendation = $recommendation
    }

    Add-Result -Category "Ping" -Test "Ping target" -Role $role -Target $target -InterfaceAlias ([string]$TargetRow.InterfaceAlias) -Severity $severity -Result $result -Value ("loss={0}%, avg={1} ms, jitter={2} ms" -f $loss, $avg, $jitter) -Details ("Resolved address: {0}" -f $resolved) -Recommendation $recommendation
    return $row
}

function Test-TcpTarget {
    param([string]$HostName, [int]$Port, [string]$Role = "", [string]$InterfaceAlias = "")

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $success = $false
    $errorText = ""
    $remoteAddress = Resolve-TargetAddress -Target $HostName
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        $success = $iar.AsyncWaitHandle.WaitOne(3000, $false)
        if ($success) {
            $client.EndConnect($iar)
        } else {
            $errorText = "Timeout"
        }
        $client.Close()
    } catch {
        $errorText = $_.Exception.Message
        $success = $false
    }
    $sw.Stop()

    $severity = if ($success) { "OK" } else { "Warning" }
    $result = if ($success) { "Reachable" } else { "Not reachable" }
    $recommendation = if ($success) { "No action required." } else { "Check target, service, firewall, routing, and DNS. For local services, compare with ping result." }
    if (-not $success -and $Role -match 'Domain Controller|DNS|Custom|SMB|RDP|WinRM') { $severity = "Error" }

    $row = [PSCustomObject]@{
        Role = $Role
        Host = $HostName
        Port = $Port
        TcpTestSucceeded = $success
        RemoteAddress = $remoteAddress
        InterfaceAlias = $InterfaceAlias
        LatencyMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
        Severity = $severity
        Result = $result
        Details = $errorText
        Recommendation = $recommendation
    }
    Add-Result -Category "TCP" -Test "TCP port" -Role $Role -Target ("{0}:{1}" -f $HostName, $Port) -InterfaceAlias $InterfaceAlias -Severity $severity -Result $result -Value ("{0} ms" -f $row.LatencyMs) -Details $errorText -Recommendation $recommendation
    return $row
}

function Test-DnsResolution {
    param([string]$Name, [string]$Server = "", [string]$Role = "Default DNS")

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $addresses = @()
    $errorText = ""
    try {
        if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
            if ([string]::IsNullOrWhiteSpace($Server)) {
                $answers = @(Resolve-DnsName -Name $Name -ErrorAction Stop)
            } else {
                $answers = @(Resolve-DnsName -Name $Name -Server $Server -ErrorAction Stop)
            }
            $addresses = @($answers | Where-Object { $_.IPAddress } | ForEach-Object { [string]$_.IPAddress } | Sort-Object -Unique)
        } else {
            $entry = [Net.Dns]::GetHostEntry($Name)
            $addresses = @($entry.AddressList | ForEach-Object { [string]$_.IPAddressToString })
        }
    } catch {
        $errorText = $_.Exception.Message
    }
    $sw.Stop()

    $severity = "OK"
    $result = "Resolved"
    $recommendation = "No action required."
    if ($addresses.Count -eq 0) {
        $severity = "Error"
        $result = "Failed"
        $recommendation = "Check DNS server reachability, DNS client service, interface DNS configuration, VPN/DNS filtering, and local hosts file."
    } elseif ($sw.Elapsed.TotalMilliseconds -gt 1000) {
        $severity = "Warning"
        $result = "Slow DNS"
        $recommendation = "DNS answer time is high. Compare default DNS with interface DNS servers and public comparison DNS."
    }

    $row = [PSCustomObject]@{
        Name = $Name
        Server = $Server
        Role = $Role
        Addresses = ($addresses -join ", ")
        DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
        Severity = $severity
        Result = $result
        Error = $errorText
        Recommendation = $recommendation
    }
    Add-Result -Category "DNS" -Test "DNS resolution" -Role $Role -Target $Name -Severity $severity -Result $result -Value ("{0} ms; {1}" -f $row.DurationMs, $row.Addresses) -Details $errorText -Recommendation $recommendation
    return $row
}

function Get-SystemInfoRows {
    $os = Invoke-Capture "Operating system" { Get-CimInstance Win32_OperatingSystem } $null
    $cs = Invoke-Capture "Computer system" { Get-CimInstance Win32_ComputerSystem } $null
    $uptime = ""
    if ($os -and $os.LastBootUpTime) {
        $uptime = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 2)
    }
    return @([PSCustomObject]@{
        ComputerName = $env:COMPUTERNAME
        UserName = $env:USERNAME
        DomainOrWorkgroup = if ($cs) { $cs.Domain } else { "" }
        PartOfDomain = if ($cs) { $cs.PartOfDomain } else { "" }
        Windows = if ($os) { $os.Caption } else { "" }
        BuildNumber = if ($os) { $os.BuildNumber } else { "" }
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        UptimeDays = $uptime
        DateTime = Get-Date
        TimeZone = ([TimeZoneInfo]::Local.DisplayName)
        IsAdmin = Test-IsAdmin
    })
}

function Get-NetworkAdapterRows {
    $adapters = @(Invoke-Capture "Get-NetAdapter" { Get-NetAdapter -ErrorAction Stop } @())
    $ipConfigs = @(Invoke-Capture "Get-NetIPConfiguration" { Get-NetIPConfiguration -ErrorAction Stop } @())
    $ipInterfaces = @(Invoke-Capture "Get-NetIPInterface" { Get-NetIPInterface -AddressFamily IPv4 -ErrorAction Stop } @())
    $dnsServers = @(Invoke-Capture "Get-DnsClientServerAddress" { Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop } @())
    $profiles = @(Invoke-Capture "Get-NetConnectionProfile" { Get-NetConnectionProfile -ErrorAction Stop } @())
    $dhcpConfigs = @(Invoke-Capture "Win32_NetworkAdapterConfiguration" { Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction Stop } @())

    $rows = @()
    foreach ($adapter in $adapters) {
        $alias = [string]$adapter.Name
        $ipconfig = @($ipConfigs | Where-Object { [string]$_.InterfaceAlias -eq $alias } | Select-Object -First 1)
        $ipInterface = @($ipInterfaces | Where-Object { [string]$_.InterfaceAlias -eq $alias } | Sort-Object InterfaceMetric | Select-Object -First 1)
        $dns = @($dnsServers | Where-Object { [string]$_.InterfaceAlias -eq $alias } | Select-Object -First 1)
        $profile = @($profiles | Where-Object { [string]$_.InterfaceAlias -eq $alias } | Select-Object -First 1)
        $dhcp = @($dhcpConfigs | Where-Object { [string]$_.Description -eq [string]$adapter.InterfaceDescription -or [string]$_.MACAddress -eq [string]$adapter.MacAddress } | Select-Object -First 1)

        $ipv4 = ""
        $prefix = ""
        $ipv6 = ""
        $gateway = ""
        if ($ipconfig.Count -gt 0) {
            $ipv4Obj = @($ipconfig[0].IPv4Address | Select-Object -First 1)
            if ($ipv4Obj.Count -gt 0) {
                $ipv4 = [string]$ipv4Obj[0].IPAddress
                $prefix = [string]$ipv4Obj[0].PrefixLength
            }
            $ipv6Obj = @($ipconfig[0].IPv6Address | Select-Object -First 1)
            if ($ipv6Obj.Count -gt 0) { $ipv6 = [string]$ipv6Obj[0].IPAddress }
            $gwObj = @($ipconfig[0].IPv4DefaultGateway | Select-Object -First 1)
            if ($gwObj.Count -gt 0) { $gateway = [string]$gwObj[0].NextHop }
        }

        $row = [PSCustomObject]@{
            Name = $alias
            InterfaceDescription = [string]$adapter.InterfaceDescription
            Status = [string]$adapter.Status
            LinkSpeed = [string]$adapter.LinkSpeed
            LinkSpeedMbps = Convert-LinkSpeedToMbps ([string]$adapter.LinkSpeed)
            MacAddress = [string]$adapter.MacAddress
            IPv4Address = $ipv4
            IPv6Address = $ipv6
            PrefixLength = $prefix
            Gateway = $gateway
            DnsServers = if ($dns.Count -gt 0) { ($dns[0].ServerAddresses -join ", ") } else { "" }
            DhcpEnabled = if ($dhcp.Count -gt 0) { [string]$dhcp[0].DHCPEnabled } else { "" }
            DhcpServer = if ($dhcp.Count -gt 0) { [string]$dhcp[0].DHCPServer } else { "" }
            InterfaceMetric = if ($ipInterface.Count -gt 0) { [string]$ipInterface[0].InterfaceMetric } else { "" }
            NetworkProfile = if ($profile.Count -gt 0) { [string]$profile[0].NetworkCategory } else { "" }
        }
        $rows += $row

        if ($row.Status -match 'Up') {
            if ($row.IPv4Address -match '^169\.254\.') {
                Add-Result -Category "Adapters" -Test "IPv4 address" -Role "Active adapter" -Target $row.Name -InterfaceAlias $row.Name -Severity "Error" -Result "APIPA address" -Value $row.IPv4Address -Recommendation "DHCP likely failed. Check DHCP server, switch/Wi-Fi, VLAN, cable, and adapter configuration."
            }
            if ([string]::IsNullOrWhiteSpace($row.Gateway) -and $row.InterfaceDescription -notmatch '(?i)loopback|virtual|vpn|bluetooth') {
                Add-Result -Category "Adapters" -Test "Default gateway" -Role "Active adapter" -Target $row.Name -InterfaceAlias $row.Name -Severity "Warning" -Result "No gateway" -Recommendation "If this adapter should provide network access, check DHCP/static IP configuration."
            }
            if ([string]::IsNullOrWhiteSpace($row.DnsServers)) {
                Add-Result -Category "Adapters" -Test "DNS servers" -Role "Active adapter" -Target $row.Name -InterfaceAlias $row.Name -Severity "Error" -Result "No DNS server" -Recommendation "Set DNS via DHCP or static configuration."
            }
            if ($row.NetworkProfile -eq "Public") {
                Add-Result -Category "Firewall" -Test "Network profile" -Role "Active adapter" -Target $row.Name -InterfaceAlias $row.Name -Severity "Warning" -Result "Public profile" -Recommendation "Public profile can block discovery, SMB, printer access, and inbound services. Use Private/Domain only if appropriate for the network."
            }
            if ($row.InterfaceDescription -match '(?i)ethernet|gbe|i219|i225|i226|realtek|killer|intel' -and $null -ne $row.LinkSpeedMbps -and $row.LinkSpeedMbps -lt 1000) {
                Add-Result -Category "Adapters" -Test "Link speed" -Role "Ethernet adapter" -Target $row.Name -InterfaceAlias $row.Name -Severity "Warning" -Result "Low link speed" -Value $row.LinkSpeed -Recommendation "A wired adapter below 1 Gbit/s can indicate cable, switch port, autonegotiation, docking station, or driver issues."
            }
        }
    }
    return $rows
}

function Get-RouteRows {
    $routes = @(Invoke-Capture "Get-NetRoute" { Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop | Sort-Object DestinationPrefix, RouteMetric, InterfaceMetric } @())
    $defaultRoutes = @($routes | Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" })
    if ($defaultRoutes.Count -eq 0) {
        Add-Result -Category "Routing" -Test "Default route" -Severity "Error" -Result "No default route" -Recommendation "Without a default route, internet and routed network access will fail."
    } elseif ($defaultRoutes.Count -gt 1) {
        $sameMetric = @($defaultRoutes | Group-Object RouteMetric, InterfaceMetric | Where-Object { $_.Count -gt 1 })
        if ($sameMetric.Count -gt 0) {
            Add-Result -Category "Routing" -Test "Default route metric" -Severity "Warning" -Result "Multiple equal default routes" -Value ($sameMetric[0].Name) -Recommendation "Multiple default routes with equal metrics can cause traffic to leave through the wrong adapter or VPN."
        } else {
            Add-Result -Category "Routing" -Test "Default routes" -Severity "Info" -Result "Multiple default routes" -Value ($defaultRoutes.Count) -Recommendation "Multiple routes can be normal with VPNs or multiple adapters. Confirm the primary route is intended."
        }
    }

    return @($routes | Select-Object DestinationPrefix, NextHop, InterfaceAlias, RouteMetric, InterfaceMetric, PolicyStore)
}

function Get-PrimaryInterfaceAlias {
    param([object[]]$RouteRows)
    $route = @($RouteRows | Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" } | Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1)
    if ($route.Count -gt 0) { return [string]$route[0].InterfaceAlias }
    return ""
}

function Build-TargetMatrix {
    param([object[]]$AdapterRows, [object[]]$RouteRows)

    $targets = @{}
    $defaultRoutes = @($RouteRows | Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" })

    foreach ($adapter in @($AdapterRows | Where-Object { $_.Status -match 'Up' })) {
        if (-not [string]::IsNullOrWhiteSpace([string]$adapter.Gateway)) {
            Add-Target ([ref]$targets) -Role ("Gateway for interface {0}" -f $adapter.Name) -Target ([string]$adapter.Gateway) -InterfaceAlias ([string]$adapter.Name) -Source "AutoDetected" -TestPing $true -TcpPorts @(80,443) -TargetType "Local"
        }

        $dnsList = @(([string]$adapter.DnsServers -split ',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        for ($i = 0; $i -lt $dnsList.Count; $i++) {
            $role = if ($i -eq 0) { "Primary DNS server for interface $($adapter.Name)" } else { "Secondary DNS server for interface $($adapter.Name)" }
            Add-Target ([ref]$targets) -Role $role -Target $dnsList[$i] -InterfaceAlias ([string]$adapter.Name) -Source "AutoDetected" -TestPing $true -TestDns $true -TcpPorts @(53) -TargetType "Local"
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$adapter.DhcpServer)) {
            Add-Target ([ref]$targets) -Role ("DHCP server for interface {0}" -f $adapter.Name) -Target ([string]$adapter.DhcpServer) -InterfaceAlias ([string]$adapter.Name) -Source "AutoDetected" -TestPing $true -TcpPorts @() -TargetType "Local"
        }
    }

    $primaryRoute = @($defaultRoutes | Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1)
    if ($primaryRoute.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$primaryRoute[0].NextHop)) {
        Add-Target ([ref]$targets) -Role "Default Gateway" -Target ([string]$primaryRoute[0].NextHop) -InterfaceAlias ([string]$primaryRoute[0].InterfaceAlias) -Source "AutoDetected" -TestPing $true -TcpPorts @(80,443) -TargetType "Local"
    }

    $cs = Invoke-Capture "Domain membership" { Get-CimInstance Win32_ComputerSystem } $null
    if ($cs -and $cs.PartOfDomain) {
        $domain = [string]$cs.Domain
        $dcTarget = ""
        try {
            $nl = (nltest /dsgetdc:$domain 2>$null) -join "`n"
            if ($nl -match '(?im)^\s*DC:\s*\\\\(.+?)\s*$') { $dcTarget = $matches[1].Trim() }
        } catch {}
        if ([string]::IsNullOrWhiteSpace($dcTarget) -and -not [string]::IsNullOrWhiteSpace($env:LOGONSERVER)) {
            $dcTarget = $env:LOGONSERVER.TrimStart('\')
        }
        if (-not [string]::IsNullOrWhiteSpace($dcTarget)) {
            Add-Target ([ref]$targets) -Role "Domain Controller" -Target $dcTarget -Source "AutoDetected" -TestPing $true -TcpPorts @(53,88,389,445) -TargetType "Local"
        }
    }

    foreach ($target in @($LocalTargets)) {
        Add-Target ([ref]$targets) -Role "Custom local target" -Target $target -Source "UserProvided" -TestPing $true -TcpPorts @() -TargetType "Local"
    }

    if (-not $NoInternetTest) {
        Add-Target ([ref]$targets) -Role "Internet target" -Target "1.1.1.1" -Source "Default" -TestPing $true -TargetType "Internet"
        Add-Target ([ref]$targets) -Role "Internet target" -Target "8.8.8.8" -Source "Default" -TestPing $true -TargetType "Internet"
        Add-Target ([ref]$targets) -Role "Internet DNS/name target" -Target "google.de" -Source "Default" -TestPing $true -TcpPorts @(443) -TargetType "Internet"
        Add-Target ([ref]$targets) -Role "Internet DNS/name target" -Target "microsoft.com" -Source "Default" -TestPing $true -TcpPorts @(443) -TargetType "Internet"
    }

    return @($targets.Values)
}

function Get-TcpRowsFromTargets {
    param([object[]]$TargetMatrix)
    $rows = @()
    foreach ($target in @($TargetMatrix)) {
        foreach ($port in @($target.TcpPorts)) {
            $rows += Test-TcpTarget -HostName ([string]$target.Target) -Port ([int]$port) -Role ([string]$target.Role) -InterfaceAlias ([string]$target.InterfaceAlias)
        }
    }

    foreach ($entry in @($TcpTargets)) {
        if ([string]::IsNullOrWhiteSpace($entry) -or $entry -notmatch '^(.+):(\d+)$') {
            Add-Result -Category "TCP" -Test "User TCP target" -Target $entry -Severity "Warning" -Result "Invalid target" -Recommendation "Use host:port format, for example nas:445."
            continue
        }
        $hostName = $matches[1]
        $port = [int]$matches[2]
        $rows += Test-TcpTarget -HostName $hostName -Port $port -Role "User provided TCP target"
    }

    if (-not $NoInternetTest) {
        $rows += Test-TcpTarget -HostName "microsoft.com" -Port 443 -Role "Internet HTTPS"
        $rows += Test-TcpTarget -HostName "google.de" -Port 443 -Role "Internet HTTPS"
    }
    return $rows
}

function Get-DnsRows {
    param([object[]]$TargetMatrix)
    $rows = @()
    $servers = @($TargetMatrix | Where-Object { $_.TestDns } | Select-Object -ExpandProperty Target -Unique)
    foreach ($name in @($DnsTestNames)) {
        $rows += Test-DnsResolution -Name $name -Role "Default resolver"
        foreach ($server in $servers) {
            $rows += Test-DnsResolution -Name $name -Server $server -Role ("DNS server {0}" -f $server)
        }
        if (-not $NoInternetTest) {
            $rows += Test-DnsResolution -Name $name -Server "1.1.1.1" -Role "Public comparison DNS 1.1.1.1"
            $rows += Test-DnsResolution -Name $name -Server "8.8.8.8" -Role "Public comparison DNS 8.8.8.8"
        }
    }
    return $rows
}

function Get-TracerouteRows {
    param([object[]]$TargetMatrix)
    if (-not $IncludeTraceroute) { return @() }
    $rows = @()
    $targets = @()
    $targets += @($LocalTargets)
    if (-not $NoInternetTest) { $targets += @("1.1.1.1","8.8.8.8","microsoft.com") }
    foreach ($target in @($targets | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        try {
            if (Get-Command Test-NetConnection -ErrorAction SilentlyContinue) {
                $tnc = Test-NetConnection -ComputerName $target -TraceRoute -InformationLevel Detailed -ErrorAction SilentlyContinue
                $trace = if ($tnc.TraceRoute) { $tnc.TraceRoute -join " -> " } else { "" }
                $rows += [PSCustomObject]@{ Target=$target; TraceRoute=$trace; PingSucceeded=$tnc.PingSucceeded; Severity="Info"; Details="" }
            } else {
                $rows += [PSCustomObject]@{ Target=$target; TraceRoute="Test-NetConnection unavailable"; PingSucceeded=""; Severity="Info"; Details="" }
            }
        } catch {
            $rows += [PSCustomObject]@{ Target=$target; TraceRoute=""; PingSucceeded=""; Severity="Warning"; Details=$_.Exception.Message }
        }
    }
    return $rows
}

function Test-MtuTarget {
    param([string]$Target, [string]$Role)
    $best = 0
    foreach ($payload in 1472,1464,1452,1400,1300,1200) {
        $output = ""
        try { $output = (ping.exe -n 1 -w 1500 -f -l $payload $Target 2>&1) -join "`n" } catch {}
        if ($LASTEXITCODE -eq 0 -and $output -match '(?i)TTL=|bytes=|Zeit=|time=') {
            $best = $payload
            break
        }
    }
    $estimated = if ($best -gt 0) { $best + 28 } else { "" }
    $severity = "Info"
    $result = if ($best -gt 0) { "MTU probe completed" } else { "MTU probe failed" }
    $rec = "MTU can be lower intentionally on VPN, PPPoE, or some WAN links."
    if ($best -gt 0 -and $Role -match 'Gateway' -and $estimated -lt 1500) {
        $severity = "Warning"
        $rec = "Gateway MTU below 1500 can be normal in some networks, but on wired LAN it can indicate VPN/tunnel or path issues."
    }
    Add-Result -Category "MTU" -Test "IPv4 MTU probe" -Role $Role -Target $Target -Severity $severity -Result $result -Value ("payload={0}; mtu={1}" -f $best, $estimated) -Recommendation $rec
    return [PSCustomObject]@{ Role=$Role; Target=$Target; BestPayload=$best; EstimatedMtu=$estimated; Severity=$severity; Result=$result; Recommendation=$rec }
}

function Get-MtuRows {
    param([object[]]$TargetMatrix)
    if (-not $IncludeMtuTest) { return @() }
    $rows = @()
    $gateway = @($TargetMatrix | Where-Object { $_.Role -match 'Default Gateway|Gateway for interface' } | Select-Object -First 1)
    if ($gateway.Count -gt 0) { $rows += Test-MtuTarget -Target ([string]$gateway[0].Target) -Role ([string]$gateway[0].Role) }
    if (-not $NoInternetTest) { $rows += Test-MtuTarget -Target "1.1.1.1" -Role "Internet target" }
    return $rows
}

function Get-WlanRows {
    $output = ""
    try { $output = (netsh.exe wlan show interfaces 2>&1) -join "`n" } catch {}
    if ([string]::IsNullOrWhiteSpace($output) -or $output -match 'There is no wireless interface|Es ist keine Drahtlosschnittstelle') {
        return @()
    }
    $script:RawData["netsh wlan show interfaces"] = $output
    $signal = ""
    $ssid = ""
    $bssid = ""
    $radio = ""
    $channel = ""
    $rxRate = ""
    $txRate = ""
    if ($output -match '(?im)^\s*SSID\s*:\s*(.+?)\s*$') { $ssid = $matches[1].Trim() }
    if ($output -match '(?im)^\s*BSSID\s*:\s*(.+?)\s*$') { $bssid = $matches[1].Trim() }
    if ($output -match '(?im)^\s*(Radio type|Funktyp)\s*:\s*(.+?)\s*$') { $radio = $matches[2].Trim() }
    if ($output -match '(?im)^\s*(Channel|Kanal)\s*:\s*(.+?)\s*$') { $channel = $matches[2].Trim() }
    if ($output -match '(?im)^\s*(Signal)\s*:\s*(\d+)%') { $signal = $matches[2].Trim() }
    if ($output -match '(?im)^\s*(Receive rate|Empfangsrate).*?:\s*(.+?)\s*$') { $rxRate = $matches[2].Trim() }
    if ($output -match '(?im)^\s*(Transmit rate|Ubertragungsrate|Übertragungsrate).*?:\s*(.+?)\s*$') { $txRate = $matches[2].Trim() }

    $severity = "Info"
    $result = "WLAN data collected"
    $rec = "Review signal quality, channel, and link rates if Wi-Fi issues are reported."
    $signalNumber = ConvertTo-Number $signal
    if ($null -ne $signalNumber -and $signalNumber -lt 50) {
        $severity = "Warning"
        $result = "Weak Wi-Fi signal"
        $rec = "Wi-Fi signal is weak. Check distance, walls, roaming, interference, antenna, and AP channel plan."
    }
    Add-Result -Category "WLAN" -Test "Wi-Fi signal" -Role "Active WLAN" -Target $ssid -Severity $severity -Result $result -Value ("signal={0}%; rx={1}; tx={2}" -f $signal, $rxRate, $txRate) -Recommendation $rec
    return @([PSCustomObject]@{ SSID=$ssid; BSSID=$bssid; SignalPercent=$signal; RadioType=$radio; Channel=$channel; ReceiveRate=$rxRate; TransmitRate=$txRate; Severity=$severity; Recommendation=$rec })
}

function Test-SmbPath {
    if ([string]::IsNullOrWhiteSpace($SmbTestPath)) { return @() }
    $rows = @()
    $hostName = ""
    if ($SmbTestPath -match '^\\\\([^\\]+)\\') { $hostName = $matches[1] }
    if ([string]::IsNullOrWhiteSpace($hostName)) {
        Add-Result -Category "SMB" -Test "UNC path" -Target $SmbTestPath -Severity "Error" -Result "Invalid UNC path" -Recommendation "Use a path like \\nas\share."
        return @([PSCustomObject]@{ Path=$SmbTestPath; Host=""; Result="Invalid UNC"; Severity="Error"; Details="" })
    }

    $tcp = Test-TcpTarget -HostName $hostName -Port 445 -Role "SMB target"
    $exists = $false
    $errorText = ""
    try { $exists = Test-Path -LiteralPath $SmbTestPath -ErrorAction Stop } catch { $errorText = $_.Exception.Message }
    $severity = if ($exists) { "OK" } else { "Error" }
    $result = if ($exists) { "UNC reachable" } else { "UNC not reachable" }
    $rec = if ($exists) { "No action required." } else { "Check DNS, TCP 445, permissions, SMB service, firewall, and share path." }
    Add-Result -Category "SMB" -Test "UNC access" -Role "SMB share" -Target $SmbTestPath -Severity $severity -Result $result -Details $errorText -Recommendation $rec

    $writeMbps = ""
    $readMbps = ""
    if ($exists -and -not $NoWriteTests) {
        $testFile = Join-Path $SmbTestPath ("NetzwerkDiagnose_{0}_{1}.tmp" -f $env:COMPUTERNAME, ([guid]::NewGuid().ToString("N")))
        $buffer = New-Object byte[] (1024 * 1024)
        (New-Object Random).NextBytes($buffer)
        try {
            $fs = [IO.File]::Open($testFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $sw = [Diagnostics.Stopwatch]::StartNew()
            for ($i = 0; $i -lt $SmbTestSizeMB; $i++) { $fs.Write($buffer, 0, $buffer.Length) }
            $fs.Close()
            $sw.Stop()
            if ($sw.Elapsed.TotalSeconds -gt 0) { $writeMbps = [math]::Round($SmbTestSizeMB / $sw.Elapsed.TotalSeconds, 2) }

            $fs = [IO.File]::Open($testFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while ($fs.Read($buffer, 0, $buffer.Length) -gt 0) {}
            $fs.Close()
            $sw.Stop()
            if ($sw.Elapsed.TotalSeconds -gt 0) { $readMbps = [math]::Round($SmbTestSizeMB / $sw.Elapsed.TotalSeconds, 2) }
            Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue

            $speedSeverity = "OK"
            $speedResult = "SMB throughput measured"
            $speedRec = "Throughput depends on link speed, disk speed, Wi-Fi quality, SMB signing/encryption, antivirus, and NAS/server performance."
            if ($writeMbps -ne "" -and [double]$writeMbps -lt 30) {
                $speedSeverity = "Warning"
                $speedRec = "SMB write throughput is low. Compare with link speed and test wired LAN if currently on Wi-Fi."
            }
            Add-Result -Category "SMB" -Test "SMB throughput" -Role "SMB share" -Target $SmbTestPath -Severity $speedSeverity -Result $speedResult -Value ("write={0} MB/s; read={1} MB/s" -f $writeMbps, $readMbps) -Recommendation $speedRec
        } catch {
            Add-Result -Category "SMB" -Test "SMB throughput" -Role "SMB share" -Target $SmbTestPath -Severity "Warning" -Result "Write/read test failed" -Details $_.Exception.Message -Recommendation "Check permissions, free space, share policy, antivirus, and network stability."
            Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue
        }
    }

    $rows += [PSCustomObject]@{ Path=$SmbTestPath; Host=$hostName; Tcp445=$tcp.TcpTestSucceeded; TestPath=$exists; WriteMBps=$writeMbps; ReadMBps=$readMbps; Severity=$severity; Details=$errorText }
    return $rows
}

function Find-Tool {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return [string]$cmd.Source }
    $local = Join-Path $PSScriptRoot $Name
    if (Test-Path -LiteralPath $local) { return $local }
    return ""
}

function Get-IperfRows {
    if ([string]::IsNullOrWhiteSpace($LanSpeedTarget)) { return @() }
    $iperf = Find-Tool "iperf3.exe"
    if ([string]::IsNullOrWhiteSpace($iperf)) {
        Add-Result -Category "LAN Speed" -Test "iperf3" -Target $LanSpeedTarget -Severity "Info" -Result "Skipped" -Details "iperf3.exe not found" -Recommendation "Install iperf3.exe or place it next to the script, then run with -LanSpeedTarget."
        return @([PSCustomObject]@{ Target=$LanSpeedTarget; Mode="iperf3"; Result="iperf3.exe not found"; Severity="Info" })
    }
    $rows = @()
    foreach ($mode in @("upload","download")) {
        $argList = if ($mode -eq "download") { @("-c", $LanSpeedTarget, "-R", "-J") } else { @("-c", $LanSpeedTarget, "-J") }
        try {
            $jsonText = (& $iperf @argList 2>&1) -join "`n"
            $json = $jsonText | ConvertFrom-Json
            $bps = $json.end.sum_received.bits_per_second
            if (-not $bps) { $bps = $json.end.sum.bits_per_second }
            $mbit = if ($bps) { [math]::Round($bps / 1000000, 2) } else { "" }
            $retrans = ""
            try { $retrans = [string]$json.end.sum_sent.retransmits } catch {}
            $severity = "OK"
            $rec = "No action required."
            if ($mbit -ne "" -and [double]$mbit -lt 300) {
                $severity = "Warning"
                $rec = "LAN throughput is low for Gigabit Ethernet. Compare with link speed, cable, switch, Wi-Fi, CPU, and iperf server performance."
            }
            Add-Result -Category "LAN Speed" -Test "iperf3 $mode" -Target $LanSpeedTarget -Severity $severity -Result "Measured" -Value ("{0} Mbit/s; retransmits={1}" -f $mbit, $retrans) -Recommendation $rec
            $rows += [PSCustomObject]@{ Target=$LanSpeedTarget; Mode=$mode; Mbps=$mbit; Retransmits=$retrans; Severity=$severity; Result="Measured" }
        } catch {
            Add-Result -Category "LAN Speed" -Test "iperf3 $mode" -Target $LanSpeedTarget -Severity "Warning" -Result "Failed" -Details $_.Exception.Message -Recommendation "Check iperf3 server, firewall, and target name."
            $rows += [PSCustomObject]@{ Target=$LanSpeedTarget; Mode=$mode; Mbps=""; Retransmits=""; Severity="Warning"; Result="Failed"; Details=$_.Exception.Message }
        }
    }
    return $rows
}

function Get-SpeedtestRows {
    if (-not $IncludeSpeedtest -or $NoInternetTest) { return @() }
    $speedtest = Find-Tool "speedtest.exe"
    $rows = @()
    if (-not [string]::IsNullOrWhiteSpace($speedtest)) {
        try {
            $jsonText = (& $speedtest "--format=json" 2>&1) -join "`n"
            $json = $jsonText | ConvertFrom-Json
            $download = if ($json.download.bandwidth) { [math]::Round(($json.download.bandwidth * 8) / 1000000, 2) } else { "" }
            $upload = if ($json.upload.bandwidth) { [math]::Round(($json.upload.bandwidth * 8) / 1000000, 2) } else { "" }
            $ping = if ($json.ping.latency) { [math]::Round($json.ping.latency, 2) } else { "" }
            Add-Result -Category "Internet Speed" -Test "speedtest.exe" -Target "Internet" -Severity "Info" -Result "Measured" -Value ("down={0} Mbit/s; up={1} Mbit/s; ping={2} ms" -f $download, $upload, $ping) -Recommendation "Internet speed depends on ISP, Wi-Fi, VPN, server selection, and current load."
            $rows += [PSCustomObject]@{ Tool="speedtest.exe"; DownloadMbps=$download; UploadMbps=$upload; PingMs=$ping; Severity="Info" }
            return $rows
        } catch {}
    }

    try {
        $url = "https://speed.cloudflare.com/__down?bytes=25000000"
        $tempFile = Join-Path $env:TEMP ("NetzwerkDiagnose_http_{0}.bin" -f ([guid]::NewGuid().ToString("N")))
        $wc = New-Object Net.WebClient
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $wc.DownloadFile($url, $tempFile)
        $sw.Stop()
        $size = (Get-Item -LiteralPath $tempFile).Length
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        $mbit = [math]::Round((($size * 8) / 1000000) / $sw.Elapsed.TotalSeconds, 2)
        Add-Result -Category "Internet Speed" -Test "HTTP download probe" -Target $url -Severity "Info" -Result "Measured" -Value ("{0} Mbit/s" -f $mbit) -Recommendation "This is a rough single-download probe, not a full speedtest."
        $rows += [PSCustomObject]@{ Tool="HTTP download probe"; DownloadMbps=$mbit; UploadMbps=""; PingMs=""; Severity="Info" }
    } catch {
        Add-Result -Category "Internet Speed" -Test "HTTP download probe" -Target "Internet" -Severity "Warning" -Result "Failed" -Details $_.Exception.Message -Recommendation "Check internet access, proxy, TLS inspection, VPN, and firewall."
        $rows += [PSCustomObject]@{ Tool="HTTP download probe"; DownloadMbps=""; UploadMbps=""; PingMs=""; Severity="Warning"; Details=$_.Exception.Message }
    }
    return $rows
}

function Get-FirewallRows {
    $profiles = @(Invoke-Capture "Get-NetConnectionProfile" { Get-NetConnectionProfile -ErrorAction Stop } @())
    $firewall = @(Invoke-Capture "Get-NetFirewallProfile" { Get-NetFirewallProfile -ErrorAction Stop } @())
    foreach ($fw in $firewall) {
        if ([string]$fw.Enabled -match 'False') {
            Add-Result -Category "Firewall" -Test "Firewall profile" -Role ([string]$fw.Name) -Severity "Warning" -Result "Firewall disabled" -Recommendation "A disabled firewall is not a connectivity fix and can reduce security. Re-enable unless deliberately managed elsewhere."
        }
    }
    return @($profiles | Select-Object Name, InterfaceAlias, NetworkCategory, IPv4Connectivity, IPv6Connectivity) + @($firewall | Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction)
}

function Get-ServiceRows {
    $names = @("Dhcp","Dnscache","NlaSvc","netprofm","LanmanWorkstation","LanmanServer","WlanSvc","WinRM")
    $rows = @()
    foreach ($name in $names) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc) {
            $startType = ""
            try { $startType = (Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue).StartMode } catch {}
            $rows += [PSCustomObject]@{ Name=$svc.Name; DisplayName=$svc.DisplayName; Status=$svc.Status; StartType=$startType }
            if ($svc.Status -ne "Running" -and $name -in @("Dhcp","Dnscache","NlaSvc","netprofm","LanmanWorkstation")) {
                Add-Result -Category "Services" -Test "Network service" -Role $name -Severity "Warning" -Result "Not running" -Value ([string]$svc.Status) -Recommendation "This service is commonly required for normal client networking. Check whether it is intentionally disabled."
            }
        } else {
            $rows += [PSCustomObject]@{ Name=$name; DisplayName=""; Status="Missing"; StartType="" }
        }
    }
    return $rows
}

function Get-NetworkEventRows {
    if (-not $IncludeEventLogs) { return @() }
    $rows = @()
    $logs = @(
        "System",
        "Microsoft-Windows-NetworkProfile/Operational",
        "Microsoft-Windows-Dhcp-Client/Admin",
        "Microsoft-Windows-DNS-Client/Operational",
        "Microsoft-Windows-WLAN-AutoConfig/Operational"
    )
    $start = (Get-Date).AddHours(-1 * [math]::Max(1, $EventHours))
    foreach ($log in $logs) {
        try {
            $events = @(Get-WinEvent -FilterHashtable @{ LogName=$log; StartTime=$start } -ErrorAction Stop | Where-Object {
                "$($_.ProviderName) $($_.Message)" -match '(?i)Tcpip|Dhcp|DNS|Netwtw|e1d|e2f|Realtek|NDIS|NetAdapter|WLAN|disconnect|duplicate|lease|name resolution'
            } | Select-Object -First 200)
            foreach ($ev in $events) {
                $msg = ""
                try { $msg = [string]$ev.Message } catch {}
                if ($msg.Length -gt 500) { $msg = $msg.Substring(0,500) + "..." }
                $rows += [PSCustomObject]@{ TimeCreated=$ev.TimeCreated; LogName=$log; ProviderName=$ev.ProviderName; Id=$ev.Id; LevelDisplayName=$ev.LevelDisplayName; Message=$msg }
            }
        } catch {
            Add-Result -Category "Event Logs" -Test "Read event log" -Target $log -Severity "Info" -Result "Skipped" -Details $_.Exception.Message -Recommendation "This log can be unavailable or require permissions on some systems."
        }
    }
    if ($rows.Count -gt 0) {
        Add-Result -Category "Event Logs" -Test "Relevant network events" -Severity "Info" -Result "Events found" -Value $rows.Count -Recommendation "Review event timestamps and correlate them with reported network symptoms."
    }
    return $rows
}

function Convert-IPv4ToUInt32 {
    param([string]$Address)
    $bytes = ([Net.IPAddress]::Parse($Address)).GetAddressBytes()
    [Array]::Reverse($bytes)
    return [BitConverter]::ToUInt32($bytes, 0)
}

function Convert-UInt32ToIPv4 {
    param([UInt32]$Value)
    $bytes = [BitConverter]::GetBytes($Value)
    [Array]::Reverse($bytes)
    return (New-Object Net.IPAddress (,$bytes)).ToString()
}

function Get-SubnetDiscoveryRows {
    param([object[]]$AdapterRows, [string]$PrimaryAlias)
    if (-not $IncludeSubnetDiscovery) { return @() }
    $adapter = @($AdapterRows | Where-Object { [string]$_.Name -eq $PrimaryAlias } | Select-Object -First 1)
    if ($adapter.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$adapter[0].IPv4Address)) {
        Add-Result -Category "Subnet Discovery" -Test "Primary subnet" -Severity "Info" -Result "Skipped" -Recommendation "No primary IPv4 interface was identified."
        return @()
    }
    $prefix = [int]$adapter[0].PrefixLength
    if ($prefix -lt 24) {
        Add-Result -Category "Subnet Discovery" -Test "Primary subnet" -Severity "Warning" -Result "Skipped large subnet" -Value ("/{0}" -f $prefix) -Recommendation "Subnet discovery is skipped for networks larger than /24 to avoid aggressive scans."
        return @()
    }
    $hostCount = [math]::Pow(2, 32 - $prefix) - 2
    if ($hostCount -gt 254) {
        Add-Result -Category "Subnet Discovery" -Test "Primary subnet" -Severity "Warning" -Result "Skipped large subnet" -Value $hostCount -Recommendation "Subnet discovery is limited to small directly connected subnets."
        return @()
    }

    $ipInt = Convert-IPv4ToUInt32 ([string]$adapter[0].IPv4Address)
    $mask = [uint32]([uint32]::MaxValue -shl (32 - $prefix))
    $network = $ipInt -band $mask
    $rows = @()
    for ($i = 1; $i -le $hostCount; $i++) {
        $ip = Convert-UInt32ToIPv4 ([uint32]($network + $i))
        try {
            if (Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                $rows += [PSCustomObject]@{ Address=$ip; Result="Responded to ping" }
            }
        } catch {}
    }
    Add-Result -Category "Subnet Discovery" -Test "Ping discovery" -Severity "Info" -Result "Completed" -Value ("{0} host(s)" -f $rows.Count) -Recommendation "Discovery is intentionally light and may miss hosts that block ICMP."
    return $rows
}

function New-HtmlReport {
    param(
        [string]$Path,
        [hashtable]$Data
    )

    $results = @(Get-ResultRows)
    $errors = @($results | Where-Object { $_.Severity -eq "Error" })
    $warnings = @($results | Where-Object { $_.Severity -eq "Warning" })
    $ok = @($results | Where-Object { $_.Severity -eq "OK" })
    $info = @($results | Where-Object { $_.Severity -eq "Info" })
    $overall = if ($errors.Count -gt 0) { "Error" } elseif ($warnings.Count -gt 0) { "Warning" } else { "OK" }
    $topProblems = @($results | Where-Object { $_.Severity -in @("Error","Warning") } | Select-Object -First 12)
    $topProblemHtml = if ($topProblems.Count -gt 0) {
        "<ul>" + (($topProblems | ForEach-Object { "<li><strong>$(Escape-Html $_.Category): $(Escape-Html $_.Test)</strong> - $(Escape-Html $_.Result). $(Escape-Html $_.Recommendation)</li>" }) -join "") + "</ul>"
    } else {
        '<p>No errors or warnings were detected by the heuristic.</p>'
    }

    $rawHtml = ""
    if ($IncludeRawData -and $script:RawData.Count -gt 0) {
        $rawBlocks = foreach ($key in $script:RawData.Keys) {
            "<details><summary>$(Escape-Html $key)</summary><pre>$(Escape-Html $script:RawData[$key])</pre></details>"
        }
        $rawHtml = ($rawBlocks -join "`n")
    } else {
        $rawHtml = '<div class="empty">Raw data was not requested. Run with -IncludeRawData to include raw command output and JSON.</div>'
    }

    $sectionsHtml = @"
<section id="system"><h2>System information</h2>$(New-ResultTable $Data.SystemInfo @("ComputerName","UserName","DomainOrWorkgroup","PartOfDomain","Windows","BuildNumber","PowerShellVersion","UptimeDays","DateTime","TimeZone","IsAdmin"))</section>
<section id="adapters"><h2>Network adapters</h2>$(New-ResultTable $Data.Adapters @("Name","InterfaceDescription","Status","LinkSpeed","IPv4Address","PrefixLength","Gateway","DnsServers","DhcpEnabled","DhcpServer","InterfaceMetric","NetworkProfile"))</section>
<section id="routes"><h2>IP configuration and routing</h2>$(New-ResultTable $Data.Routes @("DestinationPrefix","NextHop","InterfaceAlias","RouteMetric","InterfaceMetric","PolicyStore"))</section>
<section id="targets"><h2>Detected target matrix</h2>$(New-ResultTable $Data.TargetMatrix @("Role","Target","InterfaceAlias","Source","TargetType","TestPing","TestDns","TcpPorts"))</section>
<section id="ping"><h2>Ping tests</h2>$(New-ResultTable $Data.Ping @("Severity","Role","Target","ResolvedAddress","InterfaceAlias","Sent","Successful","LossPercent","MinMs","AvgMs","MaxMs","JitterMs","Result","Recommendation"))</section>
<section id="tcp"><h2>TCP port tests</h2>$(New-ResultTable $Data.Tcp @("Severity","Role","Host","Port","TcpTestSucceeded","RemoteAddress","InterfaceAlias","LatencyMs","Result","Details","Recommendation"))</section>
<section id="dns"><h2>DNS diagnostics</h2>$(New-ResultTable $Data.Dns @("Severity","Role","Name","Server","Addresses","DurationMs","Result","Error","Recommendation"))</section>
<section id="trace"><h2>Traceroute</h2>$(New-ResultTable $Data.Traceroute @("Severity","Target","PingSucceeded","TraceRoute","Details"))</section>
<section id="mtu"><h2>MTU test</h2>$(New-ResultTable $Data.Mtu @("Severity","Role","Target","BestPayload","EstimatedMtu","Result","Recommendation"))</section>
<section id="wlan"><h2>WLAN diagnostics</h2>$(New-ResultTable $Data.Wlan @("Severity","SSID","BSSID","SignalPercent","RadioType","Channel","ReceiveRate","TransmitRate","Recommendation"))</section>
<section id="smb"><h2>SMB / NAS test</h2>$(New-ResultTable $Data.Smb @("Severity","Path","Host","Tcp445","TestPath","WriteMBps","ReadMBps","Details"))</section>
<section id="iperf"><h2>iPerf3 LAN speed test</h2>$(New-ResultTable $Data.Iperf @("Severity","Target","Mode","Mbps","Retransmits","Result","Details"))</section>
<section id="speedtest"><h2>Internet speed test</h2>$(New-ResultTable $Data.Speedtest @("Severity","Tool","DownloadMbps","UploadMbps","PingMs","Details"))</section>
<section id="firewall"><h2>Firewall and network profiles</h2>$(New-ResultTable $Data.Firewall @("Name","InterfaceAlias","NetworkCategory","IPv4Connectivity","IPv6Connectivity","Enabled","DefaultInboundAction","DefaultOutboundAction"))</section>
<section id="services"><h2>Windows network services</h2>$(New-ResultTable $Data.Services @("Name","DisplayName","Status","StartType"))</section>
<section id="events"><h2>Network event logs</h2>$(New-ResultTable $Data.Events @("TimeCreated","LogName","ProviderName","Id","LevelDisplayName","Message"))</section>
<section id="subnet"><h2>Subnet discovery</h2>$(New-ResultTable $Data.SubnetDiscovery @("Address","Result"))</section>
<section id="results"><h2>All findings and test results</h2>$(New-ResultTable $results @("Severity","Category","Test","Role","Target","InterfaceAlias","Result","Value","Details","Recommendation"))</section>
<section id="raw"><h2>Raw data</h2>$rawHtml</section>
"@

    $html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Network Diagnostics Report</title>
  <style>
    :root { --ink:#17202a; --muted:#64748b; --line:#d7dee8; --soft:#f8fafc; --ok:#15803d; --warn:#b45309; --error:#b42318; --info:#2563eb; }
    * { box-sizing:border-box; }
    body { margin:0; font-family:Segoe UI, Arial, sans-serif; color:var(--ink); background:#fff; }
    header { padding:28px 34px 20px; background:#f8fafc; border-bottom:1px solid var(--line); }
    main { padding:22px 34px 42px; max-width:1700px; margin:0 auto; }
    h1 { margin:0 0 8px; font-size:28px; }
    h2 { margin:30px 0 10px; font-size:20px; }
    .meta { color:var(--muted); font-size:13px; }
    .summary { margin-top:18px; border:1px solid var(--line); border-left:7px solid var(--info); border-radius:8px; padding:16px; background:#fff; }
    .summary.Error { border-left-color:var(--error); }
    .summary.Warning { border-left-color:var(--warn); }
    .summary.OK { border-left-color:var(--ok); }
    .summary-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(180px,1fr)); gap:12px; margin-top:14px; }
    .stat { border:1px solid var(--line); border-radius:8px; padding:12px; background:#fff; }
    .stat .label { color:var(--muted); text-transform:uppercase; font-size:12px; letter-spacing:.04em; }
    .stat .value { font-size:22px; font-weight:700; margin-top:4px; }
    nav { display:flex; flex-wrap:wrap; gap:8px; margin:18px 0 6px; }
    nav a { color:#0f766e; text-decoration:none; border:1px solid #99f6e4; background:#f0fdfa; border-radius:999px; padding:5px 10px; font-size:12px; }
    section { margin-top:18px; }
    .table-wrap { width:100%; overflow:auto; border:1px solid var(--line); border-radius:8px; }
    table { width:max-content; min-width:100%; border-collapse:collapse; font-size:12px; }
    th, td { padding:8px 9px; border-bottom:1px solid var(--line); border-right:1px solid var(--line); vertical-align:top; text-align:left; white-space:normal; max-width:520px; overflow-wrap:anywhere; }
    th { background:#f1f5f9; font-weight:700; }
    .badge { border-radius:999px; padding:3px 9px; font-weight:700; font-size:11px; display:inline-block; }
    .sev-ok { color:#14532d; background:#dcfce7; border:1px solid #86efac; }
    .sev-warning { color:#7c2d12; background:#ffedd5; border:1px solid #fdba74; }
    .sev-error { color:#7f1d1d; background:#fee2e2; border:1px solid #fca5a5; }
    .sev-info { color:#1e3a8a; background:#dbeafe; border:1px solid #93c5fd; }
    .empty { border:1px dashed var(--line); border-radius:8px; padding:12px; color:var(--muted); background:#f8fafc; }
    details { border:1px solid var(--line); border-radius:8px; margin:10px 0; background:#fff; }
    summary { cursor:pointer; padding:10px 12px; font-weight:700; }
    pre { margin:0; padding:12px; overflow:auto; white-space:pre-wrap; background:#0f172a; color:#e5e7eb; border-radius:0 0 8px 8px; }
  </style>
</head>
<body>
  <header>
    <h1>Network Diagnostics Report</h1>
    <div class="meta">$ToolName $ToolVersion | Created: $(Escape-Html (Get-Date)) | Computer: $(Escape-Html $env:COMPUTERNAME)</div>
    <div class="summary $overall">
      <h2>Executive Summary</h2>
      <p><strong>Overall status:</strong> $overall</p>
      <div class="summary-grid">
        <div class="stat"><div class="label">Errors</div><div class="value">$($errors.Count)</div></div>
        <div class="stat"><div class="label">Warnings</div><div class="value">$($warnings.Count)</div></div>
        <div class="stat"><div class="label">OK</div><div class="value">$($ok.Count)</div></div>
        <div class="stat"><div class="label">Info</div><div class="value">$($info.Count)</div></div>
      </div>
      <h3>Top problems</h3>
      $topProblemHtml
    </div>
    <nav>
      <a href="#system">System</a><a href="#adapters">Adapters</a><a href="#routes">Routing</a><a href="#targets">Targets</a><a href="#ping">Ping</a><a href="#tcp">TCP</a><a href="#dns">DNS</a><a href="#wlan">WLAN</a><a href="#smb">SMB</a><a href="#events">Events</a><a href="#results">All Results</a><a href="#raw">Raw</a>
    </nav>
  </header>
  <main>
    $sectionsHtml
  </main>
</body>
</html>
"@
    [IO.File]::WriteAllText($Path, $html, [Text.UTF8Encoding]::new($true))
}

Write-Step "Collecting system information..."
$systemInfo = @(Get-SystemInfoRows)

Write-Step "Collecting network adapters..."
$adapters = @(Get-NetworkAdapterRows)

Write-Step "Collecting routes..."
$routes = @(Get-RouteRows)
$primaryAlias = Get-PrimaryInterfaceAlias -RouteRows $routes

Write-Step "Building target matrix..."
$targetMatrix = @(Build-TargetMatrix -AdapterRows $adapters -RouteRows $routes)

Write-Step "Running ping tests..."
$pingRows = @()
foreach ($target in @($targetMatrix | Where-Object { $_.TestPing })) {
    $pingRows += Test-PingTarget -TargetRow $target -Count $PingCount
}

Write-Step "Running TCP tests..."
$tcpRows = @(Get-TcpRowsFromTargets -TargetMatrix $targetMatrix)

Write-Step "Running DNS diagnostics..."
$dnsRows = @(Get-DnsRows -TargetMatrix $targetMatrix)

Write-Step "Collecting optional diagnostics..."
$traceRows = @(Get-TracerouteRows -TargetMatrix $targetMatrix)
$mtuRows = @(Get-MtuRows -TargetMatrix $targetMatrix)
$wlanRows = @(Get-WlanRows)
$smbRows = @(Test-SmbPath)
$iperfRows = @(Get-IperfRows)
$speedRows = @(Get-SpeedtestRows)
$firewallRows = @(Get-FirewallRows)
$serviceRows = @(Get-ServiceRows)
$eventRows = @(Get-NetworkEventRows)
$subnetRows = @(Get-SubnetDiscoveryRows -AdapterRows $adapters -PrimaryAlias $primaryAlias)

if ($IncludeRawData) {
    Write-Step "Collecting raw command output..."
    try { $script:RawData["ipconfig /all"] = (ipconfig.exe /all 2>&1) -join "`n" } catch {}
    try { $script:RawData["route print"] = (route.exe print 2>&1) -join "`n" } catch {}
}

$data = @{
    SystemInfo = $systemInfo
    Adapters = $adapters
    Routes = $routes
    TargetMatrix = $targetMatrix
    Ping = $pingRows
    Tcp = $tcpRows
    Dns = $dnsRows
    Traceroute = $traceRows
    Mtu = $mtuRows
    Wlan = $wlanRows
    Smb = $smbRows
    Iperf = $iperfRows
    Speedtest = $speedRows
    Firewall = $firewallRows
    Services = $serviceRows
    Events = $eventRows
    SubnetDiscovery = $subnetRows
    Results = @(Get-ResultRows)
    RawData = $script:RawData
}

if ($IncludeRawData) {
    Write-Step "Writing JSON raw data..."
    try {
        $data | ConvertTo-Json -Depth 8 | Out-File $JsonPath -Encoding UTF8
    } catch {
        Add-Result -Category "Output" -Test "JSON raw data" -Severity "Warning" -Result "Failed" -Details $_.Exception.Message -Recommendation "HTML report was still created."
    }
}

Write-Step "Writing HTML report..."
New-HtmlReport -Path $HtmlPath -Data $data

$resultRows = @(Get-ResultRows)
$errors = @($resultRows | Where-Object { $_.Severity -eq "Error" })
$warnings = @($resultRows | Where-Object { $_.Severity -eq "Warning" })
$top = @($resultRows | Where-Object { $_.Severity -in @("Error","Warning") } | Select-Object -First 5)

Write-Host ""
Write-Host "Network diagnostics finished." -ForegroundColor Green
Write-Host "HTML report: $HtmlPath" -ForegroundColor Cyan
if ($IncludeRawData) { Write-Host "JSON raw data: $JsonPath" -ForegroundColor Cyan }
$errorColor = if ($errors.Count -gt 0) { "Red" } else { "Green" }
$warningColor = if ($warnings.Count -gt 0) { "Yellow" } else { "Green" }
Write-Host ("Errors: {0}" -f $errors.Count) -ForegroundColor $errorColor
Write-Host ("Warnings: {0}" -f $warnings.Count) -ForegroundColor $warningColor
if ($top.Count -gt 0) {
    Write-Host ""
    Write-Host "Top issues:" -ForegroundColor Yellow
    foreach ($item in $top) {
        Write-Host ("- [{0}] {1}: {2} - {3}" -f $item.Severity, $item.Category, $item.Test, $item.Result) -ForegroundColor Yellow
    }
}

if ($OpenReport) {
    try { Start-Process -FilePath $HtmlPath | Out-Null } catch {}
}
