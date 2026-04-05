$tempScript = Join-Path $env:TEMP "vix-install.ps1"

@'
Write-Host ""
Write-Host "  vix - AI Coding Agent" -ForegroundColor Cyan
Write-Host "  =====================" -ForegroundColor Cyan
Write-Host ""

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # === Detect system ===
    $ramBytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
    $ramGb = [math]::Round($ramBytes / 1GB)
    $cores = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
    $arch = $env:PROCESSOR_ARCHITECTURE

    Write-Host "  Detected system:"
    Write-Host "    OS:    Windows $arch"
    Write-Host "    RAM:   ${ramGb}GB"
    Write-Host "    CPU:   ${cores} cores"
    Write-Host ""

    # === Recommend model based on RAM ===
    if ($ramGb -ge 16) {
        $model = "gemma3:4b"
        $modelName = "Gemma 3 4B"
        $modelSize = "3.3GB"
        $modelShortcut = "local-medium"
    } elseif ($ramGb -ge 8) {
        $model = "gemma3:1b"
        $modelName = "Gemma 3 1B"
        $modelSize = "815MB"
        $modelShortcut = "local"
    } else {
        $model = "llama3.2:1b"
        $modelName = "Llama 3.2 1B"
        $modelSize = "1.3GB"
        $modelShortcut = "local-small"
    }

    Write-Host "  Recommended model for your system:" -ForegroundColor Yellow
    Write-Host "    $modelName (download size: $modelSize)" -ForegroundColor Yellow
    Write-Host "    This runs locally on your CPU - free, unlimited, offline" -ForegroundColor Yellow
    Write-Host ""

    $confirm = Read-Host "  Install now? [Y/n]"
    if ($confirm -eq "n" -or $confirm -eq "N") {
        Write-Host "  Cancelled."
        return
    }
    Write-Host ""

    # === Download vix binary ===
    $installDir = Join-Path $env:USERPROFILE ".vix\bin"
    $configDir = Join-Path $env:USERPROFILE ".vix"
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null

    Write-Host "  [1/3] Downloading vix..."
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/taehojo/vix-releases/releases/latest" -Headers @{"User-Agent"="vix"}
    $ver = $rel.tag_name
    $url = "https://github.com/taehojo/vix-releases/releases/download/$ver/vix-windows-x64.exe"
    $out = Join-Path $installDir "vix.exe"
    Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
    Write-Host "        Done."

    # === Install Ollama ===
    $ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
    if (-not $ollamaCmd) {
        Write-Host "  [2/3] Installing Ollama..."
        $ollamaInstaller = Join-Path $env:TEMP "OllamaSetup.exe"
        Invoke-WebRequest -Uri "https://ollama.com/download/OllamaSetup.exe" -OutFile $ollamaInstaller -UseBasicParsing
        Start-Process -FilePath $ollamaInstaller -ArgumentList "/SILENT" -Wait
        Write-Host "        Done."

        # Add Ollama to PATH for current session
        $ollamaPath = "$env:LOCALAPPDATA\Programs\Ollama"
        if (Test-Path $ollamaPath) {
            $env:PATH = "$ollamaPath;$env:PATH"
        }
    } else {
        Write-Host "  [2/3] Ollama already installed."
    }

    # === Start Ollama service ===
    $ollamaProc = Get-Process ollama -ErrorAction SilentlyContinue
    if (-not $ollamaProc) {
        Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
        Start-Sleep -Seconds 3
    }

    # === Pull model ===
    Write-Host "  [3/3] Downloading $modelName..."
    & ollama pull $model
    Write-Host "        Done."

    # === Save default model ===
    $config = @{ default_model = $modelShortcut } | ConvertTo-Json
    Set-Content -Path (Join-Path $configDir "config.json") -Value $config

    # === Add to PATH ===
    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($userPath -notlike "*\.vix\bin*") {
        [Environment]::SetEnvironmentVariable("PATH", "$installDir;$userPath", "User")
    }
    $env:PATH = "$installDir;$env:PATH"

    Write-Host ""
    Write-Host "  vix installed successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Default model: $modelName (local, free, unlimited)" -ForegroundColor Cyan
    Write-Host "  Run 'vix' anytime to start."
    Write-Host ""
    Write-Host "  Starting vix now..." -ForegroundColor Cyan
    Write-Host ""
    & $out
} catch {
    Write-Host ""
    Write-Host "  Error: $_" -ForegroundColor Red
    Write-Host ""
    Read-Host "  Press Enter to close"
}
'@ | Set-Content -Path $tempScript -Encoding UTF8

& $tempScript
Remove-Item $tempScript -ErrorAction SilentlyContinue
