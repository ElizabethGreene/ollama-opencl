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

The workflow also runs on push to a `ci-opencl*` branch, or when the
workflow / `scripts/build_windows_opencl.ps1` change on `main`.

## Artifacts

| Artifact name | Zip file | Target |
|---|---|---|
| `ollama-windows-arm64-opencl` | `ollama-windows-arm64-opencl.zip` | Snapdragon / Adreno (Windows ARM64) |
| `ollama-windows-amd64-opencl` | `ollama-windows-amd64-opencl.zip` | Intel Iris Xe / generic x64 OpenCL |

Each zip is a release-style payload, not an installer:

```
ollama.exe
lib/ollama/                 CPU llama-server + ggml
lib/ollama/opencl/          ggml-opencl.dll (+ OpenCL.dll when bundled)
README_OPENCL.txt
```

## ARM64 Adreno vs x64 Intel

- **ARM64 (Adreno):** `GGML_OPENCL_USE_ADRENO_KERNELS=ON`, binary kernels
  off (`GGML_OPENCL_USE_ADRENO_BIN_KERNELS=OFF`, X2-only). Built with
  llvm-mingw + `cmake/windows-arm64-llvm-mingw.cmake`, matching the local
  recipe in [development.md](./development.md).
- **x64 (Intel):** `GGML_OPENCL_USE_ADRENO_KERNELS=OFF`. Built with MSVC +
  Ninja on `windows-latest`.

## Run environment

Use the extracted `ollama.exe` (not a store/winget install):

```powershell
$env:OLLAMA_LLM_LIBRARY = "opencl"
$env:OLLAMA_VULKAN = "0"
.\ollama.exe serve
```

`OLLAMA_LLM_LIBRARY=opencl` selects the `lib/ollama/opencl` runner.
`OLLAMA_VULKAN=0` keeps Vulkan from being probed if a vulkan dir is also
present. This zip does not ship Vulkan.

Local hardware notes (Latitude 7455 / Adreno X1-85) are in
[opencl-adreno-spike.md](./opencl-adreno-spike.md).

## Runner choices

Both jobs use GitHub-hosted **`windows-latest`** (x64):

- **ARM64** is an **x64 → ARM64 cross-compile**, the same educational path
  as upstream `scripts/build_windows.ps1` `cpuArm64` / `release.yaml`
  (llvm-mingw **x86_64 host** package with an `aarch64-w64-mingw32`
  target). `windows-11-arm` would be a native ARM64 runner, but it is not
  required here and has a different toolchain layout than the documented
  Adreno recipe.
- **x64** is a native MSVC + Ninja build on that same runner (Intel OpenCL
  test laptop target). llvm-mingw is not added to `PATH` on this job so
  CMake does not pick `gcc` over `cl.exe`.

Toolchains are pinned `Invoke-WebRequest` downloads (Ninja 1.12.1,
llvm-mingw 20240619, Khronos OpenCL-Headers / ICD Loader `v2024.10.24`).
No winget.

Local rebuild (after installing Go, CMake, Ninja, and llvm-mingw for
ARM64):

```powershell
./scripts/build_windows_opencl.ps1 -Arch arm64
./scripts/build_windows_opencl.ps1 -Arch amd64
```
