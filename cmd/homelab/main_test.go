package main

import "testing"

func TestValidateTarget(t *testing.T) {
	tests := []struct {
		name   string
		target string
		valid  bool
	}{
		{name: "tag", target: "homelab/app:sha-abc", valid: true},
		{name: "registry tag", target: "registry.example:5000/app:v1", valid: true},
		{name: "digest", target: "registry.example/app@sha256:abc", valid: false},
		{name: "missing tag", target: "homelab/app", valid: false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := validateTarget(test.target) == nil; got != test.valid {
				t.Fatalf("validateTarget(%q) = %v, want %v", test.target, got, test.valid)
			}
		})
	}
}

func TestSplitHosts(t *testing.T) {
	got := splitHosts(" primary, secondary,, ")
	want := []string{"primary", "secondary"}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("splitHosts() = %#v, want %#v", got, want)
	}
}
