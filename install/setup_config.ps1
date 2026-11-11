param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('install', 'uninstall')]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [string]$HermesHome,

    [switch]$NoCli
)

$ErrorActionPreference = 'Stop'

try {
    $HermesHome = (Resolve-Path -LiteralPath $HermesHome).Path
} catch {
    Write-Error "Hermes home not found: $HermesHome"
    exit 1
}

$configPath = Join-Path $HermesHome 'config.yaml'
if (-not (Test-Path -LiteralPath $configPath)) {
    Write-Error "config.yaml not found under $HermesHome"
    exit 1
}
$env:HERMES_HOME = $HermesHome

function Find-HermesCli {
    if ($NoCli) { return $null }
    $candidates = @()
    $cmd = Get-Command hermes -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    $candidates += (Join-Path $HermesHome 'hermes-agent\.hermes\bin\hermes.exe')
    $candidates += (Join-Path $env:LOCALAPPDATA 'hermes\hermes-agent\.hermes\bin\hermes.exe')
    $candidates += (Join-Path $env:USERPROFILE '.hermes\hermes-agent\.hermes\bin\hermes.exe')
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }
    return $null
}

function Read-EnabledEntries {
    param([string]$Cli)
    if (-not $Cli) { return $null }
    try {
        $out = (& $Cli config get plugins.enabled --json 2>$null | Out-String)
        $jsonLine = @($out -split "`r?`n" | Where-Object {
            $t = $_.Trim()
            $t.StartsWith('[') -or $t.StartsWith('{') -or $t -eq 'null'
        } | Select-Object -Last 1)
        if (-not $jsonLine) { return $null }
        $parsed = ([string]$jsonLine[0]) | ConvertFrom-Json
        if ($null -eq $parsed) { return @() }
        return @($parsed | ForEach-Object { [string]$_ })
    } catch {
        return $null
    }
}

function Set-EnabledEntries {
    param([string]$Cli, [string[]]$Entries)
    $quoted = @($Entries | ForEach-Object {
        '"' + (($_ -replace '\\', '\\\\') -replace '"', '\"') + '"'
    })
    $json = '[' + ($quoted -join ',') + ']'
    & $Cli config set plugins.enabled $json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "hermes config set failed" }
}

function Update-YamlList {
    param([string]$Action)

    $text = [IO.File]::ReadAllText($configPath)
    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($text -split "`r?`n")) { $lines.Add($line) }

    $pluginsIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^plugins:\s*$') { $pluginsIndex = $i; break }
    }

    if ($pluginsIndex -lt 0) {
        if ($Action -ne 'install') { return $true }
        $lines.Add('plugins:')
        $lines.Add('  enabled:')
        $lines.Add('    - session-lock')
    } else {
        $sectionEnd = $lines.Count
        for ($i = $pluginsIndex + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\S') { $sectionEnd = $i; break }
        }

        $enabledIndex = -1
        $enabledIndent = '  '
        for ($i = $pluginsIndex + 1; $i -lt $sectionEnd; $i++) {
            if ($lines[$i] -match '^(\s+)enabled:\s*(.*)$') {
                $enabledIndex = $i
                $enabledIndent = $Matches[1]
                break
            }
        }

        if ($enabledIndex -lt 0) {
            if ($Action -ne 'install') { return $true }
            $lines.Insert($pluginsIndex + 1, '  enabled:')
            $lines.Insert($pluginsIndex + 2, '    - session-lock')
        } else {
            $inline = ''
            if ($lines[$enabledIndex] -match '^(\s+)enabled:\s*(.*)$') {
                $enabledIndent = $Matches[1]
                $inline = $Matches[2].Trim()
            }

            if ($inline -eq '[]') {
                if ($Action -ne 'install') { return $false }
                $lines[$enabledIndex] = "$enabledIndent" + 'enabled:'
                $lines.Insert($enabledIndex + 1, "$enabledIndent" + '  - session-lock')
            } elseif ($inline -ne '') {
                # Inline non-empty lists are unusual; let the CLI handle them.
                return $false
            } else {
                $listEnd = $enabledIndex + 1
                $listIndent = $enabledIndent + '  '
                $lastItem = -1
                while ($listEnd -lt $sectionEnd) {
                    $line = $lines[$listEnd]
                    if ($line -match '^(\s*)-\s*') {
                        $listIndent = $Matches[1]
                        $lastItem = $listEnd
                        $listEnd++
                    } elseif ($line.Trim() -eq '') {
                        $listEnd++
                    } else {
                        break
                    }
                }

                if ($Action -eq 'install') {
                    $already = $false
                    for ($i = $enabledIndex + 1; $i -lt $listEnd; $i++) {
                        if ($lines[$i] -match '^\s*-\s*session-lock\s*$') { $already = $true; break }
                    }
                    if ($already) { return $true }
                    $insertAt = $enabledIndex + 1
                    if ($lastItem -ge 0) { $insertAt = $lastItem + 1 }
                    $lines.Insert($insertAt, "$listIndent- session-lock")
                } else {
                    $removed = $false
                    for ($i = $listEnd - 1; $i -ge $enabledIndex + 1; $i--) {
                        if ($lines[$i] -match '^\s*-\s*session-lock\s*$') {
                            $lines.RemoveAt($i)
                            $removed = $true
                        }
                    }
                    if (-not $removed) { return $true }
                }
            }
        }
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item -LiteralPath $configPath -Destination "$configPath.bak-session-lock-$stamp" -Force
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($configPath, (($lines -join $newline) + $newline), $encoding)
    return $true
}

$cli = Find-HermesCli
$entries = Read-EnabledEntries -Cli $cli
$byCli = $false
if ($null -ne $entries) {
    try {
        if ($Mode -eq 'install') {
            if ($entries -notcontains 'session-lock') { $entries += 'session-lock' }
        } else {
            $entries = @($entries | Where-Object { $_ -ne 'session-lock' })
        }
        Set-EnabledEntries -Cli $cli -Entries $entries
        $after = Read-EnabledEntries -Cli $cli
        if ($null -eq $after) { throw "could not read back plugins.enabled" }
        if ($Mode -eq 'install' -and ($after -notcontains 'session-lock')) { throw "session-lock missing after install" }
        if ($Mode -eq 'uninstall' -and ($after -contains 'session-lock')) { throw "session-lock still listed after uninstall" }
        $byCli = $true
    } catch {
        $byCli = $false
    }
}

if (-not $byCli) {
    if (-not (Update-YamlList -Action $Mode)) {
        Write-Error "Could not update plugins.enabled. Add/remove session-lock under plugins.enabled in $configPath manually."
        exit 1
    }
    Write-Output "CONFIG_OK=yaml"
} else {
    Write-Output "CONFIG_OK=cli"
}
exit 0
