$tempScript = Join-Path $env:TEMP "vix-install.ps1"

@'
Write-Host ""
Write-Host "  vix - AI Coding Agent" -ForegroundColor Cyan
Write-Host "  =====================" -ForegroundColor Cyan
Write-Host ""

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Host "  Checking latest version..."

    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/taehojo/vix-releases/releases/latest" -Headers @{"User-Agent"="vix"}
    $ver = $rel.tag_name
    Write-Host "  Version: $ver"

    $dir = Join-Path $env:USERPROFILE ".vix\bin"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    $url = "https://github.com/taehojo/vix-releases/releases/download/$ver/vix-windows-x64.exe"
    $out = Join-Path $dir "vix.exe"

    Write-Host "  Downloading..."
    Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
    Write-Host "  Downloaded!" -ForegroundColor Green

    $p = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($p -notlike "*\.vix*") {
        [Environment]::SetEnvironmentVariable("PATH", "$dir;$p", "User")
        Write-Host "  Added to PATH" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "  vix $ver installed!" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Next steps:"
    Write-Host "    1. Open a NEW PowerShell window"
    Write-Host "    2. Get free API key at https://aistudio.google.com/app/apikey"
    Write-Host '    3. $env:GOOGLE_API_KEY="your-key"'
    Write-Host "    4. vix --model gemma"
    Write-Host ""
} catch {
    Write-Host "  Error: $_" -ForegroundColor Red
    Write-Host ""
}
Read-Host "Press Enter to close"
'@ | Set-Content -Path $tempScript -Encoding UTF8

& $tempScript
Remove-Item $tempScript -ErrorAction SilentlyContinue
