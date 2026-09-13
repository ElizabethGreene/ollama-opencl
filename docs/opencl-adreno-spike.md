# Spike: OpenCL Adreno on Windows ARM64

Status: discovery only. This is **not** a supported backend. Do not treat
`opencl` as a valid `OLLAMA_LLAMA_BACKENDS` value until an implementation PR
adds it.

v1 target: Windows ARM64 + Qualcomm Adreno (Snapdragon X Elite / Adreno
X1-85). Broader OpenCL can wait.

Pinned llama.cpp in this tree: `LLAMA_CPP_VERSION` (`b10864` at spike time).
That tree already has `ggml-opencl` with Adreno kernels. Ollama does not
wire it.

## Architecture map

Ollama does not compile ggml itself. GPU backends are extra
`llama-server` ExternalProject builds. Discovery then glob-loads
`lib/ollama/<runner>/*ggml-*`.

```
cmake -B build . -DOLLAMA_LLAMA_BACKENDS=vulkan   # current pattern
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
| Windows packaging | `scripts/build_windows.ps1` (`cpuArm64`, `vulkan`, zip) |
| Library root | `ml/path.go` |
| Device model / priority | `ml/device.go` (`PreferredLibrary`, `FlashAttentionSupported`, `GetDevicesEnv`) |
| Bootstrap / iGPU / env | `discover/runner.go` |
| `--list-devices` parse | `discover/llama_server.go` (`inferLibrary`) |
| Native ggml probe | `discover/native_probe_platform.go` (cuda/hip/vulkan only) |
| Vulkan UMA / Windows refine | `discover/vulkan.go`, `discover/vulkan_refine_windows.go` |
| Env knobs | `envconfig/config.go` (`OLLAMA_LLM_LIBRARY`, `OLLAMA_VULKAN`, `OLLAMA_IGPU_ENABLE`) |
| Dev docs | `docs/development.md`, `docs/gpu.mdx` |

There is **no** OpenCL hook today: no `GGML_OPENCL`, no `ggml-opencl`, no
`opencl` runner dir. Hits for "OpenCL" in this repo are the unrelated
OpenClaw launcher.

llama.cpp OpenCL device name at `b10864` is the constant `GPUOpenCL`
(`ggml_backend_opencl_device_get_name`). `--list-devices` looks like:

```
  GPUOpenCL: QUALCOMM Adreno(TM) X1-85 GPU (8192 MiB, 7184 MiB free)
```

`inferLibrary` only special-cases CUDA / ROCm / Metal / Vulkan. The
default returns the **description**, so Adreno would show up as library
`"QUALCOMM Adreno(TM) X1-85 GPU"`, not `"OpenCL"`.

ggml-opencl reports `GGML_BACKEND_DEVICE_TYPE_GPU` (not iGPU). The iGPU
filter therefore does **not** drop an OpenCL Adreno device unless a later
change marks it integrated.

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

What does **not** match / is incomplete:

| Sketch | Current tree |
|---|---|
| `-DOLLAMA_LLAMA_BACKENDS=opencl` | Superbuild `FATAL_ERROR`s unknown backends. Sketch bypasses this with a raw `llama/server` configure. |
| `-DCMAKE_PREFIX_PATH=" "` | Empty prefix. llama.cpp OpenCL needs Khronos headers + ICD loader (`find_package(OpenCL)`). |
| No toolchain | llama.cpp Windows ARM64 OpenCL requires **Clang + Ninja**, not `cl.exe`. VS is only for headers/libs. |
| No ICD install | `llama/server/CMakeLists.txt` bundles CUDA/ROCm/CRT DLLs, not `OpenCL.dll`. |
| `OLLAMA_LLM_LIBRARY` only | If a `vulkan` runner is also present it is probed unless `OLLAMA_VULKAN=0`. Vulkan is **on** by default when the dir exists. |
| No `inferLibrary("GPUOpenCL")` | Logs/scheduler will not say `OpenCL`. |
| "GPU slower than CPU" | 2025-era Adreno OpenCL; user's llama.cpp proof on Latitude 7455 is the v1 counter-example. Treat as a measurement problem, not a reason to skip the runner. |
| Docs: "Windows ARM has no acceleration" | Stale. Official ARM64 zips can include CUDA 13 (NVIDIA ARM, not Adreno). OpenCL is still unwired. |

Related: [ollama/ollama#4373](https://github.com/ollama/ollama/issues/4373) (OpenCL feature request). NPU/Hexagon is out of v1 scope.

## Recommended first change set

**Build the experimental `opencl` runner.** That unblocks local Adreno
testing sooner than discovery-only or docs-only work. The #5360 command
sequence is still the right *shape*; promote it to a first-class
superbuild entry and fix the prefix/ICD/Clang gaps.

Keep this fork-scoped. Do not add OpenCL to official Windows zip/CI yet.

### PR1 — experimental runner (do this next)

1. `cmake/local.cmake`: accept `opencl` in `OLLAMA_LLAMA_BACKENDS`.
   Mirror vulkan: `RUNNER_DIR=opencl`, `TARGETS ggml-opencl`,
   `-DGGML_OPENCL=ON -DGGML_BACKEND_DL=ON -DOLLAMA_GPU_BACKEND=opencl`.
   Forward `CMAKE_PREFIX_PATH` (same helper ROCm uses).
2. `llama/server/CMakePresets.json`: `llama_opencl` +
   `llama_opencl_windows_arm64` (Clang/Ninja; Adreno kernels default on
   in llama.cpp). Do **not** set `GGML_OPENCL_USE_ADRENO_BIN_KERNELS`
   for X1-85 (binary kernel lib is X2-only).
3. `llama/server/CMakeLists.txt`: if `GGML_OPENCL`, install
   `ggml-opencl` and copy `OpenCL.dll` next to it when the ICD prefix
   is known.
4. `discover/llama_server.go` `inferLibrary`: map `gpuopencl` / `opencl`
   → `"OpenCL"`. Add a parse test with a `GPUOpenCL: ... Adreno ...` line.
5. Recipe in `docs/development.md` (experimental, Windows ARM64 only).

Success on a Dell Latitude 7455 (Windows ARM64, Adreno X1-85):

- `lib/ollama/opencl/ggml-opencl.dll` exists after configure/build.
- Khronos or vendor `OpenCL.dll` is on `PATH` or beside that DLL.
- ```
  $env:OLLAMA_LLM_LIBRARY="opencl"
  $env:OLLAMA_VULKAN="0"
  .\ollama.exe serve
  ```
- Logs show `load_backend: loaded ... ggml-opencl.dll` and
  `GPUOpenCL` / `OpenCL` / `Adreno`, **not** Vulkan.
- `ollama run` of a **Q4** text model completes a short prompt.
- Vision/mmproj OOM on ~2 GiB `CL_DEVICE_MAX_MEM_ALLOC_SIZE` is known;
  do not block PR1 on it.

Local recipe (until PR1 lands, use this on the laptop):

```powershell
# 1) Khronos headers + ICD → $HOME/dev/llm/opencl  (see llama.cpp docs/backend/OPENCL.md)
# 2) CPU + ollama.exe
cmake -B build .
cmake --build build --target ollama-local --parallel 8

# 3) OpenCL runner (Clang/Ninja, not cl.exe)
cmake -S llama/server -B build/llama-server-opencl -G Ninja `
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
  -DOLLAMA_GPU_BACKEND=opencl `
  -DCMAKE_PREFIX_PATH="$HOME/dev/llm/opencl"
cmake --build build/llama-server-opencl --target ggml-opencl
cmake --install build/llama-server-opencl --component llama-server
Copy-Item $HOME/dev/llm/opencl/bin/OpenCL.dll build/lib/ollama/opencl/ -ErrorAction SilentlyContinue

$env:OLLAMA_LLM_LIBRARY="opencl"
$env:OLLAMA_VULKAN="0"
.\ollama.exe serve
```

### PR2 — discovery hardening (after a device run)

Only if PR1 logs or scheduling are wrong:

- `PreferredLibrary` / `Compare`: do not treat Vulkan+OpenCL Adreno as
  two GPUs (`likelyVulkanDuplicate` is CUDA/ROCm-only today).
- `native_probe_platform.go`: probe `ggml-opencl.dll`.
- `GetDevicesEnv`: no OpenCL visible-device var (OK for single Adreno).
- `FlashAttentionSupported`: leave OpenCL false (llama.cpp: FA is
  mixed on Adreno).
- iGPU allowlist: **not** required for ggml-opencl's GPU device type.
  Still set `OLLAMA_IGPU_ENABLE=1` if Vulkan Adreno is in the same
  process and you need that device visible.

### Out of scope for v1

- Official `scripts/build_windows.ps1` / release zip / GitHub Actions.
- Linux/Android OpenCL, Intel OpenCL, Hexagon NPU.
- `GGML_OPENCL_USE_ADRENO_BIN_KERNELS` (X2).
- Changing the "GPU is slower than CPU" #5360 narrative without
  Latitude 7455 Q4 numbers.

## Runtime deps (Windows ARM64)

Build: Git, CMake 3.29+, Clang 19, Ninja, VS 2022 C++ workload (or Build
Tools), PowerShell 7. Not `cl.exe` for ggml-opencl.

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
| Vulkan overlap | Default-on if `lib/ollama/vulkan` exists; duplicate-device logic ignores OpenCL | `OLLAMA_VULKAN=0` and/or `OLLAMA_LLM_LIBRARY=opencl` for v1 |
| iGPU filter | Vulkan Adreno is often UMA/`Integrated=true` and dropped | OpenCL Adreno is type GPU today; do not mark it iGPU in PR1 |
| `inferLibrary` | `GPUOpenCL` becomes the description string | Five-line map to `"OpenCL"` in PR1 |
| ~2 GiB max alloc | Adreno `CL_DEVICE_MAX_MEM_ALLOC_SIZE`; mmproj OOM | Q4 text models; small ctx; no vision in first test |
| ICD / packaging | Superbuild does not bundle OpenCL | Copy `OpenCL.dll`; document registry ICD |
| Clang vs mingw | Wrong compiler → link/load fail | Clang/Ninja; reuse `cpu_arm64` only if it finds OpenCL |
| Perf vs CPU | #5360 assumed GPU loss | Publish Q4 tok/s vs CPU on the same 7455; do not official-bundle on that debate |
| FA | Mixed on Adreno | Keep `FlashAttentionSupported` false |

## Next implementation agent prompt

```
Implement PR1 only on this ollama-opencl fork: experimental Windows
ARM64 OpenCL runner wiring. Do not add a general OpenCL backend, CI,
or release packaging.

1. cmake/local.cmake: OLLAMA_LLAMA_BACKENDS=opencl →
   ollama_add_llama_server_build like vulkan, TARGETS ggml-opencl,
   RUNNER_DIR=opencl, GGML_OPENCL=ON, OLLAMA_GPU_BACKEND=opencl,
   forward CMAKE_PREFIX_PATH.
2. llama/server/CMakePresets.json: llama_opencl and
   llama_opencl_windows_arm64. Adreno source kernels on; binary
   kernel lib off.
3. llama/server/CMakeLists.txt: install ggml-opencl; copy OpenCL.dll
   from the OpenCL prefix when present.
4. discover/llama_server.go inferLibrary: gpuopencl/opencl → "OpenCL".
   Test GPUOpenCL + Adreno --list-devices output.
5. docs/development.md: experimental Windows ARM64 recipe from
   docs/opencl-adreno-spike.md. Keep it labeled experimental.

Do not change iGPU policy, PreferredLibrary, native probe, or
build_windows.ps1 in this PR.

Verify with cmake configure (opencl in the allowlist, unknown names
still fail) and go test ./discover/ ./ml/. Hardware check is on a
Snapdragon X Elite box: OLLAMA_LLM_LIBRARY=opencl OLLAMA_VULKAN=0,
logs must show OpenCL/Adreno not Vulkan, Q4 text model only.
```
