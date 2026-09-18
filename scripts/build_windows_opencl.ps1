# powershell -ExecutionPolicy Bypass -File .\scripts\build_windows_opencl.ps1 -Arch arm64
# powershell -ExecutionPolicy Bypass -File .\scripts\build_windows_opencl.ps1 -Arch amd64
#
# Fork-only helper for unsigned Windows OpenCL zip payloads. Not used by
# .github/workflows/release.yaml. Builds the experimental opencl runner the
# same way as the local Dell ARM64 recipe in docs/development.md:
#   Ninja + (ARM64: llvm-mingw toolchain file) + OLLAMA_LLAMA_BACKENDS=opencl
#   + Khronos headers/import lib on CMAKE_PREFIX_PATH.
#
# ARM64: Adreno source kernels ON (Snapdragon / Adreno). GitHub Actions
# builds this natively on windows-11-arm with the llvm-mingw aarch64-host
# package. An x64→ARM64 cross-compile can produce a loadable ggml-opencl.dll
# that still fails Adreno device enumeration; prefer a native ARM64 host.
# AMD64: GGML_OPENCL_USE_ADRENO_KERNELS=OFF (Intel OpenCL test laptops).
#
# Zip layout (release-style, no installer / no signing):
#   ollama.exe
#   lib/ollama/**            (CPU llama-server + ggml)
#   lib/ollama/opencl/**     (ggml-opencl.dll + mingw runtime DLLs)
#   Start-OpenCL.ps1 / Start-CPU.ps1
#   README_OPENCL.txt
#
# ggml-opencl.dll must stay under lib/ollama/opencl/. llama-server only
# auto-loads backends from its own directory; ollama.exe serve sets
# GGML_BACKEND_PATH to that DLL when OLLAMA_LLM_LIBRARY=opencl. Copying
# it next to llama-server.exe makes discovery work but breaks CPU opt-out.
#
# OpenCL.dll is intentionally not bundled. Adreno Windows uses the
# host/vendor loader in C:\Windows\System32.

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("arm64", "amd64")]
    [string]$Arch,

    [string]$BuildDir = "",
    [string]$DistDir = "",
    [string]$OpenCLPrefix = "",
    [string]$OpenCLTag = "v2024.10.24"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function ConvertTo-CMakePath {
    param([string]$Path)
    if (-not $Path) {
        return $Path
    }
    return ([IO.Path]::GetFullPath($Path)).Replace('\', '/')
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Command,
        [string]$Label
    )
    Write-Host "==> $Label"
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE"
    }
}

function Find-VisualStudioInstall {
    if ($env:VSINSTALLDIR -and (Test-Path $env:VSINSTALLDIR)) {
        return $env:VSINSTALLDIR
    }

    $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
    if ($programFilesX86) {
        $vswhere = Join-Path $programFilesX86 "Microsoft Visual Studio\Installer\vswhere.exe"
        if (Test-Path $vswhere) {
            $install = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null | Select-Object -First 1
            if ($install) {
                return $install
            }
        }
    }
    return $null
}

function Enter-MsvcNinjaShell {
    param([string]$MsvcArch)

    $cl = Get-Command -Name "cl.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cl -and $cl.Source -match "[\\/]$MsvcArch[\\/]cl\.exe$") {
        Write-Host "MSVC $MsvcArch cl.exe already on PATH: $($cl.Source)"
        return
    }

    $vsInstall = Find-VisualStudioInstall
    if (-not $vsInstall) {
        throw "Visual Studio C++ tools not found. x64 OpenCL builds need MSVC + Ninja (or run from a VS Developer shell)."
    }

    $devShell = Join-Path $vsInstall "Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
    if (-not (Test-Path $devShell)) {
        throw "Microsoft.VisualStudio.DevShell.dll not found under $vsInstall"
    }

    Import-Module $devShell
    Enter-VsDevShell -VsInstallPath $vsInstall -SkipAutomaticLocation -DevCmdArguments "-arch=$MsvcArch -host_arch=x64 -no_logo"

    $cl = Get-Command -Name "cl.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cl) {
        throw "Ninja x64 OpenCL builds require MSVC cl.exe after Enter-VsDevShell"
    }
    Write-Host "MSVC $MsvcArch cl.exe available: $($cl.Source)"
}

function Find-LlvmMingwBin {
    $cmd = Get-Command -Name "aarch64-w64-mingw32-gcc.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) {
        return (Split-Path -Parent $cmd.Path)
    }

    $hints = @()
    if ($env:ProgramFiles) {
        $hints += Resolve-Path "$env:ProgramFiles\llvm-mingw-*-x86_64*\bin" -ErrorAction SilentlyContinue
        $hints += Resolve-Path "$env:ProgramFiles\llvm-mingw-*-aarch64*\bin" -ErrorAction SilentlyContinue
    }
    if ($env:LOCALAPPDATA) {
        $hints += Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\MartinStorsjo.LLVM-MinGW*\llvm-mingw-*-x86_64*\bin" -ErrorAction SilentlyContinue
        $hints += Resolve-Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\MartinStorsjo.LLVM-MinGW*\llvm-mingw-*-aarch64*\bin" -ErrorAction SilentlyContinue
    }
    foreach ($bin in ($hints | Sort-Object -Property Path -Descending)) {
        $gcc = Join-Path $bin.Path "aarch64-w64-mingw32-gcc.exe"
        if (Test-Path $gcc) {
            return $bin.Path
        }
    }
    return $null
}

function Install-OpenCLSdk {
    param(
        [string]$Prefix,
        [string]$Arch,
        [string]$Tag,
        [string]$ToolchainFile
    )

    $clHeader = Join-Path $Prefix "include\CL\cl.h"
    $openclDll = @(
        (Join-Path $Prefix "bin\OpenCL.dll"),
        (Join-Path $Prefix "lib\OpenCL.dll"),
        (Join-Path $Prefix "OpenCL.dll")
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ((Test-Path $clHeader) -and $openclDll) {
        Write-Host "Reusing OpenCL SDK at $Prefix ($openclDll)"
        return
    }

    $srcRoot = Join-Path ([IO.Path]::GetFullPath((Join-Path $Prefix ".."))) "opencl-src"
    New-Item -ItemType Directory -Force -Path $srcRoot | Out-Null
    New-Item -ItemType Directory -Force -Path $Prefix | Out-Null

    $headersZip = Join-Path $srcRoot "OpenCL-Headers-$Tag.zip"
    $icdZip = Join-Path $srcRoot "OpenCL-ICD-Loader-$Tag.zip"
    $headersUrl = "https://github.com/KhronosGroup/OpenCL-Headers/archive/refs/tags/$Tag.zip"
    $icdUrl = "https://github.com/KhronosGroup/OpenCL-ICD-Loader/archive/refs/tags/$Tag.zip"

    if (-not (Test-Path $headersZip)) {
        Write-Host "Downloading OpenCL-Headers $Tag"
        Invoke-WebRequest -Uri $headersUrl -OutFile $headersZip
    }
    if (-not (Test-Path $icdZip)) {
        Write-Host "Downloading OpenCL-ICD-Loader $Tag"
        Invoke-WebRequest -Uri $icdUrl -OutFile $icdZip
    }

    $headersExtract = Join-Path $srcRoot "headers"
    $icdExtract = Join-Path $srcRoot "icd"
    if (Test-Path $headersExtract) { Remove-Item -Recurse -Force $headersExtract }
    if (Test-Path $icdExtract) { Remove-Item -Recurse -Force $icdExtract }
    Expand-Archive -Path $headersZip -DestinationPath $headersExtract -Force
    Expand-Archive -Path $icdZip -DestinationPath $icdExtract -Force

    $headersSrc = Get-ChildItem -Path $headersExtract -Directory | Select-Object -First 1
    $icdSrc = Get-ChildItem -Path $icdExtract -Directory | Select-Object -First 1
    if (-not $headersSrc -or -not $icdSrc) {
        throw "Failed to extract Khronos OpenCL sources"
    }

    $cmakePrefix = ConvertTo-CMakePath $Prefix
    $headersBuild = Join-Path $srcRoot "headers-build-$Arch"
    $icdBuild = Join-Path $srcRoot "icd-build-$Arch"
    if (Test-Path $headersBuild) { Remove-Item -Recurse -Force $headersBuild }
    if (Test-Path $icdBuild) { Remove-Item -Recurse -Force $icdBuild }

    $common = @("-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_INSTALL_PREFIX=$cmakePrefix")
    if ($ToolchainFile) {
        $common += @("-DCMAKE_TOOLCHAIN_FILE=$(ConvertTo-CMakePath $ToolchainFile)")
    }

    Invoke-Checked -Label "Configure OpenCL-Headers" -Command {
        cmake -S $headersSrc.FullName -B $headersBuild @common
    }
    Invoke-Checked -Label "Install OpenCL-Headers" -Command {
        cmake --build $headersBuild --target install
    }

    $icdArgs = $common + @(
        "-DCMAKE_PREFIX_PATH=$cmakePrefix",
        "-DOPENCL_ICD_LOADER_HEADERS_DIR=$cmakePrefix/include",
        "-DBUILD_SHARED_LIBS=ON",
        "-DOPENCL_ICD_LOADER_BUILD_SHARED_LIBS=ON",
        "-DOPENCL_ICD_LOADER_BUILD_TESTING=OFF",
        "-DENABLE_OPENCL_LAYERINFO=OFF"
    )
    Invoke-Checked -Label "Configure OpenCL-ICD-Loader ($Arch)" -Command {
        cmake -S $icdSrc.FullName -B $icdBuild @icdArgs
    }
    Invoke-Checked -Label "Install OpenCL-ICD-Loader" -Command {
        cmake --build $icdBuild --target install
    }

    if (-not (Test-Path (Join-Path $Prefix "include\CL\cl.h"))) {
        throw "OpenCL headers did not install to $Prefix\include\CL\cl.h"
    }
    $dll = @(
        (Join-Path $Prefix "bin\OpenCL.dll"),
        (Join-Path $Prefix "lib\OpenCL.dll")
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $dll) {
        throw "OpenCL.dll was not installed under $Prefix (bin/ or lib/)"
    }
    Write-Host "Installed OpenCL SDK ($Arch) to $Prefix"
}

function New-UnsignedZip {
    param(
        [string]$SourceDir,
        [string]$ZipPath
    )

    if (Test-Path $ZipPath) {
        Remove-Item -Force $ZipPath
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ZipPath) | Out-Null

    if (Get-Command 7z -ErrorAction SilentlyContinue) {
        Push-Location $SourceDir
        try {
            & 7z a -tzip -mx=7 -mmt=on $ZipPath "*"
            if ($LASTEXITCODE -ne 0) {
                throw "7z failed with exit code $LASTEXITCODE"
            }
        } finally {
            Pop-Location
        }
    } else {
        Compress-Archive -CompressionLevel Optimal -Path (Join-Path $SourceDir "*") -DestinationPath $ZipPath -Force
    }
}

$srcDir = [IO.Path]::GetFullPath((Get-Location).Path)
if (-not (Test-Path (Join-Path $srcDir "cmake\local.cmake"))) {
    throw "Run this script from the repository root"
}

if (-not $BuildDir) {
    $BuildDir = Join-Path $srcDir "build\windows-$Arch-opencl"
}
if (-not $DistDir) {
    $DistDir = Join-Path $srcDir "dist"
}
if (-not $OpenCLPrefix) {
    if ($env:OLLAMA_OPENCL_PREFIX) {
        $OpenCLPrefix = $env:OLLAMA_OPENCL_PREFIX
    } else {
        $OpenCLPrefix = Join-Path $srcDir "build\opencl-sdk-$Arch"
    }
}

$BuildDir = [IO.Path]::GetFullPath($BuildDir)
$DistDir = [IO.Path]::GetFullPath($DistDir)
$OpenCLPrefix = [IO.Path]::GetFullPath($OpenCLPrefix)
$stageDir = Join-Path $DistDir "windows-$Arch-opencl"
$zipName = "ollama-windows-$Arch-opencl.zip"
$zipPath = Join-Path $DistDir $zipName
$toolchainFile = $null
$adrenoKernels = "OFF"

Write-Host "Building unsigned Windows $Arch OpenCL payload"
Write-Host "  source:    $srcDir"
Write-Host "  build:     $BuildDir"
Write-Host "  opencl:    $OpenCLPrefix"
Write-Host "  stage:     $stageDir"

if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
    throw "cmake is required"
}
if (-not (Get-Command go -ErrorAction SilentlyContinue)) {
    throw "go is required (install Go or use actions/setup-go)"
}
if (-not (Get-Command ninja -ErrorAction SilentlyContinue)) {
    throw "ninja is required and must be on PATH"
}

$env:CMAKE_GENERATOR = "Ninja"

if ($Arch -eq "arm64") {
    $adrenoKernels = "ON"
    $mingwBin = Find-LlvmMingwBin
    if (-not $mingwBin) {
        throw "llvm-mingw aarch64-w64-mingw32-gcc.exe not found. Install the x86_64-host llvm-mingw package (same as release.yaml) or a native aarch64 package."
    }
    $env:Path = "$mingwBin;$env:Path"
    $env:CC = "aarch64-w64-mingw32-gcc"
    $env:CXX = "aarch64-w64-mingw32-g++"
    $env:GOOS = "windows"
    $env:GOARCH = "arm64"
    $env:CGO_ENABLED = "1"
    $toolchainFile = Join-Path $srcDir "cmake\windows-arm64-llvm-mingw.cmake"
    if (-not (Test-Path $toolchainFile)) {
        throw "Missing $toolchainFile"
    }
    $hostArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    if ("$hostArch" -ne "Arm64") {
        Write-Warning "Cross-compiling ARM64 OpenCL on host $hostArch. The CI zip that failed Adreno discovery was an x64→ARM64 llvm-mingw cross build; prefer a native ARM64 host (Dell or windows-11-arm)."
    }
    Write-Host "ARM64 OpenCL: llvm-mingw at $mingwBin (Adreno kernels ON, host=$hostArch)"
} else {
    # Intel / generic OpenCL. MSVC + Ninja matches test.yaml's Windows CPU job.
    # Do not put llvm-mingw on PATH here or CMake may pick gcc over cl.exe.
    Remove-Item Env:CC -ErrorAction SilentlyContinue
    Remove-Item Env:CXX -ErrorAction SilentlyContinue
    $env:GOOS = "windows"
    $env:GOARCH = "amd64"
    $env:CGO_ENABLED = "1"
    Enter-MsvcNinjaShell -MsvcArch "x64"
    Write-Host "AMD64 OpenCL: MSVC + Ninja (Adreno kernels OFF)"
}

Install-OpenCLSdk -Prefix $OpenCLPrefix -Arch $Arch -Tag $OpenCLTag -ToolchainFile $toolchainFile

$version = $env:VERSION
if (-not $version) {
    $version = (git describe --tags --first-parent --abbrev=7 --long --dirty --always 2>$null)
    if (-not $version) {
        $version = "0.0.0-opencl"
    }
}

$cmakePrefix = ConvertTo-CMakePath $OpenCLPrefix
$configure = @(
    "-S", $srcDir,
    "-B", $BuildDir,
    "-G", "Ninja",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DOLLAMA_LLAMA_BACKENDS=opencl",
    "-DCMAKE_PREFIX_PATH=$cmakePrefix",
    "-DGGML_OPENCL_USE_ADRENO_KERNELS=$adrenoKernels",
    "-DGGML_OPENCL_USE_ADRENO_BIN_KERNELS=OFF",
    "-DOLLAMA_VERSION=$version"
)
if ($toolchainFile) {
    $configure += "-DCMAKE_TOOLCHAIN_FILE=$(ConvertTo-CMakePath $toolchainFile)"
}

Invoke-Checked -Label "Configure OpenCL superbuild" -Command {
    cmake @configure
}
Invoke-Checked -Label "Build ollama-local" -Command {
    cmake --build $BuildDir --target ollama-local --parallel
}
Invoke-Checked -Label "Build ollama-llama-server-opencl" -Command {
    cmake --build $BuildDir --target ollama-llama-server-opencl --parallel
}

if (Test-Path $stageDir) {
    Remove-Item -Recurse -Force $stageDir
}
New-Item -ItemType Directory -Force -Path $stageDir | Out-Null

Invoke-Checked -Label "Install ollama-local payload" -Command {
    cmake --install $BuildDir --component ollama-local --prefix $stageDir
}

$installedExe = Join-Path $stageDir "bin\ollama.exe"
$rootExe = Join-Path $stageDir "ollama.exe"
if (Test-Path $installedExe) {
    Move-Item -Force $installedExe $rootExe
    $binDir = Join-Path $stageDir "bin"
    if ((Get-ChildItem $binDir -Force | Measure-Object).Count -eq 0) {
        Remove-Item -Recurse -Force $binDir
    }
} elseif (-not (Test-Path $rootExe)) {
    $goExe = Join-Path $srcDir "ollama.exe"
    if (Test-Path $goExe) {
        Copy-Item $goExe $rootExe
    }
}

$readme = @"
Unsigned experimental Ollama OpenCL build (fork CI; not an official release).
Architecture: $Arch
Adreno kernels: $adrenoKernels  (ON = Snapdragon/Adreno, OFF = Intel/generic OpenCL)
Binary kernels: OFF
OpenCL loader: host/vendor (typically C:\Windows\System32\OpenCL.dll)
This zip does not bundle OpenCL.dll.

Layout (do not flatten):
  lib\ollama\llama-server.exe      CPU ggml
  lib\ollama\opencl\ggml-opencl.dll

llama-server only auto-loads backends from its own directory. ollama.exe
serve sets GGML_BACKEND_PATH to lib\ollama\opencl\ggml-opencl.dll when
OLLAMA_LLM_LIBRARY=opencl. Do not copy opencl\* up into lib\ollama\ —
that makes --list-devices work, but then OLLAMA_LLM_LIBRARY=cpu still
uses the GPU.

Run from this extracted folder (so lib\ is next to ollama.exe):

  .\Start-OpenCL.ps1
  .\Start-CPU.ps1

Or:

  `$env:OLLAMA_LLM_LIBRARY = "opencl"
  `$env:OLLAMA_VULKAN = "0"
  .\ollama.exe serve

On a Snapdragon / Adreno machine, OpenCL serve should log something like:
  library=OpenCL
  name=GPUOpenCL
  description=Qualcomm(R) Adreno(TM) X1-85 GPU

CPU serve (OLLAMA_LLM_LIBRARY=cpu, Vulkan off) must not log GPUOpenCL.

Optional direct llama-server check (ollama serve does this for you):

  `$env:GGML_BACKEND_PATH = "`$PWD\lib\ollama\opencl\ggml-opencl.dll"
  .\lib\ollama\llama-server.exe --list-devices

Without GGML_BACKEND_PATH, --list-devices looks next to llama-server.exe
and reports (none).

If you only see library=cpu from ollama.exe serve:
  1. Confirm you launched this folder's .\ollama.exe (not a store/winget install).
  2. Keep PATH clear of other ggml-base.dll copies (dev\llm\llama-opencl,
     WinGet ggml.llamacpp). Those trigger
     "potentially incompatible library detected in PATH".
  3. Confirm C:\Windows\System32\OpenCL.dll exists (Qualcomm GPU driver).
"@
Set-Content -Path (Join-Path $stageDir "README_OPENCL.txt") -Value $readme -Encoding utf8

$startOpenCL = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = "Stop"
Set-Location -LiteralPath `$PSScriptRoot
`$env:OLLAMA_LLM_LIBRARY = "opencl"
`$env:OLLAMA_VULKAN = "0"
& .\ollama.exe serve @args
"@
$startCPU = @"
Set-StrictMode -Version Latest
`$ErrorActionPreference = "Stop"
Set-Location -LiteralPath `$PSScriptRoot
`$env:OLLAMA_LLM_LIBRARY = "cpu"
`$env:OLLAMA_VULKAN = "0"
& .\ollama.exe serve @args
"@
Set-Content -Path (Join-Path $stageDir "Start-OpenCL.ps1") -Value $startOpenCL -Encoding utf8
Set-Content -Path (Join-Path $stageDir "Start-CPU.ps1") -Value $startCPU -Encoding utf8

$required = @(
    (Join-Path $stageDir "ollama.exe"),
    (Join-Path $stageDir "lib\ollama\llama-server.exe"),
    (Join-Path $stageDir "lib\ollama\opencl\ggml-opencl.dll"),
    (Join-Path $stageDir "Start-OpenCL.ps1"),
    (Join-Path $stageDir "Start-CPU.ps1")
)
foreach ($path in $required) {
    if (-not (Test-Path $path)) {
        throw "Missing required payload file: $path"
    }
}

$flattenedOpenCL = Join-Path $stageDir "lib\ollama\ggml-opencl.dll"
if (Test-Path $flattenedOpenCL) {
    throw "ggml-opencl.dll must stay in lib\ollama\opencl\ so OLLAMA_LLM_LIBRARY=cpu does not auto-load the GPU"
}

$bundledIcd = Join-Path $stageDir "lib\ollama\opencl\OpenCL.dll"
if (Test-Path $bundledIcd) {
    Write-Host "Removing staged OpenCL.dll so System32/host vendor loader is used"
    Remove-Item -Force $bundledIcd
}

Write-Host "Staged payload:"
Get-ChildItem -Path $stageDir -Recurse -File | ForEach-Object {
    Write-Host ("  {0}" -f $_.FullName.Substring($stageDir.Length).TrimStart('\', '/'))
}

New-UnsignedZip -SourceDir $stageDir -ZipPath $zipPath
Write-Host "Wrote $zipPath"
Get-Item $zipPath | Format-List FullName, Length
