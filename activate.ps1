# Source this file to sync and apply the PM environment; deactivate restores it.
# Trusts the recorded tool digest. `hermes pm install` re-checks the bytes.
# -TestExtras a,b selects runtime extras in the test environment (default: [all]).
# aiDAPTIV+: when <HERMES_HOME>\config.yaml does not exist yet (it is gitignored,
# so a fresh clone has none), it is created from cli-config.yaml.example with
# aiDAPTIV+ as the default provider. An existing config.yaml is never changed.
# Global `hermes`: this checkout's launcher folder (.hermes\bin) is put on the
# User PATH, so every new console can run `hermes` from any folder and with any
# venv active (the launcher uses Hermes's own Python and keeps the current
# folder). -NoGlobal skips that registration.
param([string]$TestExtras = '', [switch]$NoGlobal)
$ErrorActionPreference = 'Stop'

$OutputEncoding = [System.Console]::OutputEncoding = [System.Console]::InputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['*:Encoding'] = 'utf8'

$repo = $PSScriptRoot
$bootstrapSaved = @{}
foreach ($key in @('PYTHONPATH', 'PYTHONHOME', 'VIRTUAL_ENV')) {
    $bootstrapSaved[$key] = [Environment]::GetEnvironmentVariable($key)
    Remove-Item "env:$key" -ErrorAction SilentlyContinue
}
try {
    # Run separately so setup's exit/failure cannot terminate the sourced shell.
    $shell = (Get-Process -Id $PID).Path
    $testArgs = @()
    if ($TestExtras) { $testArgs = @('-TestExtras', $TestExtras) }
    & $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$repo\setup-hermes.ps1" -RuntimeOnly @testArgs | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'activate: setup failed; shell environment unchanged' }
} finally {
    foreach ($key in $bootstrapSaved.Keys) {
        if ($null -eq $bootstrapSaved[$key]) { Remove-Item "env:$key" -ErrorAction SilentlyContinue }
        else { Set-Item "env:$key" $bootstrapSaved[$key] }
    }
}
if (Test-Path function:deactivate) { deactivate }
$py = $null
foreach ($candidate in @("$repo\.venv\Scripts\python.exe", "$repo\venv\Scripts\python.exe")) {
    if (Test-Path -LiteralPath $candidate) { $py = $candidate; break }
}
if (-not $py) {
    $roots = @($env:HERMES_RUNTIME_DIR, "$repo\..\tools")
    $homeRoot = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { "$env:LOCALAPPDATA\hermes" }
    $roots += (Join-Path $homeRoot 'tools')
    foreach ($root in $roots) {
        if (-not $root) { continue }
        foreach ($entry in @(Get-ChildItem -LiteralPath $root -Directory -Filter 'python-*' -ErrorAction SilentlyContinue)) {
            $candidate = Join-Path $entry.FullName 'python.exe'
            if (Test-Path -LiteralPath $candidate) { $py = $candidate; break }
        }
        if ($py) { break }
    }
}
if (-not $py) { throw 'activate: no bootstrap Python found; run setup-hermes.ps1' }
$priorPath = $env:PYTHONPATH
$priorHome = $env:PYTHONHOME
try {
    $env:PYTHONPATH = $repo
    Remove-Item env:PYTHONHOME -ErrorAction SilentlyContinue
    $json = (& $py -m pm.environments) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'activate: could not read the installed environment' }
    $composed = $json | ConvertFrom-Json
} finally {
    if ($null -eq $priorPath) { Remove-Item env:PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $priorPath }
    if ($null -eq $priorHome) { Remove-Item env:PYTHONHOME -ErrorAction SilentlyContinue } else { $env:PYTHONHOME = $priorHome }
}
# __HERMES_ACTIVATED (the sentinel repo scripts and the shebang prologue read)
# is part of the composed env, so it is saved and restored with the rest.
$global:_hermesKeys = @($composed.PSObject.Properties.Name)
$global:_hermesSaved = @{}
foreach ($key in $global:_hermesKeys) {
    $global:_hermesSaved[$key] = [pscustomobject]@{
        WasSet = (Test-Path "env:$key")
        Value = [Environment]::GetEnvironmentVariable($key)
    }
}
foreach ($property in $composed.PSObject.Properties) {
    Set-Item -Path "env:$($property.Name)" -Value ([string]$property.Value)
}

# ---------------------------------------------------------------------------
# aiDAPTIV+ default config. Hermes reads <HERMES_HOME>\config.yaml; on Windows
# HERMES_HOME defaults to %LOCALAPPDATA%\hermes (hermes_constants.py).
# ---------------------------------------------------------------------------
$hermesHome = if ($env:HERMES_HOME) { $env:HERMES_HOME } else { "$env:LOCALAPPDATA\hermes$($env:HERMES_DATA_DIR_SUFFIX)" }
$configPath = Join-Path $hermesHome 'config.yaml'
$templatePath = Join-Path $repo 'cli-config.yaml.example'
if (Test-Path -LiteralPath $configPath) {
    # custom_providers "- name: aiDAPTIV", or a named "providers: aiDAPTIV:" block
    if (-not (Select-String -LiteralPath $configPath -Pattern '^\s+(- name: )?aiDAPTIV:?\s*$' -Quiet)) {
        Write-Host "activate: $configPath exists and has no aiDAPTIV provider; left unchanged" -ForegroundColor Yellow
    }
} elseif (-not (Test-Path -LiteralPath $templatePath)) {
    Write-Host "activate: $templatePath not found; config.yaml not created" -ForegroundColor Yellow
} else {
    New-Item -ItemType Directory -Force -Path $hermesHome | Out-Null
    $text = [IO.File]::ReadAllText($templatePath)
    if ($text -match '(?m)^\s+- name: aiDAPTIV\s*$') {
        # The aiDAPTIV+ edition of the template: use it as it is.
        Copy-Item -LiteralPath $templatePath -Destination $configPath
    } else {
        # Stock upstream template: add the same aiDAPTIV+ defaults the
        # aiDAPTIV+ edition carries (model section + custom_providers entry).
        $aidaptivUrl = 'http://localhost:8080/v1'
        $aidaptivModel = 'gemma-4-26B-A4B-it-UD-Q4_K_M.gguf'
        $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
        $lines = [Collections.Generic.List[string]]($text -split "\r?\n")

        # model: section. Only its first-level keys (two-space indent) are
        # touched; the section ends at the next top-level key.
        $start = $lines.IndexOf('model:')
        if ($start -lt 0) { $lines.Insert(0, 'model:'); $start = 0 }
        $end = $start + 1
        while ($end -lt $lines.Count -and $lines[$end] -notmatch '^[A-Za-z_]') { $end++ }
        $modelKeys = [ordered]@{
            default  = "  default: `"$aidaptivModel`""
            provider = '  provider: "custom"'
            base_url = "  base_url: `"$aidaptivUrl`""
        }
        foreach ($key in @($modelKeys.Keys)) {
            $found = $false
            for ($i = $start + 1; $i -lt $end; $i++) {
                if ($lines[$i] -match "^  ${key}:") { $lines[$i] = $modelKeys[$key]; $found = $true; break }
            }
            if (-not $found) { $lines.Insert($start + 1, $modelKeys[$key]); $end++ }
        }

        # custom_providers entry. Join an existing top-level custom_providers:
        # list (a second key would be a duplicate-key YAML error), else add one.
        $entry = @(
            '  - name: aiDAPTIV',
            "    base_url: $aidaptivUrl",
            "    model: $aidaptivModel",
            '    models:',
            "      ${aidaptivModel}:",
            '        context_length: 64000',
            '    extra_body:',
            '      cache_prompt: true',
            '      offload_folder_name: "Hermes"',
            '      chat_template_kwargs:',
            '        enable_thinking: true'
        )
        $listAt = $lines.IndexOf('custom_providers:')
        if ($listAt -ge 0) {
            $lines.InsertRange($listAt + 1, [string[]]$entry)
        } else {
            while ($lines.Count -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
            $lines.AddRange([string[]](@('', '# aiDAPTIV+ (added by activate.ps1)', 'custom_providers:') + $entry + @('')))
        }
        # UTF-8 without BOM, like the template.
        [IO.File]::WriteAllText($configPath, ($lines -join $nl), (New-Object System.Text.UTF8Encoding($false)))
    }
    Write-Host "activate: created $configPath with aiDAPTIV+ as the default provider" -ForegroundColor Green
}
# ---------------------------------------------------------------------------
# Global `hermes`: register <repo>\.hermes\bin on the User PATH (once; later
# runs find it present). Uses Hermes's own helper, which keeps the PATH value's
# registry type (%VARS% stay expandable), matches case-insensitively and
# notifies Windows. Takes effect in NEW consoles; this one uses the function below.
# ---------------------------------------------------------------------------
$launcherDir = Join-Path $repo '.hermes\bin'
$launcherExe = @('hermes.exe', 'hermes.cmd') | ForEach-Object { Join-Path $launcherDir $_ } |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($NoGlobal) {
    # Skipped on request.
} elseif (-not $launcherExe) {
    Write-Host "activate: no launcher in $launcherDir; global hermes not registered (run setup-hermes.ps1)" -ForegroundColor Yellow
} else {
    $priorPath = $env:PYTHONPATH
    $priorHome = $env:PYTHONHOME
    $priorPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 turns redirected native stderr into a
        # terminating error under 'Stop'; the exit code is checked instead.
        $ErrorActionPreference = 'Continue'
        $env:PYTHONPATH = $repo
        Remove-Item env:PYTHONHOME -ErrorAction SilentlyContinue
        $register = 'import sys; from pathlib import Path; from hermes_cli._launchers import _register_windows_user_path as r; print(r(Path(sys.argv[1])))'
        $state = (& $py -c $register $launcherDir 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            Write-Host "activate: could not add $launcherDir to the User PATH: $state" -ForegroundColor Yellow
        } elseif ($state -eq 'added') {
            Write-Host "activate: added $launcherDir to the User PATH; open a new console to use hermes from any folder" -ForegroundColor Green
        }
    } finally {
        $ErrorActionPreference = $priorPreference
        if ($null -eq $priorPath) { Remove-Item env:PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $priorPath }
        if ($null -eq $priorHome) { Remove-Item env:PYTHONHOME -ErrorAction SilentlyContinue } else { $env:PYTHONHOME = $priorHome }
    }
}

# This checkout, not whichever `hermes` PATH finds. A function beats PATH,
# an alias, and the MSIX execution alias. Inside this worktree it runs the
# checkout's venv (dev mode); outside it runs the checkout's launcher from the
# current folder, so a project's AGENTS.md, terminal cwd and venv apply.
$global:_hermesWorktree = $repo
$global:_hermesLauncher = $launcherExe
# The branch names the worktree. A checkout cannot share a branch with another.
# git's "not a repository" is not an activation failure: the directory name is
# the label, and the command still refuses outside this tree.
$branch = $null
try { $branch = & git -C $repo rev-parse --abbrev-ref HEAD 2>$null } catch { $branch = $null }
if ($branch -and $branch -ne 'HEAD') {
    $global:_hermesWorktreeName = $branch
} else {
    $global:_hermesWorktreeName = Split-Path -Leaf $repo
}
if (Test-Path function:prompt) {
    $global:_hermesSavedPrompt = (Get-Item function:prompt).ScriptBlock
} else {
    $global:_hermesSavedPrompt = $null
}

function global:_hermesWorktreeHere {
    # Prompt calls this after every command. Keep the user's exit code.
    $saved = $global:LASTEXITCODE
    $top = $null
    try { $top = & git rev-parse --show-toplevel 2>$null } catch { $top = $null }
    $global:LASTEXITCODE = $saved
    if (-not $top) { return $false }
    $here = [System.IO.Path]::GetFullPath($top).TrimEnd('\')
    $root = [System.IO.Path]::GetFullPath($global:_hermesWorktree).TrimEnd('\')
    return $here.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)
}

function global:hermes {
    if (-not (_hermesWorktreeHere)) {
        # Outside the checkout: run its launcher here, without changing folder.
        if ($global:_hermesLauncher -and (Test-Path -LiteralPath $global:_hermesLauncher)) {
            & $global:_hermesLauncher @args
            return
        }
        $here = (Get-Location).Path
        Write-Error "hermes: $here is outside $($global:_hermesWorktree) and $($global:_hermesWorktree)\.hermes\bin has no launcher; run setup-hermes.ps1" -ErrorAction Continue
        $global:LASTEXITCODE = 1
        return
    }
    Push-Location -LiteralPath $global:_hermesWorktree
    try {
        $py = $env:PYTHON
        if (-not $py) {
            foreach ($candidate in @(
                '.venv\Scripts\python.exe', 'venv\Scripts\python.exe',
                '.venv\bin\python', 'venv\bin\python'
            )) {
                if (Test-Path -LiteralPath $candidate) { $py = $candidate; break }
            }
        }
        if (-not $py) { $py = 'python' }
        & $py hermes @args
    } finally {
        Pop-Location
    }
}

function global:prompt {
    $prefix = ''
    if (_hermesWorktreeHere) { $prefix = "($($global:_hermesWorktreeName)) " }
    if ($global:_hermesSavedPrompt) {
        return $prefix + (& $global:_hermesSavedPrompt)
    }
    return "$prefix$($(Get-Location).Path)> "
}

function global:deactivate {
    foreach ($key in $global:_hermesKeys) {
        $saved = $global:_hermesSaved[$key]
        if ($saved.WasSet) { Set-Item -Path "env:$key" -Value $saved.Value }
        else { Remove-Item -Path "env:$key" -ErrorAction SilentlyContinue }
    }
    if ($global:_hermesSavedPrompt) {
        Set-Item -Path function:prompt -Value $global:_hermesSavedPrompt
    } else {
        Remove-Item function:prompt -ErrorAction SilentlyContinue
    }
    $global:_hermesKeys = $null
    $global:_hermesSaved = $null
    # The User PATH entry stays: global `hermes` is meant to outlive activation.
    $global:_hermesWorktree = $null
    $global:_hermesLauncher = $null
    $global:_hermesWorktreeName = $null
    $global:_hermesSavedPrompt = $null
    Remove-Item function:deactivate, function:hermes, function:_hermesWorktreeHere -ErrorAction SilentlyContinue
}
