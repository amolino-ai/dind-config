#!/bin/sh
set -e

DEST=/usr/local/share/docker-init.sh
BACKUP=/usr/local/share/docker-init.original.sh

if [ -f "${DEST}" ] && [ ! -f "${BACKUP}" ]; then
  mv "${DEST}" "${BACKUP}"
fi

if [ ! -f "${BACKUP}" ]; then
  echo "Backup entrypoint ${BACKUP} missing; Docker-in-Docker feature may not have installed correctly" >&2
  exit 1
fi

cat <<'EOF' > "${DEST}"
#!/bin/bash
set -euo pipefail

ORIGINAL_ENTRYPOINT="/usr/local/share/docker-init.original.sh"

if [ ! -x "${ORIGINAL_ENTRYPOINT}" ]; then
  echo "Expected Docker entrypoint backup ${ORIGINAL_ENTRYPOINT} not found or not executable" >&2
  exit 1
fi

sudo_if() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

PARENT="${DIND_CGROUP_PARENT:-/dind.slice}"
PARENT="${PARENT%/}"
if [ -z "${PARENT}" ]; then
  PARENT="/dind.slice"
fi
CPU_PERIOD="${DIND_CPU_PERIOD:-100000}"
CPU_QUOTA="${DIND_CPU_QUOTA:-}"
MEMORY_MAX="${DIND_MEMORY_MAX:-}"
SWAP_MAX="${DIND_SWAP_MAX:-}"

sudo_if python3 - "${PARENT}" <<'PY'
import json
import os
import sys

parent = sys.argv[1].rstrip("/\n") or "/dind.slice"
path = "/etc/docker/daemon.json"

config = {}
if os.path.exists(path):
  try:
    with open(path, "r", encoding="utf-8") as handle:
      config = json.load(handle)
  except Exception:
    config = {}

config["default-cgroup-parent"] = parent
config.setdefault("default-cgroupns-mode", "host")

with open(path, "w", encoding="utf-8") as handle:
  json.dump(config, handle, indent=2)
  handle.write("\n")
PY

if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
  for controller in cpu memory pids; do
    sudo_if sh -c "echo +${controller} > /sys/fs/cgroup/cgroup.subtree_control" || true
  done

  sanitized_parent="${PARENT#/}"
  if [ -z "${sanitized_parent}" ]; then
    sanitized_parent="dind.slice"
  fi
  cgroup_path="/sys/fs/cgroup/${sanitized_parent}"

  sudo_if mkdir -p "${cgroup_path}"

  if [ -n "${CPU_QUOTA}" ]; then
    if [ "${CPU_QUOTA}" = "max" ]; then
      sudo_if sh -c "echo max > '${cgroup_path}/cpu.max'" || true
    else
      sudo_if sh -c "echo '${CPU_QUOTA} ${CPU_PERIOD}' > '${cgroup_path}/cpu.max'" || true
    fi
  fi

  if [ -n "${MEMORY_MAX}" ]; then
    sudo_if sh -c "echo '${MEMORY_MAX}' > '${cgroup_path}/memory.max'" || true
  fi

  if [ -n "${SWAP_MAX}" ]; then
    sudo_if sh -c "echo '${SWAP_MAX}' > '${cgroup_path}/memory.swap.max'" || true
  fi
fi

exec "${ORIGINAL_ENTRYPOINT}" "$@"
EOF

chmod +x "${DEST}"
