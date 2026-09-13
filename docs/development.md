# Development

Install prerequisites:

- [Go](https://go.dev/doc/install)
- [CMake](https://cmake.org/download/) 3.24 or newer
- C/C++ compiler: Clang on macOS, Visual Studio 2022 C++ tools on Windows, or GCC/Clang on Linux
- [Ninja](https://github.com/ninja-build/ninja/releases) in `PATH` is recommended, especially on Windows

For pure Go iteration against an existing native payload, run Ollama from the repository root:

```shell
go run . serve
```

> [!NOTE]
> Ollama includes native code compiled with CGO.  From time to time these data structures can change and CGO can get out of sync resulting in unexpected crashes.  You can force a full build of the native code by running `go clean -cache` first. 

## Native build model

For a fresh checkout, or after changing native code, build from the repository root. On macOS arm64, this builds Metal inference. On all other platforms this builds CPU-only inference. It builds the Go binary at the repository root and installs the native runtime payload under `build/lib/ollama`.

```shell
cmake -B build .
cmake --build build --parallel 8
./ollama serve
```

To install into a standard prefix layout:

```shell
cmake --install build --prefix /path/to/install
```

On all platforms except macOS arm64, to build GPU backends select the backends explicitly:

```shell
cmake -B build . -DOLLAMA_LLAMA_BACKENDS="cuda_v13;vulkan"
cmake --build build --parallel 8
```

Supported backend values are `cuda_v12`, `cuda_v13`, `rocm_v7_1`, `rocm_v7_2`, `vulkan`, `cuda_jetpack5`, and `cuda_jetpack6`. Experimental `opencl` is accepted for local Windows ARM64 / Adreno builds only; it is not a general or release backend.

Use standard CMake architecture overrides to narrow GPU builds for local hardware:

```shell
# CUDA
cmake -B build . -DOLLAMA_LLAMA_BACKENDS=cuda_v13 -DCMAKE_CUDA_ARCHITECTURES=native

# ROCm / HIP
cmake -B build . -DOLLAMA_LLAMA_BACKENDS=rocm_v7_2 -DCMAKE_HIP_ARCHITECTURES=gfx1100
```

You can tune GGML build options by setting `GGML_*` values during configure. For example, to disable CUDA flash attention kernels for local debugging:

```shell
cmake -B build . -DOLLAMA_LLAMA_BACKENDS=cuda_v12 -DGGML_CUDA_FA=OFF
```

## macOS (Apple Silicon)

Additional prerequisites:

MLX Metal requires the Metal toolchain. Install [Xcode](https://developer.apple.com/xcode/) first, then:

```shell
xcodebuild -downloadComponent MetalToolchain
```

## Windows

Additional prerequisites:

- [Visual Studio 2022](https://visualstudio.microsoft.com/downloads/) including the Native Desktop Workload
- (Optional) AMD GPU support
    - [ROCm](https://rocm.docs.amd.com/en/latest/)
- (Optional) NVIDIA GPU support
    - [CUDA SDK](https://developer.nvidia.com/cuda-downloads?target_os=Windows&target_arch=x86_64&target_type=exe_network)
- (Optional) Vulkan GPU support
    - [Vulkan SDK](https://vulkan.lunarg.com/sdk/home) - useful for AMD/Intel GPUs
- (Optional) MLX engine support
    - [CUDA 13+ SDK](https://developer.nvidia.com/cuda-downloads)
    - [cuDNN 9+](https://developer.nvidia.com/cudnn)

For Ninja builds, run CMake from a Developer PowerShell/Command Prompt or another shell where the Visual Studio compiler is available.

> Building for Vulkan requires VULKAN_SDK environment variable:
> 
> PowerShell
> ```powershell
> $env:VULKAN_SDK="C:\VulkanSDK\<version>"
> ```
> CMD
> ```cmd
> set VULKAN_SDK=C:\VulkanSDK\<version>
> ```

## Windows (ARM)

Official Windows ARM64 payloads can include CPU plus CUDA 13 for NVIDIA
ARM GPUs (for example GB10). That does not cover Qualcomm Adreno.

### Experimental OpenCL (Adreno)

`OLLAMA_LLAMA_BACKENDS=opencl` is an **experimental** local runner for
Windows ARM64 + Qualcomm Adreno (Snapdragon X Elite / Adreno X1-85). It
is not in official zip/CI. Discovery notes and remaining gaps are in
[opencl-adreno-spike.md](./opencl-adreno-spike.md).

**Hardware-verified** on a Dell Latitude 7455 (Adreno X1-85): discovery
reported `library=OpenCL`, `name=GPUOpenCL`,
`description="Qualcomm(R) Adreno(TM) X1-85 GPU"` (libdirs include
`opencl`, not Vulkan). Short Q4 text run succeeded (~202 tok/s prompt /
~29 tok/s decode on that small model). A larger HF IQ2_M model also used
the OpenCL/Adreno path. ~2 GiB `CL_DEVICE_MAX_MEM_ALLOC_SIZE` / mmproj
OOM is still expected.

Prerequisites (see also llama.cpp `docs/backend/OPENCL.md`):

- Git, CMake 3.29+, **llvm-mingw + Ninja**, VS 2022 C++ workload (or Build Tools) for headers/libs, PowerShell 7
- Native Windows ARM64: MSVC/`cl.exe` fails for llama.cpp CPU ARM (`MSVC is not supported for ARM`). Use llvm-mingw. The native winget package is `llvm-mingw-*-aarch64*`; `cmake/windows-arm64-llvm-mingw.cmake` also accepts the cross-host `*-x86_64*` layout. `HOST_CXX` can be the aarch64 package's `clang++`.
- Do **not** use `cl.exe` for ggml-opencl
- Khronos [OpenCL-Headers](https://github.com/KhronosGroup/OpenCL-Headers) +
  [OpenCL-ICD-Loader](https://github.com/KhronosGroup/OpenCL-ICD-Loader)
  installed to a prefix (example: `C:\Users\eliza\dev\llm\opencl` or `$HOME/dev/llm/opencl`)
- Qualcomm Adreno ICD from the GPU driver (registry
  `HKLM\SOFTWARE\Khronos\OpenCL\Vendors`)
- Do **not** set `GGML_OPENCL_USE_ADRENO_BIN_KERNELS` on X1-85 (X2-only)

```powershell
# 1) CPU + ollama.exe (llvm-mingw + Ninja; not MSVC)
cmake -B build .
cmake --build build --target ollama-local --parallel 8

# 2) Experimental OpenCL runner (superbuild). Clang/Ninja, not cl.exe.
#    CMAKE_PREFIX_PATH must point at the Khronos headers + ICD loader.
cmake -B build . -DOLLAMA_LLAMA_BACKENDS=opencl `
  -DCMAKE_PREFIX_PATH="C:\Users\eliza\dev\llm\opencl"
cmake --build build --target ollama-llama-server-opencl --parallel 8

# Equivalent llama/server presets: llama_opencl, llama_opencl_windows_arm64
# cmake --preset llama_opencl_windows_arm64 -DCMAKE_PREFIX_PATH="C:\Users\eliza\dev\llm\opencl"
# cmake --build --preset llama_opencl_windows_arm64
# cmake --install build/llama-server-opencl_windows_arm64 --component llama-server

# Run the dist binary explicitly so PATH does not hit store/winget Ollama.
cd dist\windows-arm64   # or your install prefix
$env:OLLAMA_LLM_LIBRARY="opencl"
$env:OLLAMA_VULKAN="0"
# Optional: avoid clashing with an installed Ollama
# $env:OLLAMA_HOST="127.0.0.1:11435"
.\ollama.exe serve
```

`OpenCL.dll` is copied next to `ggml-opencl.dll` when it is found under
`CMAKE_PREFIX_PATH`. Otherwise put a host/vendor loader on `PATH`.

## Linux

Additional prerequisites:

- (Optional) AMD GPU support
    - [ROCm](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/install/quick-start.html)
- (Optional) NVIDIA GPU support
    - [CUDA SDK](https://developer.nvidia.com/cuda-downloads)
- (Optional) Vulkan GPU support
    - [Vulkan SDK](https://vulkan.lunarg.com/sdk/home) - useful for AMD/Intel GPUs
    - Or install via package manager: `sudo apt install vulkan-sdk` (Ubuntu/Debian) or `sudo dnf install vulkan-sdk` (Fedora/CentOS)
- (Optional) MLX engine support
    - [CUDA 13+ SDK](https://developer.nvidia.com/cuda-downloads)
    - [cuDNN 9+](https://developer.nvidia.com/cudnn)
    - OpenBLAS/LAPACK: `sudo apt install libopenblas-dev liblapack-dev liblapacke-dev` (Ubuntu/Debian)
> [!IMPORTANT]
> Ensure prerequisites are in `PATH` before running CMake.

## MLX Engine (Optional)

The MLX engine enables running safetensor based models. On macOS arm64, MLX is enabled by default. On other platforms, MLX backends are selected with `OLLAMA_MLX_BACKENDS`.

### CUDA

Requires CUDA 13+ and [cuDNN](https://developer.nvidia.com/cudnn) 9+.

```shell
cmake -B build . -DOLLAMA_MLX_BACKENDS=cuda_v13
cmake --build build --parallel 8
```

### Local MLX source overrides

To build against a local checkout of MLX and/or MLX-C (useful for development), set environment variables before running CMake:

```shell
export OLLAMA_MLX_SOURCE=/path/to/mlx
export OLLAMA_MLX_C_SOURCE=/path/to/mlx-c
```

On macOS arm64:

```shell
OLLAMA_MLX_SOURCE=../mlx OLLAMA_MLX_C_SOURCE=../mlx-c cmake -B build .
cmake --build build --parallel 8
```

For CUDA:

```powershell
$env:OLLAMA_MLX_SOURCE="../mlx"
$env:OLLAMA_MLX_C_SOURCE="../mlx-c"
cmake -B build . -DOLLAMA_MLX_BACKENDS=cuda_v13
cmake --build build --parallel 8
```

## Docker

```shell
docker build .
```

### ROCm

```shell
docker build --build-arg FLAVOR=rocm .
```

## Running tests

To run tests, use `go test`:

```shell
go test ./...
```

## Library detection

Ollama looks for native helper binaries and acceleration libraries in installed and local development layouts:

* `../lib/ollama` for standard installs where `ollama` is under `bin/`
* `./lib/ollama` for Windows release-style payloads and local dist output
* `.` for macOS release artifacts that colocate helpers with `ollama`
* `build/lib/ollama` and `dist/<platform>/lib/ollama` for local development builds

If the libraries are not found, Ollama will not run with any acceleration libraries.
