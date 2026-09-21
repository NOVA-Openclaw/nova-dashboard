#!/usr/bin/env bash
# =============================================================================
# Node.js runtime resolver for Nova Dashboard scripts
# =============================================================================
#
# Provides helpers that locate a Node.js runtime satisfying OpenClaw's engine
# requirements. This prevents PATH-ordering bugs where linuxbrew's unsupported
# node shadows the system node and causes `openclaw health` to exit silently.
#
# OpenClaw requires one of:
#   >=22.22.3 <23, >=24.15.0 <25, or >=25.9.0
#
# Usage:
#   source "$(dirname "$0")/lib/node-resolve.sh"
#   node_bin=$(resolve_supported_node) || { echo "no supported node"; exit 1; }
# =============================================================================

# shellcheck shell=bash

_version_ge() {
    # Returns 0 if $1 >= $2 (semantic version comparison)
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

node_version_supported() {
    local version="${1#v}"  # strip leading 'v' if present
    local major
    major=$(echo "$version" | cut -d. -f1)

    # >=22.22.3 <23
    if [ "$major" -eq 22 ]; then
        _version_ge "$version" "22.22.3" && return 0
        return 1
    fi
    # >=24.15.0 <25
    if [ "$major" -eq 24 ]; then
        _version_ge "$version" "24.15.0" && return 0
        return 1
    fi
    # >=25.9.0
    if [ "$major" -eq 25 ]; then
        _version_ge "$version" "25.9.0" && return 0
        return 1
    fi
    # Anything newer than 25 is assumed supported
    [ "$major" -gt 25 ]
}

# resolve_supported_node prints the path to a Node.js binary whose version is
# supported by OpenClaw. It checks PATH first, then scans common install paths.
# Returns 1 if no supported node is found.
#
# Operator override: set NODE_BIN to force a specific node interpreter.
resolve_supported_node() {
    local node_bin candidates v

    # Explicit operator override for unusual installs or testing.
    if [ -n "${NODE_BIN:-}" ]; then
        if [ -x "$NODE_BIN" ]; then
            v=$("$NODE_BIN" --version 2>/dev/null | sed 's/^v//')
            if node_version_supported "$v"; then
                echo "$NODE_BIN"
                return 0
            fi
        fi
        return 1
    fi

    # Try the node currently on PATH first.
    node_bin=$(command -v node 2>/dev/null || true)
    if [ -n "$node_bin" ] && [ -x "$node_bin" ]; then
        v=$("$node_bin" --version 2>/dev/null | sed 's/^v//')
        if node_version_supported "$v"; then
            echo "$node_bin"
            return 0
        fi
    fi

    # Fallback: scan well-known install locations for a supported node.
    candidates=(
        "/usr/bin/node"
        "/usr/local/bin/node"
        "/opt/node/bin/node"
    )

    # nvm installs, if present (newest first)
    if [ -d "$HOME/.nvm/versions/node" ]; then
        while IFS= read -r d; do
            candidates+=("$d/bin/node")
        done < <(find "$HOME/.nvm/versions/node" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V -r)
    fi

    for c in "${candidates[@]}"; do
        [ -x "$c" ] || continue
        v=$("$c" --version 2>/dev/null | sed 's/^v//')
        if node_version_supported "$v"; then
            echo "$c"
            return 0
        fi
    done

    return 1
}

# resolve_openclaw_bin prints the path to the openclaw CLI binary.
# Returns 1 if openclaw cannot be found.
#
# Operator override: set OPENCLAW_BIN to force a specific openclaw executable.
resolve_openclaw_bin() {
    if [ -n "${OPENCLAW_BIN:-}" ]; then
        if [ -x "$OPENCLAW_BIN" ]; then
            echo "$OPENCLAW_BIN"
            return 0
        fi
        return 1
    fi

    local openclaw_bin
    openclaw_bin=$(command -v openclaw 2>/dev/null || true)
    if [ -n "$openclaw_bin" ] && [ -x "$openclaw_bin" ]; then
        echo "$openclaw_bin"
        return 0
    fi
    for c in "/home/$(whoami)/.npm-global/bin/openclaw" "$HOME/.npm-global/bin/openclaw"; do
        if [ -x "$c" ]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}
