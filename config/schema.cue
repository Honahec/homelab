package homelab

import (
	"encoding/yaml"
	"strings"
)

#Image: {
	source:           string & !=""
	target:           string & !=""
	_sourcePinned:    true
	_sourcePinned:    strings.Contains(source, "@sha256:") || strings.Contains(source, ":sha-")
	_targetTagged:    true
	_targetTagged:    target =~ "(^|.*/)[^/:]+:[^/:]+$"
	_targetImmutable: true
	_targetImmutable: !strings.Contains(target, ":latest")
}

#Env: [=~"^[A-Z][A-Z0-9_]*$"]: string

#ServiceName: string & =~"^[a-z0-9][a-z0-9_-]*$"

#NetworkName: "edge" | "backend"

#Duration: string & =~"^[1-9][0-9]*(ms|s|m|h)$"

#MemoryLimit: string & =~"^[1-9][0-9]*[kmg]$"

#RestartPolicy: "always" | "unless-stopped"

#DependencyCondition: "service_started" | "service_healthy" | "service_completed_successfully"

#Dependency: {
	condition: #DependencyCondition
}

#Healthcheck: {
	test: (["CMD", string, ...string] | ["CMD-SHELL", string])
	interval:      #Duration
	timeout:       #Duration
	retries:       int & >=1
	start_period?: #Duration
}

#EnvFile: {
	path:     string & =~"^/srv/homelab/env/[A-Za-z0-9._-]+\\.env$"
	required: false
	format?:  "raw"
}

#Capability: "NET_ADMIN" | "NET_RAW"

#NetworkMode: "host" | "none"

#Logging: {
	driver: "json-file"
	options: {
		"max-size": string & =~"^[1-9][0-9]*[kmg]$"
		"max-file": string & =~"^[1-9][0-9]*$"
	}
}

#ComposeService: {
	// Generated centrally; declaring these fields here keeps the final object closed.
	image?:       string & !=""
	restart?:     #RestartPolicy
	pull_policy?: "never"
	logging?:     #Logging

	hostname?:     string & !=""
	network_mode?: #NetworkMode
	cap_add?: [...#Capability] & [_, ...]
	devices?: [...string] & [_, ...]
	env_file?: [...#EnvFile] & [_, ...]
	environment?: #Env
	command?: string | [...string]
	entrypoint?: string | [...string]
	depends_on?: [=~"^[a-z0-9][a-z0-9_-]*$"]: #Dependency
	healthcheck?: #Healthcheck
	ports?: [...string] & [_, ...]
	volumes?: [...string] & [_, ...]
	networks?: [...#NetworkName] & [_, ...]
	mem_limit?: #MemoryLimit
	read_only?: bool
	tmpfs?: [...string] & [_, ...]
}

#Network: {
	internal?: bool
}

#Volume: {
	external?: bool
	name?:     string & !=""
}

#ComposeTopLevel: {
	volumes?: [=~"^[a-z0-9][a-z0-9_-]*$"]: #Volume
}

#Endpoint: {
	service:       #ServiceName
	port:          int
	_validService: true
	_validService: service != ""
	_validPort:    true
	_validPort:    port >= 1 && port <= 65535
}

#Route: {
	path:     string & =~"^/"
	upstream: #Endpoint
}

#Site: {
	{
		kind:     "proxy"
		upstream: #Endpoint
	} | {
		kind: "routes"
		routes: [...#Route] & [_, ...]
		fallbackStatus: int & >=400 & <=599
	}
}

#Caddy: {
	email: string & =~"^[^@ ]+@[^@ ]+$"
	proxySites: [=~"^[A-Za-z0-9.-]+$"]: #Endpoint
	routeSites: [=~"^[A-Za-z0-9.-]+$"]: {
		routes: [...#Route] & [_, ...]
		fallbackStatus: *404 | (int & >=400 & <=599)
	}
}

#Service: {
	image:    #Image
	compose:  #ComposeService
	database: *false | bool
	env?:     #Env
	if database {
		env: {
			DB_NAME:      string & !=""
			DB_USER:      string & !=""
			DB_PASSWORD:  string
			DATABASE_URL: string & !=""
		}
	}
}

#Host: {
	restart: #RestartPolicy
	services: [=~"^[a-z0-9][a-z0-9_-]*$"]: #Service
	networks: {
		"edge":    #Network
		"backend": #Network
	}
	topLevel: *{} | #ComposeTopLevel
	caddy:   #Caddy
	hostEnv: #Env

	_serviceRefs: {
		for domain, endpoint in caddy.proxySites {
			"proxy:\(domain)": services[endpoint.service]
		}
		for domain, site in caddy.routeSites {
			for index, route in site.routes {
				"route:\(domain):\(index)": services[route.upstream.service]
			}
		}
	}
	_networkRefs: {
		for serviceName, service in services if service.compose.networks != _|_ {
			for _, networkName in service.compose.networks {
				"\(serviceName):\(networkName)": networks[networkName]
			}
		}
	}
	_dependencyRefs: {
		for serviceName, service in services if service.compose.depends_on != _|_ {
			for dependencyName, _ in service.compose.depends_on {
				"\(serviceName):\(dependencyName)": services[dependencyName]
			}
		}
	}
}

hosts: {
	"primary":   #Host
	"secondary": #Host
}

outputs: {
	for hostName, host in hosts {
		"\(hostName)": {
			compose: yaml.Marshal({
				name: "homelab-\(hostName)"
				services: {
					for serviceName, service in host.services {
						"\(serviceName)": service.compose & {
							image:       service.image.target
							restart:     host.restart
							pull_policy: "never"
							logging: {
								driver: "json-file"
								options: {
									"max-size": "10m"
									"max-file": "3"
								}
							}
						}
					}
				}
				networks: host.networks
				if host.topLevel.volumes != _|_ {
					volumes: host.topLevel.volumes
				}
			})
			images: strings.Join([
				for _, service in host.services {
					"\(service.image.source)|\(service.image.target)"
				},
			], "\n")
			databases: strings.Join([
				for serviceName, service in host.services if service.database {
					serviceName
				},
			], "\n")
			caddy:   host.caddy
			hostEnv: host.hostEnv
			envExamples: {
				for serviceName, service in host.services if service.env != _|_ {
					"\(serviceName)": service.env
				}
			}
		}
	}
}
