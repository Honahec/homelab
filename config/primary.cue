package homelab

hosts: "primary": {
	restart: "unless-stopped"
	hostEnv: {}
	networks: {
		"edge": {}
		"backend": {internal: true}
	}
	caddy: {
		email: "ops@example.com"
		proxySites: {
			"app-primary.example.com": {service: "web", port: 80}
		}
		routeSites: {}
	}
	services: {
		"web": {
			image: {
				source: "nginx@sha256:5616878291a2eed594aee8db4dade5878cf7edcb475e59193904b198d9b830de"
				target: source
			}
			compose: {
				healthcheck: {
					test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1/"]
					interval: "30s"
					timeout:  "5s"
					retries:  5
				}
				networks: ["edge"]
				mem_limit: "128m"
			}
		}
		"caddy": {
			image: {
				source: "caddy@sha256:4c6e91c6ed0e2fa03efd5b44747b625fec79bc9cd06ac5235a779726618e530d"
				target: source
			}
			compose: {
				depends_on: {"web": {condition: "service_healthy"}}
				ports: ["80:80", "443:443", "443:443/udp"]
				volumes: [
					"/srv/homelab/runtime/primary/Caddyfile:/etc/caddy/Caddyfile:ro",
					"/srv/homelab/data/caddy-primary/data:/data",
					"/srv/homelab/data/caddy-primary/config:/config",
				]
				networks: ["edge"]
				mem_limit: "128m"
			}
		}
	}
}
