package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestCheckPreflightEnvOnly(t *testing.T) {
	root := t.TempDir()
	config := filepath.Join(root, "release")
	if err := os.MkdirAll(filepath.Join(root, "env"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(config, 0o755); err != nil {
		t.Fatal(err)
	}
	compose := "services:\n  app:\n    env_file:\n      - path: /srv/homelab/env/app.env\n"
	writeTestFile(t, filepath.Join(config, "compose.yaml"), compose, 0o644)
	writeTestFile(t, filepath.Join(config, "Caddyfile"), "{}\n", 0o644)
	writeTestFile(t, filepath.Join(root, "env", "primary.env"), "", 0o600)
	writeTestFile(t, filepath.Join(root, "env", "app.env"), "", 0o600)

	err := checkPreflight(preflightOptions{
		host: "primary", config: config, mode: "env-only", root: root,
	})
	if err != nil {
		t.Fatalf("checkPreflight() error = %v", err)
	}
}

func TestCheckPreflightMissingEnvReturnsTen(t *testing.T) {
	root := t.TempDir()
	config := filepath.Join(root, "release")
	if err := os.MkdirAll(config, 0o755); err != nil {
		t.Fatal(err)
	}
	writeTestFile(t, filepath.Join(config, "compose.yaml"), "services: {}\n", 0o644)
	writeTestFile(t, filepath.Join(config, "Caddyfile"), "{}\n", 0o644)

	err := checkPreflight(preflightOptions{
		host: "primary", config: config, mode: "env-only", root: root,
	})
	var coded *exitError
	if !errors.As(err, &coded) || coded.code != 10 {
		t.Fatalf("checkPreflight() error = %v, want exit code 10", err)
	}
}

func writeTestFile(t *testing.T, path, content string, mode os.FileMode) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}
