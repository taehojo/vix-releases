$tempScript = Join-Path $env:TEMP "vix-install.ps1"

@'
$ProgressPreference = "Continue"

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
    $read = 0
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
        $file.Close()
        $stream.Close()
        $resp.Close()
    }
    Write-Progress -Activity $Label -Completed
}

Write-Host ""
Write-Host "  vix - AI Coding Agent" -ForegroundColor Cyan
Write-Host "  =====================" -ForegroundColor Cyan
Write-Host ""

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # === Detect system ===
    $ramGb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
    $cores = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
    $arch = $env:PROCESSOR_ARCHITECTURE

    # Detect GPU + VRAM
    $gpuName = "none"
    $vramGb = 0
    try {
        $gpus = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue
        foreach ($gpu in $gpus) {
            if ($gpu.AdapterRAM -and $gpu.AdapterRAM -gt 0) {
                $gb = [math]::Round($gpu.AdapterRAM / 1GB)
                if ($gb -gt $vramGb) {
                    $vramGb = $gb
                    $gpuName = $gpu.Name
                }
            }
        }
        # nvidia-smi if available (more accurate for NVIDIA)
        $nvsmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
        if ($nvsmi) {
            $nvOutput = & nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1
            if ($nvOutput) {
                $parts = $nvOutput -split ","
                $gpuName = $parts[0].Trim()
                $vramMb = [int]($parts[1].Trim())
                $vramGb = [math]::Round($vramMb / 1024)
            }
        }
    } catch {}

    Write-Host "  Detected system:" -ForegroundColor Yellow
    Write-Host "    OS:    Windows $arch"
    Write-Host "    RAM:   ${ramGb}GB"
    Write-Host "    CPU:   ${cores} cores"
    Write-Host "    GPU:   $gpuName (${vramGb}GB VRAM)"
    Write-Host ""

    # === Recommend model ===
    if ($vramGb -ge 80) {
        $model = "qwen2.5:72b"; $modelName = "Qwen 2.5 72B"; $modelSize = "47GB"; $tier = "gpu-ultra"
    } elseif ($vramGb -ge 48) {
        $model = "qwen2.5-coder:32b"; $modelName = "Qwen 2.5 Coder 32B"; $modelSize = "20GB"; $tier = "gpu-xlarge"
    } elseif ($vramGb -ge 24) {
        $model = "qwen2.5-coder:32b"; $modelName = "Qwen 2.5 Coder 32B"; $modelSize = "20GB"; $tier = "gpu-large"
    } elseif ($vramGb -ge 12) {
        $model = "deepseek-coder-v2:16b"; $modelName = "DeepSeek Coder V2 16B"; $modelSize = "9GB"; $tier = "gpu-medium"
    } elseif ($vramGb -ge 6) {
        $model = "qwen2.5-coder:7b"; $modelName = "Qwen 2.5 Coder 7B"; $modelSize = "4.7GB"; $tier = "gpu-small"
    } elseif ($ramGb -ge 16) {
        $model = "gemma3:4b"; $modelName = "Gemma 3 4B"; $modelSize = "3.3GB"; $tier = "medium"
    } elseif ($ramGb -ge 8) {
        $model = "gemma3:1b"; $modelName = "Gemma 3 1B"; $modelSize = "815MB"; $tier = "small"
    } else {
        $model = "llama3.2:1b"; $modelName = "Llama 3.2 1B"; $modelSize = "1.3GB"; $tier = "minimal"
    }

    Write-Host "  Recommended model:" -ForegroundColor Yellow
    Write-Host "    $modelName ($modelSize)" -ForegroundColor Green
    Write-Host "    Tier: $tier"
    Write-Host "    Runs locally - free, unlimited, offline"
    Write-Host ""

    $confirm = Read-Host "  Install now? [Y/n]"
    if ($confirm -eq "n" -or $confirm -eq "N") {
        Write-Host "  Cancelled."
        return
    }
    Write-Host ""

    $installDir = Join-Path $env:USERPROFILE ".vix\bin"
    $configDir = Join-Path $env:USERPROFILE ".vix"
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    New-Item -ItemType Directory -Force -Path $configDir | Out-Null

    # === Step 1: Download vix binary ===
    Write-Host "  [1/3] Downloading vix..." -ForegroundColor Cyan
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/taehojo/vix-releases/releases/latest" -Headers @{"User-Agent"="vix"}
    $ver = $rel.tag_name
    $url = "https://github.com/taehojo/vix-releases/releases/download/$ver/vix-windows-x64.exe"
    $out = Join-Path $installDir "vix.exe"
    Download-WithProgress -Url $url -OutPath $out -Label "Downloading vix $ver"
    Write-Host "        Done." -ForegroundColor Green

    # === Step 2: Install Ollama ===
    $ollamaCmd = Get-Command ollama -ErrorAction SilentlyContinue
    if (-not $ollamaCmd) {
        Write-Host "  [2/3] Installing Ollama..." -ForegroundColor Cyan
        $ollamaInstaller = Join-Path $env:TEMP "OllamaSetup.exe"
        Download-WithProgress -Url "https://ollama.com/download/OllamaSetup.exe" -OutPath $ollamaInstaller -Label "Downloading Ollama installer"
        Write-Host "        Running installer (silent)..."
        Start-Process -FilePath $ollamaInstaller -ArgumentList "/SILENT" -Wait
        Write-Host "        Done." -ForegroundColor Green

        $ollamaPath = "$env:LOCALAPPDATA\Programs\Ollama"
        if (Test-Path $ollamaPath) {
            $env:PATH = "$ollamaPath;$env:PATH"
        }
    } else {
        Write-Host "  [2/3] Ollama already installed." -ForegroundColor Green
    }

    # Start Ollama
    $ollamaProc = Get-Process ollama -ErrorAction SilentlyContinue
    if (-not $ollamaProc) {
        Start-Process -FilePath "ollama" -ArgumentList "serve" -WindowStyle Hidden
        Start-Sleep -Seconds 3
    }

    # === Step 3: Pull model ===
    Write-Host "  [3/3] Downloading $modelName ($modelSize)..." -ForegroundColor Cyan
    Write-Host ""
    & ollama pull $model
    Write-Host ""
    Write-Host "        Done." -ForegroundColor Green

    # === Save config ===
    $config = @{
        default_model = $model
        tier = $tier
        detected = @{
            ram_gb = $ramGb
            vram_gb = $vramGb
            cores = $cores
            gpu = $gpuName
        }
    } | ConvertTo-Json
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
