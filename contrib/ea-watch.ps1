<#
.SYNOPSIS
    Records which programs on this PC look up and talk to EA's servers, so you can check what
    skate. and ReSkate send to EA.

.DESCRIPTION
    Uses two event-tracing providers built into Windows; nothing is installed and the game is not
    touched:
      Microsoft-Windows-DNS-Client      every DNS lookup, with the program that made it
      Microsoft-Windows-Kernel-Network  every TCP/UDP connect, send and receive, with the program,
                                        the remote address and the size in bytes
    The traffic itself is encrypted; the report shows which EA hosts were looked up, by which
    program, and how many bytes went to and came from them.

    The game keeps the fast-travel artwork it downloads in its own cache and only fetches it from
    EA's image CDN when it is missing. To see those downloads, close the game and rename
    %LOCALAPPDATA%\ReSkate\Game\Skate\data\cache\http before recording; the game makes a new one.
    The report also warns about hosts-file entries and Windows Firewall rules that would hide or
    change what the game sends.

    Each recording gets its own folder, %LOCALAPPDATA%\ReSkate\ea-watch\<date>-<time>, holding the
    trace (ea-watch.etl), the report (ea-watch-report.txt) and CSV files with every lookup and
    connection. These list your IP addresses and the programs you ran, so read them before sharing.

    Recording needs an administrator PowerShell, because Windows only lets administrators start an
    event trace. Analysing a recording again (-Analyze) does not.

    Run it with Windows PowerShell (powershell.exe), which every Windows 10 and 11 PC has.
    -ExecutionPolicy Bypass in the examples applies to that one command only.

.PARAMETER Analyze
    Reads a recording again instead of making a new one: the newest one, or the folder in -OutDir.

.PARAMETER OutDir
    The folder to record into or analyse. Defaults to a new folder per recording (see above).

.PARAMETER MaxMinutes
    Stops the recording by itself after this many minutes (default 30).

.PARAMETER ReverseDns
    Names addresses no recorded lookup explains through reverse DNS. Each unanswered query waits
    for a timeout, so with many such addresses this takes minutes.

.PARAMETER MaxEvents
    Reads only this many trace events (0, the default, reads all); for timing a large trace.

.EXAMPLE
    # 1. Open Windows PowerShell as administrator (Start, type PowerShell, Run as administrator).
    # 2. Start recording, from the folder this script is in:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\ea-watch.ps1
    # 3. Start ReSkate from its launcher, play as usual, and quit with Quit Game.
    # 4. Press Enter in the recording window. The report is printed and saved.

.EXAMPLE
    # Read the newest recording again (no administrator rights needed):
    powershell -NoProfile -ExecutionPolicy Bypass -File .\ea-watch.ps1 -Analyze
#>
#Requires -PSEdition Desktop

param(
    [switch]$Analyze,
    [string]$OutDir,
    [int]$MaxMinutes = 30,
    [switch]$ReverseDns,
    [long]$MaxEvents = 0
)

$ErrorActionPreference = 'Stop'

$runsRoot = Join-Path $env:LOCALAPPDATA 'ReSkate\ea-watch'
if (-not $OutDir) {
    if ($Analyze) {
        $latest = Get-ChildItem -LiteralPath $runsRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'ea-watch.etl') } |
            Sort-Object Name -Descending | Select-Object -First 1
        if (-not $latest) { throw "No recording found under $runsRoot. Record one first, or pass -OutDir." }
        $OutDir = $latest.FullName
    } else {
        $OutDir = Join-Path $runsRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
    }
}

$session     = 'ReSkateEaWatch'
$etlPath     = Join-Path $OutDir 'ea-watch.etl'
$stopPath    = Join-Path $OutDir 'ea-watch.stop'
$procPath    = Join-Path $OutDir 'ea-watch-processes.csv'
$statsPath   = Join-Path $OutDir 'ea-watch-session.txt'
$envPath     = Join-Path $OutDir 'ea-watch-environment.txt'
$reportPath  = Join-Path $OutDir 'ea-watch-report.txt'
$dnsCsvPath  = Join-Path $OutDir 'ea-watch-dns.csv'
$flowCsvPath = Join-Path $OutDir 'ea-watch-flows.csv'

# Programs whose whole network activity is listed, EA or not.
$focusProcesses = @('Skate', 'ReSkateLauncher')

# 'service' for EA's online services, 'cdn' for the image CDN the fast-travel artwork comes from
# (ReSkate still uses it, for downloads only), nothing for other hosts.
function Get-EaKind([string]$Name) {
    if (-not $Name) { return $null }
    $Name = $Name.TrimEnd('.').ToLowerInvariant()
    if ($Name -match '(^|\.)(ea\.com|ea\.net|eadp\.com|origin\.com|tnt-ea\.com|easports\.com|eaplay\.com)$') { return 'service' }
    if ($Name -match '^dingo-[a-z0-9-]*\.akamaized\.net$') { return 'cdn' }
    return $null
}

# 159.153.0.0/16 is Electronic Arts' own address block (AS3402). EA services hosted on AWS or a
# CDN are only recognisable by the names they were looked up under.
function Test-EaAddress([string]$Address) {
    return $Address -match '^159\.153\.'
}

# Private, link-local, multicast and broadcast addresses: traffic that never leaves the local network.
function Test-LocalNetworkAddress([string]$Address) {
    return $Address -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.|22[4-9]\.|23\d\.|255\.255\.255\.255$|fe[89ab][0-9a-f]:|ff[0-9a-f]{2}:|f[cd][0-9a-f]{2}:)'
}

# Reading the trace is done in compiled code: PowerShell takes minutes over ~100k events.
Add-Type -ReferencedAssemblies 'System.Core' -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Diagnostics.Eventing.Reader;
using System.Net;
using System.Text.RegularExpressions;

public sealed class TraceFlow
{
    public int ProcessId;
    public string Process;
    public string Protocol;
    public string Address;
    public int Port;
    public int Connects;
    public long SentBytes;
    public int Sends;
    public long ReceivedBytes;
    public int Receives;
    public DateTime First;
    public DateTime Last;
}

public sealed class TraceLookup
{
    public DateTime Time;
    public int Event;
    public int ProcessId;
    public string Process;
    public string Name;
    public string Type;
    public string Status;
    public string Results;
}

public sealed class TraceResult
{
    public readonly List<TraceFlow> Flows = new List<TraceFlow>();
    public readonly List<TraceLookup> Lookups = new List<TraceLookup>();
    public readonly Dictionary<string, HashSet<string>> NamesByAddress =
        new Dictionary<string, HashSet<string>>(StringComparer.OrdinalIgnoreCase);
    public long Events, NetworkEvents, LoopbackEvents, DnsEvents;
    public DateTime First, Last;
    public double Seconds;
}

public static class TraceAnalysis
{
    static readonly Guid KernelNetwork = new Guid("7DD42A49-5329-4832-8DFD-43D979153A88");
    static readonly Guid DnsClient = new Guid("1C95126E-7EEA-49A9-A3FE-A378B03DDB4D");
    static readonly Regex DataPattern = new Regex("<Data Name=['\"](\\w+)['\"]>([^<]*)</Data>", RegexOptions.Compiled);
    static readonly Regex AliasPattern = new Regex(@"^type:\s*\d+\s+(\S+)$", RegexOptions.Compiled);

    // Kernel-Network event ids: 10/26 TCP sent, 11/27 TCP received, 12/28 TCP connect attempted,
    // 42/58 UDP sent, 43/59 UDP received (IPv4/IPv6). Their payload starts with
    // PID, size, daddr (the remote end), saddr, dport, sport.
    static int Kind(int id)
    {
        switch (id)
        {
            case 10: case 26: case 42: case 58: return 1;
            case 11: case 27: case 43: case 59: return 2;
            case 12: case 28: return 3;
            default: return 0;
        }
    }

    // IPv4 arrives as the four address bytes read as one little-endian number
    // (4211081440 = E0 00 00 FB backwards = 224.0.0.251); IPv6 as 16 bytes.
    static IPAddress Address(object value)
    {
        if (value is uint) return new IPAddress((long)(uint)value);
        if (value is int) return new IPAddress((long)(uint)(int)value);
        var bytes = value as byte[];
        if (bytes != null && (bytes.Length == 4 || bytes.Length == 16)) return new IPAddress(bytes);
        var text = value == null ? "" : value.ToString().Trim();
        uint number;
        if (uint.TryParse(text, out number)) return new IPAddress((long)number);
        if (text.Length == 32)
        {
            var parsed = new byte[16];
            for (int i = 0; i < 16; i++) parsed[i] = Convert.ToByte(text.Substring(i * 2, 2), 16);
            return new IPAddress(parsed);
        }
        IPAddress address;
        return IPAddress.TryParse(text, out address) ? address : null;
    }

    // Ports arrive in network byte order: 47873 is 0xBB01, port 0x01BB = 443.
    static int Port(object value)
    {
        int raw = Convert.ToInt32(value);
        return ((raw & 0xFF) << 8) | ((raw >> 8) & 0xFF);
    }

    static string Text(Dictionary<string, string> data, string name)
    {
        string value;
        return data.TryGetValue(name, out value) ? value : null;
    }

    public static TraceResult Run(string path, long maxEvents)
    {
        var watch = Stopwatch.StartNew();
        var result = new TraceResult();
        var flows = new Dictionary<string, TraceFlow>();
        using (var reader = new EventLogReader(new EventLogQuery(path, PathType.FilePath)))
        {
            for (EventRecord record = reader.ReadEvent(); record != null; record = reader.ReadEvent())
            {
                using (record)
                {
                    if (maxEvents > 0 && result.Events >= maxEvents) break;
                    result.Events++;
                    var time = record.TimeCreated ?? DateTime.MinValue;
                    if (result.Events == 1) result.First = time;
                    result.Last = time;
                    var provider = record.ProviderId ?? Guid.Empty;

                    if (provider == KernelNetwork)
                    {
                        int kind = Kind(record.Id);
                        if (kind == 0) continue;
                        var properties = record.Properties;
                        if (properties.Count < 6) continue;
                        var address = Address(properties[2].Value);
                        if (address == null) continue;
                        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
                        if (IPAddress.IsLoopback(address)) { result.LoopbackEvents++; continue; }
                        result.NetworkEvents++;

                        int pid = Convert.ToInt32(properties[0].Value);
                        long size = Convert.ToInt64(properties[1].Value);
                        int port = Port(properties[4].Value);
                        string protocol = record.Id < 40 ? "TCP" : "UDP";
                        string text = address.ToString();
                        string key = pid + "|" + protocol + "|" + text + "|" + port;
                        TraceFlow flow;
                        if (!flows.TryGetValue(key, out flow))
                        {
                            flow = new TraceFlow { ProcessId = pid, Protocol = protocol, Address = text, Port = port, First = time };
                            flows[key] = flow;
                            result.Flows.Add(flow);
                        }
                        flow.Last = time;
                        if (kind == 1) { flow.SentBytes += size; flow.Sends++; }
                        else if (kind == 2) { flow.ReceivedBytes += size; flow.Receives++; }
                        else flow.Connects++;
                    }
                    else if (provider == DnsClient && (record.Id == 3006 || record.Id == 3008))
                    {
                        result.DnsEvents++;
                        var data = new Dictionary<string, string>();
                        foreach (Match m in DataPattern.Matches(record.ToXml())) data[m.Groups[1].Value] = m.Groups[2].Value;
                        var name = Text(data, "QueryName");
                        if (string.IsNullOrEmpty(name)) continue;
                        var results = Text(data, "QueryResults");
                        result.Lookups.Add(new TraceLookup {
                            Time = time, Event = record.Id, ProcessId = record.ProcessId ?? 0, Name = name,
                            Type = Text(data, "QueryType"), Status = Text(data, "QueryStatus"), Results = results });

                        // "type:  5 alias.example;::ffff:1.2.3.4;" - CNAME targets and addresses, ';'-separated.
                        if (record.Id != 3008 || string.IsNullOrEmpty(results)) continue;
                        var aliases = new List<string> { name };
                        foreach (var raw in results.Split(';'))
                        {
                            var token = raw.Trim();
                            if (token.Length == 0) continue;
                            var alias = AliasPattern.Match(token);
                            if (alias.Success) { aliases.Add(alias.Groups[1].Value); continue; }
                            IPAddress answer;
                            if (!IPAddress.TryParse(token, out answer)) continue;
                            if (answer.IsIPv4MappedToIPv6) answer = answer.MapToIPv4();
                            HashSet<string> names;
                            if (!result.NamesByAddress.TryGetValue(answer.ToString(), out names))
                            {
                                names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                                result.NamesByAddress[answer.ToString()] = names;
                            }
                            foreach (var n in aliases) names.Add(n);
                        }
                    }
                }
            }
        }
        result.Seconds = watch.Elapsed.TotalSeconds;
        return result;
    }
}
'@

# logman reports its own failures through the exit code; its output is only shown on failure.
function Invoke-Logman([string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & logman @Arguments 2>&1 | Out-String } finally { $ErrorActionPreference = $previous }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output.Trim() }
}

function Start-Recording {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Recording needs an administrator PowerShell (Start, type PowerShell, Run as administrator).'
    }

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    [void](Invoke-Logman @('stop', $session, '-ets'))
    Remove-Item -LiteralPath $etlPath, $stopPath -ErrorAction SilentlyContinue

    # What would make the report misleading: a hosts-file entry answers a lookup before DNS sees
    # it, and a firewall rule stops a connection before it opens (blocked UDP still shows as sent).
    $environment = New-Object System.Collections.Generic.List[string]
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    foreach ($line in Get-Content -LiteralPath $hostsPath -ErrorAction SilentlyContinue) {
        $entry = ($line -replace '#.*$', '').Trim()
        if ($entry -and @($entry -split '\s+' | Select-Object -Skip 1 | Where-Object { Get-EaKind $_ }).Count) {
            $environment.Add("The hosts file has '$entry', so lookups of that name are answered on this PC and its traffic does not show as it would without it.")
        }
    }
    try {
        foreach ($filter in Get-NetFirewallApplicationFilter -ErrorAction Stop | Where-Object { $_.Program -match '\\(Skate|ReSkateLauncher)\.exe$' }) {
            foreach ($rule in $filter | Get-NetFirewallRule | Where-Object { "$($_.Enabled)" -eq 'True' -and "$($_.Action)" -eq 'Block' }) {
                $environment.Add("Windows Firewall rule '$($rule.DisplayName)' blocks $("$($rule.Direction)".ToLowerInvariant()) traffic of $($filter.Program), so connections it stops do not show and what shows as sent may not have left this PC.")
            }
        }
    } catch {
        $environment.Add("Windows Firewall rules could not be read ($($_.Exception.Message)), so rules that block the game were not checked.")
    }
    $environment | Set-Content -LiteralPath $envPath -Encoding utf8

    # Lookups answered from the cache are still logged, but flushing makes every
    # name the game needs go through a fresh, visible lookup.
    Clear-DnsClientCache

    # Flags and levels are quoted: unquoted, PowerShell would turn 0xffffffffffffffff into -1.
    $start = Invoke-Logman @('start', $session, '-p', 'Microsoft-Windows-Kernel-Network', '0x30', '5',
        '-o', $etlPath, '-bs', '1024', '-nb', '64', '512', '-ets')
    if ($start.ExitCode -ne 0) { throw "logman could not start the trace session: $($start.Output)" }
    $update = Invoke-Logman @('update', 'trace', $session, '-p', 'Microsoft-Windows-DNS-Client', '0xffffffffffffffff', '5', '-ets')
    if ($update.ExitCode -ne 0) {
        [void](Invoke-Logman @('stop', $session, '-ets'))
        throw "logman could not add the DNS client provider: $($update.Output)"
    }

    $processes = @{}
    $started = Get-Date
    $deadline = $started.AddMinutes($MaxMinutes)
    Write-Host ''
    Write-Host "Recording since $($started.ToString('HH:mm:ss')) into $OutDir" -ForegroundColor Green
    Write-Host 'Start ReSkate from its launcher now, play, and quit with Quit Game.' -ForegroundColor Green
    Write-Host "Then press Enter here. It stops by itself after $MaxMinutes minutes." -ForegroundColor Green

    $keysReadable = $true
    try {
        while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $stopPath)) {
            # Kernel-Network only gives process ids, so names are collected while processes live.
            foreach ($p in Get-Process) {
                $existing = $processes[$p.Id]
                if (-not $existing) { $processes[$p.Id] = $p.ProcessName }
                elseif (($existing -split '/') -notcontains $p.ProcessName) { $processes[$p.Id] = "$existing/$($p.ProcessName)" }
            }
            $enter = $false
            if ($keysReadable) {
                try {
                    while ($Host.UI.RawUI.KeyAvailable) {
                        $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown,IncludeKeyUp')
                        if ($key.KeyDown -and $key.VirtualKeyCode -eq 13) { $enter = $true }
                    }
                } catch {
                    # Hosts without a console (PowerShell ISE, redirected input) cannot report key presses.
                    $keysReadable = $false
                    Write-Host "This window cannot detect key presses ($($_.Exception.Message))." -ForegroundColor Yellow
                    Write-Host "To stop, create the file $stopPath" -ForegroundColor Yellow
                }
            }
            if ($enter) { break }
            Start-Sleep -Milliseconds 300
        }
    } finally {
        (Invoke-Logman @('query', $session, '-ets')).Output | Set-Content -LiteralPath $statsPath -Encoding utf8
        $stop = Invoke-Logman @('stop', $session, '-ets')
        if ($stop.ExitCode -ne 0) { Write-Warning "logman could not stop the trace session: $($stop.Output)" }
        $processes.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Id = $_.Key; Name = $_.Value } } |
            Export-Csv -LiteralPath $procPath -NoTypeInformation -Encoding utf8
        Remove-Item -LiteralPath $stopPath -ErrorAction SilentlyContinue
    }
    Write-Host "Recording stopped at $((Get-Date).ToString('HH:mm:ss')). Analysing..." -ForegroundColor Green
}

function Invoke-Analysis {
    if (-not (Test-Path -LiteralPath $etlPath)) { throw "No trace at $etlPath." }

    $processes = @{}
    if (Test-Path -LiteralPath $procPath) {
        Import-Csv -LiteralPath $procPath | ForEach-Object { $processes[[int]$_.Id] = $_.Name }
    }
    function Get-ProcessLabel([int]$Id) {
        $name = $processes[$Id]
        if ($name) { return "$name($Id)" }
        return "pid $Id (name not captured)"
    }

    $result = [TraceAnalysis]::Run($etlPath, $MaxEvents)
    foreach ($f in $result.Flows) { $f.Process = Get-ProcessLabel $f.ProcessId }
    foreach ($l in $result.Lookups) { $l.Process = Get-ProcessLabel $l.ProcessId }

    $namesByAddress = $result.NamesByAddress
    function Get-Names([string]$Address) {
        if ($Address -and $namesByAddress.ContainsKey($Address)) { return @($namesByAddress[$Address]) }
        return @()
    }
    # A flow counts as an EA service when any name its address was looked up under is one.
    function Get-FlowKind($Flow) {
        if (Test-EaAddress $Flow.Address) { return 'service' }
        $kinds = @(Get-Names $Flow.Address | ForEach-Object { Get-EaKind $_ })
        if ($kinds -contains 'service') { return 'service' }
        if ($kinds -contains 'cdn') { return 'cdn' }
        return $null
    }
    function Format-Flow($Flow) {
        $names = (Get-Names $Flow.Address) -join ', '
        if (-not $names) { $names = 'no lookup recorded' }
        '{0,-28} {1} {2}:{3}  [{4}]  connects {5}, sent {6:N0} B in {7}, received {8:N0} B in {9}, {10:HH:mm:ss.fff}-{11:HH:mm:ss.fff}' -f
            $Flow.Process, $Flow.Protocol, $Flow.Address, $Flow.Port, $names, $Flow.Connects,
            $Flow.SentBytes, $Flow.Sends, $Flow.ReceivedBytes, $Flow.Receives, $Flow.First, $Flow.Last
    }
    function Format-Targets($Flows) {
        ($Flows | ForEach-Object {
            $n = (Get-Names $_.Address) -join '/'
            if (-not $n) { $n = $_.Address }
            "$n ($($_.Address):$($_.Port))"
        } | Select-Object -Unique) -join ', '
    }

    $allFlows = @($result.Flows | Sort-Object First)
    # Windows itself (System, pid 4) sends NetBIOS name queries (UDP 137) to addresses this PC has
    # just connected to; they are not the game's traffic.
    $isNetBios = { $_.ProcessId -eq 4 -and $_.Protocol -eq 'UDP' -and $_.Port -eq 137 }
    $eaFlows = @($allFlows | Where-Object { Get-FlowKind $_ })
    $netBiosQueries = @($eaFlows | Where-Object $isNetBios).Count
    $eaFlows = @($eaFlows | Where-Object { -not (& $isNetBios) })
    $serviceFlows = @($eaFlows | Where-Object { (Get-FlowKind $_) -eq 'service' })
    $cdnFlows = @($eaFlows | Where-Object { (Get-FlowKind $_) -eq 'cdn' })
    # Tools that read the DNS cache through WMI (Get-DnsClientCache) show up as lookups by WmiPrvSE;
    # those are cache reads, not a program contacting the host.
    $isEaLookup = { $_.Event -eq 3006 -and (Get-EaKind $_.Name) }
    $cacheReaders = @($result.Lookups | Where-Object $isEaLookup | Where-Object { $_.Process -like 'WmiPrvSE(*' })
    $eaLookups = @($result.Lookups | Where-Object $isEaLookup | Where-Object { $_.Process -notlike 'WmiPrvSE(*' } | Sort-Object Time)
    $eaAnswers = @($result.Lookups | Where-Object { $_.Event -eq 3008 -and $_.Status -eq '0' -and (Get-EaKind $_.Name) })
    $focusIds = @($processes.GetEnumerator() | Where-Object { ($_.Value -split '/') | Where-Object { $focusProcesses -contains $_ } } | ForEach-Object { [int]$_.Key })
    $focusFlows = @($allFlows | Where-Object { $focusIds -contains $_.ProcessId })
    $focusListed = @($focusFlows | Where-Object { $_.Protocol -eq 'TCP' -or -not (Test-LocalNetworkAddress $_.Address) })
    $focusLocal = $focusFlows.Count - $focusListed.Count

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('ReSkate EA traffic watch')
    $lines.Add(('Recorded {0:yyyy-MM-dd HH:mm:ss} to {1:HH:mm:ss}; {2:N0} events read in {3:N1} s ({4:N0} network, {5:N0} loopback network left out, {6:N0} DNS).' -f
        $result.First, $result.Last, $result.Events, $result.Seconds, $result.NetworkEvents, $result.LoopbackEvents, $result.DnsEvents))
    if (Test-Path -LiteralPath $statsPath) {
        $lost = Get-Content -LiteralPath $statsPath | Where-Object { $_ -match 'Lost' }
        if ($lost) { $lines.Add('Trace session: ' + (($lost | ForEach-Object { $_.Trim() }) -join '; ')) }
    }
    if ($MaxEvents -gt 0) { $lines.Add("NOTE: only the first $MaxEvents events were read (-MaxEvents).") }
    if ($result.NetworkEvents -eq 0) { $lines.Add('WARNING: no network events were recorded, so this capture cannot show traffic.') }
    if ($result.DnsEvents -eq 0) { $lines.Add('WARNING: no DNS events were recorded, so this capture cannot show lookups.') }
    if ($focusIds.Count -eq 0) { $lines.Add('WARNING: Skate.exe and ReSkateLauncher.exe were not running during the recording.') }
    if (Test-Path -LiteralPath $envPath) {
        Get-Content -LiteralPath $envPath | Where-Object { $_ } | ForEach-Object { $lines.Add("WARNING: $_") }
    }
    if ($netBiosQueries -gt 0) {
        $lines.Add("NOTE: $netBiosQueries NetBIOS name queries (UDP 137) that Windows itself sent to EA addresses are left out; they are not the game's traffic.")
    }

    $lines.Add('')
    $lines.Add('== 1. EA hostnames looked up, and by which program ==')
    if ($cacheReaders.Count -gt 0) { $lines.Add("($($cacheReaders.Count) DNS cache reads through WMI (WmiPrvSE) left out.)") }
    if ($eaLookups.Count -eq 0) { $lines.Add('(none)') }
    foreach ($l in $eaLookups) {
        $answer = $eaAnswers | Where-Object { $_.Name -eq $l.Name -and $_.ProcessId -eq $l.ProcessId -and $_.Time -ge $l.Time } |
            Sort-Object Time | Select-Object -First 1
        $answerText = if ($answer) { $answer.Results } else { 'no answer recorded' }
        $lines.Add(('{0:HH:mm:ss.fff}  {1,-28} {2}  -> {3}' -f $l.Time, $l.Process, $l.Name, $answerText))
    }

    $lines.Add('')
    $lines.Add('== 2. Traffic to or from EA services ==')
    if ($serviceFlows.Count -eq 0) { $lines.Add('(none)') }
    foreach ($f in $serviceFlows) { $lines.Add((Format-Flow $f)) }

    $lines.Add('')
    $lines.Add("== 3. Traffic to or from EA's image CDN (fast-travel artwork downloads) ==")
    if ($cdnFlows.Count -eq 0) {
        $lines.Add('(none) The game only downloads artwork missing from its cache. To record these downloads, close the game')
        $lines.Add('and rename %LOCALAPPDATA%\ReSkate\Game\Skate\data\cache\http before recording.')
    }
    foreach ($f in $cdnFlows) { $lines.Add((Format-Flow $f)) }

    $lines.Add('')
    $lines.Add('== 4. Verdict ==')
    $serviceSent = @($serviceFlows | Where-Object { $_.SentBytes -gt 0 })
    if ($serviceSent.Count -gt 0) {
        $lines.Add('DATA WAS SENT TO EA SERVICES:')
        foreach ($group in $serviceSent | Group-Object Process) {
            $bytes = ($group.Group | Measure-Object SentBytes -Sum).Sum
            $lines.Add(('  {0} sent {1:N0} bytes to {2}' -f $group.Name, $bytes, (Format-Targets $group.Group)))
        }
    } elseif (@($eaLookups | Where-Object { (Get-EaKind $_.Name) -eq 'service' }).Count -gt 0) {
        $lines.Add('EA service hostnames were looked up, but no data was sent to their addresses.')
    } else {
        $lines.Add('No EA service was looked up or contacted.')
    }
    foreach ($group in $cdnFlows | Group-Object Process) {
        $sent = ($group.Group | Measure-Object SentBytes -Sum).Sum
        $received = ($group.Group | Measure-Object ReceivedBytes -Sum).Sum
        $lines.Add(('CDN downloads: {0} sent {1:N0} bytes of requests and received {2:N0} bytes from {3}' -f
            $group.Name, $sent, $received, (Format-Targets $group.Group)))
    }

    $lines.Add('')
    $lines.Add("== 5. Traffic of $($focusProcesses -join ' / '): all TCP, and UDP beyond the local network ==")
    if ($focusLocal -gt 0) { $lines.Add("($focusLocal UDP flows to local-network, broadcast or multicast addresses left out.)") }
    if ($focusListed.Count -eq 0) { $lines.Add('(none)') }
    $ptrTried = @{}
    foreach ($f in $focusListed) {
        if ($ReverseDns -and (Get-Names $f.Address).Count -eq 0 -and -not $ptrTried.ContainsKey($f.Address)) {
            $ptrTried[$f.Address] = $true
            $ptr = try { (Resolve-DnsName -Type PTR $f.Address -QuickTimeout -ErrorAction Stop | Select-Object -First 1).NameHost } catch { $null }
            if ($ptr) {
                $set = New-Object 'System.Collections.Generic.HashSet[string]'
                [void]$set.Add("reverse DNS: $ptr")
                $namesByAddress[$f.Address] = $set
            }
        }
        $lines.Add((Format-Flow $f))
    }

    $lines | Set-Content -LiteralPath $reportPath -Encoding utf8
    $result.Lookups | Sort-Object Time | Select-Object Time, Event, Process, ProcessId, Name, Type, Status, Results |
        Export-Csv -LiteralPath $dnsCsvPath -NoTypeInformation -Encoding utf8
    $allFlows | Select-Object Process, ProcessId, Protocol, Address, Port,
        @{ n = 'Names'; e = { (Get-Names $_.Address) -join ', ' } }, @{ n = 'EA'; e = { Get-FlowKind $_ } },
        Connects, SentBytes, Sends, ReceivedBytes, Receives, First, Last |
        Export-Csv -LiteralPath $flowCsvPath -NoTypeInformation -Encoding utf8

    $lines | ForEach-Object { Write-Host $_ }
    Write-Host ''
    Write-Host "Report: $reportPath" -ForegroundColor Green
}

if (-not $Analyze) { Start-Recording }
Invoke-Analysis
