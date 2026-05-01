# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`kubecrash` is a hands-on Kubernetes mastery project: build a local cluster on physical machines, intentionally break things through chaos testing, and learn Kubernetes deeply by operating and recovering from failures. The repository contains tooling and documentation for flashing Raspberry Pi OS onto drives and bootstrapping the cluster.

## Development Environment

The project uses a VS Code devcontainer (Ubuntu 24.04) with `mise` for tool management. Tools are defined in `mise.toml`:
- `kubectl` — cluster interaction
- `claude-code` — AI assistant CLI

After container creation, `scripts/setup.sh` runs automatically: it trusts and installs the `mise.toml` tools.

The devcontainer runs with `--network=host` so `kubectl` can reach cluster nodes directly. The `.kube/` directory is bind-mounted from the host filesystem (it is gitignored) and should contain the kubeconfig for the cluster.

## Repository Structure

- `01-setup/` — Raspberry Pi OS installation. `rpi-install.sh` is the primary interactive script; `rpi-installation.md` is the step-by-step manual equivalent.
- `scripts/` — Devcontainer lifecycle scripts.
- `.kube/` — Kubeconfig (gitignored, host-mounted into the container at `~/.kube`).

## Raspberry Pi Setup Script

`01-setup/rpi-install.sh` is an interactive bash script that:
1. Flashes `2026-04-21-raspios-trixie-arm64-lite.img.xz` to a target disk (prompts for `/dev/sdX`).
2. Mounts the boot partition and enables SSH, sets up a user account, and enables USB max current.
3. Mounts the root partition, copies `wifi.nmconnection` (which uses `PI_SSID_NAME`/`PI_SSID_PASSWORD` as sed-replaced placeholders), and sets the hostname.

Run from within `01-setup/`:
```bash
cd 01-setup
bash rpi-install.sh
```

The `.img.xz` file is gitignored — it must be present locally before running the script.

## Kubernetes Interaction

Use `kubectl` directly. The kubeconfig is at `~/.kube/` (mounted from host). No wrapper scripts exist yet.
