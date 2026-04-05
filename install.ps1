$tempScript = Join-Path $env:TEMP "vix-install.ps1"

@'
function Download-WithProgress {
    param($Url, $OutPath, $Label)
    $uri = [System.Uri]$Url
    $req = [System.Net.HttpWebRequest]::Create($uri)
    $req.UserAgent = "vix-installer"
    $resp = $req.GetResponse()
    $total = $resp.ContentLength
    $stream = $resp.GetResponseStream()
    $file = [System.IO.File]::Create($OutPath)
    $buffer = New-Object byte[] 65536
    $totalRead = 0
    $lastPercent = -1
    try {
        do {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -gt 0) {
                $file.Write($buffer, 0, $read)
                $totalRead += $read
                if ($total -gt 0) {
                    $percent = [math]::Floor(($totalRead / $total) * 100)
                    if ($percent -ne $lastPercent) {
                        $mb = [math]::Round($totalRead / 1MB, 1)
                        $totalMb = [math]::Round($total / 1MB, 1)
                        Write-Progress -Activity $Label -Status "$mb MB / $totalMb MB" -PercentComplete $percent
                        $lastPercent = $percent
                    }
                }
            }
        } while ($read -gt 0)
    } finally {
        $file.Close(); $stream.Close(); $resp.Close()
    }
    Write-Progress -Activity $Label -Completed
}

function Install-VixBinary {
    param($InstallDir)
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/taehojo/vix-releases/releases/latest" -Headers @{"User-Agent"="vix"}
    $ver = $rel.tag_name
    $url = "https://github.com/taehojo/vix-releases/releases/download/$ver/vix-windows-x64.exe"
    $out = Join-Path $InstallDir "vix.exe"
    Download-WithProgress -Url $url -OutPath $out -Label "Downloading vix $ver"
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

    # === Choose mode ===
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
        elseif ($vramGb -ge 6)  { $model = "qwen2.5-coder:7b"; $mn = "Qwen 2.5 Coder 7B"; $ms = "4.7GB" }
        elseif ($ramGb -ge 16)  { $model = "gemma3:4b"; $mn = "Gemma 3 4B"; $ms = "3.3GB" }
        elseif ($ramGb -ge 8)   { $model = "gemma3:1b"; $mn = "Gemma 3 1B"; $ms = "815MB" }
        else                    { $model = "llama3.2:1b"; $mn = "Llama 3.2 1B"; $ms = "1.3GB" }

        Write-Host "  Recommended model: " -NoNewline -ForegroundColor Yellow
        Write-Host "$mn ($ms)" -ForegroundColor Green
        Write-Host ""
        $confirm = Read-Host "  Install now? [Y/n]"
        if ($confirm -eq "n" -or $confirm -eq "N") { Write-Host "  Cancelled."; return }
        Write-Host ""

        Write-Host "  [1/3] Downloading vix..." -ForegroundColor Cyan
        $vixExe = Install-VixBinary -InstallDir $installDir

        $ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
        if (-not $ollamaCmd) {
            Write-Host "  [2/3] Installing Ollama..." -ForegroundColor Cyan
            $ollamaInstaller = Join-Path $env:TEMP "OllamaSetup.exe"
            Download-WithProgress -Url "https://ollama.com/download/OllamaSetup.exe" -OutPath $ollamaInstaller -Label "Downloading Ollama"
            Write-Host "        Running installer (silent)..."
            Start-Process -FilePath $ollamaInstaller -ArgumentList "/SILENT" -Wait
            $ollamaPath = "$env:LOCALAPPDATA\Programs\Ollama"
            if (Test-Path $ollamaPath) { $env:PATH = "$ollamaPath;$env:PATH" }
        } else {
            Write-Host "  [2/3] Ollama already installed." -ForegroundColor Green
        }

        $ollamaProc = Get-Process ollama -ErrorAction SilentlyContinue
        if (-not $ollamaProc) {
            Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
            Start-Sleep -Seconds 3
        }

        Write-Host "  [3/3] Downloading $mn ($ms)..." -ForegroundColor Cyan
        Write-Host ""
        & ollama pull $model
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

        Write-Host "  [1/1] Downloading vix..." -ForegroundColor Cyan
        $vixExe = Install-VixBinary -InstallDir $installDir

        # Save API key as user environment variable
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
