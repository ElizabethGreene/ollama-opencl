# Fork CI: unsigned Windows OpenCL zips

This fork can produce **unsigned** Windows OpenCL zip artifacts from GitHub
Actions. That is a learning/ops path for the fork owner. It is **not** an
official Ollama release and does not replace
[`.github/workflows/release.yaml`](../.github/workflows/release.yaml)
(no code signing, no MSIX, no `OllamaSetup.exe`, no `environment: release`
secrets).

Workflow: [`.github/workflows/build-opencl.yml`](../.github/workflows/build-opencl.yml)

## How to run

1. Open the GitHub repo → **Actions**
2. Select **Windows OpenCL (unsigned zip)**
3. **Run workflow** (choose `both`, `arm64`, or `amd64`)

The workflow also runs on pull requests that touch the OpenCL CI files,
on push to a `ci-opencl*` branch, or when those files change on `main`.
Download the artifact from the workflow run (Actions tab or the PR
checks).

After it finishes, download the `ollama-windows-arm64-opencl` artifact
and extract `ollama-windows-arm64-opencl.zip`.

## Artifacts

| Artifact name | Zip file | Target |
|---|---|---|
| `ollama-windows-arm64-opencl` | `ollama-windows-arm64-opencl.zip` | Snapdragon / Adreno (Windows ARM64) |
| `ollama-windows-amd64-opencl` | `ollama-windows-amd64-opencl.zip` | Intel Iris Xe / generic x64 OpenCL |

Each zip is a release-style payload, not an installer:

```
ollama.exe
lib/ollama/                 CPU llama-server + ggml
lib/ollama/opencl/          ggml-opencl.dll + mingw runtime DLLs
Start-OpenCL.ps1
Start-CPU.ps1
README_OPENCL.txt
```

`ggml-opencl.dll` must stay under `lib/ollama/opencl/`. ggml/llama-server
only auto-loads backends from the directory that contains
`llama-server.exe` (and the current working directory). Ollama's serve
path sets `GGML_BACKEND_PATH` to
`lib/ollama/opencl/ggml-opencl.dll` when the `opencl` runner is selected.

Do **not** copy `opencl\*` up into `lib\ollama\`. That makes a raw
`.\llama-server.exe --list-devices` show Adreno, but then
`OLLAMA_LLM_LIBRARY=cpu` still loads the GPU.

Zip verify fails if `ggml-opencl.dll` is missing from `opencl/` **or**
if it was flattened next to `llama-server.exe`.

`OpenCL.dll` is **not** in the zip. On Adreno Windows the working loader
is `C:\Windows\System32\OpenCL.dll` (Qualcomm ICD via the GPU driver).
A Khronos ICD built only so CMake can link `ggml-opencl.dll` must not
shadow that file.

## ARM64 Adreno vs x64 Intel

- **ARM64 (Adreno):** `GGML_OPENCL_USE_ADRENO_KERNELS=ON`, binary kernels
  off (`GGML_OPENCL_USE_ADRENO_BIN_KERNELS=OFF`, X2-only). Built **natively**
  on `windows-11-arm` with llvm-mingw +
  `cmake/windows-arm64-llvm-mingw.cmake`, matching the local Dell recipe
  in [development.md](./development.md).
- **x64 (Intel):** `GGML_OPENCL_USE_ADRENO_KERNELS=OFF`. Built with MSVC +
  Ninja on `windows-latest`.

An earlier x64→ARM64 llvm-mingw **cross-compile** produced a zip whose
`ggml-opencl.dll` loaded on a Latitude / Adreno X1-85 but
`--list-devices` never reported an OpenCL device (`library=cpu` only).
The same machine accepted a native Dell `lib\` tree. ARM64 CI therefore
uses `windows-11-arm` and the llvm-mingw **aarch64-host** package, not
the `release.yaml` cpuArm64 x86_64-host cross package.

## Run environment

Use the extracted `ollama.exe` (not a store/winget install):

```powershell
.\Start-OpenCL.ps1
# or:
$env:OLLAMA_LLM_LIBRARY = "opencl"
$env:OLLAMA_VULKAN = "0"
.\ollama.exe serve
```

`OLLAMA_LLM_LIBRARY=opencl` selects the `lib/ollama/opencl` runner and
makes serve set `GGML_BACKEND_PATH` to that directory's
`ggml-opencl.dll`. `OLLAMA_VULKAN=0` keeps Vulkan from being probed if
a vulkan dir is also present. This zip does not ship Vulkan.

On Adreno, serve should log `library=OpenCL`, `name=GPUOpenCL`, and a
Qualcomm Adreno description (for example
`Qualcomm(R) Adreno(TM) X1-85 GPU`).

CPU opt-out (fresh zip, no copied DLLs):

```powershell
.\Start-CPU.ps1
# or:
$env:OLLAMA_LLM_LIBRARY = "cpu"
$env:OLLAMA_VULKAN = "0"
.\ollama.exe serve
```

That must **not** log `GPUOpenCL` / `library=OpenCL`.

A raw `.\lib\ollama\llama-server.exe --list-devices` without
`GGML_BACKEND_PATH` reports `(none)`. That is expected. Optional
manual check:

```powershell
$env:GGML_BACKEND_PATH = "$PWD\lib\ollama\opencl\ggml-opencl.dll"
.\lib\ollama\llama-server.exe --list-devices
```

Keep `PATH` clear of other `ggml-base.dll` copies (`dev\llm\llama-opencl`,
WinGet `ggml.llamacpp`). Those trigger
`potentially incompatible library detected in PATH` and can make
discovery look like a backend failure.

Local hardware notes (Latitude 7455 / Adreno X1-85) are in
[opencl-adreno-spike.md](./opencl-adreno-spike.md).

## Runner choices

- **ARM64** uses GitHub-hosted **`windows-11-arm`** (native ARM64). That
  is the same llvm-mingw + Ninja shape as an on-device Dell build.
  `windows-11-arm` is free for **public** repositories (it fails on
  private repos).
- **x64** uses **`windows-latest`** with native MSVC + Ninja (Intel
  OpenCL test laptop). llvm-mingw is not added to `PATH` on this job so
  CMake does not pick `gcc` over `cl.exe`.

Toolchains are pinned `Invoke-WebRequest` downloads (Ninja 1.12.1,
llvm-mingw 20240619 **ucrt-aarch64** for ARM64, Khronos OpenCL-Headers /
ICD Loader `v2024.10.24` for headers and the import lib only). No winget.

Local rebuild (after installing Go, CMake, Ninja, and llvm-mingw for
ARM64):

```powershell
./scripts/build_windows_opencl.ps1 -Arch arm64
./scripts/build_windows_opencl.ps1 -Arch amd64
```

Prefer running the ARM64 script **on an ARM64 host**. The script warns
if it is cross-compiling.

## Re-run Actions

1. GitHub → **Actions** → **Windows OpenCL (unsigned zip)**
2. **Run workflow** → `arm64` (Dell / Adreno) or `both`
3. Download `ollama-windows-arm64-opencl` and extract the zip

The workflow also runs `go test ./llm ./discover` for the
`GGML_BACKEND_PATH` / runner-dir wiring before it builds the zip.

## Dell smoke test (Latitude / Adreno X1-85)

Extract a **fresh** zip. Do not copy `lib\ollama\opencl\*` into
`lib\ollama\`.

| Launch | Expected serve log |
|---|---|
| `.\Start-OpenCL.ps1` | `library=OpenCL`, `name=GPUOpenCL`, `Qualcomm(R) Adreno(TM) X1-85 GPU` |
| `.\Start-CPU.ps1` | CPU only; no `GPUOpenCL` |

If OpenCL serve still says `library=cpu`, confirm this folder's
`.\ollama.exe` is the process, `C:\Windows\System32\OpenCL.dll` exists,
and `PATH` has no extra `ggml-base.dll`.
