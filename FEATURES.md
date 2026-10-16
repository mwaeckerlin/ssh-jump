# Features

Numbered register of every feature; a number is never reused. Every feature is covered by tests listed in [TESTS.md](TESTS.md); the guard `tests/docs-contract.sh` fails when a feature has no test.

- **F1 — Jump host on port 2222.** sshd listens on port 2222 and forwards a client's connection to a destination behind it (`ssh -J`, `ProxyJump`). The destination authenticates the client itself: git over SSH to Gitea through the jump host checks the user's own key at Gitea, and the jump host holds no key there.
- **F2 — Nothing runs on the jump host.** The jump host runs no command, opens no terminal and accepts no remote forwarding, agent forwarding, X11 or tunnel. The shell of the login user `somebody` is the start program, which refuses every command.
- **F3 — Login with a key only, as `somebody` only.** The keys in the secret `/run/secrets/authorized_keys` may log in as `somebody`, the run user of the mwaeckerlin images. A password, an unknown key and every other user name are refused. After repeated failed logins from one address, sshd refuses every connection from that address for a while, also with the right key (`PerSourcePenalties`, the default of OpenSSH).
- **F4 — Destinations.** `SSH_PERMIT_OPEN` lists the destinations a client may reach, `host:port` separated by spaces, `*` for any host or port; the default `any` leaves the boundary to the networks the container is attached to.
- **F5 — Configuration snippets.** Files `/etc/ssh/sshd_config.d/*.conf` are read after the configuration of the image; a snippet changes a setting inside a `Match` block, `Match all` for every connection.
- **F6 — Stable host key.** The host key comes from the secret `/run/secrets/ssh_host_ed25519_key` when it exists, also from a secret whose last line has no line break; otherwise the image creates one in the volume `/var/lib/ssh-jump` on the first start and keeps it across restarts.
- **F7 — Validated configuration.** `SSH_PERMIT_OPEN` is checked before the configuration is written; a malformed value, above all one with a line break that would add directives of its own, stops the container with `invalid SSH_PERMIT_OPEN`.
- **F8 — Health check in the image.** The image carries a `HEALTHCHECK`: `/usr/bin/init --healthcheck` connects to `127.0.0.1:2222` and reports healthy only when sshd sends its `SSH-2.0` identification.
- **F9 — Headless.** Only sshd, its session programs, `ssh-keygen`, their libraries and the start program are in the image: no shell, no ssh client, no `scp`, no sftp server, no package manager.
- **F10 — Fixed user.** sshd runs as the run user of the mwaeckerlin images, `somebody`, uid 100, so a deployment can hand the volume `/var/lib/ssh-jump` to that uid.
- **F11 — Published for amd64 and arm64.** Every push builds the image natively for both architectures and publishes it under one tag on Docker Hub, with the reusable workflow of `mwaeckerlin/scratch`.
