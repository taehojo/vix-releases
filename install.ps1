$tempScript = Join-Path $env:TEMP "vix-install.ps1"

@'
$ProgressPreference = "Continue"

function Download-File {
    param($Url, $OutPath, $Label)
    Write-Host "    $Label"
    # Use Windows built-in curl.exe which shows inline progress
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & curl.exe -# -fL -o $OutPath $Url
        if ($LASTEXITCODE -ne 0) { throw "Download failed: $Url" }
    } else {
        # Fallback to .NET with manual progress
        $uri = [System.Uri]$Url
        $req = [System.Net.HttpWebRequest]::Create($uri)
        $req.UserAgent = "vix-installer"
        $resp = $req.GetResponse()
        $total = $resp.ContentLength
        $stream = $resp.GetResponseStream()
        $file = [System.IO.File]::Create($OutPath)
        $buffer = New-Object byte[] 65536
        $totalRead = 0
        $lastLine = ""
        try {
            do {
                $read = $stream.Read($buffer, 0, $buffer.Length)
                if ($read -gt 0) {
                    $file.Write($buffer, 0, $read)
                    $totalRead += $read
                    if ($total -gt 0) {
                        $mb = [math]::Round($totalRead / 1MB, 1)
                        $totalMb = [math]::Round($total / 1MB, 1)
                        $pct = [math]::Floor(($totalRead / $total) * 100)
                        $bar = "#" * [math]::Floor($pct / 5)
                        $bar = $bar.PadRight(20, "-")
                        $line = "    [$bar] $pct% ($mb/$totalMb MB)"
                        if ($line -ne $lastLine) {
                            Write-Host "`r$line" -NoNewline
                            $lastLine = $line
                        }
                    }
                }
            } while ($read -gt 0)
            Write-Host ""
        } finally {
            $file.Close(); $stream.Close(); $resp.Close()
        }
    }
}

function Start-Spinner {
    param($Label, $Action)
    $job = Start-Job -ScriptBlock $Action
    $spinner = @('|', '/', '-', '\')
    $i = 0
    $startTime = Get-Date
    while ($job.State -eq 'Running') {
        $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
        Write-Host "`r    $($spinner[$i % 4]) $Label ($elapsed`s)" -NoNewline
        Start-Sleep -Milliseconds 200
        $i++
    }
    $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
    Write-Host "`r    $Label done ($elapsed`s)                    "
    Receive-Job $job -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $job -Force -ErrorAction SilentlyContinue
}

function Install-VixBinary {
    param($InstallDir)
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/taehojo/vix-releases/releases/latest" -Headers @{"User-Agent"="vix"}
    $ver = $rel.tag_name
    $url = "https://github.com/taehojo/vix-releases/releases/download/$ver/vix-windows-x64.exe"
    $out = Join-Path $InstallDir "vix.exe"
    Download-File -Url $url -OutPath $out -Label "Downloading vix $ver..."
    return $out
}

function Save-Config {
    param($ConfigDir, $Model, $Mode)
    $config = @{ default_model = $Model; mode = $Mode } | ConvertTo-Json
    Set-Content -Path (Join-Path $ConfigDir "config.json") -Value $config
}

function Setup-Path {
    param($InstallDir)
    $userPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($userPath -notlike "*\.vix\bin*") {
        [Environment]::SetEnvironmentVariable("PATH", "$InstallDir;$userPath", "User")
    }
    $env:PATH = "$InstallDir;$env:PATH"
}

Write-Host ""
Write-Host "  vix - AI Coding Agent" -ForegroundColor Cyan
Write-Host "  =====================" -ForegroundColor Cyan
Write-Host ""

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $installDir = Join-Path $env:USERPROFILE ".vix\bin"
    $configDir = Join-Path $env:USERPROFILE ".vix"
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null

    Write-Host "  Choose how to use vix:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    1) Local LLM - free, unlimited, offline (recommended)" -ForegroundColor Green
    Write-Host "    2) Cloud API - choose your own model (OpenAI, Claude, Gemma, etc.)" -ForegroundColor Green
    Write-Host ""
    $mode = Read-Host "  Select [1/2]"
    Write-Host ""
    if (-not $mode) { $mode = "1" }

    # ========================================
    # MODE 1: LOCAL LLM
    # ========================================
    if ($mode -eq "1") {
        $ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
        $cores = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum

        $gpuName = "none"
        $vramGb = 0
        try {
            $gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
            foreach ($gpu in $gpus) {
                if ($gpu.AdapterRAM -and $gpu.AdapterRAM -gt 0) {
                    $gb = [math]::Round($gpu.AdapterRAM / 1GB)
                    if ($gb -gt $vramGb) { $vramGb = $gb; $gpuName = $gpu.Name }
                }
            }
            $nvsmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
            if ($nvsmi) {
                $nvOut = & nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1
                if ($nvOut) {
                    $parts = $nvOut -split ","
                    $gpuName = $parts[0].Trim()
                    $vramGb = [math]::Round([int]($parts[1].Trim()) / 1024)
                }
            }
        } catch {}

        Write-Host "  Detected system:" -ForegroundColor Yellow
        Write-Host "    RAM:   ${ramGb}GB"
        Write-Host "    CPU:   ${cores} cores"
        Write-Host "    GPU:   $gpuName (${vramGb}GB VRAM)"
        Write-Host ""

        if     ($vramGb -ge 80) { $model = "qwen2.5:72b"; $mn = "Qwen 2.5 72B"; $ms = "47GB" }
        elseif ($vramGb -ge 24) { $model = "qwen2.5-coder:32b"; $mn = "Qwen 2.5 Coder 32B"; $ms = "20GB" }
        elseif ($vramGb -ge 12) { $model = "deepseek-coder-v2:16b"; $mn = "DeepSeek Coder V2 16B"; $ms = "9GB" }
        elseif ($vramGb -ge 8)  { $model = "qwen2.5-coder:7b"; $mn = "Qwen 2.5 Coder 7B"; $ms = "4.7GB" }
        elseif ($vramGb -ge 5)  { $model = "qwen2.5-coder:3b"; $mn = "Qwen 2.5 Coder 3B"; $ms = "1.9GB" }
        elseif ($vramGb -ge 4)  { $model = "qwen2.5-coder:1.5b"; $mn = "Qwen 2.5 Coder 1.5B"; $ms = "986MB" }
        elseif ($ramGb -ge 16)  { $model = "gemma3:4b"; $mn = "Gemma 3 4B"; $ms = "3.3GB" }
        elseif ($ramGb -ge 8)   { $model = "gemma3:1b"; $mn = "Gemma 3 1B"; $ms = "815MB" }
        else                    { $model = "llama3.2:1b"; $mn = "Llama 3.2 1B"; $ms = "1.3GB" }

        Write-Host "  Recommended model: " -NoNewline -ForegroundColor Yellow
        Write-Host "$mn ($ms)" -ForegroundColor Green
        Write-Host ""
        $confirm = Read-Host "  Install now? [Y/n]"
        if ($confirm -eq "n" -or $confirm -eq "N") { Write-Host "  Cancelled."; return }
        Write-Host ""

        Write-Host "  [1/3] vix" -ForegroundColor Cyan
        $vixExe = Install-VixBinary -InstallDir $installDir

        $ollamaPortablePath = Join-Path $env:USERPROFILE ".vix\ollama"
        $ollamaExe = Join-Path $ollamaPortablePath "ollama.exe"

        if (-not (Test-Path $ollamaExe)) {
            Write-Host ""
            Write-Host "  [2/3] Ollama" -ForegroundColor Cyan

            $ollamaZip = Join-Path $env:TEMP "ollama-windows-amd64.zip"
            Download-File -Url "https://github.com/ollama/ollama/releases/latest/download/ollama-windows-amd64.zip" -OutPath $ollamaZip -Label "Downloading Ollama portable..."

            Write-Host "    Extracting..."
            New-Item -ItemType Directory -Force -Path $ollamaPortablePath | Out-Null
            Expand-Archive -Path $ollamaZip -DestinationPath $ollamaPortablePath -Force
            Remove-Item $ollamaZip -ErrorAction SilentlyContinue
            Write-Host "    Done." -ForegroundColor Green
        } else {
            Write-Host ""
            Write-Host "  [2/3] Ollama already installed." -ForegroundColor Green
        }

        $env:PATH = "$ollamaPortablePath;$env:PATH"

        # Kill any existing ollama processes, then start our portable one
        Get-Process -Name "ollama" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Get-Process -Name "ollama app" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1

        Write-Host "    Starting Ollama service..."
        Start-Process -FilePath $ollamaExe -ArgumentList "serve" -WindowStyle Hidden

        # Wait for Ollama to be ready (up to 15 seconds)
        $ready = $false
        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep -Seconds 1
            try {
                $null = Invoke-WebRequest -Uri "http://localhost:11434" -UseBasicParsing -TimeoutSec 1 -ErrorAction Stop
                $ready = $true
                break
            } catch {}
        }
        if (-not $ready) {
            Write-Host "    Warning: Ollama did not start within 15s" -ForegroundColor Yellow
        }

        # Set up auto-start on login via Windows startup
        $startupBat = Join-Path $env:USERPROFILE ".vix\start-ollama.bat"
        @"
@echo off
tasklist /FI "IMAGENAME eq ollama.exe" 2>NUL | find /I "ollama.exe" >NUL
if errorlevel 1 start "" /B "$ollamaExe" serve
"@ | Set-Content -Path $startupBat -Encoding ASCII

        $startupFolder = [Environment]::GetFolderPath("Startup")
        $startupLink = Join-Path $startupFolder "vix-ollama.bat"
        Copy-Item $startupBat $startupLink -Force -ErrorAction SilentlyContinue

        Write-Host ""
        Write-Host "  [3/3] $mn ($ms)" -ForegroundColor Cyan
        Write-Host "    Downloading model (ollama will show progress)..."
        Write-Host ""
        & $ollamaExe pull $model
        Write-Host ""

        Save-Config -ConfigDir $configDir -Model $model -Mode "local"
        Setup-Path -InstallDir $installDir

        Write-Host ""
        Write-Host "  Done! Default model: $mn (local, free, unlimited)" -ForegroundColor Green
        Write-Host "  Run 'vix' anytime to start."
        Write-Host ""
        Write-Host "  Starting vix..." -ForegroundColor Cyan
        Write-Host ""
        & $vixExe
    }

    # ========================================
    # MODE 2: CLOUD API
    # ========================================
    elseif ($mode -eq "2") {
        Write-Host "  Choose your API model:" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "    1) Gemma 4 31B   (free, Google AI Studio)"
        Write-Host "    2) Gemini Flash  (free, higher limits)"
        Write-Host "    3) Llama 3.3 70B (free, Groq)"
        Write-Host "    4) GPT-4o        (paid, OpenAI)"
        Write-Host "    5) Claude Sonnet (paid, Anthropic)"
        Write-Host ""
        $modelChoice = Read-Host "  Select [1-5]"
        Write-Host ""

        switch ($modelChoice) {
            "1" { $model = "gemma"; $provName = "Google AI Studio"; $keyVar = "GOOGLE_API_KEY"; $keyUrl = "https://aistudio.google.com/app/apikey" }
            "2" { $model = "gemini"; $provName = "Google AI Studio"; $keyVar = "GOOGLE_API_KEY"; $keyUrl = "https://aistudio.google.com/app/apikey" }
            "3" { $model = "llama"; $provName = "Groq"; $keyVar = "GROQ_API_KEY"; $keyUrl = "https://console.groq.com/keys" }
            "4" { $model = "gpt-4o"; $provName = "OpenAI"; $keyVar = "OPENAI_API_KEY"; $keyUrl = "https://platform.openai.com/api-keys" }
            "5" { $model = "claude"; $provName = "Anthropic"; $keyVar = "ANTHROPIC_API_KEY"; $keyUrl = "https://console.anthropic.com/settings/keys" }
            default { Write-Host "  Invalid choice."; return }
        }

        Write-Host "  Selected: $model ($provName)" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Get your API key at:" -ForegroundColor Yellow
        Write-Host "  $keyUrl" -ForegroundColor Cyan
        Write-Host ""
        $apiKey = Read-Host "  Paste API key"
        Write-Host ""

        if (-not $apiKey) {
            Write-Host "  No key entered. Cancelling."
            return
        }

        Write-Host "  [1/1] vix" -ForegroundColor Cyan
        $vixExe = Install-VixBinary -InstallDir $installDir

        [Environment]::SetEnvironmentVariable($keyVar, $apiKey, "User")
        Set-Item -Path "env:$keyVar" -Value $apiKey

        Save-Config -ConfigDir $configDir -Model $model -Mode "api"
        Setup-Path -InstallDir $installDir

        Write-Host ""
        Write-Host "  Done! Default model: $model ($provName)" -ForegroundColor Green
        Write-Host "  API key saved to user environment." -ForegroundColor Green
        Write-Host "  Run 'vix' anytime to start."
        Write-Host ""
        Write-Host "  Starting vix..." -ForegroundColor Cyan
        Write-Host ""
        & $vixExe
    }
    else {
        Write-Host "  Invalid choice."
    }
} catch {
    Write-Host ""
    Write-Host "  Error: $_" -ForegroundColor Red
    Write-Host ""
    Read-Host "  Press Enter to close"
}
'@ | Set-Content -Path $tempScript -Encoding UTF8

& $tempScript
Remove-Item $tempScript -ErrorAction SilentlyContinue
