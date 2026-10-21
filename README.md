# SSH Jump Host

Headless, shell-free SSH jump host built on `mwaeckerlin/scratch`. sshd forwards a client's connection to a destination behind it and runs nothing else: **no shell, no ssh client, no `scp`, no sftp server, no busybox, no package manager.** A client that logs in can open a connection to an allowed destination and nothing more: no command, no terminal, no remote forwarding, no agent forwarding, no X11, no tunnel.

The destination checks the client's own credentials. For git over SSH to Gitea behind the jump host, Gitea checks the user's key; the jump host holds no key at Gitea.

## Usage

The client reaches the destination with `ProxyJump`, here for a Gitea whose SSH server listens on `gitea:2222` behind the jump host `jump.example.com`, in `~/.ssh/config`:

```ssh-config
Host gitea
    HostName gitea
    Port 2222
    User git
    ProxyJump somebody@jump.example.com:2222
```

Then:

```bash
git clone gitea:owner/repository.git
```

Without a configuration file, `ssh -J somebody@jump.example.com:2222 -p 2222 git@gitea` does the same.

## Configuration

| Path or variable | Default | Description |
|---|---|---|
| port `2222` | | sshd listens on 2222 inside the container, because it does not run as root; a port mapping publishes it on another port. |
| user `somebody`, uid 100 | | The only user that may log in: the run user of the mwaeckerlin images. A volume for `/var/lib/ssh-jump` belongs to uid 100. |
| `/run/secrets/authorized_keys` | | The public keys that may log in as `somebody`, one per line, as a Docker secret. A password is never accepted. |
| `/run/secrets/ssh_host_ed25519_key` | | The host key, as a Docker secret, readable for uid 100. The image copies it to `/run/ssh-jump` and adds a missing final line break, which sshd needs. Without it, the image creates a key in `/var/lib/ssh-jump` on the first start. |
| `SSH_PERMIT_OPEN` | `any` | The destinations a client may reach: `host:port`, `[ipv6]:port`, `*` for any host or any port, separated by single spaces, or `none`. With `any`, the networks the container is attached to are the boundary. |
| `SSH_ADDRESS_FAMILY` | `inet` | The addresses sshd listens on: `inet` for IPv4, `inet6` for IPv6, `any` for both. With `inet6` the health check connects to `[::1]:2222`. |
| `SSH_CLIENT_ALIVE_INTERVAL` | `60` | Seconds without data from a client after which sshd asks the client whether it is still there; after three unanswered requests sshd closes the connection. `0` switches the check off. |
| `/etc/ssh/sshd_config.d/*.conf` | | Snippets read after the configuration of the image. sshd takes the first value of a directive, so a snippet changes a setting inside a `Match` block; `Match all` applies to every connection. |

The variables are checked before sshd starts. In `SSH_PERMIT_OPEN`, a line break, a destination without a port or a port outside 1 to 65535 stops the container with `invalid SSH_PERMIT_OPEN`; a value of `SSH_ADDRESS_FAMILY` other than `any`, `inet` or `inet6` stops it with `invalid SSH_ADDRESS_FAMILY`, and a value of `SSH_CLIENT_ALIVE_INTERVAL` that is not a number of seconds with at most nine digits with `invalid SSH_CLIENT_ALIVE_INTERVAL`.

A snippet that allows only Gitea, for every connection:

```ssh-config
Match all
    PermitOpen gitea:2222
```

The snippets are read by the user `somebody`, so a file `0644` owned by root is enough.

## Volumes to persist

- `/var/lib/ssh-jump` — the host key the image creates when no secret provides one. **Persist this volume**: without it every new container shows a new host key and every client refuses it as a changed host. Several replicas on several hosts share one key through the secret or through a shared volume.

## Health check

The image carries a `HEALTHCHECK` (every 60s, timeout 5s, three retries): `/usr/bin/init --healthcheck` connects to `127.0.0.1:2222`, with `SSH_ADDRESS_FAMILY=inet6` to `[::1]:2222`, and reports healthy only when sshd sends its `SSH-2.0` identification. sshd logs every check as a closed connection from `127.0.0.1`.

## Docker Swarm

```yaml
services:
  ssh-jump:
    image: mwaeckerlin/ssh-jump
    ports:
      - target: 2222
        published: 2222
        mode: host
    environment:
      SSH_PERMIT_OPEN: "tasks.gitea_gitea:2222"
    secrets:
      - source: jump_host_authorized_keys
        target: authorized_keys
    volumes:
      - hostkeys:/var/lib/ssh-jump
    networks: [gitea]

secrets:
  jump_host_authorized_keys:
    external: true

volumes:
  hostkeys:
```

## Testing

```bash
npm test
```

runs four suites and fails on any single error:

1. **Docs contract** (`tests/docs-contract.sh`) — every feature of [FEATURES.md](FEATURES.md) has a test in [TESTS.md](TESTS.md), and every variable the start program reads stands in the table under «Configuration» and in the `ENV` of the Dockerfile with the same default.
2. **Image contract** (`tests/image-contract.sh`) — the image must be headless: no `/bin/sh`, no bash, no busybox, no perl, no `ssh`, no `scp`, no sftp server.
3. **Config validation** (`tests/config-validation.sh`) — every malformed `SSH_PERMIT_OPEN`, `SSH_ADDRESS_FAMILY` and `SSH_CLIENT_ALIVE_INTERVAL` is refused, every valid one accepted, the `sshd_config` the container writes carries the default and an override of `SSH_ADDRESS_FAMILY` and `SSH_CLIENT_ALIVE_INTERVAL`, and the start program refuses to run a command.
4. **Functional e2e** (`tests/run.sh`, via `tests/docker-compose.yml`) — a real Gitea sits on a network the client cannot reach. The suite runs `git ls-remote`, `git clone` and `git push` through the jump host, and checks that the client does not reach Gitea without it. It checks that a command, a terminal, a remote forwarding, a password, an unknown key and other users are refused, that repeated failed logins block the client's address, that `SSH_PERMIT_OPEN` and a snippet limit the destinations, that the host key stays the same across a restart and comes from the secret, the image's health check, the user `somebody` with uid 100, and that no container has a host bind mount. The client is a small Alpine image with git and the ssh client, built from `tests/client/Dockerfile`.

To start the image on its own, with your key:

```bash
AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" npm start
```

## Image layout

The image is built in the same stages as `mwaeckerlin/redis`:

1. **`init`** — compiles `init.cpp` statically with `g++ -static -Os -flto`. The resulting binary checks the environment, makes sure a host key exists, writes `/run/ssh-jump/sshd_config` and `execv`s sshd. As the shell of `somebody` it refuses every command.
2. **`build`** — installs `openssh-server` and `openssh-keygen` on the Alpine base, sets the shell of `somebody` to the init, then uses `tar cph … + ldd` to collect only sshd, its session programs, `ssh-keygen` and their `.so` dependencies into `/root/`.
3. **runtime** — `FROM mwaeckerlin/scratch`, `COPY --from=build /root/ /`. `ENTRYPOINT ["/usr/bin/init"]`.
