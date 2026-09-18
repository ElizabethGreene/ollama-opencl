//go:build windows

package llm

import (
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows"
)

const windowsOpenCLRuntimeDLLName = "OpenCL.dll"

func WindowsOpenCLRuntimeDLLPath(libDirs []string) (string, error) {
	systemDir, err := windows.GetSystemDirectory()
	if err != nil {
		return "", err
	}
	return windowsOpenCLRuntimeDLLPath(systemDir, os.Getenv("PATH"), libDirs, fileExists)
}

func adjustWindowsOpenCLLibraryPaths(paths, gpuLibs []string) []string {
	openclDir := firstWindowsOpenCLLibDir(gpuLibs)
	if openclDir == "" {
		return paths
	}

	openclPath, err := WindowsOpenCLRuntimeDLLPath(gpuLibs)
	if err != nil {
		slog.Debug("windows OpenCL loader selection unavailable", "error", err)
		return paths
	}

	slog.Debug("selected windows OpenCL loader", "path", openclPath)

	return insertPathBefore(paths, filepath.Dir(openclPath), openclDir)
}

// Use the host OpenCL ICD loader supplied by the GPU driver (System32 on
// Adreno Windows). Do not probe backend library directories so a Khronos
// OpenCL.dll built only for linking cannot shadow the vendor loader.
func windowsOpenCLRuntimeDLLPath(
	systemDir string,
	pathEnv string,
	libDirs []string,
	exists func(string) bool,
) (string, error) {
	systemDir = filepath.Clean(systemDir)

	systemPath := filepath.Join(systemDir, windowsOpenCLRuntimeDLLName)
	if exists(systemPath) {
		return systemPath, nil
	}

	if path := firstWindowsOpenCLRuntimeDLLOnPath(pathEnv, libDirs, exists); path != "" {
		return path, nil
	}

	return "", errors.New("no host OpenCL.dll runtime DLL found")
}

func firstWindowsOpenCLRuntimeDLLOnPath(pathEnv string, excludedDirs []string, exists func(string) bool) string {
	for _, dir := range filepath.SplitList(pathEnv) {
		dir = strings.Trim(filepath.Clean(strings.Trim(dir, `"`)), `"`)
		if dir == "." || dir == "" || windowsDirInList(dir, excludedDirs) {
			continue
		}

		path := filepath.Join(dir, windowsOpenCLRuntimeDLLName)
		if exists(path) {
			return filepath.Clean(path)
		}
	}
	return ""
}

func firstWindowsOpenCLLibDir(libDirs []string) string {
	for _, dir := range libDirs {
		if dir == "" {
			continue
		}
		base := strings.ToLower(filepath.Base(dir))
		if strings.Contains(base, "opencl") {
			return filepath.Clean(dir)
		}
		if fileExists(filepath.Join(dir, "ggml-opencl.dll")) || fileExists(filepath.Join(dir, "libggml-opencl.dll")) {
			return filepath.Clean(dir)
		}
	}
	return ""
}
