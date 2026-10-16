#!/usr/bin/env bash
# Functional e2e tests for mwaeckerlin/ssh-jump against a real Gitea.
# Usage: bash tests/run.sh
set -euo pipefail

cd "$(dirname "$0")/.."
COMPOSE="tests/docker-compose.yml"
IMAGE="mwaeckerlin/ssh-jump"
# the login of the jump host: the run user of the image family
LOGIN="somebody"

# compose reads both on every call; the real values follow once the client
# has generated the keys
export JUMP_AUTHORIZED_KEYS="pending"
export JUMP_HOST_KEY="pending"

cleanup() {
    docker compose -f "$COMPOSE" down -v --remove-orphans > /dev/null 2>&1 || true
}
trap cleanup EXIT

PASS=0
FAIL=0
_pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
_fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $1: $2"; }

_client() { docker compose -f "$COMPOSE" exec -T client "$@"; }
# output and exit status of a command in the client, for the checks below
_try() { OUT="$(timeout 60 docker compose -f "$COMPOSE" exec -T client "$@" 2>&1 < /dev/null)" && RC=0 || RC=$?; }
_health() { docker inspect --format '{{.State.Health.Status}}' "$(docker compose -f "$COMPOSE" ps -q "$1")" 2>/dev/null || true; }
# ssh-keyscan adds a comment line «# host:port SSH-2.0-…» to the key line
_keyscan() { _client ssh-keyscan -p 2222 -t ed25519 "$1" 2>/dev/null | awk '!/^#/ { print $3 }'; }

GITEA_USER="tester"
GITEA_PASSWORD="e2e-test-password-12"
_gitea_api() {
    docker compose -f "$COMPOSE" exec -T gitea curl -fsS -u "${GITEA_USER}:${GITEA_PASSWORD}" \
        -H "Content-Type: application/json" -d "$2" "http://localhost:3000/api/v1/$1" > /dev/null
}

echo "==> Starting Gitea and the client..."
docker compose -f "$COMPOSE" build client
docker compose -f "$COMPOSE" up -d --wait gitea client

# keys of the client: one that the jump hosts accept, one they do not know,
# and a host key for jump-hostkey
_client ssh-keygen -q -t ed25519 -N "" -C tester -f /home/tester/.ssh/id_ed25519
_client ssh-keygen -q -t ed25519 -N "" -C stranger -f /home/tester/.ssh/stranger
_client ssh-keygen -q -t ed25519 -N "" -C hostkey -f /home/tester/hostkey
JUMP_AUTHORIZED_KEYS="$(_client cat /home/tester/.ssh/id_ed25519.pub)"
# $(…) drops the final line break, which sshd needs: the image adds it, and
# host_key_from_secret proves that (regression: «error in libcrypto»)
JUMP_HOST_KEY="$(_client cat /home/tester/hostkey)"
HOST_PUBKEY="$(_client cat /home/tester/hostkey.pub | awk '{ print $2 }')"
export JUMP_AUTHORIZED_KEYS JUMP_HOST_KEY

_client sh -c 'cat > /home/tester/.ssh/config' <<EOF
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
    BatchMode yes
    IdentitiesOnly yes
    IdentityFile /home/tester/.ssh/id_ed25519
    ConnectTimeout 20
Host gitea
    User git
    Port 2222
    ProxyJump ${LOGIN}@jump:2222
Host gitea-restricted
    HostName gitea
    User git
    Port 2222
    ProxyJump ${LOGIN}@jump-restricted:2222
Host gitea-snippet
    HostName gitea
    User git
    Port 2222
    ProxyJump ${LOGIN}@jump-snippet:2222
EOF
_client chmod 600 /home/tester/.ssh/config

# a Gitea user with the client's key and a repository with one commit
docker compose -f "$COMPOSE" exec -T gitea gitea admin user create --username "$GITEA_USER" \
    --password "$GITEA_PASSWORD" --email tester@example.com --must-change-password=false > /dev/null
_gitea_api user/keys "{\"title\":\"e2e\",\"key\":\"${JUMP_AUTHORIZED_KEYS}\"}"
_gitea_api user/repos '{"name":"probe","auto_init":true,"default_branch":"main"}'

echo "==> Starting the jump hosts..."
JUMPS=(jump jump-restricted jump-snippet jump-hostkey jump-refusals)
if ! docker compose -f "$COMPOSE" up -d --wait "${JUMPS[@]}"; then
    docker compose -f "$COMPOSE" logs --no-color "${JUMPS[@]}"
    exit 1
fi

# 1. git reads and writes through the jump host
_try git ls-remote gitea:tester/probe.git
if [[ $RC -eq 0 && "$OUT" == *"refs/heads/main"* ]]; then
    _pass "git_ls_remote_through_jump"
else
    _fail "git_ls_remote_through_jump" "rc=${RC}: ${OUT}"
fi
_try sh -c 'git clone -q gitea:tester/probe.git probe && cd probe \
    && git -c user.name=tester -c user.email=tester@example.com commit -q --allow-empty -m e2e \
    && git push -q origin main && git ls-remote origin main'
if [[ $RC -eq 0 && "$OUT" == *"refs/heads/main"* ]]; then
    _pass "git_clone_and_push_through_jump"
else
    _fail "git_clone_and_push_through_jump" "rc=${RC}: ${OUT}"
fi

# ...and without the jump host Gitea is out of reach of the client
_try git -c core.sshCommand="ssh -o ProxyJump=none" ls-remote gitea:tester/probe.git
if [[ $RC -ne 0 ]]; then
    _pass "gitea_unreachable_without_jump"
else
    _fail "gitea_unreachable_without_jump" "the client reached Gitea directly: ${OUT}"
fi

# 2. nothing runs on the jump host: no command, no terminal, no remote forwarding
_try ssh -p 2222 "${LOGIN}@jump" id
if [[ $RC -ne 0 && "$OUT" != *"uid="* ]]; then
    _pass "command_refused"
else
    _fail "command_refused" "rc=${RC}: ${OUT}"
fi
_try ssh -tt -p 2222 "${LOGIN}@jump"
if [[ $RC -ne 0 ]]; then
    _pass "terminal_refused"
else
    _fail "terminal_refused" "a terminal session ended with rc=0: ${OUT}"
fi
_try ssh -N -o ExitOnForwardFailure=yes -R 9000:localhost:22 -p 2222 "${LOGIN}@jump"
if [[ $RC -ne 0 && "$OUT" == *"forwarding failed"* ]]; then
    _pass "remote_forwarding_refused"
else
    _fail "remote_forwarding_refused" "rc=${RC}: ${OUT}"
fi

# 3. only the run user, only with a key from authorized_keys
_try ssh -o PubkeyAuthentication=no -p 2222 "${LOGIN}@jump-refusals" -W gitea:2222
if [[ $RC -ne 0 && "$OUT" == *"Permission denied (publickey)"* ]]; then
    _pass "password_refused"
else
    _fail "password_refused" "rc=${RC}: ${OUT}"
fi
# -F /dev/null: the config would add the accepted key beside the unknown one
_stranger() {
    _try ssh -F /dev/null -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
        -o IdentitiesOnly=yes -i /home/tester/.ssh/stranger -p 2222 "${LOGIN}@$1" -W gitea:2222
}
_stranger jump-refusals
if [[ $RC -ne 0 && "$OUT" == *"Permission denied"* ]]; then
    _pass "unknown_key_refused"
else
    _fail "unknown_key_refused" "rc=${RC}: ${OUT}"
fi
for user in root git tester jump; do
    _try ssh -p 2222 "${user}@jump-refusals" -W gitea:2222
    if [[ $RC -ne 0 && "$OUT" == *"Permission denied"* ]]; then
        _pass "user_${user}_refused"
    else
        _fail "user_${user}_refused" "rc=${RC}: ${OUT}"
    fi
done

# 4. SSH_PERMIT_OPEN and a snippet limit the destinations
for host in restricted snippet; do
    _try git ls-remote "gitea-${host}:tester/probe.git"
    if [[ $RC -eq 0 && "$OUT" == *"refs/heads/main"* ]]; then
        _pass "${host}_allows_gitea_ssh"
    else
        _fail "${host}_allows_gitea_ssh" "rc=${RC}: ${OUT}"
    fi
    # LogLevel INFO: ssh names the reason of a refused channel only from INFO on
    _try ssh -o LogLevel=INFO -p 2222 "${LOGIN}@jump-${host}" -W gitea:3000
    if [[ $RC -ne 0 && "$OUT" == *"administratively prohibited"* ]]; then
        _pass "${host}_refuses_other_destination"
    else
        _fail "${host}_refuses_other_destination" "rc=${RC}: ${OUT}"
    fi
done
# the default forwards to any destination: Gitea's web port answers HTTP
_try sh -c "printf 'GET /api/healthz HTTP/1.0\r\nHost: gitea\r\n\r\n' | ssh -p 2222 ${LOGIN}@jump -W gitea:3000"
if [[ "$OUT" == "HTTP/1."* ]]; then
    _pass "default_allows_any_destination"
else
    _fail "default_allows_any_destination" "rc=${RC}: ${OUT}"
fi

# 5. host key: generated once and kept in the volume, or taken from the secret
BEFORE="$(_keyscan jump)"
docker compose -f "$COMPOSE" restart jump > /dev/null 2>&1
docker compose -f "$COMPOSE" up -d --wait jump > /dev/null 2>&1
AFTER="$(_keyscan jump)"
if [[ -n "$BEFORE" && "$BEFORE" == "$AFTER" ]]; then
    _pass "host_key_kept_across_restart"
else
    _fail "host_key_kept_across_restart" "before «${BEFORE}», after «${AFTER}»"
fi
SCANNED="$(_keyscan jump-hostkey)"
if [[ -n "$SCANNED" && "$SCANNED" == "$HOST_PUBKEY" ]]; then
    _pass "host_key_from_secret"
else
    _fail "host_key_from_secret" "server shows «${SCANNED}», secret holds «${HOST_PUBKEY}»"
fi

# ...and repeated failed logins from one address make sshd refuse that address
# for a while, even with the right key (sshd's PerSourcePenalties)
# measured at the server: what the client prints for the refused connection
# differs between machines (locally «Connection reset by peer», on the GitHub
# runners nothing at all), so the check reads sshd's log
_jump_log() { docker compose -f "$COMPOSE" logs --no-color jump 2>&1; }
_count() { grep -c "$1" <<< "$(_jump_log)" || true; }
for _ in 1 2 3 4 5; do _stranger jump; done
ACCEPTED_BEFORE="$(_count "Accepted publickey for ${LOGIN}")"
_try ssh -p 2222 "${LOGIN}@jump" -W gitea:2222
ACCEPTED_AFTER="$(_count "Accepted publickey for ${LOGIN}")"
PENALTIES="$(_count "penalty")"
if [[ $RC -ne 0 && "$ACCEPTED_AFTER" == "$ACCEPTED_BEFORE" && "$PENALTIES" -gt 0 ]]; then
    _pass "repeated_failures_block_source"
else
    _fail "repeated_failures_block_source" "rc=${RC}, accepted logins ${ACCEPTED_BEFORE} → ${ACCEPTED_AFTER}, penalty lines ${PENALTIES}: ${OUT}
$(grep -i "penalt\|drop\|Accepted\|Failed\|Connection" <<< "$(_jump_log)" | tail -20)"
fi

# 6. the image checks its own health: healthy from the image's HEALTHCHECK,
# and the check fails where no sshd answers
STATE="$(_health jump)"
if [[ "$STATE" == "healthy" ]]; then
    _pass "image_healthcheck_healthy"
else
    _fail "image_healthcheck_healthy" "health state «${STATE}»"
fi
if timeout 30 docker run --rm --pull=never --network none "$IMAGE" --healthcheck > /dev/null 2>&1; then
    _fail "healthcheck_fails_without_server" "the check passed with no sshd running"
else
    _pass "healthcheck_fails_without_server"
fi

# 7. the user the server runs as: deployments give the volume to this uid
PASSWD="$(docker compose -f "$COMPOSE" cp jump:/etc/passwd - | tar -xO)"
# the login is the family's run user somebody, uid 100, and its shell is the
# init that refuses every command; no user jump of its own
LOGIN_ENTRY="$(awk -F: -v user="$LOGIN" '$1 == user { print $3 ":" $7 }' <<< "$PASSWD")"
JUMP_ENTRY="$(awk -F: '$1 == "jump"' <<< "$PASSWD")"
if [[ "$LOGIN_ENTRY" == "100:/usr/bin/init" && -z "$JUMP_ENTRY" ]]; then
    _pass "run_user_somebody_uid_100"
else
    _fail "run_user_somebody_uid_100" "${LOGIN} has «${LOGIN_ENTRY}», jump has «${JUMP_ENTRY}»"
fi

# 8. the secrets and the snippet reach the containers without a host bind mount
MOUNTS=""
for service in "${JUMPS[@]}"; do
    MOUNTS+="$(docker inspect --format '{{range .Mounts}}{{.Type}}:{{.Destination}} {{end}}' \
        "$(docker compose -f "$COMPOSE" ps -q "$service")")"
done
if [[ "$MOUNTS" != *"bind:"* ]]; then
    _pass "no_bind_mounts"
else
    _fail "no_bind_mounts" "${MOUNTS}"
fi

echo ""
echo "==> Functional results: ${PASS} passed, ${FAIL} failed"
[[ ${FAIL} -eq 0 ]] || exit 1
