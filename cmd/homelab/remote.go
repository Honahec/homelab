package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type exitError struct {
	code    int
	message string
}

func (err *exitError) Error() string {
	return err.message
}

type preflightOptions struct {
	host      string
	config    string
	mode      string
	root      string
	minFreeKB uint64
}

var envFilePattern = regexp.MustCompile(`(?m)^\s*- path: (/srv/homelab/env/[^\s]+\.env)$`)

func preflight(args []string) error {
	flags := flag.NewFlagSet("preflight", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	options := preflightOptions{}
	flags.StringVar(&options.host, "host", "", "host name")
	flags.StringVar(&options.config, "config", "", "generated config directory")
	flags.StringVar(&options.mode, "mode", "full", "preflight mode")
	flags.StringVar(&options.root, "root", "/srv/homelab", "homelab root")
	flags.Uint64Var(&options.minFreeKB, "min-free-kb", 0, "minimum free disk space")
	if err := flags.Parse(args); err != nil {
		return err
	}
	return checkPreflight(options)
}

func checkPreflight(options preflightOptions) error {
	if options.host == "" || options.config == "" {
		return errors.New("preflight requires --host and --config")
	}
	compose := filepath.Join(options.config, "compose.yaml")
	if err := requireFile(compose); err != nil {
		return err
	}
	if err := requireFile(filepath.Join(options.config, "Caddyfile")); err != nil {
		return err
	}
	missing := false
	hostEnv := filepath.Join(options.root, "env", options.host+".env")
	if err := requirePrivateEnv(hostEnv); err != nil {
		fmt.Fprintln(os.Stderr, err)
		missing = true
	}
	content, err := os.ReadFile(compose)
	if err != nil {
		return err
	}
	seen := map[string]bool{}
	for _, match := range envFilePattern.FindAllStringSubmatch(string(content), -1) {
		path := rootedPath(options.root, match[1])
		if seen[path] {
			continue
		}
		seen[path] = true
		if err := requirePrivateEnv(path); err != nil {
			fmt.Fprintln(os.Stderr, err)
			missing = true
		}
	}
	if missing {
		return &exitError{code: 10, message: "production environment is not ready"}
	}
	if options.mode == "env-only" {
		return nil
	}
	if options.mode != "full" {
		return fmt.Errorf("unknown preflight mode: %s", options.mode)
	}
	if err := runCommand("", nil, "docker", "compose", "version"); err != nil {
		return err
	}
	if err := runCommand("", nil, "docker", "compose", "--env-file", hostEnv, "-f", compose, "config", "--quiet"); err != nil {
		return err
	}
	if options.minFreeKB > 0 {
		var stats syscall.Statfs_t
		if err := syscall.Statfs("/", &stats); err != nil {
			return err
		}
		availableKB := stats.Bavail * uint64(stats.Bsize) / 1024
		if availableKB < options.minFreeKB {
			return fmt.Errorf("insufficient disk space: %d KiB available, need %d KiB", availableKB, options.minFreeKB)
		}
	}
	return nil
}

func deploy(args []string) error {
	flags := flag.NewFlagSet("deploy", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	host := flags.String("host", "", "host name")
	revision := flags.String("revision", "origin/main", "Git revision")
	config := flags.String("config", "", "generated config directory")
	root := flags.String("root", "/srv/homelab", "homelab root")
	minFreeKB := flags.Uint64("min-free-kb", 0, "minimum free disk space")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *host == "" || *config == "" {
		return errors.New("deploy requires --host and --config")
	}
	stack := filepath.Join(*root, "stack")
	if err := runCommand(stack, nil, "git", "fetch", "--prune", "origin"); err != nil {
		return err
	}
	dirty, err := dirtyWorktree(stack)
	if err != nil {
		return err
	}
	if dirty {
		if err := backupAndCleanWorktree(stack, *root, *host); err != nil {
			return err
		}
	}
	if err := runCommand(stack, nil, "git", "checkout", "--detach", *revision); err != nil {
		return err
	}
	runtime := filepath.Join(*root, "runtime", *host)
	if err := os.MkdirAll(runtime, 0o755); err != nil {
		return err
	}
	if err := copyFile(filepath.Join(*config, "Caddyfile"), filepath.Join(runtime, "Caddyfile"), 0o644); err != nil {
		return err
	}
	if err := replaceSymlink(*config, filepath.Join(*root, "candidate")); err != nil {
		return err
	}
	if err := checkPreflight(preflightOptions{host: *host, config: *config, root: *root, mode: "full", minFreeKB: *minFreeKB}); err != nil {
		return err
	}
	if err := runCommand("", nil, filepath.Join(stack, "ops", "init-databases.sh"), *host, *config); err != nil {
		return err
	}
	envFile := filepath.Join(*root, "env", *host+".env")
	compose := filepath.Join(*config, "compose.yaml")
	composeArgs := []string{"compose", "--env-file", envFile, "-f", compose}
	if err := runCommand("", nil, "docker", append(composeArgs, "up", "-d", "--pull", "never", "--remove-orphans", "--wait", "--wait-timeout", "180")...); err != nil {
		return err
	}
	services, err := commandOutput("", "docker", append(composeArgs, "config", "--services")...)
	if err != nil {
		return err
	}
	if containsLine(services, "caddy") {
		if err := reconcileCaddy(composeArgs, filepath.Join(runtime, "Caddyfile")); err != nil {
			return err
		}
	}
	if err := runCommand("", nil, filepath.Join(stack, "ops", "verify.sh"), *host, *config); err != nil {
		return err
	}
	if err := runCommand("", nil, filepath.Join(stack, "ops", "cleanup-images.sh"), *host, *config); err != nil {
		return err
	}
	return replaceSymlink(*config, filepath.Join(*root, "current"))
}

func reconcileCaddy(composeArgs []string, caddyfile string) error {
	file, err := os.Open(caddyfile)
	if err != nil {
		return err
	}
	cmp := exec.Command("docker", append(composeArgs, "exec", "-T", "caddy", "cmp", "-s", "/etc/caddy/Caddyfile", "-")...)
	cmp.Stdin = file
	cmp.Stdout = os.Stdout
	cmp.Stderr = os.Stderr
	matched := cmp.Run() == nil
	file.Close()
	if !matched {
		if err := runCommand("", nil, "docker", append(composeArgs, "up", "-d", "--pull", "never", "--no-deps", "--force-recreate", "caddy")...); err != nil {
			return err
		}
	}
	if err := runCommand("", nil, "docker", append(composeArgs, "exec", "-T", "caddy", "caddy", "validate", "--config", "/etc/caddy/Caddyfile")...); err != nil {
		return err
	}
	wgetArgs := append(composeArgs, "exec", "-T", "caddy", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:2019/config/")
	if !commandSucceeds("", "docker", wgetArgs...) {
		if err := runCommand("", nil, "docker", append(composeArgs, "up", "-d", "--pull", "never", "--no-deps", "--force-recreate", "caddy")...); err != nil {
			return err
		}
	}
	return runCommand("", nil, "docker", append(composeArgs, "exec", "-T", "caddy", "caddy", "reload", "--address", "127.0.0.1:2019", "--config", "/etc/caddy/Caddyfile")...)
}

func dirtyWorktree(stack string) (bool, error) {
	if !commandSucceeds(stack, "git", "diff", "--quiet") || !commandSucceeds(stack, "git", "diff", "--cached", "--quiet") {
		return true, nil
	}
	untracked, err := commandOutput(stack, "git", "ls-files", "--others", "--exclude-standard")
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(untracked) != "", nil
}

func backupAndCleanWorktree(stack, root, host string) error {
	directory := filepath.Join(root, "backups", "working-tree")
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	archive := filepath.Join(directory, host+"-"+time.Now().UTC().Format("20060102T150405Z")+".tgz")
	if err := runCommand(stack, nil, "tar", "--exclude=.git", "-czf", archive, "."); err != nil {
		return err
	}
	if err := os.Chmod(archive, 0o600); err != nil {
		return err
	}
	if err := runCommand(stack, nil, "git", "reset", "--hard", "HEAD"); err != nil {
		return err
	}
	return runCommand(stack, nil, "git", "clean", "-fd")
}

func requireFile(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("not a regular file: %s", path)
	}
	return nil
}

func requirePrivateEnv(path string) error {
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("missing environment file: %s", path)
	}
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("not a regular environment file: %s", path)
	}
	if info.Mode().Perm() != 0o600 {
		return fmt.Errorf("environment file must have mode 600: %s", path)
	}
	return nil
}

func rootedPath(root, path string) string {
	if root == "/srv/homelab" {
		return path
	}
	return filepath.Join(root, strings.TrimPrefix(path, "/srv/homelab/"))
}

func copyFile(source, target string, mode os.FileMode) error {
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()
	output, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(output, input); err != nil {
		output.Close()
		return err
	}
	if err := output.Close(); err != nil {
		return err
	}
	return os.Chmod(target, mode)
}

func replaceSymlink(target, link string) error {
	temporary := link + ".tmp-" + strconv.Itoa(os.Getpid())
	_ = os.Remove(temporary)
	if err := os.Symlink(target, temporary); err != nil {
		return err
	}
	if err := os.Rename(temporary, link); err != nil {
		os.Remove(temporary)
		return err
	}
	return nil
}

func runCommand(dir string, stdin io.Reader, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	cmd.Stdin = stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func commandOutput(dir, name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	output, err := cmd.Output()
	if err != nil {
		return "", commandError(cmd, err)
	}
	return string(output), nil
}

func commandSucceeds(dir, name string, args ...string) bool {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	return cmd.Run() == nil
}

func containsLine(output, expected string) bool {
	for _, line := range strings.Split(output, "\n") {
		if line == expected {
			return true
		}
	}
	return false
}
