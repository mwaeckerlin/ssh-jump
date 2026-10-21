#!/usr/bin/env bash
# Config validation: init must refuse malformed environment values and
# every attempt to run it as a shell.
#
# SSH_PERMIT_OPEN, SSH_ADDRESS_FAMILY and SSH_CLIENT_ALIVE_INTERVAL are
# written into sshd_config. A value containing a newline
# would smuggle extra directives into the configuration (config injection,
# e.g. `PermitTTY yes`); a malformed destination would stop sshd with an
# unclear parser error. init therefore validates the value up front and
# exits with a clear `invalid <variable>` error before anything runs. The
# `config_*` checks start the container and read the sshd_config it wrote.
#
# The image is shell-free, so the checks run from outside: the
# `--healthcheck` entrypoint path performs the same validation first, fails
# fast (no server is running) and never touches the network — `--network
# none` pins that. `--pull=never` keeps docker from testing a stale registry
# image instead of the local build.
#
# Usage: tests/config-validation.sh IMAGE

set -uo pipefail

IMAGE="${1:-mwaeckerlin/ssh-jump}"

PASS=0
FAIL=0
declare -a FAILED_NAMES

_pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
_fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); echo "  FAIL  $1: $2"; }

_image_exists() {
    if docker image inspect "${IMAGE}" > /dev/null 2>&1; then
        return 0
    fi
    _fail "image_exists" "image not built — run 'npm run build' first"
    return 1
}

# A malformed value must abort with a message naming the variable.
_reject() {
    local name="$1" value="$2" variable="${3:-SSH_PERMIT_OPEN}"
    local out rc
    out=$(timeout 30 docker run --rm --pull=never --network none \
              -e "${variable}=${value}" "${IMAGE}" --healthcheck 2>&1)
    rc=$?
    if [[ ${rc} -ne 0 && "${out}" == *"invalid ${variable}"* ]]; then
        _pass "reject_${name}"
    else
        _fail "reject_${name}" "value not rejected (rc=${rc}): ${out}"
    fi
}

# The configuration sshd really reads: the container starts, init writes
# /run/ssh-jump/sshd_config, and the file must carry the expected line.
CONTAINERS=()
_cleanup() { [[ ${#CONTAINERS[@]} -eq 0 ]] || docker rm -fv "${CONTAINERS[@]}" > /dev/null 2>&1; }
trap _cleanup EXIT
_effective() {
    local name="$1" line="$2"
    shift 2
    local id conf=""
    id=$(docker run -d --pull=never --network none "$@" "${IMAGE}" 2>&1) || {
        _fail "config_${name}" "container did not start: ${id}"
        return
    }
    CONTAINERS+=("${id}")
    # init writes the file before it starts sshd; wait for it, at most 30s
    for _ in $(seq 1 60); do
        conf=$(docker cp "${id}:/run/ssh-jump/sshd_config" - 2>/dev/null | tar -xO 2>/dev/null)
        [[ -n "${conf}" ]] && break
        sleep 0.5
    done
    if grep -qx "${line}" <<< "${conf}"; then
        _pass "config_${name}"
    else
        _fail "config_${name}" "no line «${line}» in sshd_config: ${conf:-$(docker logs "${id}" 2>&1)}"
    fi
}

# A well-formed value must pass validation (the probe itself fails — no
# server is running — but no validation error may appear).
_accept() {
    local name="$1"
    shift
    local out
    out=$(timeout 30 docker run --rm --pull=never --network none \
              "$@" "${IMAGE}" --healthcheck 2>&1)
    if [[ "${out}" == *"invalid "* ]]; then
        _fail "accept_${name}" "valid value rejected: ${out}"
    else
        _pass "accept_${name}"
    fi
}

# sshd runs every session through the shell of the user, which is init, as
# `init -c <command>`; init must refuse and run nothing.
_refuse_shell() {
    local name="$1"
    shift
    local out rc
    out=$(timeout 30 docker run --rm --pull=never --network none "$@" 2>&1)
    rc=$?
    if [[ ${rc} -ne 0 && "${out}" == *"forwards connections only"* ]]; then
        _pass "shell_${name}_refused"
    else
        _fail "shell_${name}_refused" "rc=${rc}: ${out}"
    fi
}

echo "==> Config validation: malformed environment must be refused"

_image_exists || { echo ""; echo "==> Config validation results: 0 passed, 1 failed"; exit 1; }

_reject permit_open_injection  $'gitea:2222\nPermitTTY yes'
_reject permit_open_no_port    "gitea"
_reject permit_open_bad_port   "gitea:ssh"
_reject permit_open_port_range "gitea:70000"
_reject permit_open_bad_host   "gitea;rm:22"
_reject permit_open_space      "gitea:22  other:22"
_reject address_family_injection        $'inet\nPermitTTY yes'      SSH_ADDRESS_FAMILY
_reject address_family_unknown          "ipv4"                      SSH_ADDRESS_FAMILY
_reject client_alive_interval_injection $'60\nPermitTTY yes'        SSH_CLIENT_ALIVE_INTERVAL
_reject client_alive_interval_not_number "1m"                       SSH_CLIENT_ALIVE_INTERVAL
_reject client_alive_interval_negative  "-1"                        SSH_CLIENT_ALIVE_INTERVAL

_accept defaults
_accept permit_open_list -e SSH_PERMIT_OPEN='gitea:2222 tasks.gitea_gitea:2222 [fd00::1]:22 10.0.0.1:* *:443'
_accept permit_open_none -e SSH_PERMIT_OPEN=none
_accept address_family_any -e SSH_ADDRESS_FAMILY=any
_accept client_alive_interval_off -e SSH_CLIENT_ALIVE_INTERVAL=0

_effective address_family_default        "AddressFamily inet"
_effective address_family_override       "AddressFamily inet6"       -e SSH_ADDRESS_FAMILY=inet6
_effective client_alive_interval_default "ClientAliveInterval 60"
_effective client_alive_interval_override "ClientAliveInterval 300"  -e SSH_CLIENT_ALIVE_INTERVAL=300

_refuse_shell command "${IMAGE}" -c id

echo ""
echo "==> Config validation results: ${PASS} passed, ${FAIL} failed"
if [[ ${FAIL} -gt 0 ]]; then
    echo "==> Failed checks: ${FAILED_NAMES[*]}"
    exit 1
fi
