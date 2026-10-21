# Installs esp32agent on Windows from GitHub Releases:
#   irm https://raw.githubusercontent.com/onehumanbeing/esp32-iphone-agent/main/cli/install/install.ps1 | iex
# Env: ESP32AGENT_VERSION (default: latest), ESP32AGENT_BIN_DIR (default ~\.local\bin),
#      ESP32AGENT_ARCHIVE=C:\path\esp32agent_windows_<arch>.zip for a local build (checksums.txt next to it, or
#      ESP32AGENT_CHECKSUMS), ESP32AGENT_FFMPEG=yes|no to answer the ffmpeg question without a prompt.
$ErrorActionPreference = 'Stop'
$repo = 'onehumanbeing/esp32-iphone-agent'
$binDir = if ($env:ESP32AGENT_BIN_DIR) { $env:ESP32AGENT_BIN_DIR } else { Join-Path $HOME '.local\bin' }

$arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'ARM64' { 'arm64' } 'AMD64' { 'amd64' } default { throw "unsupported CPU $env:PROCESSOR_ARCHITECTURE" } }
$name = "esp32agent_windows_$arch.zip"
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("esp32agent-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $zip = Join-Path $tmp $name
    $sums = Join-Path $tmp 'checksums.txt'
    if ($env:ESP32AGENT_ARCHIVE) {
        Copy-Item $env:ESP32AGENT_ARCHIVE $zip
        $src = if ($env:ESP32AGENT_CHECKSUMS) { $env:ESP32AGENT_CHECKSUMS } else { Join-Path (Split-Path $env:ESP32AGENT_ARCHIVE) 'checksums.txt' }
        Copy-Item $src $sums
        Write-Host "installing esp32agent from $env:ESP32AGENT_ARCHIVE"
    } else {
        $version = $env:ESP32AGENT_VERSION
        if (-not $version) {
            $tag = (Invoke-RestMethod "https://api.github.com/repos/$repo/releases?per_page=50" | Where-Object { $_.tag_name -like 'cli-v*' } | Select-Object -First 1).tag_name
            if (-not $tag) { throw "no cli-v* release found on github.com/$repo" }
            $version = $tag.Substring(5)
        }
        $url = "https://github.com/$repo/releases/download/cli-v$version"
        Write-Host "downloading esp32agent $version (windows/$arch)"
        Invoke-WebRequest "$url/$name" -OutFile $zip -UseBasicParsing
        Invoke-WebRequest "$url/checksums.txt" -OutFile $sums -UseBasicParsing
    }

    $line = Get-Content $sums | Where-Object { ($_ -split '\s+')[1] -in @($name, "*$name") } | Select-Object -First 1
    if (-not $line) { throw "$name is not listed in checksums.txt" }
    $want = ($line -split '\s+')[0].ToLower()
    $got = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
    if ($want -ne $got) { throw "checksum mismatch for $name (expected $want, got $got)" }

    Expand-Archive $zip -DestinationPath $tmp -Force
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    $dest = Join-Path $binDir 'esp32agent.exe'
    Copy-Item (Join-Path $tmp 'esp32agent.exe') $dest -Force
    Write-Host "installed $dest ($(& $dest version))"
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not (($env:Path + ';' + $userPath) -split ';' | Where-Object { $_ -eq $binDir })) {
    Write-Warning "$binDir is not on your PATH. Add it: [Environment]::SetEnvironmentVariable('Path', `"$binDir;`" + [Environment]::GetEnvironmentVariable('Path','User'), 'User')"
}

# ffmpeg decodes the mirrored screen (screenshots need it).
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    $answer = $env:ESP32AGENT_FFMPEG
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget -and -not $answer) { $answer = Read-Host 'ffmpeg is needed for screenshots. Install it with winget now? [y/N]' }
    if ($winget -and $answer -match '^(y|yes)$') { winget install --id Gyan.FFmpeg -e --accept-source-agreements --accept-package-agreements }
    else { Write-Host 'ffmpeg not found: install it for screenshots (winget install Gyan.FFmpeg)' }
}

Write-Host @'

Next:
  1. Plug the board into the iPhone, then within 3 minutes:  esp32agent pair
  2. On the iPhone: Control Center > Screen Mirroring > ESP32 Agent
  3. Let your agent use it:
       claude mcp add esp32agent -- esp32agent mcp
       codex mcp add esp32agent -- esp32agent mcp
       esp32agent skill install      (Claude Code skill)
'@
