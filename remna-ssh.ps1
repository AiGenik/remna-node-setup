# Помощник подключения к нодам Remnawave по SSH для Windows PowerShell.
# Поддерживает Windows PowerShell 5.1+, PowerShell 7+, встроенный OpenSSH (Windows 10/11) и Git OpenSSH.

$ErrorActionPreference = 'Stop'

function Show-Usage([bool]$ToStderr = $false) {
    $writer = if ($ToStderr) { [Console]::Error } else { [Console]::Out }
    $writer.WriteLine('Использование: remna-ssh [--port PORT] [--panel SSH_АЛИАС] [--bootstrap] [[user@]host]')
    $writer.WriteLine('Без аргументов в терминале запускает пошаговый мастер подключения и автоустановки на новый VPS.')
    $writer.WriteLine('Короткая команда после установки клиента: rns')
    $writer.WriteLine('Можно указать имена из ~/.ssh/config.')
}

function Enable-VirtualTerminal {
    try {
        if ([Console]::IsOutputRedirected) { return }
        if (-not ('RemnaWin32Console' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RemnaWin32Console {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
}
'@ -ErrorAction Stop
        }
        $hOut = [RemnaWin32Console]::GetStdHandle(-11)
        [uint32]$mode = 0
        if ([RemnaWin32Console]::GetConsoleMode($hOut, [ref]$mode)) {
            [void][RemnaWin32Console]::SetConsoleMode($hOut, ($mode -bor 0x0004))
        }
    } catch {}
}

function Test-SshTarget([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return $false }
    if ($Value.StartsWith('-')) { return $false }
    if ($Value -match '[\s\x00-\x1f\x7f]') { return $false }
    return $true
}

function Test-ValidPortNumber([string]$Value) {
    if ($Value -notmatch '^[1-9][0-9]{0,4}$') { return $false }
    return ([int]$Value -le 65535)
}

function Get-UserHomeDir {
    if ($env:HOME -and (Test-Path -LiteralPath $env:HOME -PathType Container)) { return $env:HOME }
    if ($env:USERPROFILE) { return $env:USERPROFILE }
    if ($HOME) { return $HOME }
    return [Environment]::GetFolderPath('UserProfile')
}

function Get-SshExecutable {
    if ($env:REMNA_SSH_BIN -and (Test-Path -LiteralPath $env:REMNA_SSH_BIN -PathType Leaf)) {
        return $env:REMNA_SSH_BIN
    }
    $cmd = Get-Command ssh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd -and $cmd.Source) {
        return $cmd.Source
    }
    if ($env:SystemRoot) {
        $winSsh = Join-Path (Join-Path (Join-Path $env:SystemRoot 'System32') 'OpenSSH') 'ssh.exe'
        if (Test-Path -LiteralPath $winSsh -PathType Leaf) {
            return $winSsh
        }
    }
    return $null
}

function Format-Win32Arg([string]$Arg) {
    if ($null -eq $Arg) { return '""' }
    if ($Arg.Length -gt 0 -and $Arg -notmatch '[\s"]') {
        return $Arg
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashes = 0
    foreach ($ch in $Arg.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashes++
        } elseif ($ch -eq '"') {
            if ($backslashes -gt 0) {
                [void]$sb.Append('\', $backslashes * 2)
                $backslashes = 0
            }
            [void]$sb.Append('\"')
        } else {
            if ($backslashes -gt 0) {
                [void]$sb.Append('\', $backslashes)
                $backslashes = 0
            }
            [void]$sb.Append($ch)
        }
    }
    if ($backslashes -gt 0) {
        [void]$sb.Append('\', $backslashes * 2)
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Format-Win32CommandLine([string[]]$ArgList) {
    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in $ArgList) {
        [void]$parts.Add((Format-Win32Arg $item))
    }
    return ($parts.ToArray() -join ' ')
}

function Invoke-CaptureProcess([string]$ExePath, [string[]]$ArgList, [int]$TimeoutMs = 5000) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ExePath
    $psi.Arguments = Format-Win32CommandLine $ArgList
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        try { $proc.StandardInput.Close() } catch {}
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutMs)) {
            try { $proc.Kill() } catch {}
            return @{ ExitCode = -1; Stdout = ''; Stderr = '' }
        }
        $proc.WaitForExit()
        return @{
            ExitCode = $proc.ExitCode
            Stdout = $outTask.GetAwaiter().GetResult()
            Stderr = $errTask.GetAwaiter().GetResult()
        }
    } finally {
        $proc.Dispose()
    }
}

function Test-SshOptionGroup([string]$SshExe, [string]$EmptyConfig, [string[]]$Options) {
    $probeArgs = New-Object 'System.Collections.Generic.List[string]'
    [void]$probeArgs.Add('-G')
    [void]$probeArgs.Add('-F')
    [void]$probeArgs.Add($EmptyConfig)
    foreach ($opt in $Options) {
        [void]$probeArgs.Add('-o')
        [void]$probeArgs.Add($opt)
    }
    [void]$probeArgs.Add('127.0.0.1')
    $res = Invoke-CaptureProcess $SshExe $probeArgs.ToArray() 5000
    return ($res.ExitCode -eq 0)
}

function Get-SupportedSshSecurityOptions([string]$SshExe) {
    $opts = New-Object 'System.Collections.Generic.List[string]'
    $emptyCfg = [System.IO.Path]::GetTempFileName()
    try {
        if (Test-SshOptionGroup $SshExe $emptyCfg @('ControlMaster=no', 'ControlPath=none', 'ControlPersist=no')) {
            [void]$opts.Add('-o'); [void]$opts.Add('ControlMaster=no')
            [void]$opts.Add('-o'); [void]$opts.Add('ControlPath=none')
            [void]$opts.Add('-o'); [void]$opts.Add('ControlPersist=no')
        }
        if (Test-SshOptionGroup $SshExe $emptyCfg @('ClearAllForwardings=yes')) {
            [void]$opts.Add('-o'); [void]$opts.Add('ClearAllForwardings=yes')
        }
        [void]$opts.Add('-o'); [void]$opts.Add('ForwardAgent=no')
        if (Test-SshOptionGroup $SshExe $emptyCfg @('RemoteCommand=none')) {
            [void]$opts.Add('-o'); [void]$opts.Add('RemoteCommand=none')
        }
    } finally {
        Remove-Item -LiteralPath $emptyCfg -Force -ErrorAction SilentlyContinue
    }
    return $opts.ToArray()
}

function Invoke-SshQuery([string]$SshExe, [string]$Destination) {
    $res = Invoke-CaptureProcess $SshExe @('-G', $Destination) 5000
    if ($res.ExitCode -ne 0 -or -not $res.Stdout) { return ,@() }
    return ,($res.Stdout -split "\r?\n")
}

function Get-SshConfigAliases([string]$HomeDir) {
    $cfg = Join-Path (Join-Path $HomeDir '.ssh') 'config'
    $list = New-Object 'System.Collections.Generic.List[string]'
    if (-not (Test-Path -LiteralPath $cfg -PathType Leaf)) { return ,$list.ToArray() }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    try {
        $lines = [System.IO.File]::ReadAllLines($cfg, [System.Text.Encoding]::UTF8)
    } catch {
        return ,$list.ToArray()
    }
    foreach ($line in $lines) {
        if ($line -match '^\s*[Hh][Oo][Ss][Tt](?:\s+|=)(.+)$') {
            $rest = $Matches[1]
            $tokens = $rest.Trim() -split '\s+'
            foreach ($tok in $tokens) {
                if ([string]::IsNullOrEmpty($tok)) { continue }
                if ($tok.StartsWith('#')) { break }
                if ($tok -match '[*?!]') { continue }
                if ($seen.Add($tok)) {
                    [void]$list.Add($tok)
                }
            }
        }
    }
    return ,$list.ToArray()
}

function Test-HasHostAlias([string[]]$Aliases, [string]$Target) {
    foreach ($alias in $Aliases) {
        if ($alias -ceq $Target) { return $true }
    }
    return $false
}

function Get-SavedPanelFile([string]$HomeDir) {
    return (Join-Path (Join-Path (Join-Path $HomeDir '.config') 'remna-node-setup') 'panel')
}

function Get-SavedPanel([string]$HomeDir) {
    $file = Get-SavedPanelFile $HomeDir
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return '' }
    try {
        $attrs = [System.IO.File]::GetAttributes($file)
        if (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return '' }
        $lines = [System.IO.File]::ReadAllLines($file, [System.Text.Encoding]::UTF8)
        if ($lines.Count -gt 0) { return $lines[0].TrimEnd("`r") }
    } catch {}
    return ''
}

function Save-PanelChoice([string]$HomeDir, [string]$Value) {
    $file = Get-SavedPanelFile $HomeDir
    $dir = Split-Path -Parent $file
    try {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $tmp = Join-Path $dir ('.panel.' + [System.Guid]::NewGuid().ToString('N').Substring(0, 6))
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tmp, ($Value + "`n"), $utf8NoBom)
        Move-Item -LiteralPath $tmp -Destination $file -Force
    } catch {}
}

function Invoke-InteractiveSetup(
    [string]$SshExe,
    [string]$HomeDir,
    [bool]$HasPortFlag,
    [ref]$DestinationRef,
    [ref]$PanelRef,
    [System.Collections.Generic.List[string]]$SshOptions
) {
    $esc = [char]27
    $aliases = Get-SshConfigAliases $HomeDir

    [Console]::Out.Write("`n  $esc[1;96m╭─[  ◉  ]─╮$esc[0m  $esc[1mREMNA-SSH · подключение к ноде$esc[0m`n")
    [Console]::Out.Write("  $esc[2m────────────────────────────────────────────$esc[0m`n`n")
    [Console]::Out.Flush()

    while ($true) {
        [Console]::Out.Write("  $esc[1mАдрес новой ноды$esc[0m (IP, user@IP или хост из ~/.ssh/config) → ")
        [Console]::Out.Flush()
        $rawDest = [Console]::ReadLine()
        if ($null -eq $rawDest) { return $false }
        $rawDest = $rawDest.Trim()
        if (-not (Test-SshTarget $rawDest)) {
            [Console]::Error.WriteLine("  $esc[1;93mУкажите корректный IP, домен или SSH-алиас.$esc[0m")
            continue
        }
        if (($rawDest -notmatch '@') -and (-not (Test-HasHostAlias $aliases $rawDest))) {
            $rawDest = "root@$rawDest"
        }
        $DestinationRef.Value = $rawDest
        break
    }

    $destHost = $DestinationRef.Value
    if ($destHost.Contains('@')) {
        $destHost = $destHost.Substring($destHost.IndexOf('@') + 1)
    }

    if (-not $HasPortFlag) {
        $detectedPort = '22'
        foreach ($line in (Invoke-SshQuery $SshExe $DestinationRef.Value)) {
            if ($line -match '^\s*port\s+(\d+)\s*$') {
                $detectedPort = $Matches[1]
                break
            }
        }
        if (-not (Test-HasHostAlias $aliases $destHost)) {
            while ($true) {
                [Console]::Out.Write("  $esc[1mПорт SSH ноды$esc[0m [$detectedPort] → ")
                [Console]::Out.Flush()
                $portInput = [Console]::ReadLine()
                if ($null -eq $portInput) { return $false }
                $portInput = $portInput.Trim()
                if ([string]::IsNullOrEmpty($portInput)) { $portInput = $detectedPort }
                if (Test-ValidPortNumber $portInput) {
                    if ($portInput -ne '22') {
                        [void]$SshOptions.Add('-p')
                        [void]$SshOptions.Add($portInput)
                    }
                    break
                }
                [Console]::Error.WriteLine("  $esc[1;93mВведите порт 1–65535.$esc[0m")
            }
        }
    }

    if ([string]::IsNullOrEmpty($PanelRef.Value)) {
        $savedPanel = Get-SavedPanel $HomeDir
        $panelAliases = New-Object 'System.Collections.Generic.List[string]'
        foreach ($item in $aliases) {
            if ($item -ceq $DestinationRef.Value -or $item -ceq $destHost) { continue }
            [void]$panelAliases.Add($item)
        }
        $defaultPanel = ''
        if (-not [string]::IsNullOrEmpty($savedPanel) -and (Test-SshTarget $savedPanel)) {
            $defaultPanel = $savedPanel
        } elseif ($panelAliases.Count -eq 1) {
            $defaultPanel = $panelAliases[0]
        }

        [Console]::Out.Write("`n  $esc[1mПанель Remnawave для проверки связи$esc[0m (только локально):`n")
        $i = 0
        foreach ($item in $panelAliases) {
            $i++
            if ($item -ceq $defaultPanel) {
                [Console]::Out.Write(("    $esc[1;96m[{0,2}]$esc[0m {1} $esc[2m(по умолчанию)$esc[0m`n" -f $i, $item))
            } else {
                [Console]::Out.Write(("    $esc[1;96m[{0,2}]$esc[0m {1}`n" -f $i, $item))
            }
        }
        [Console]::Out.Write("    $esc[2m[ 0] Без проверки с панели$esc[0m`n")
        [Console]::Out.Flush()

        $promptDefault = if ($defaultPanel) { $defaultPanel } else { '0' }
        while ($true) {
            [Console]::Out.Write("  Выбор панели (номер или SSH-адрес) [$promptDefault] → ")
            [Console]::Out.Flush()
            $choice = [Console]::ReadLine()
            if ($null -eq $choice) { return $false }
            $choice = $choice.Trim()
            if ([string]::IsNullOrEmpty($choice)) {
                $PanelRef.Value = $defaultPanel
                break
            } elseif ($choice -eq '0' -or $choice -eq 'none') {
                $PanelRef.Value = ''
                break
            } elseif ($choice -match '^[1-9][0-9]*$' -and ([int]$choice -le $panelAliases.Count)) {
                $PanelRef.Value = $panelAliases[[int]$choice - 1]
                break
            } elseif (Test-SshTarget $choice) {
                $PanelRef.Value = $choice
                break
            } else {
                [Console]::Error.WriteLine("  $esc[1;93mВыберите номер из списка или введите адрес SSH.$esc[0m")
            }
        }
        if (-not [string]::IsNullOrEmpty($PanelRef.Value)) {
            Save-PanelChoice $HomeDir $PanelRef.Value
        }
    }

    return $true
}

function New-RandomTicket {
    $bytes = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

function Quote-PosixArg([string]$Value) {
    if ($Value -match '^[A-Za-z0-9_@%+=:,./-]+$') { return $Value }
    return "'" + ($Value -replace "'", "'\''") + "'"
}

function Test-JsonPort($Value) {
    if ($null -eq $Value) { return $false }
    if (-not (($Value -is [int]) -or ($Value -is [long]))) { return $false }
    return ($Value -ge 1 -and $Value -le 65535)
}

function Invoke-PanelMenu(
    [string]$SshExe,
    [string[]]$PanelSshBaseOpts,
    [string]$Panel,
    [string]$ProbeHost,
    [string]$Ticket,
    [string[]]$MenuSshArgs
) {
    $panelClient = @'
from concurrent.futures import ThreadPoolExecutor
import json
import socket
import ssl
import sys

args = sys.argv[1:]
extra = {}
if args[:1] == ["--extra"]:
    extra = json.loads(args[1])
    args = args[2:]

host, token, tls_port, *ports = args
udp_ports = extra.get("udp", [])
busy_ports = extra.get("busy", [])
ack = token.encode()
body = ack * 128
tls_status = b""

def check_tls(port):
    try:
        conn = socket.create_connection((host, int(port)), timeout=4)
    except socket.gaierror:
        return "dns"
    except TimeoutError:
        return "tcp_timeout"
    except ConnectionRefusedError:
        return "refused"
    except OSError:
        return "unreachable"
    with conn:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        try:
            with context.wrap_socket(conn, server_hostname=host):
                return "ok"
        except TimeoutError:
            return "tls_timeout"
        except (OSError, ValueError):
            return "tls_error"

def check_tcp_open(port):
    try:
        with socket.create_connection((host, int(port)), timeout=4):
            return "ok"
    except socket.gaierror:
        return "dns"
    except TimeoutError:
        return "tcp_timeout"
    except ConnectionRefusedError:
        return "refused"
    except OSError:
        return "unreachable"

def check_udp(port):
    try:
        family = socket.AF_INET6 if ":" in host else socket.AF_INET
        with socket.socket(family, socket.SOCK_DGRAM) as conn:
            conn.settimeout(4)
            conn.sendto(body, (host, int(port)))
            reply, _ = conn.recvfrom(len(body) + 128)
            return "ok" if reply == body else "incomplete"
    except TimeoutError:
        return "udp_timeout"
    except OSError:
        return "unreachable"

tls_result = check_tls(tls_port) if tls_port != "0" else None
if tls_result is not None:
    tls_status = b"+" if tls_result == "ok" else b"-"

def check(port):
    try:
        with socket.create_connection((host, int(port)), timeout=4) as conn:
            conn.sendall(body)
            with conn.makefile("rb") as reply:
                if reply.read(len(body)) != body:
                    return False
                conn.sendall(ack + tls_status)
                return reply.read(1) == b"+"
    except OSError:
        return False

with ThreadPoolExecutor(max_workers=8) as pool:
    passed = list(pool.map(check, ports))
    udp_res = {str(p): check_udp(p) for p in udp_ports}
    busy_res = {str(p): check_tcp_open(p) for p in busy_ports}

if extra:
    print(json.dumps({"tls": tls_result, "udp": udp_res, "busy": busy_res}), flush=True)
else:
    print(json.dumps({"tls": tls_result}), flush=True)

ok = (
    all(passed)
    and tls_status != b"-"
    and all(v == "ok" for v in udp_res.values())
    and all(v == "ok" for v in busy_res.values())
)
sys.exit(not ok)
'@
    $panelClient = ($panelClient -replace "`r`n", "`n") + "`n"

    $tlsMessages = @{
        'ok' = 'TLS отвечает.'
        'dns' = 'Адрес ноды не найден.'
        'tcp_timeout' = 'Панель не дождалась подключения.'
        'refused' = 'Подключение отклонено.'
        'unreachable' = 'Панель не подключилась.'
        'tls_timeout' = 'TCP открыт, TLS не ответил вовремя.'
        'tls_error' = 'TCP открыт, TLS не установился.'
    }
    $busyMessages = @{
        'ok' = 'Занятый порт доступен с панели (TCP открыт).'
        'dns' = 'Адрес ноды не найден.'
        'tcp_timeout' = 'Занятый порт недоступен с панели (таймаут — проверьте firewall/провайдера).'
        'refused' = 'Подключение к порту отклонено.'
        'unreachable' = 'Панель не достучалась до порта.'
    }
    $seenTokens = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)

    function Write-ProbeLine([System.IO.Stream]$Stream, [string]$Text) {
        $lineBytes = [System.Text.Encoding]::UTF8.GetBytes("`r  $Text`r`n")
        $Stream.Write($lineBytes, 0, $lineBytes.Length)
        $Stream.Flush()
    }

    function Invoke-ProbeFrame([byte[]]$FrameBytes, [System.IO.Stream]$OutStream) {
        try {
            $jsonText = [System.Text.Encoding]::UTF8.GetString($FrameBytes)
            $message = $jsonText | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $message -or -not ($message -is [PSCustomObject])) { return }
            $ticketProp = $message.PSObject.Properties['ticket']
            $tokenProp = $message.PSObject.Properties['token']
            $portsProp = $message.PSObject.Properties['ports']
            $tlsProp = $message.PSObject.Properties['tls']
            if ($null -eq $ticketProp -or $null -eq $tokenProp -or $null -eq $portsProp -or $null -eq $tlsProp) { return }
            if ($ticketProp.Value -isnot [string] -or $ticketProp.Value -cne $Ticket) { return }

            $token = $tokenProp.Value
            if ($token -isnot [string] -or $token -cnotmatch '^[a-f0-9]{32}$') { return }

            if ($null -eq $portsProp.Value -or $portsProp.Value -isnot [System.Collections.IList]) { return }
            $ports = @($portsProp.Value)
            if ($ports.Count -gt 16) { return }
            foreach ($p in $ports) { if (-not (Test-JsonPort $p)) { return } }

            $udpProp = $message.PSObject.Properties['udp']
            $udp = @()
            if ($null -ne $udpProp -and $null -ne $udpProp.Value) {
                if ($udpProp.Value -isnot [System.Collections.IList]) { return }
                $udp = @($udpProp.Value)
                if ($udp.Count -gt 16) { return }
                foreach ($p in $udp) { if (-not (Test-JsonPort $p)) { return } }
            }

            $busyProp = $message.PSObject.Properties['busy']
            $busy = @()
            if ($null -ne $busyProp -and $null -ne $busyProp.Value) {
                if ($busyProp.Value -isnot [System.Collections.IList]) { return }
                $busy = @($busyProp.Value)
                if ($busy.Count -gt 16) { return }
                foreach ($p in $busy) { if (-not (Test-JsonPort $p)) { return } }
            }

            $tlsVal = $tlsProp.Value
            if ($null -ne $tlsVal -and -not (Test-JsonPort $tlsVal)) { return }
            if ($ports.Count -eq 0 -and $udp.Count -eq 0 -and $busy.Count -eq 0 -and $null -eq $tlsVal) { return }
            if (-not $seenTokens.Add($token)) { return }
        } catch {
            return
        }

        $cliArgs = New-Object 'System.Collections.Generic.List[string]'
        if ($udp.Count -gt 0 -or $busy.Count -gt 0) {
            $extraParts = New-Object 'System.Collections.Generic.List[string]'
            if ($udp.Count -gt 0) { [void]$extraParts.Add('"udp":[' + ($udp -join ',') + ']') }
            if ($busy.Count -gt 0) { [void]$extraParts.Add('"busy":[' + ($busy -join ',') + ']') }
            [void]$cliArgs.Add('--extra')
            [void]$cliArgs.Add('{' + ($extraParts.ToArray() -join ',') + '}')
        }
        [void]$cliArgs.Add($ProbeHost)
        [void]$cliArgs.Add($token)
        [void]$cliArgs.Add($(if ($null -ne $tlsVal) { [string]$tlsVal } else { '0' }))
        foreach ($p in $ports) { [void]$cliArgs.Add([string]$p) }

        $quotedPosix = New-Object 'System.Collections.Generic.List[string]'
        foreach ($ca in $cliArgs) { [void]$quotedPosix.Add((Quote-PosixArg $ca)) }
        $remoteCmd = 'python3 -I - ' + ($quotedPosix.ToArray() -join ' ')

        Write-ProbeLine $OutStream "Проверка с панели $Panel"

        $panelArgs = New-Object 'System.Collections.Generic.List[string]'
        [void]$panelArgs.Add('-T')
        [void]$panelArgs.Add('-o'); [void]$panelArgs.Add('BatchMode=yes')
        [void]$panelArgs.Add('-o'); [void]$panelArgs.Add('ConnectTimeout=6')
        foreach ($o in $PanelSshBaseOpts) { [void]$panelArgs.Add($o) }
        [void]$panelArgs.Add($Panel)
        [void]$panelArgs.Add($remoteCmd)

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $SshExe
        $psi.Arguments = Format-Win32CommandLine $panelArgs.ToArray()
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
        $psi.CreateNoWindow = $true

        $probeProc = $null
        try {
            $probeProc = [System.Diagnostics.Process]::Start($psi)
            $inBytes = [System.Text.Encoding]::UTF8.GetBytes($panelClient)
            $probeProc.StandardInput.BaseStream.Write($inBytes, 0, $inBytes.Length)
            $probeProc.StandardInput.BaseStream.Flush()
            $probeProc.StandardInput.BaseStream.Close()
            $outTask = $probeProc.StandardOutput.ReadToEndAsync()
            $errTask = $probeProc.StandardError.ReadToEndAsync()
            if (-not $probeProc.WaitForExit(24000)) {
                try { $probeProc.Kill() } catch {}
                Write-ProbeLine $OutStream 'Проверка с панели прервана.'
                return
            }
            $probeProc.WaitForExit()
            $stdoutText = $outTask.GetAwaiter().GetResult()
            [void]$errTask.GetAwaiter().GetResult()

            if ($probeProc.ExitCode -eq 255) {
                Write-ProbeLine $OutStream 'Не удалось войти на панель по SSH.'
                return
            }

            if ([string]::IsNullOrWhiteSpace($stdoutText)) {
                Write-ProbeLine $OutStream 'Панель не вернула результат проверки.'
                return
            }

            $parsed = $stdoutText | ConvertFrom-Json -ErrorAction Stop
            $state = $null
            if ($parsed -is [PSCustomObject]) {
                $tlsObjProp = $parsed.PSObject.Properties['tls']
                if ($null -ne $tlsObjProp) { $state = $tlsObjProp.Value }
                $busyObjProp = $parsed.PSObject.Properties['busy']
                if ($null -ne $busyObjProp -and $null -ne $busyObjProp.Value -and $busyObjProp.Value -is [PSCustomObject]) {
                    foreach ($prop in $busyObjProp.Value.PSObject.Properties) {
                        $st = [string]$prop.Value
                        $mark = if ($st -ceq 'ok') { '✓' } else { '×' }
                        $msg = if ($busyMessages.ContainsKey($st)) { $busyMessages[$st] } else { $st }
                        Write-ProbeLine $OutStream ("{0} {1,5}/tcp · {2}" -f $mark, [int]$prop.Name, $msg)
                    }
                }
            } else {
                $state = $parsed
            }

            if ($null -ne $tlsVal) {
                if (($state -isnot [string]) -or (-not $tlsMessages.ContainsKey($state))) {
                    Write-ProbeLine $OutStream 'Панель не вернула результат проверки.'
                    return
                }
                $mark = if ($state -ceq 'ok') { '✓' } else { '×' }
                Write-ProbeLine $OutStream ("{0} {1,5}/tcp · {2}" -f $mark, [int]$tlsVal, $tlsMessages[$state])
            }
        } catch [System.ComponentModel.Win32Exception], [System.IO.IOException] {
            Write-ProbeLine $OutStream 'Проверка с панели прервана.'
        } catch {
            Write-ProbeLine $OutStream 'Панель не вернула результат проверки.'
        } finally {
            if ($null -ne $probeProc) { $probeProc.Dispose() }
        }
    }

    $menuPsi = New-Object System.Diagnostics.ProcessStartInfo
    $menuPsi.FileName = $SshExe
    $menuPsi.Arguments = Format-Win32CommandLine $MenuSshArgs
    $menuPsi.UseShellExecute = $false
    $menuPsi.RedirectStandardInput = $false
    $menuPsi.RedirectStandardOutput = $true
    $menuPsi.RedirectStandardError = $false

    $menuProc = [System.Diagnostics.Process]::Start($menuPsi)
    try {
        $inStream = $menuProc.StandardOutput.BaseStream
        $outStream = [Console]::OpenStandardOutput()
        $buf = New-Object byte[] 4096
        $inFrame = $false
        $frameInvalid = $false
        $frameBuf = New-Object 'System.Collections.Generic.List[byte]'
        while (($read = $inStream.Read($buf, 0, $buf.Length)) -gt 0) {
            $pos = 0
            while ($pos -lt $read) {
                $len = $read - $pos
                if (-not $inFrame) {
                    $idx = [Array]::IndexOf($buf, [byte]0x1e, $pos, $len)
                    if ($idx -lt 0) {
                        $outStream.Write($buf, $pos, $len)
                        $outStream.Flush()
                        $pos = $read
                    } else {
                        $before = $idx - $pos
                        if ($before -gt 0) {
                            $outStream.Write($buf, $pos, $before)
                            $outStream.Flush()
                        }
                        $inFrame = $true
                        $frameInvalid = $false
                        $frameBuf.Clear()
                        $pos = $idx + 1
                    }
                } else {
                    $idx = [Array]::IndexOf($buf, [byte]0x1f, $pos, $len)
                    if ($idx -lt 0) {
                        if (-not $frameInvalid) {
                            if ($frameBuf.Count + $len -le 4096) {
                                for ($k = $pos; $k -lt $read; $k++) { [void]$frameBuf.Add($buf[$k]) }
                            } else {
                                $frameInvalid = $true
                                $frameBuf.Clear()
                            }
                        }
                        $pos = $read
                    } else {
                        $chunkLen = $idx - $pos
                        if (-not $frameInvalid) {
                            if ($frameBuf.Count + $chunkLen -le 4096) {
                                for ($k = $pos; $k -lt $idx; $k++) { [void]$frameBuf.Add($buf[$k]) }
                                Invoke-ProbeFrame $frameBuf.ToArray() $outStream
                            }
                        }
                        $inFrame = $false
                        $frameInvalid = $false
                        $frameBuf.Clear()
                        $pos = $idx + 1
                    }
                }
            }
        }
        $menuProc.WaitForExit()
        return $menuProc.ExitCode
    } finally {
        if (-not $menuProc.HasExited) {
            try { $menuProc.Kill() } catch {}
            try { $menuProc.WaitForExit() } catch {}
        }
        $menuProc.Dispose()
    }
}

function Invoke-DirectSsh([string]$SshExe, [string[]]$SshArgs) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $SshExe
    $psi.Arguments = Format-Win32CommandLine $SshArgs
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $false
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        $proc.WaitForExit()
        return $proc.ExitCode
    } finally {
        $proc.Dispose()
    }
}

function Invoke-RemnaSshMain {
    param([string[]]$InputArgs = @())

    $origInEnc = $null
    $origOutEnc = $null
    try {
        try {
            if (-not [Console]::IsInputRedirected) {
                $origInEnc = [Console]::InputEncoding
                [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
            }
        } catch {}
        try {
            $origOutEnc = [Console]::OutputEncoding
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        } catch {}
        Enable-VirtualTerminal

        $sshExe = Get-SshExecutable
        if (-not $sshExe) {
            [Console]::Error.WriteLine('Не найден клиент OpenSSH (ssh.exe).')
            [Console]::Error.WriteLine('Включите «Клиент OpenSSH» в Параметрах Windows или выполните в PowerShell от администратора:')
            [Console]::Error.WriteLine('  Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0')
            return 1
        }

        $panel = ''
        $hasPortFlag = $false
        $bootstrap = if ((-not [Console]::IsInputRedirected) -and (-not [Console]::IsOutputRedirected)) { 'yes' } else { 'no' }
        $portArgList = New-Object 'System.Collections.Generic.List[string]'

        $idx = 0
        while ($idx -lt $InputArgs.Count) {
            $arg = $InputArgs[$idx]
            if (-not $arg.StartsWith('-')) { break }
            switch ($arg) {
                { $_ -eq '-h' -or $_ -eq '--help' } {
                    Show-Usage $false
                    return 0
                }
                '--client' {
                    $idx++
                    continue
                }
                '--bootstrap' {
                    $bootstrap = 'yes'
                    $idx++
                    continue
                }
                { $_ -eq '-p' -or $_ -eq '--port' } {
                    if ($idx + 1 -ge $InputArgs.Count) {
                        Show-Usage $true
                        return 2
                    }
                    $portVal = $InputArgs[$idx + 1]
                    if (-not (Test-ValidPortNumber $portVal)) {
                        Show-Usage $true
                        return 2
                    }
                    [void]$portArgList.Add('-p')
                    [void]$portArgList.Add($portVal)
                    $hasPortFlag = $true
                    $idx += 2
                    continue
                }
                '--panel' {
                    if ($idx + 1 -ge $InputArgs.Count) {
                        Show-Usage $true
                        return 2
                    }
                    $panelVal = $InputArgs[$idx + 1]
                    if (-not (Test-SshTarget $panelVal)) {
                        Show-Usage $true
                        return 2
                    }
                    $panel = $panelVal
                    $idx += 2
                    continue
                }
                default {
                    Show-Usage $true
                    return 2
                }
            }
        }

        $baseSecOpts = Get-SupportedSshSecurityOptions $sshExe
        $sshOptions = New-Object 'System.Collections.Generic.List[string]'
        [void]$sshOptions.Add('-tt')
        foreach ($o in $baseSecOpts) { [void]$sshOptions.Add($o) }
        [void]$sshOptions.Add('-o'); [void]$sshOptions.Add('ConnectTimeout=10')
        foreach ($pa in $portArgList) { [void]$sshOptions.Add($pa) }

        $homeDir = Get-UserHomeDir
        $destination = ''
        $remaining = $InputArgs.Count - $idx
        if ($remaining -eq 0) {
            if ((-not [Console]::IsInputRedirected) -and (-not [Console]::IsOutputRedirected)) {
                $destRef = [ref]$destination
                $panelRef = [ref]$panel
                $ok = Invoke-InteractiveSetup $sshExe $homeDir $hasPortFlag $destRef $panelRef $sshOptions
                if (-not $ok) { return 1 }
                $destination = $destRef.Value
                $panel = $panelRef.Value
            } else {
                Show-Usage $true
                return 2
            }
        } elseif ($remaining -eq 1 -and (Test-SshTarget $InputArgs[$idx])) {
            $destination = $InputArgs[$idx]
        } else {
            Show-Usage $true
            return 2
        }

        $probeHost = ''
        if (-not [string]::IsNullOrEmpty($panel)) {
            foreach ($line in (Invoke-SshQuery $sshExe $destination)) {
                if ($line -match '^\s*hostname\s+(\S+)\s*$') {
                    $probeHost = $Matches[1].ToLowerInvariant()
                    break
                }
            }
            if ($probeHost -match '^\[(.+)\]$') { $probeHost = $Matches[1] }
            $probeHost = $probeHost.TrimEnd('.')
            if ($probeHost -notmatch '^[a-z0-9:][a-z0-9.:-]*$') {
                [Console]::Error.WriteLine('Укажите IP или домен ноды в команде или SSH-конфиге.')
                return 2
            }
        }

        $previous = ''
        while ($true) {
            $ticket = New-RandomTicket
            if ($ticket -cnotmatch '^[a-f0-9]{32}$') { return 1 }

            $menuArgs = if (-not [string]::IsNullOrEmpty($panel)) {
                $prevToken = if ($previous) { $previous } else { '-' }
                "__ssh-menu $ticket $prevToken $probeHost"
            } elseif ($previous) {
                "__ssh-menu $ticket $previous"
            } else {
                "__ssh-menu $ticket"
            }

            $tool = '/usr/local/bin/remna-node-setup'
            if ($bootstrap -eq 'yes') {
                $command = "if [ ! -x $tool ]; then printf '%s\n' 'На VPS не найден Remna Node Setup — устанавливаю автоматически...'; inst=`$(curl -qfsSL --proto '=https' https://github.com/AiGenik/remna-node-setup/raw/HEAD/install.sh) || exit 1; if [ `"`$(id -u)`" -eq 0 ]; then bash -c `"`$inst`" -- </dev/null || exit 1; else printf '%s\n' `"`$inst`" | sudo bash -s -- || exit 1; fi; fi; if [ `"`$(id -u)`" -eq 0 ]; then exec $tool $menuArgs; else exec sudo $tool $menuArgs; fi"
            } else {
                $command = "if [ ! -x $tool ]; then printf '%s\n' 'На VPS не найден Remna Node Setup. Сначала установите мастер по шагу 1 в README.' >&2; exit 127; fi; if [ `"`$(id -u)`" -eq 0 ]; then exec $tool $menuArgs; else exec sudo $tool $menuArgs; fi"
            }

            $fullSshArgs = New-Object 'System.Collections.Generic.List[string]'
            foreach ($o in $sshOptions) { [void]$fullSshArgs.Add($o) }
            [void]$fullSshArgs.Add($destination)
            [void]$fullSshArgs.Add($command)

            $result = 0
            if (-not [string]::IsNullOrEmpty($panel)) {
                $result = Invoke-PanelMenu $sshExe $baseSecOpts $panel $probeHost $ticket $fullSshArgs.ToArray()
            } else {
                $result = Invoke-DirectSsh $sshExe $fullSshArgs.ToArray()
            }

            switch ($result) {
                0 { return 0 }
                42 {
                    $previous = $ticket
                    [Console]::Out.Write("`nПроверяю новое SSH-подключение…`n")
                    [Console]::Out.Flush()
                    Start-Sleep -Milliseconds 200
                }
                default {
                    if (-not [string]::IsNullOrEmpty($panel) -and $result -eq 2) {
                        [Console]::Error.WriteLine('Для --panel обновите Remna Node Setup на ноде до 1.1 или новее.')
                    }
                    if (-not [string]::IsNullOrEmpty($previous)) {
                        [Console]::Error.WriteLine('SSH завершился с ошибкой. Для неподтверждённых изменений действует автооткат.')
                    }
                    return $result
                }
            }
        }
    } finally {
        try { if ($null -ne $origInEnc) { [Console]::InputEncoding = $origInEnc } } catch {}
        try { if ($null -ne $origOutEnc) { [Console]::OutputEncoding = $origOutEnc } } catch {}
    }
}

$script:RemnaSshExitCode = Invoke-RemnaSshMain -InputArgs $args
exit $script:RemnaSshExitCode
