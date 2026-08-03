# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Shell scripts to install the full Lightspeed agentic stack on an OpenShift cluster for development. Builds images from local source (sibling repos), pushes to the OCP internal registry, and deploys in-cluster. All scripts are Bash, use `set -euo pipefail`, and source `_lib.sh` for shared helpers.

## Prerequisites

- `oc`, `podman`, `envsubst`, `helm` on PATH
- Logged into an OpenShift cluster with cluster-admin
- GCP credentials available (service account key, `GOOGLE_APPLICATION_CREDENTIALS`, or `gcloud auth application-default login`)
- Required sibling repos cloned alongside this repo (use `clone.sh` from lightspeed-operator):
  - `lightspeed-agentic-operator` (required)
  - `lightspeed-operator`, `lightspeed-agentic-sandbox`, `agentic-skills`, `lightspeed-agentic-console`, `cluster-update-console-plugin`, `cluster-version-operator` (optional)

## Common Commands

```bash
# Full install (build from source + deploy)
export VERTEX_PROJECT=my-project VERTEX_REGION=us-east5
./install-all.sh

# Skip builds, use pre-built Konflux images
SKIP_BUILD=1 ./install-all.sh

# Build images locally only (no cluster needed)
BUILD_ONLY=1 ./install-all.sh

# Individual components
./install-sandbox.sh
./install-skills.sh
./install-console.sh
./install-lightspeed.sh
./install-agentic-operator.sh
./install-cluster-update-console.sh
./configure-llm.sh --vertex-anthropic   # or --vertex-google, --openai
./ols-configure-llm.sh --vertex-anthropic  # or --vertex-google, --openai

# Dev CVO with agenticrun controller (optional, standalone)
./install-cvo.sh
./install-cvo.sh --skip-tp-check

# Teardown
./uninstall.sh
FORCE=1 ./uninstall.sh
```

## Architecture

**`_lib.sh`** — shared library sourced by all scripts. Provides:
- `lib::log_*` — colored logging (step, info, success, warning, error)
- `lib::require_cmd`, `lib::require_var`, `lib::require_oc_login` — validation
- `lib::resolve_sibling` — locates sibling repos by env var or convention (`../repo-name`)
- `lib::setup_registry`, `lib::build_and_push`, `lib::build_local` — image build/push to OCP internal registry
- `lib::wait_for_deployment`, `lib::ensure_namespace`, `lib::ensure_pull_secret` — cluster helpers

**`install-all.sh`** — orchestrator. Runs in order:
1. Prerequisite checks
2. Resolves sibling repo paths
3. Builds sandbox, skills, console images
4. Deploys lightspeed operator via `install-lightspeed.sh` (kustomize-based `make deploy`) + OLSConfig
5. Deploys agentic operator via upstream quickstart `install.sh`
6. Deploys cluster-update-console-plugin via Helm
7. Configures LLM provider + Agent CR via `configure-llm.sh` with a provider flag

**`templates/`** — Kubernetes CR templates with `${ENV_VAR}` placeholders processed by `envsubst`:
- `openai.yaml` — LLMProvider + Agent for OpenAI (direct API key)
- `vertex-anthropic.yaml` — LLMProvider + Agent for Anthropic models via Vertex AI
- `vertex-google.yaml` — LLMProvider + Agent for Google models via Vertex AI
- `approvalpolicy-manual.yaml` — cluster-scoped ApprovalPolicy requiring manual approval at all stages
- `ols-openai.yaml` — OLSConfig for OpenAI
- `ols-vertex-google.yaml` — OLSConfig for Google models via Vertex AI
- `ols-vertex-anthropic.yaml` — OLSConfig for Anthropic models via Vertex AI

**`install-lightspeed.sh`** — builds the lightspeed-operator from `../lightspeed-operator`, pushes to internal registry, deploys via `make deploy IMG=<image>` (kustomize-based), and calls `ols-configure-llm.sh` to create the OLSConfig CR + LLM secret.

**`install-cvo.sh`** — standalone script (not called by `install-all.sh`). Builds a dev CVO from the `cluster-version-operator` sibling repo with the agenticrun controller enabled. Generates a `Dockerfile.dev` with embedded release metadata and agentic-skills image reference, pushes to the `cvo-dev` project, and patches the live CVO deployment. Supports `--skip-tp-check` to bypass the TechPreviewNoUpgrade gate.

**Image build pattern**: each `install-*.sh` script outputs the in-cluster image URL on stdout so callers can capture it (e.g., `SANDBOX_IMAGE=$(./install-sandbox.sh)`). `BUILD_ONLY` mode uses `lib::build_local` (no push); normal mode uses `lib::build_and_push`.

## Key Environment Variables

| Variable | Required | Default |
|---|---|---|
| `VERTEX_PROJECT` | for vertex providers | — |
| `VERTEX_REGION` | for vertex providers | — |
| `VERTEX_MODEL` | no | `gemini-2.5-flash` (vertex-google) / `claude-opus-4-6` (vertex-anthropic) |
| `VERTEX_MODEL_PROVIDER` | no | `Google` |
| `OPENAI_API_KEY` | for openai provider | — |
| `OPENAI_MODEL` | no | `gpt-5.4` |
| `OLS_MODEL` | no | `gpt-5.4` (openai) / `gemini-2.5-flash` (vertex-google) / `claude-opus-4-6` (vertex-anthropic) |
| `AGENTIC_NAMESPACE` | no | `openshift-lightspeed` |
| `SANDBOX_MODE` | no | `bare-pod` |
| `SKIP_BUILD` | no | unset |
| `BUILD_ONLY` | no | unset |

## Shell Conventions

- All scripts use `set -euo pipefail` and source `_lib.sh`
- New shared helpers go in `_lib.sh` with `lib::` prefix
- Scripts that build images print the image URL to stdout (no other stdout output)
- All user-facing output goes to stderr via `lib::log_*`
- Each script supports `-h`/`--help` via `lib::parse_args`
