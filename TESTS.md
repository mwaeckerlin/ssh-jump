# Tests

Register of all tests, sorted by the [FEATURES.md](FEATURES.md) number each test covers. `npm test` runs everything; the guard `tests/docs-contract.sh` fails when a feature has no test entry here.

## E2E (`tests/run.sh` against `tests/docker-compose.yml`)

The stack runs a real Gitea on the network `inner` and the client on the network `outer`; the jump hosts sit on both.

- **F1** git_ls_remote_through_jump, git_clone_and_push_through_jump, gitea_unreachable_without_jump — `git ls-remote`, `git clone` and `git push` reach Gitea through the jump host with the user's own key; without the jump host the client does not reach Gitea.
- **F2** command_refused, terminal_refused, remote_forwarding_refused — a command, a terminal and a remote forwarding are refused.
- **F3** password_refused, unknown_key_refused, user_root_refused, user_git_refused, user_tester_refused — the server offers only `publickey`, refuses a key outside `authorized_keys` and every user other than `jump`; these run against `jump-refusals`, whose snippet switches `PerSourcePenalties` off, so that each refusal is measured on its own.
- **F3** repeated_failures_block_source — after five failed logins the client is refused also with the right key.
- **F4** restricted_allows_gitea_ssh, restricted_refuses_other_destination, default_allows_any_destination — with `SSH_PERMIT_OPEN=gitea:2222` git works and `gitea:3000` is refused as «administratively prohibited»; with the default, an HTTP request to `gitea:3000` through the jump host gets Gitea's answer.
- **F5** snippet_allows_gitea_ssh, snippet_refuses_other_destination — a snippet with `Match all` and `PermitOpen gitea:2222` limits the destinations the same way.
- **F6** host_key_kept_across_restart, host_key_from_secret — the generated host key stays the same across a restart; with the secret the server shows exactly that key; the test hands the secret over without a final line break (regression: sshd refused such a key with «error in libcrypto»).
- **F8** image_healthcheck_healthy, healthcheck_fails_without_server — the container turns healthy from the image's `HEALTHCHECK`; the check fails where no sshd answers.
- **F10** jump_user_uid_102 — `/etc/passwd` of the image gives the user `jump` uid 102.
- **F3** no_bind_mounts — the secrets and the snippet reach the containers without a host bind mount.

## Config validation (`tests/config-validation.sh`)

- **F7** reject_permit_open_injection, reject_permit_open_no_port, reject_permit_open_bad_port, reject_permit_open_port_range, reject_permit_open_bad_host, reject_permit_open_space — every malformed value stops the container with `invalid SSH_PERMIT_OPEN`.
- **F7** accept_defaults, accept_permit_open_list, accept_permit_open_none — the default, a list of host, IPv4, IPv6 and wildcard destinations, and `none` pass.
- **F2** shell_command_refused — started as `init -c id`, the way sshd starts a session, the start program refuses and runs nothing.

## Image contract

- **F9** `tests/image-contract.sh` › no sh, no bash, no busybox, no perl, no ssh, no scp, no sftp_server — the image is headless.

## Workflow contract

- **F11** `tests/workflow-contract.sh` of `mwaeckerlin/scratch` — the reusable workflow selects exactly the images a repository publishes; this repository calls it from `.github/workflows/docker.yml`.
