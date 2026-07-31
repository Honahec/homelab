package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

type endpoint struct {
	Service string `json:"service"`
	Port    int    `json:"port"`
}

type route struct {
	Path     string   `json:"path"`
	Upstream endpoint `json:"upstream"`
}

type routeSite struct {
	Routes         []route `json:"routes"`
	FallbackStatus int     `json:"fallbackStatus"`
}

type caddyConfig struct {
	Email      string               `json:"email"`
	ProxySites map[string]endpoint  `json:"proxySites"`
	RouteSites map[string]routeSite `json:"routeSites"`
}

type generatedConfig struct {
	HostEnv     map[string]string            `json:"hostEnv"`
	Caddy       caddyConfig                  `json:"caddy"`
	EnvExamples map[string]map[string]string `json:"envExamples"`
}

func main() {
	if len(os.Args) < 2 {
		fatalf("usage: homelab <generate|transfer-images> [options]")
	}

	var err error
	switch os.Args[1] {
	case "generate":
		err = generate(os.Args[2:])
	case "transfer-images":
		err = transferImages(os.Args[2:])
	default:
		err = fmt.Errorf("unknown command %q", os.Args[1])
	}
	if err != nil {
		fatalf("%v", err)
	}
}

func generate(args []string) error {
	flags := flag.NewFlagSet("generate", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	output := flags.String("output", "", "output directory")
	root := flags.String("root", ".", "repository root")
	hosts := flags.String("hosts", "primary,secondary", "comma-separated host names")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *output == "" {
		return errors.New("generate requires --output")
	}
	if _, err := os.Stat(*output); err == nil {
		return fmt.Errorf("output already exists: %s", *output)
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	absoluteRoot, err := filepath.Abs(*root)
	if err != nil {
		return err
	}
	*root = absoluteRoot
	if err := run(*root, "cue", "vet", filepath.Join(*root, "config")); err != nil {
		return err
	}
	for _, host := range splitHosts(*hosts) {
		if err := generateHost(*root, *output, host); err != nil {
			return fmt.Errorf("generate %s: %w", host, err)
		}
	}
	return nil
}

func generateHost(root, output, host string) error {
	dir := filepath.Join(output, host)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	compose, err := cueExport(root, "outputs."+host+".compose", "text")
	if err != nil {
		return err
	}
	images, err := cueExport(root, "outputs."+host+".images", "text")
	if err != nil {
		return err
	}
	databases, err := cueExport(root, "outputs."+host+".databases", "text")
	if err != nil {
		return err
	}
	configJSON, err := cueExport(root, "outputs."+host, "json")
	if err != nil {
		return err
	}
	var config generatedConfig
	if err := json.Unmarshal([]byte(configJSON), &config); err != nil {
		return fmt.Errorf("decode CUE output: %w", err)
	}
	if err := writeFile(filepath.Join(dir, "compose.yaml"), compose); err != nil {
		return err
	}
	if err := writeFile(filepath.Join(dir, "images.txt"), images); err != nil {
		return err
	}
	if err := writeFile(filepath.Join(dir, "databases.txt"), databases); err != nil {
		return err
	}
	if err := writeEnv(filepath.Join(dir, ".env.example"), config.HostEnv); err != nil {
		return err
	}
	if err := writeCaddy(filepath.Join(dir, "Caddyfile"), config.Caddy); err != nil {
		return err
	}
	for app, values := range config.EnvExamples {
		if err := writeEnv(filepath.Join(dir, app+".env.example"), values); err != nil {
			return err
		}
	}
	return nil
}

func transferImages(args []string) error {
	flags := flag.NewFlagSet("transfer-images", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	manifest := flags.String("manifest", "", "image manifest")
	destination := flags.String("destination", "", "SSH destination")
	port := flags.String("port", "", "SSH port")
	sudo := flags.String("sudo", "", "remote sudo command")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if *manifest == "" || *destination == "" || *port == "" {
		return errors.New("transfer-images requires --manifest, --destination and --port")
	}
	file, err := os.Open(*manifest)
	if err != nil {
		return err
	}
	defer file.Close()
	var targets []string
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "|", 2)
		if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
			return fmt.Errorf("invalid image manifest line: %q", line)
		}
		source, target := parts[0], parts[1]
		if err := validateTarget(target); err != nil {
			return err
		}
		if imageExists(*destination, *port, *sudo, target) {
			continue
		}
		if err := run(".", "docker", "pull", source); err != nil {
			return err
		}
		if source != target {
			if err := run(".", "docker", "tag", source, target); err != nil {
				return err
			}
		}
		targets = append(targets, target)
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	if len(targets) == 0 {
		return nil
	}
	return saveAndLoad(targets, *destination, *port, *sudo)
}

func validateTarget(target string) error {
	if strings.Contains(target, "@") {
		return fmt.Errorf("target image must use an explicit tag for docker save/load: %s", target)
	}
	name := target[strings.LastIndex(target, "/")+1:]
	if !strings.Contains(name, ":") {
		return fmt.Errorf("target image must use an explicit tag for docker save/load: %s", target)
	}
	return nil
}

func imageExists(destination, port, sudo, target string) bool {
	args := []string{"-n", "-p", port, destination}
	args = append(args, shellWords(sudo)...)
	args = append(args, "docker", "image", "inspect", target)
	return exec.Command("ssh", args...).Run() == nil
}

func saveAndLoad(targets []string, destination, port, sudo string) error {
	save := exec.Command("docker", append([]string{"save"}, targets...)...)
	stdout, err := save.StdoutPipe()
	if err != nil {
		return err
	}
	if err := save.Start(); err != nil {
		return err
	}
	gzipCmd := exec.Command("gzip", "-1")
	gzipCmd.Stdin = stdout
	gzipOutput, err := gzipCmd.StdoutPipe()
	if err != nil {
		return err
	}
	if err := gzipCmd.Start(); err != nil {
		return err
	}
	args := []string{"-p", port, destination}
	args = append(args, shellWords(sudo)...)
	args = append(args, "sh", "-c", "gunzip | docker load")
	remote := exec.Command("ssh", args...)
	remote.Stdin = gzipOutput
	remote.Stdout = os.Stdout
	remote.Stderr = os.Stderr
	if err := remote.Run(); err != nil {
		return err
	}
	if err := gzipCmd.Wait(); err != nil {
		return err
	}
	return save.Wait()
}

func cueExport(root, expression, format string) (string, error) {
	cmd := exec.Command("cue", "export", filepath.Join(root, "config"), "-e", expression, "--out", format)
	output, err := cmd.Output()
	if err != nil {
		return "", commandError(cmd, err)
	}
	return string(output), nil
}

func run(dir, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func commandError(cmd *exec.Cmd, err error) error {
	if exitErr, ok := err.(*exec.ExitError); ok {
		return fmt.Errorf("%s: %s", strings.Join(cmd.Args, " "), strings.TrimSpace(string(exitErr.Stderr)))
	}
	return err
}

func writeFile(path, content string) error {
	return os.WriteFile(path, []byte(content), 0o644)
}

func writeEnv(path string, values map[string]string) error {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var builder strings.Builder
	for _, key := range keys {
		fmt.Fprintf(&builder, "%s=%s\n", key, values[key])
	}
	return writeFile(path, builder.String())
}

func writeCaddy(path string, config caddyConfig) error {
	var builder strings.Builder
	fmt.Fprintf(&builder, "{\n\temail %s\n}\n\n", config.Email)
	proxyDomains := sortedKeys(config.ProxySites)
	for _, domain := range proxyDomains {
		endpoint := config.ProxySites[domain]
		fmt.Fprintf(&builder, "%s {\n\treverse_proxy %s:%d\n}\n\n", domain, endpoint.Service, endpoint.Port)
	}
	routeDomains := sortedKeys(config.RouteSites)
	for _, domain := range routeDomains {
		site := config.RouteSites[domain]
		fmt.Fprintf(&builder, "%s {\n", domain)
		for index, item := range site.Routes {
			fmt.Fprintf(&builder, "\t@route%d path %s\n\thandle @route%d {\n\t\treverse_proxy %s:%d\n\t}\n", index, item.Path, index, item.Upstream.Service, item.Upstream.Port)
		}
		fmt.Fprintf(&builder, "\trespond %d\n}\n\n", site.FallbackStatus)
	}
	return writeFile(path, builder.String())
}

func sortedKeys[T any](values map[string]T) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func splitHosts(value string) []string {
	var hosts []string
	for _, host := range strings.Split(value, ",") {
		if host = strings.TrimSpace(host); host != "" {
			hosts = append(hosts, host)
		}
	}
	return hosts
}

func shellWords(value string) []string {
	if value == "" {
		return nil
	}
	return strings.Fields(value)
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
