# Changelog

- 2026-10-15 **1.0.2**
    - The jump host logs in as `somebody`, uid 100, the run user of every mwaeckerlin image, in place of a user `jump` of its own (uid 102): clients write `somebody@` in `ProxyJump`, and a volume for `/var/lib/ssh-jump` belongs to uid 100

- 2026-10-15 **1.0.1**
    - Test suite: the check that repeated failed logins block an address reads the log of sshd, so it gives the same result on every machine; the GitHub runners failed it on the message of the client

- 2026-10-15 **1.0.0**
    - Initial release: headless SSH jump host
        - forwards a client's connection to a destination behind it (`ssh -J`, `ProxyJump`); the destination checks the client's own key, so git over SSH reaches Gitea with the user's key
        - runs nothing: no command, no terminal, no remote forwarding, no agent forwarding, no X11, no tunnel
        - login only as `jump` and only with a key from the secret `authorized_keys`
        - `SSH_PERMIT_OPEN` limits the destinations; snippets in `/etc/ssh/sshd_config.d` change settings in `Match` blocks
        - host key from a secret, or created once in a volume and kept across restarts
        - health check in the image
        - no shell, no ssh client, no package manager; published for amd64 and arm64
    - Test suite (`npm test`)
        - image contract: the shipped image must be headless and carry no ssh client
        - config validation: malformed destinations are refused
        - functional end-to-end against a real Gitea: git through the jump host, every refused access, destination limits, host key, health check
