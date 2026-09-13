# Spike: OpenCL Adreno on Windows ARM64

Status: experimental runner wiring landed (PR1) and **hardware-verified**
on a Dell Latitude 7455 (Snapdragon X Elite / Adreno X1-85). This is
**not** a supported or release backend. Official zip/CI still omit OpenCL.
On Adreno, set `OLLAMA_LLM_LIBRARY=opencl` and `OLLAMA_VULKAN=0`. There
is no auto-prefer of OpenCL over Vulkan (upstream-shaped; CUDA/ROCm-only
`PreferredLibrary`).

v1 target: Windows ARM64 + Qualcomm Adreno (Snapdragon X Elite / Adreno
X1-85). Broader OpenCL can wait.

Pinned llama.cpp in this tree: `LLAMA_CPP_VERSION` (`b10864` at spike time).
That tree already has `ggml-opencl` with Adreno kernels. Ollama now has an
experimental `opencl` runner that builds and installs that backend.

## Architecture map

Ollama does not compile ggml itself. GPU backends are extra
`llama-server` ExternalProject builds. Discovery then glob-loads
`lib/ollama/<runner>/*ggml-*`.

```
cmake -B build . -DOLLAMA_LLAMA_BACKENDS=opencl   # experimental Adreno runner
        │
        ▼
cmake/local.cmake
  ollama_add_llama_server_build(<name>
      RUNNER_DIR <name>
      TARGETS ggml-<backend>
      CMAKE_ARGS -DGGML_<BACKEND>=ON -DOLLAMA_GPU_BACKEND=<backend>)
        │
        ▼
llama/server/CMakeLists.txt
  FetchContent llama.cpp @ LLAMA_CPP_VERSION
  install ggml-<backend>.dll → lib/ollama/<runner>/
        │
        ▼
ml/path.go                  LibOllamaPath = lib/ollama
discover/runner.go          Glob lib/ollama/*/*ggml-*
                            OLLAMA_LLM_LIBRARY skips other runner dirs
                            OLLAMA_VULKAN=0 skips the vulkan dir
                            filterIntegratedGPUs drops most iGPUs
        │
        ▼
discover/llama_server.go    spawn llama-server --list-devices
                            inferLibrary(name, description)
        │
        ▼
llm/llama_server.go         GGML_BACKEND_PATH + PATH include runner dir
```

| Concern | Files |
|---|---|
| Superbuild allowlist | `cmake/local.cmake` (`OLLAMA_LLAMA_BACKENDS`) |
| llama-server presets | `llama/server/CMakePresets.json` |
| Install / DLL glob | `llama/server/CMakeLists.txt` (`OLLAMA_GPU_BACKEND`, `ggml-${OLLAMA_GPU_BACKEND}*.dll`) |
| Windows ARM CPU toolchain | `cmake/windows-arm64-llvm-mingw.cmake`, preset `cpu_arm64` |
| Windows ARM CUDA (NVIDIA only) | preset `llama_cuda_v13_windows_arm64`; `scripts/build_windows.ps1` `cuda13Arm64` |
| Experimental OpenCL (Adreno) | `OLLAMA_LLAMA_BACKENDS=opencl`; presets `llama_opencl`, `llama_opencl_windows_arm64` |
| Windows packaging | `scripts/build_windows.ps1` (`cpuArm64`, `vulkan`, zip) |
| Library root | `ml/path.go` |
| Device model / priority | `ml/device.go` (`PreferredLibrary`, `FlashAttentionSupported`, `GetDevicesEnv`) |
| Bootstrap / iGPU / env | `discover/runner.go` |
| `--list-devices` parse | `discover/llama_server.go` (`inferLibrary`) |
| Native ggml probe | `discover/native_probe_platform.go` (cuda/hip/vulkan only) |
| Vulkan UMA / Windows refine | `discover/vulkan.go`, `discover/vulkan_refine_windows.go` |
| Env knobs | `envconfig/config.go` (`OLLAMA_LLM_LIBRARY`, `OLLAMA_VULKAN`, `OLLAMA_IGPU_ENABLE`) |
| Dev docs | `docs/development.md`, `docs/gpu.mdx` |

PR1 added the experimental hook: `OLLAMA_LLAMA_BACKENDS=opencl` builds
`ggml-opencl` into `lib/ollama/opencl/`, and `inferLibrary` maps
`GPUOpenCL` / `opencl` to library `"OpenCL"`. Hits for "OpenClaw" in this
repo are still the unrelated launcher.

llama.cpp OpenCL device name at `b10864` is the constant `GPUOpenCL`
(`ggml_backend_opencl_device_get_name`). `--list-devices` looks like:

```
  GPUOpenCL: Qualcomm(R) Adreno(TM) X1-85 GPU (...)
```

On-device discovery used `description="Qualcomm(R) Adreno(TM) X1-85 GPU"`
(~15.8 GiB total). Both that string and the older `QUALCOMM Adreno(TM) ...`
sketch map to library `"OpenCL"`.

`inferLibrary` now special-cases `gpuopencl` / `opencl` → `"OpenCL"`
alongside CUDA / ROCm / Metal / Vulkan. Without that map, the default
returns the **description**, so Adreno would show up as library
`"QUALCOMM Adreno(TM) X1-85 GPU"`.

ggml-opencl reports `GGML_BACKEND_DEVICE_TYPE_GPU` (not iGPU). The iGPU
filter therefore does **not** drop an OpenCL Adreno device unless a later
change marks it integrated. PR1 does **not** mark OpenCL as iGPU.

## Gap vs #5360 sketch

Maintainer sketch ([ollama/ollama#5360](https://github.com/ollama/ollama/issues/5360), 2026-07-03):

```powershell
cmake -B build .
cmake --build build --target ollama-local
cmake -S llama/server -B build/llama-server-opencl `
  -DOLLAMA_RUNNER_DIR=opencl -DGGML_OPENCL=ON -DOLLAMA_GPU_BACKEND=opencl `
  -DFETCHCONTENT_SOURCE_DIR_LLAMA_CPP="$PWD/build/_deps/llama_cpp-src" `
  -DCMAKE_PREFIX_PATH=" "
cmake --build build/llama-server-opencl --target ggml-opencl
cmake --install build/llama-server-opencl --component llama-server
$env:OLLAMA_LLM_LIBRARY="opencl"
.\ollama.exe serve
```

What still matches:

- GPU backends are still a second `llama/server` build into
  `lib/ollama/<OLLAMA_RUNNER_DIR>/`.
- Install glob `ggml-${OLLAMA_GPU_BACKEND}*.dll` matches `ggml-opencl.dll`.
- Discovery glob `*ggml-*` will see that DLL.
- `OLLAMA_LLM_LIBRARY=opencl` still selects only the `opencl` runner dir.

What PR1 now matches:

| Sketch | Current tree |
|---|---|
| `-DOLLAMA_LLAMA_BACKENDS=opencl` | Superbuild allowlists `opencl` (unknown names still `FATAL_ERROR`). |
| `-DCMAKE_PREFIX_PATH` | Forwarded into the nested llama-server OpenCL build (same helper ROCm uses). |
| ICD install | `llama/server/CMakeLists.txt` copies `OpenCL.dll` from the OpenCL prefix when present. |
| `inferLibrary("GPUOpenCL")` | Maps to library `"OpenCL"`. |

What is still incomplete (intentionally, PR2 / later):

| Sketch | Current tree |
|---|---|
| No toolchain auto-select | llama.cpp Windows ARM64 OpenCL requires **llvm-mingw + Ninja**, not `cl.exe`. Preset `llama_opencl_windows_arm64` sets Clang/Ninja; the superbuild does not force a compiler (same as vulkan). Set `CMAKE_GENERATOR`/`CC`/`CXX` (or the ARM64 llvm-mingw toolchain file) before the first configure so nested builds do not inherit MSVC. VS is only for headers/libs. |
| `OLLAMA_LLM_LIBRARY` only | Required on Adreno, with `OLLAMA_VULKAN=0`. Vulkan is **on** by default when the dir exists. `PreferredLibrary` stays CUDA/ROCm-only (no OpenCL auto-prefer). Vulkan on Adreno can hard-fail (ggml pre-allocated tensor / operation `NONE`). |
| "GPU slower than CPU" | First 7455 Q4 numbers exist (see hardware verification). Still a measurement problem, not a reason to skip the runner or to official-bundle. |
| Docs / packaging | Official ARM64 zips can include CUDA 13 (NVIDIA ARM, not Adreno). OpenCL is still experimental and unwired in zip/CI. |

Related: [ollama/ollama#4373](https://github.com/ollama/ollama/issues/4373) (OpenCL feature request). NPU/Hexagon is out of v1 scope.

## Recommended first change set

**Build the experimental `opencl` runner.** That unblocks local Adreno
testing sooner than discovery-only or docs-only work. The #5360 command
sequence is still the right *shape*; promote it to a first-class
superbuild entry and fix the prefix/ICD/Clang gaps.

Keep this fork-scoped. Do not add OpenCL to official Windows zip/CI yet.

### PR1 — experimental runner (landed)

1. `cmake/local.cmake`: accept `opencl` in `OLLAMA_LLAMA_BACKENDS`.
   Mirror vulkan: `RUNNER_DIR=opencl`, `TARGETS ggml-opencl`,
   `-DGGML_OPENCL=ON -DGGML_BACKEND_DL=ON -DOLLAMA_GPU_BACKEND=opencl`.
   Forward `CMAKE_PREFIX_PATH` (same helper ROCm uses).
2. `llama/server/CMakePresets.json`: `llama_opencl` +
   `llama_opencl_windows_arm64` (Clang/Ninja; Adreno source kernels on).
   `GGML_OPENCL_USE_ADRENO_BIN_KERNELS` is **OFF** (binary kernel lib is
   X2-only; do not enable on X1-85).
3. `llama/server/CMakeLists.txt`: if `GGML_OPENCL`, install
   `ggml-opencl` and copy `OpenCL.dll` next to it when the ICD prefix
   is known.
4. `discover/llama_server.go` `inferLibrary`: map `gpuopencl` / `opencl`
   → `"OpenCL"`. Parse test covers `GPUOpenCL: ... Adreno ...`.
5. Recipe in `docs/development.md` (experimental, Windows ARM64 only).

### Hardware verification (Latitude 7455) — done

Built this branch on-device and staged the payload at
`C:\Users\eliza\dev\ollama-opencl\dist\windows-arm64` (not the default
superbuild layout, which leaves `ollama.exe` at the repo root).

```powershell
cd C:\Users\eliza\dev\ollama-opencl\dist\windows-arm64
$env:OLLAMA_LLM_LIBRARY="opencl"
$env:OLLAMA_VULKAN="0"
# Optional: avoid clashing with store/winget Ollama
# $env:OLLAMA_HOST="127.0.0.1:11435"
.\ollama.exe serve
```

Use the dist `.\ollama.exe` so `PATH` does not hit an installed Ollama.

Discovery confirmed OpenCL/Adreno, **not** Vulkan:

- `library=OpenCL`, `name=GPUOpenCL`
- `description="Qualcomm(R) Adreno(TM) X1-85 GPU"`
- libdirs include `opencl`
- ~15.8 GiB total; OpenCL `max mem alloc size: 2048 MB`
- Adreno kernels (`GGML_OPENCL_USE_ADRENO_KERNELS`)
- Qualcomm OpenCL 3.0 driver

Runs:

- Short Q4 text model (local Modelfile) succeeded on OpenCL:
  roughly **~202 tok/s prompt / ~29 tok/s decode** on that small model.
- Larger HF model also on the OpenCL/Adreno path:
  `hf.co/DavidAU/Qwen3.5-9B-The-Defiant-Fable-Uncensored-Heretic-NEO-IMATRIX-MAX-MTP-GGUF:IQ2_M`

Vision/mmproj OOM on ~2 GiB `CL_DEVICE_MAX_MEM_ALLOC_SIZE` remains
expected; use a CPU projector (or skip vision) if the projector weights
do not fit. Flash Attention on Adreno is situational — leave it off
unless a given model/backend combination is known-good.

Vulkan on this Adreno can hard-fail (ggml pre-allocated tensor /
operation `NONE`) if the `vulkan` runner is probed. Keep
`OLLAMA_LLM_LIBRARY=opencl` and `OLLAMA_VULKAN=0`. Do not rely on
discovery to pick OpenCL.

Build notes from that machine:

- MSVC fails for llama.cpp CPU ARM (`MSVC is not supported for ARM` /
  Unsupported ARM target OS). Use **llvm-mingw + Ninja**, not `cl.exe`.
- Native winget llvm-mingw is `llvm-mingw-*-aarch64*`. The toolchain
  file now GLOBs that as well as the cross-host `*-x86_64*` layout.
  `HOST_CXX` can be the aarch64 package's `clang++`.
- OpenCL SDK prefix: Khronos headers + ICD loader, e.g.
  `C:\Users\eliza\dev\llm\opencl` via `CMAKE_PREFIX_PATH`.
- Superbuild `ollama-local` sets `GGML_CPU_ALL_VARIANTS=OFF` on Windows
  ARM64. ggml only has ARM variant matrices for Linux/Android/Apple;
  `=ON` fatals with `Unsupported ARM target OS: Windows`. Same as
  preset `cpu_arm64`. No extra `-D` is required.

Local recipe (superbuild, preferred after PR1). From a **clean**
PowerShell, export Ninja + llvm-mingw **before the first cmake**. Bare
`cmake -B build .` picks Visual Studio/MSVC when VS is installed, and
nested OpenCL configures inherit it. `-G Ninja` alone can still pick
`cl.exe`.

```powershell
# llvm-mingw aarch64 bin must be on PATH (native winget: llvm-mingw-*-aarch64*).
# $env:Path = "C:\path\to\llvm-mingw-<ver>-ucrt-aarch64\bin;$env:Path"
$env:CMAKE_GENERATOR = "Ninja"
$env:CC = "aarch64-w64-mingw32-gcc"
$env:CXX = "aarch64-w64-mingw32-g++"

# 1) Khronos headers + ICD → $HOME/dev/llm/opencl  (see llama.cpp docs/backend/OPENCL.md)
# 2) Superbuild: ollama.exe at repo root; libs under build/lib/ollama
cmake -B build . -G Ninja `
  -DCMAKE_TOOLCHAIN_FILE="$PWD/cmake/windows-arm64-llvm-mingw.cmake" `
  -DOLLAMA_LLAMA_BACKENDS=opencl `
  -DCMAKE_PREFIX_PATH="$HOME/dev/llm/opencl"
cmake --build build --target ollama-local --parallel 8
cmake --build build --target ollama-llama-server-opencl --parallel 8

# Primary run (no dist\ folder unless you install):
$env:OLLAMA_LLM_LIBRARY="opencl"
$env:OLLAMA_VULKAN="0"
# Optional: $env:OLLAMA_HOST="127.0.0.1:11435"
.\ollama.exe serve

# Optional staged prefix (Latitude 7455 used dist\windows-arm64):
# cmake --install build --prefix dist/windows-arm64
# then run the ollama.exe under that prefix (often prefix\bin\ollama.exe).
```

Equivalent `llama/server` presets when you want to configure that project
directly: `llama_opencl` and `llama_opencl_windows_arm64`. Invoke them with
`-S llama/server` (the repo-root preset file does not define them). The raw
configure below is still valid if you already have a fetched llama.cpp
tree. `-G Ninja` is not enough — also pass the ARM64 llvm-mingw toolchain
(or `CMAKE_C_COMPILER`/`CMAKE_CXX_COMPILER` / `CC`/`CXX`) so CMake does
not pick `cl.exe`:

```powershell
cmake -S llama/server --preset llama_opencl_windows_arm64 `
  -DCMAKE_PREFIX_PATH="$HOME/dev/llm/opencl" `
  -DCMAKE_INSTALL_PREFIX="$PWD/build"
# or, without the preset:
cmake -S llama/server -B build/llama-server-opencl -G Ninja `
  -DCMAKE_TOOLCHAIN_FILE="$PWD/cmake/windows-arm64-llvm-mingw.cmake" `
  -DCMAKE_C_COMPILER=aarch64-w64-mingw32-gcc `
  -DCMAKE_CXX_COMPILER=aarch64-w64-mingw32-g++ `
  -DCMAKE_BUILD_TYPE=Release `
  -DCMAKE_INSTALL_PREFIX="$PWD/build" `
  -DOLLAMA_LIB_DIR=lib/ollama `
  -DOLLAMA_RUNNER_DIR=opencl `
  -DFETCHCONTENT_SOURCE_DIR_LLAMA_CPP="$PWD/build/_deps/llama_cpp-src" `
  -DOLLAMA_LLAMA_CPP_SKIP_COMPAT_PATCH=ON `
  -DBUILD_SHARED_LIBS=ON `
  -DGGML_BACKEND_DL=ON `
  -DGGML_OPENCL=ON `
  -DGGML_OPENCL_USE_ADRENO_KERNELS=ON `
  -DGGML_OPENCL_USE_ADRENO_BIN_KERNELS=OFF `
  -DOLLAMA_GPU_BACKEND=opencl `
  -DCMAKE_PREFIX_PATH="$HOME/dev/llm/opencl"
cmake --build build/llama-server-opencl --target ggml-opencl
cmake --install build/llama-server-opencl --component llama-server
```

`OpenCL.dll` is installed from the prefix when CMake can see it; the
manual `Copy-Item` is only needed if the prefix was not passed.

### PR2 — env guidance (no auto-prefer)

Do **not** teach `PreferredLibrary` / `Compare` to prefer OpenCL over
Vulkan. That is long-term fork drift from upstream. On Adreno, set
`OLLAMA_LLM_LIBRARY=opencl` and `OLLAMA_VULKAN=0`. Vulkan can hard-fail
(ggml pre-allocated tensor / operation `NONE`).

Still optional / later if logs require it, and only if it can land
upstream:

- `native_probe_platform.go`: probe `ggml-opencl.dll`.
- `GetDevicesEnv`: no OpenCL visible-device var (OK for single Adreno).
- `FlashAttentionSupported`: leave OpenCL false (FA is situational on
  Adreno).
- iGPU allowlist: **not** required for ggml-opencl's GPU device type.
  Still set `OLLAMA_IGPU_ENABLE=1` if Vulkan Adreno is in the same
  process and you need that device visible.

### Out of scope for v1

- Official `scripts/build_windows.ps1` / release zip / GitHub Actions.
- Linux/Android OpenCL, Intel OpenCL, Hexagon NPU.
- `GGML_OPENCL_USE_ADRENO_BIN_KERNELS` (X2).
- Official-bundling on the #5360 "GPU is slower than CPU" debate.
  First 7455 Q4 numbers are in the hardware section; more comparisons
  can wait.

## Runtime deps (Windows ARM64)

Build: Git, CMake 3.29+, **llvm-mingw + Ninja** (not MSVC/`cl.exe` for
llama.cpp CPU ARM or ggml-opencl), VS 2022 C++ workload (or Build Tools)
for headers/libs, PowerShell 7. Native Windows ARM64 winget installs
`llvm-mingw-*-aarch64*`; cross-host packages are `llvm-mingw-*-x86_64*`.
`cmake/windows-arm64-llvm-mingw.cmake` searches both. `HOST_CXX` can be
the aarch64 package's `clang++`.

OpenCL SDK (llama.cpp OPENCL.md):

1. [Khronos OpenCL-Headers](https://github.com/KhronosGroup/OpenCL-Headers)
2. [Khronos OpenCL-ICD-Loader](https://github.com/KhronosGroup/OpenCL-ICD-Loader)
   → `OpenCL.dll` + `OpenCL.lib`
3. Qualcomm Adreno ICD from the GPU driver (registry
   `HKLM\SOFTWARE\Khronos\OpenCL\Vendors`)

Put `OpenCL.dll` next to `ggml-opencl.dll` or on `PATH`. Host/vendor
loader is preferred, same idea as `llm/vulkan_windows.go` using the
system `vulkan-1.dll`.

CPU `llama-server` on Windows ARM is llvm-mingw; CUDA ARM64 is already
MSVC. `GGML_BACKEND_DL` is how those mix. Clang-built `ggml-opencl.dll`
is the same pattern.

## Risks

| Risk | Why | Mitigation |
|---|---|---|
| Vulkan overlap | Default-on if `lib/ollama/vulkan` exists; `PreferredLibrary` is CUDA/ROCm-only | Set `OLLAMA_LLM_LIBRARY=opencl` and `OLLAMA_VULKAN=0`. Vulkan on Adreno can hard-fail (ggml pre-allocated tensor / operation `NONE`) |
| iGPU filter | Vulkan Adreno is often UMA/`Integrated=true` and dropped | OpenCL Adreno is type GPU today; do not mark it iGPU in PR1 |
| `inferLibrary` | `GPUOpenCL` used to become the description string | Mapped to `"OpenCL"` in PR1 |
| ~2 GiB max alloc | Adreno `CL_DEVICE_MAX_MEM_ALLOC_SIZE`; mmproj OOM | Q4 text models; small ctx; CPU projector (or skip vision) if mmproj does not fit |
| ICD / packaging | Superbuild copies `OpenCL.dll` only when the prefix is visible | Keep host/vendor loader on PATH as fallback; document registry ICD |
| Clang vs mingw | Wrong compiler → link/load fail | Clang/Ninja; reuse `cpu_arm64` only if it finds OpenCL |
| Perf vs CPU | #5360 assumed GPU loss | First 7455 Q4 point: ~202 / ~29 tok/s on a small text model; do not official-bundle on that debate |
| FA | Situational on Adreno | Leave `FlashAttentionSupported` false unless a combo is known-good |

## Next implementation agent prompt

```
Do not auto-prefer OpenCL over Vulkan in PreferredLibrary / Compare.
That is fork drift. Adreno must set OLLAMA_LLM_LIBRARY=opencl and
OLLAMA_VULKAN=0. Remaining discovery work is optional and only if it
can land upstream: native probe of ggml-opencl.dll, OpenCL
visible-device env, or iGPU allowlist. Do not add official zip/CI,
Hexagon/NPU, or Intel x64 OpenCL.

Do not change build_windows.ps1 or release packaging.
```
