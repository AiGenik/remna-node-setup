# Короткая точка входа для Windows PowerShell:
# ставит remna-ssh.ps1 и короткую команду rns в %USERPROFILE%\.local\bin,
# добавляет каталог в PATH пользователя и запускает мастер.
#
# Запуск в одну строку (PowerShell 5.1 и 7+):
#   irm https://raw.githubusercontent.com/AiGenik/remna-node-setup/HEAD/i.ps1 | iex

$ErrorActionPreference = 'Stop'

function Invoke-RemnaClientInstall {
    param([string[]]$InputArgs = @())

    $origProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    $origInEnc = $null
    $origOutEnc = $null
    $stage = $null
    $script:RemnaInstallExitCode = 0

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

        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        } catch {}

        $clientOnly = $false
        $forwardArgs = New-Object 'System.Collections.Generic.List[string]'
        foreach ($arg in $InputArgs) {
            if ($arg -eq '--client' -or $arg -eq '-ClientOnly') {
                $clientOnly = $true
            } else {
                [void]$forwardArgs.Add($arg)
            }
        }

        $homeDir = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($HOME) { $HOME } else { [Environment]::GetFolderPath('UserProfile') }
        $binDir = if ($env:REMNA_CLIENT_BIN_DIR) {
            $env:REMNA_CLIENT_BIN_DIR
        } else {
            Join-Path (Join-Path $homeDir '.local') 'bin'
        }
        $assetsBase = if ($env:REMNA_RELEASE_ASSETS_URL) {
            $env:REMNA_RELEASE_ASSETS_URL.TrimEnd('/')
        } else {
            'https://github.com/AiGenik/remna-node-setup/releases/latest/download'
        }

        if (-not $env:REMNA_RELEASE_ASSETS_URL -and ($assetsBase -notmatch '^https://')) {
            throw 'Загрузка разрешена только по HTTPS.'
        }

        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
        $stage = Join-Path $binDir ('.remna-ssh.' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $stage -Force | Out-Null

        $scriptUrl = "$assetsBase/remna-ssh.ps1"
        $shaUrl = "$assetsBase/remna-ssh.ps1.sha256"
        $stagedScript = Join-Path $stage 'remna-ssh.ps1'
        $stagedSha = Join-Path $stage 'remna-ssh.ps1.sha256'

        try {
            Invoke-WebRequest -Uri $scriptUrl -OutFile $stagedScript -UseBasicParsing -TimeoutSec 60 -MaximumRedirection 5
            Invoke-WebRequest -Uri $shaUrl -OutFile $stagedSha -UseBasicParsing -TimeoutSec 60 -MaximumRedirection 5
        } catch {
            throw ("Не удалось скачать remna-ssh.ps1 из последнего релиза GitHub ({0}): {1}" -f $assetsBase, $_.Exception.Message)
        }

        $shaLine = ([System.IO.File]::ReadAllText($stagedSha, [System.Text.Encoding]::UTF8) -split "\r?\n")[0].Trim()
        if ($shaLine -notmatch '^([a-fA-F0-9]{64})\s+\*?remna-ssh\.ps1$') {
            throw 'В релизе отсутствует корректная сумма SHA-256 для remna-ssh.ps1.'
        }
        $expectedHash = $Matches[1].ToLowerInvariant()
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $stream = [System.IO.File]::OpenRead($stagedScript)
            try {
                $actualHash = ([System.BitConverter]::ToString($sha256.ComputeHash($stream)) -replace '-', '').ToLowerInvariant()
            } finally {
                $stream.Dispose()
            }
        } finally {
            $sha256.Dispose()
        }
        if ($actualHash -cne $expectedHash) {
            throw 'Контрольная сумма SHA-256 для remna-ssh.ps1 не совпала.'
        }

        foreach ($name in @('remna-ssh.ps1', 'remna-ssh.cmd', 'rns.cmd')) {
            $targetPath = Join-Path $binDir $name
            if (Test-Path -LiteralPath $targetPath -PathType Container) {
                throw "Каталог $targetPath занимает место файла помощника."
            }
        }

        $installedScript = Join-Path $binDir 'remna-ssh.ps1'
        Move-Item -LiteralPath $stagedScript -Destination $installedScript -Force

        $shimBody = @(
            '@echo off',
            'setlocal',
            'where pwsh.exe >nul 2>nul',
            'if errorlevel 1 goto :winps',
            'pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0remna-ssh.ps1" %*',
            'exit /b %errorlevel%',
            ':winps',
            'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0remna-ssh.ps1" %*',
            'exit /b %errorlevel%'
        ) -join "`r`n"
        $shimBody += "`r`n"

        foreach ($shimName in @('remna-ssh.cmd', 'rns.cmd')) {
            $shimTmp = Join-Path $stage $shimName
            [System.IO.File]::WriteAllText($shimTmp, $shimBody, [System.Text.Encoding]::ASCII)
            Move-Item -LiteralPath $shimTmp -Destination (Join-Path $binDir $shimName) -Force
        }

        if ($env:REMNA_CLIENT_NO_PATH -ne '1') {
            $normBin = $binDir.TrimEnd('\', '/')
            $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
            $entries = @()
            if ($userPath) {
                $entries = $userPath -split ';' | Where-Object { $_ -and $_.Trim() -ne '' }
            }
            $hasUserPath = $false
            foreach ($entry in $entries) {
                if ($entry.Trim().TrimEnd('\', '/').Equals($normBin, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $hasUserPath = $true
                    break
                }
            }
            if (-not $hasUserPath) {
                $updated = if ($entries.Count -gt 0) { ($entries -join ';') + ';' + $binDir } else { $binDir }
                [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
            }

            $sessionEntries = @()
            if ($env:PATH) {
                $sessionEntries = $env:PATH -split [System.IO.Path]::PathSeparator | Where-Object { $_ }
            }
            $hasSessionPath = $false
            foreach ($entry in $sessionEntries) {
                if ($entry.Trim().TrimEnd('\', '/').Equals($normBin, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $hasSessionPath = $true
                    break
                }
            }
            if (-not $hasSessionPath) {
                $env:PATH = $binDir + [System.IO.Path]::PathSeparator + $env:PATH
            }
        }

        $cmdPath = Join-Path $binDir 'remna-ssh.cmd'
        [Console]::Out.WriteLine(("Помощник установлен. Команда запуска: {0} (коротко: rns)" -f $cmdPath))

        if (-not $clientOnly -and $env:REMNA_CLIENT_ONLY -ne '1') {
            $psExe = $null
            try {
                $procPath = (Get-Process -Id $PID -ErrorAction Stop).Path
                if ($procPath -and (Test-Path -LiteralPath $procPath -PathType Leaf)) {
                    $psExe = $procPath
                }
            } catch {}
            if (-not $psExe) {
                $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell.exe' }
            }
            $psLaunchArgs = New-Object 'System.Collections.Generic.List[string]'
            [void]$psLaunchArgs.Add('-NoLogo')
            [void]$psLaunchArgs.Add('-NoProfile')
            if ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
                [void]$psLaunchArgs.Add('-ExecutionPolicy')
                [void]$psLaunchArgs.Add('Bypass')
            }
            [void]$psLaunchArgs.Add('-File')
            [void]$psLaunchArgs.Add($installedScript)
            foreach ($fa in $forwardArgs) { [void]$psLaunchArgs.Add($fa) }

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $psExe
            $quotedArgs = New-Object 'System.Collections.Generic.List[string]'
            foreach ($a in $psLaunchArgs) {
                if ($a.Length -gt 0 -and $a -notmatch '[\s"]') {
                    [void]$quotedArgs.Add($a)
                } else {
                    $sb = New-Object System.Text.StringBuilder
                    [void]$sb.Append('"')
                    $bs = 0
                    foreach ($ch in $a.ToCharArray()) {
                        if ($ch -eq '\') { $bs++ }
                        elseif ($ch -eq '"') {
                            if ($bs -gt 0) { [void]$sb.Append('\', $bs * 2); $bs = 0 }
                            [void]$sb.Append('\"')
                        } else {
                            if ($bs -gt 0) { [void]$sb.Append('\', $bs); $bs = 0 }
                            [void]$sb.Append($ch)
                        }
                    }
                    if ($bs -gt 0) { [void]$sb.Append('\', $bs * 2) }
                    [void]$sb.Append('"')
                    [void]$quotedArgs.Add($sb.ToString())
                }
            }
            $psi.Arguments = ($quotedArgs.ToArray() -join ' ')
            $psi.UseShellExecute = $false
            $proc = [System.Diagnostics.Process]::Start($psi)
            try {
                $proc.WaitForExit()
                $script:RemnaInstallExitCode = $proc.ExitCode
            } finally {
                $proc.Dispose()
            }
        }
    } finally {
        $ProgressPreference = $origProgress
        if ($stage -and (Test-Path -LiteralPath $stage)) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
        try { if ($null -ne $origInEnc) { [Console]::InputEncoding = $origInEnc } } catch {}
        try { if ($null -ne $origOutEnc) { [Console]::OutputEncoding = $origOutEnc } } catch {}
    }
}

Invoke-RemnaClientInstall -InputArgs $args
if ($MyInvocation.InvocationName -match '\.ps1$' -and $script:RemnaInstallExitCode -ne 0) {
    exit $script:RemnaInstallExitCode
}
