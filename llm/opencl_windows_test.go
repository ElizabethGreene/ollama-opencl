//go:build windows

package llm

import (
	"path/filepath"
	"testing"
)

func TestWindowsOpenCLRuntimeDLLPathPrefersSystem32(t *testing.T) {
	systemDir := `C:\Windows\System32`
	openclDir := `C:\ollama\lib\ollama\opencl`
	files := map[string]bool{
		filepath.Join(systemDir, windowsOpenCLRuntimeDLLName): true,
		filepath.Join(openclDir, windowsOpenCLRuntimeDLLName): true,
	}
	exists := func(path string) bool { return files[filepath.Clean(path)] }

	got, err := windowsOpenCLRuntimeDLLPath(
		systemDir,
		openclDir,
		[]string{openclDir},
		exists,
	)
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(systemDir, windowsOpenCLRuntimeDLLName)
	if got != want {
		t.Fatalf("OpenCL loader = %q, want System32 %q", got, want)
	}
}

func TestWindowsOpenCLRuntimeDLLPathIgnoresBundledLoader(t *testing.T) {
	systemDir := `C:\Windows\System32`
	openclDir := `C:\ollama\lib\ollama\opencl`
	files := map[string]bool{
		filepath.Join(openclDir, windowsOpenCLRuntimeDLLName): true,
	}
	exists := func(path string) bool { return files[filepath.Clean(path)] }

	_, err := windowsOpenCLRuntimeDLLPath(
		systemDir,
		openclDir,
		[]string{openclDir},
		exists,
	)
	if err == nil {
		t.Fatal("expected error when only a bundled OpenCL.dll exists")
	}
}

func TestAdjustWindowsOpenCLLibraryPathsInsertsSystem32(t *testing.T) {
	systemDir := `C:\Windows\System32`
	llamaDir := `C:\ollama\lib\ollama`
	openclDir := filepath.Join(llamaDir, "opencl")
	paths := []string{llamaDir, openclDir}

	got := insertPathBefore(paths, systemDir, openclDir)
	if len(got) != 3 || got[0] != llamaDir || got[1] != systemDir || got[2] != openclDir {
		t.Fatalf("PATH order = %#v, want llama, System32, opencl", got)
	}
}
