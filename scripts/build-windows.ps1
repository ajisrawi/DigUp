# Builds DigUp for Windows: the `digup` helper (Swift), llama.cpp and the C libraries it needs, and the Tauri shell
# (shell/), packaged as an installer in shell/src-tauri/target/release/bundle/nsis/.
#   powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1
#   ... -SkipInstaller     stops after staging build.windows\ (the helper and its DLLs) and building the shell's exe
# Needs Visual Studio 2022 (or its Build Tools) with the C++ workload, Git for Windows, Python 3, the Swift toolchain
# (6.4 or later, swift.org), Rust (rustup) and Node.js (for Tauri's CLI). CMake and Ninja come from PATH, else from uv.
param([switch]$SkipInstaller)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Need($what, $path) { if (-not $path -or -not (Test-Path $path)) { throw "Can't find $what" }; $path }

# The tools: Visual Studio's x64 environment (for llama.cpp and dumpbin), Git's bash (for the vendor scripts), Swift.
$vswhere = Need 'vswhere (Visual Studio 2022)' "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$vcvars = Need 'vcvars64.bat (the C++ workload)' "$vs\VC\Auxiliary\Build\vcvars64.bat"
$bash = Need "Git for Windows' bash" "$env:ProgramFiles\Git\bin\bash.exe"
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') +
            ";$env:USERPROFILE\.cargo\bin;$env:USERPROFILE\.local\bin"
if (-not $env:SDKROOT) { $env:SDKROOT = [Environment]::GetEnvironmentVariable('SDKROOT', 'User') }
$swift = (Get-Command swift -ErrorAction SilentlyContinue).Source
if (-not $swift) { throw "Can't find swift: install the toolchain from swift.org" }
if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) { uv tool install cmake; uv tool install ninja }

# 1. SQLite, stb, miniz and PDFium (Vendor/), then llama.cpp as DLLs, built with MSVC. Each does nothing when current.
$unix = '/' + ($root -replace ':', '' -replace '\\', '/').Substring(0, 1).ToLower() + ($root -replace '^.:', '' -replace '\\', '/')
cmd /c "call `"$vcvars`" >nul 2>&1 &&`"$bash`" -c `"cd '$unix' && scripts/fetch-vendor.sh && scripts/build-llama.sh`""
if ($LASTEXITCODE) { throw 'Building the vendored libraries failed' }

# 2. The helper. Vendor\llama\lib and the PDFium DLL go on PATH so `swift build` can run anything it links.
$env:Path = "$root\Vendor\llama\lib;$root\Vendor\pdfium\bin;$env:Path"
swift build -c release --product digup
if ($LASTEXITCODE) { throw 'swift build failed' }
$bin = (swift build -c release --show-bin-path).Trim()

# 3. build.windows\helper: digup.exe and every DLL it loads that isn't Windows' own (Swift's runtime, the C++ runtime,
#    llama.cpp, PDFium), found by walking its imports. ggml's backends load at run time, so they're copied whole. Then
#    ffmpeg, which the helper runs.
$stage = "$root\build.windows\helper"
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item "$bin\digup.exe" $stage
Copy-Item "$root\Vendor\llama\lib\*.dll" $stage
Copy-Item "$root\Resources\Acknowledgements.txt" $stage
$runtime = Split-Path -Parent (Get-Command swiftCore.dll -ErrorAction SilentlyContinue).Source
if (-not $runtime) { $runtime = (Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Runtimes\*\usr\bin" | Select-Object -Last 1).FullName }
$sources = @($runtime, "$root\Vendor\pdfium\bin", "$root\Vendor\llama\lib")
$dumpbin = Get-ChildItem "$vs\VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe" | Select-Object -Last 1 -ExpandProperty FullName
$queue = [System.Collections.Generic.Queue[string]]::new()
Get-ChildItem $stage -Filter *.exe | ForEach-Object { $queue.Enqueue($_.FullName) }
Get-ChildItem $stage -Filter *.dll | ForEach-Object { $queue.Enqueue($_.FullName) }
while ($queue.Count) {
    $file = $queue.Dequeue()
    $imports = & $dumpbin /nologo /dependents $file | Where-Object { $_ -match '^\s+\S+\.dll\s*$' } | ForEach-Object { $_.Trim() }
    foreach ($dll in $imports) {
        if (Test-Path "$stage\$dll") { continue }
        $found = $sources | ForEach-Object { Join-Path $_ $dll } | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($found) { Copy-Item $found $stage; $queue.Enqueue("$stage\$dll") }
    }
}
# ffmpeg and ffprobe beside the helper, where it looks first: Windows has no AVFoundation, so audio, video and HEIC,
# WebP, TIFF and AVIF pictures go through them, and they must be 8.1 or later (Images+Portable.swift). An LGPL build
# (BtbN/FFmpeg-Builds) at a pinned date, its zip checked; ffplay isn't needed. Its license and where its source is go
# with it.
$ffmpegTag = 'autobuild-2026-10-13-13-05'
$ffmpegName = 'ffmpeg-n8.1.3-18-g46d899d7a0-win64-lgpl-shared-8.1'
$ffmpegSha = '19d92dfb1481e72e4e8f94844bf609418297a646f33deb6864c409ca752469c4'
$ffmpegZip = "$root\Vendor\ffmpeg-download\$ffmpegName.zip"
if (-not (Test-Path $ffmpegZip) -or (Get-FileHash $ffmpegZip -Algorithm SHA256).Hash -ne $ffmpegSha) {
    New-Item -ItemType Directory -Force (Split-Path $ffmpegZip) | Out-Null
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest "https://github.com/BtbN/FFmpeg-Builds/releases/download/$ffmpegTag/$ffmpegName.zip" -OutFile $ffmpegZip -UseBasicParsing
    if ((Get-FileHash $ffmpegZip -Algorithm SHA256).Hash -ne $ffmpegSha) { throw "ffmpeg's zip isn't the pinned one" }
}
$ffmpegDir = "$root\Vendor\ffmpeg"
Remove-Item -Recurse -Force $ffmpegDir -ErrorAction SilentlyContinue
Expand-Archive $ffmpegZip -DestinationPath $ffmpegDir
Get-ChildItem "$ffmpegDir\$ffmpegName\bin" | Where-Object Name -ne 'ffplay.exe' | Copy-Item -Destination $stage
Copy-Item "$ffmpegDir\$ffmpegName\LICENSE.txt" "$stage\ffmpeg-LICENSE.txt"
Set-Content "$stage\ffmpeg-SOURCE.txt" -Encoding ascii -Value @"
ffmpeg.exe, ffprobe.exe and the av*, sw* DLLs beside them are FFmpeg (https://ffmpeg.org), licensed under the
LGPL 2.1 or later (ffmpeg-LICENSE.txt). They are the unmodified build $ffmpegName from
https://github.com/BtbN/FFmpeg-Builds/releases/tag/$ffmpegTag, whose source and build scripts are there and at
https://github.com/BtbN/FFmpeg-Builds. You can replace them with any other FFmpeg 8.1 or later build.
"@
& "$stage\ffmpeg.exe" -hide_banner -version | Select-Object -First 1
if ($LASTEXITCODE) { throw 'The staged ffmpeg does not run' }
"Staged {0} files, {1:N0} MB, in build.windows\helper" -f (Get-ChildItem $stage).Count, ((Get-ChildItem $stage | Measure-Object Length -Sum).Sum / 1MB)
& "$stage\digup.exe" --help | Select-Object -First 1
if ($LASTEXITCODE) { throw 'The staged helper does not run' }

# 4. The shell, and its installer (Tauri's CLI fetches NSIS the first time).
Set-Location "$root\shell\src-tauri"
if ($SkipInstaller) {
    cargo build --release
} else {
    npx --yes @tauri-apps/cli@2 build
}
if ($LASTEXITCODE) { throw 'Building the shell failed' }
Set-Location $root
Get-ChildItem "$root\shell\src-tauri\target\release\bundle\nsis\*.exe" -ErrorAction SilentlyContinue | ForEach-Object { "Installer: $($_.FullName)" }
