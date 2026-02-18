package test

import (
	"fmt"
	"testing"
	"time"

	"github.com/gruntwork-io/terratest/modules/retry"
	"github.com/gruntwork-io/terratest/modules/ssh"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestScalewayCluster provisions real Scaleway instances and validates them.
// Run with: go test -v -timeout 30m -run TestScalewayCluster
//
// Prerequisites:
//   - SCW_ACCESS_KEY and SCW_SECRET_KEY environment variables set
//   - SSH key pair available at ~/.ssh/id_ed25519{,.pub}
func TestScalewayCluster(t *testing.T) {
	t.Parallel()

	terraformOptions := &terraform.Options{
		TerraformDir: "../",
		Vars: map[string]interface{}{
			"project_name":        "homelab-test",
			"control_plane_count": 1,
			"worker_count":        1,        // minimal pour les tests
			"control_plane_type":  "DEV1-S",
			"plex_worker_type":    "DEV1-S", // DEV1-S suffisant en test
			"worker_type":         "DEV1-S",
		},
		// Retry on eventual consistency errors from Scaleway API
		RetryableTerraformErrors: map[string]string{
			".*timeout.*":           "API timeout, retrying...",
			".*rate limit.*":        "Rate limited, retrying...",
			".*already exists.*":    "Resource conflict, retrying...",
		},
		MaxRetries:         3,
		TimeBetweenRetries: 15 * time.Second,
	}

	// Always destroy after tests
	defer terraform.Destroy(t, terraformOptions)

	// Init and apply
	terraform.InitAndApply(t, terraformOptions)

	// ── Validate outputs ─────────────────────────────────────────────────────
	t.Run("ValidateOutputs", func(t *testing.T) {
		cpIPs := terraform.OutputList(t, terraformOptions, "control_plane_public_ips")
		require.Len(t, cpIPs, 1, "expected 1 control plane IP")
		assert.NotEmpty(t, cpIPs[0], "control plane IP should not be empty")

		workerIPs := terraform.OutputList(t, terraformOptions, "worker_public_ips")
		require.Len(t, workerIPs, 1, "expected 1 worker IP")
		assert.NotEmpty(t, workerIPs[0], "worker IP should not be empty")

		privateNetID := terraform.Output(t, terraformOptions, "private_network_id")
		assert.NotEmpty(t, privateNetID, "private network ID should not be empty")
	})

	// ── SSH connectivity ─────────────────────────────────────────────────────
	t.Run("SSHConnectivity", func(t *testing.T) {
		cpIPs := terraform.OutputList(t, terraformOptions, "control_plane_public_ips")
		workerIPs := terraform.OutputList(t, terraformOptions, "worker_public_ips")
		allIPs := append(cpIPs, workerIPs...)

		for _, ip := range allIPs {
			ip := ip // capture range variable
			t.Run(fmt.Sprintf("SSH_%s", ip), func(t *testing.T) {
				t.Parallel()
				sshHost := ssh.Host{
					Hostname:    ip,
					SshUserName: "root",
					SshKeyPair:  ssh.GenerateRSAKeyPair(t, 4096),
				}
				retry.DoWithRetry(t, "SSH to node", 10, 30*time.Second, func() (string, error) {
					out, err := ssh.CheckSshCommandE(t, sshHost, "hostname")
					if err != nil {
						return "", err
					}
					return out, nil
				})
			})
		}
	})

	// ── Cloud-init completed ─────────────────────────────────────────────────
	t.Run("CloudInitComplete", func(t *testing.T) {
		cpIPs := terraform.OutputList(t, terraformOptions, "control_plane_public_ips")
		sshHost := ssh.Host{
			Hostname:    cpIPs[0],
			SshUserName: "root",
			SshKeyPair:  ssh.GenerateRSAKeyPair(t, 4096),
		}

		// Wait for cloud-init to finish (can take several minutes on first boot)
		retry.DoWithRetry(t, "Wait for cloud-init", 20, 30*time.Second, func() (string, error) {
			out, err := ssh.CheckSshCommandE(t, sshHost,
				"cloud-init status --wait && echo 'DONE'")
			if err != nil {
				return "", fmt.Errorf("cloud-init not done: %w", err)
			}
			return out, nil
		})
	})

	// ── Required packages installed ──────────────────────────────────────────
	t.Run("RequiredPackages", func(t *testing.T) {
		cpIPs := terraform.OutputList(t, terraformOptions, "control_plane_public_ips")
		sshHost := ssh.Host{
			Hostname:    cpIPs[0],
			SshUserName: "root",
			SshKeyPair:  ssh.GenerateRSAKeyPair(t, 4096),
		}

		packages := []string{"kubelet", "kubeadm", "kubectl", "containerd", "wg"}
		for _, pkg := range packages {
			pkg := pkg
			t.Run(fmt.Sprintf("Package_%s", pkg), func(t *testing.T) {
				out, err := ssh.CheckSshCommandE(t, sshHost,
					fmt.Sprintf("command -v %s && echo 'FOUND'", pkg))
				assert.NoError(t, err, "%s should be installed", pkg)
				assert.Contains(t, out, "FOUND", "%s binary not found", pkg)
			})
		}
	})

	// ── Swap disabled ────────────────────────────────────────────────────────
	t.Run("SwapDisabled", func(t *testing.T) {
		cpIPs := terraform.OutputList(t, terraformOptions, "control_plane_public_ips")
		sshHost := ssh.Host{
			Hostname:    cpIPs[0],
			SshUserName: "root",
			SshKeyPair:  ssh.GenerateRSAKeyPair(t, 4096),
		}
		out, err := ssh.CheckSshCommandE(t, sshHost, "swapon --show")
		assert.NoError(t, err)
		assert.Empty(t, out, "swap should be disabled")
	})
}

// TestTerraformPlan runs only a plan (no real resources) for faster CI feedback.
// Run with: go test -v -timeout 5m -run TestTerraformPlan
func TestTerraformPlan(t *testing.T) {
	t.Parallel()

	terraformOptions := &terraform.Options{
		TerraformDir: "../",
		Vars: map[string]interface{}{
			"project_name":        "homelab-plan-test",
			"control_plane_count": 1,
			"worker_count":        2,
			"plex_worker_type":    "DEV1-S",
			"worker_type":         "DEV1-S",
		},
		PlanFilePath: "/tmp/homelab-tfplan",
	}

	terraform.Init(t, terraformOptions)
	exitCode := terraform.PlanExitCode(t, terraformOptions)

	// Exit code 0 = no changes, 2 = changes to apply (both acceptable for a plan)
	assert.Contains(t, []int{0, 2}, exitCode,
		"terraform plan should succeed (exit 0 or 2), got %d", exitCode)
}
