# Agentic Dev Setup

Scripts to install all Lightspeed agentic components on an OpenShift cluster for
development. Builds from local source, pushes to the OpenShift internal registry, and
deploys in-cluster.

## Prerequisites

- `oc`, `podman`, `envsubst`, `helm` on PATH
- Logged into an OpenShift cluster with cluster-admin
- GCP credentials available (see [Credentials](#gcp-credentials) below)
- Sibling repos cloned alongside this repo:

```
parent-dir/
├── agentic-dev-setup/               ← this repo
├── lightspeed-agentic-operator/     (required)
├── lightspeed-agentic-sandbox/      (optional — for building sandbox from source)
├── agentic-skills/                  (optional — for building skills from source)
├── lightspeed-agentic-console/      (optional — for building console from source)
├── cluster-update-console-plugin/   (optional — for cluster update console)
└── lightspeed-operator/             (separate concern, not used by these scripts)
```

Use `clone.sh` from lightspeed-operator to set up the directory layout.

## Quick Start

```bash
# Set required env vars
export VERTEX_PROJECT=my-gcp-project
export VERTEX_REGION=us-east5

# Install everything (builds from source)
./install-all.sh

# Or skip builds (use pre-built Konflux images)
SKIP_BUILD=1 ./install-all.sh

# Build and push images only (no deploy)
BUILD_ONLY=1 ./install-all.sh

# Show all available options
./install-all.sh --help
```

## GCP Credentials

Only `VERTEX_PROJECT` and `VERTEX_REGION` are required. Credentials are auto-discovered
in this order:

1. `VERTEX_SA_KEY_PATH` — explicit path to a service account key JSON
2. `GOOGLE_APPLICATION_CREDENTIALS` — standard GCP env var
3. `~/.config/gcloud/application_default_credentials.json` — from `gcloud auth application-default login`

If none are found, `configure-llm.sh` exits with instructions.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `VERTEX_PROJECT` | *(required)* | GCP project ID |
| `VERTEX_REGION` | *(required)* | GCP region |
| `VERTEX_SA_KEY_PATH` | *(auto-discovered)* | Path to GCP credentials JSON |
| `VERTEX_MODEL` | `gemini-2.5-flash` | Model name |
| `VERTEX_MODEL_PROVIDER` | `Google` | `Google`, `Anthropic`, or `OpenAI` |
| `AGENTIC_NAMESPACE` | `openshift-lightspeed` | Namespace for all components |
| `SANDBOX_MODE` | `bare-pod` | `bare-pod` or `sandbox-claim` |
| `SANDBOX_IMAGE` | *(auto)* | Override sandbox image (skip build) |
| `CONSOLE_IMAGE` | *(auto)* | Override console plugin image (skip build) |
| `CLUSTER_UPDATE_IMAGE` | *(auto)* | Override cluster-update-console image (skip build) |
| `SKIP_BUILD` | *(unset)* | Skip all image builds |
| `BUILD_ONLY` | *(unset)* | Build images locally only (no push, no deploy, no cluster needed) |
| `AGENTIC_OPERATOR_DIR` | `../lightspeed-agentic-operator` | Agentic operator source |
| `SANDBOX_DIR` | `../lightspeed-agentic-sandbox` | Sandbox source |
| `SKILLS_DIR` | `../agentic-skills` | Skills source |
| `CONSOLE_DIR` | `../lightspeed-agentic-console` | Console plugin source |
| `CLUSTER_UPDATE_DIR` | `../cluster-update-console-plugin` | Cluster update console source |

## Individual Scripts

Each script can be run independently:

```bash
./install-sandbox.sh                # Build sandbox image only
./install-skills.sh                 # Build skills image only
./install-console.sh                # Build console plugin image only
./install-agentic-operator.sh       # Deploy agentic operator
./install-cluster-update-console.sh # Build + deploy cluster-update-console-plugin
./configure-llm.sh                  # Configure LLM provider
./uninstall.sh                      # Tear down everything
```

## Uninstall

```bash
./uninstall.sh

# Skip confirmation prompt
FORCE=1 ./uninstall.sh
```
