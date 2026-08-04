# Ansible-Actions-Runner

An Ansible role for installing GitHub Actions self-hosted runners, several per
machine, on Linux, macOS and Windows.

It is built around three ideas that current existing roles do not cover:

**A machine's runners are described as a list in `host_vars`.** You do not
invoke the role once per runner. One entry per runner, one run of the role, any
mix of repositories on the same box.

**An existing runner is never touched.** If a runner's directory is present the
role skips it entirely: no restart, no re-registration, no version check,
nothing. A bad playbook run cannot disturb a runner that is in the middle of a
job. Reinstalling means deleting the directory by hand first.

**macOS gets a real LaunchDaemon.** `svc.sh install` writes a LaunchAgent into
`~/Library/LaunchAgents`, which only starts once the runner user logs into the
GUI. This role writes the daemon to `/Library/LaunchDaemons` instead, so
runners come up at boot over plain SSH with nobody logged in. See
[actions/runner#1056](https://github.com/actions/runner/issues/1056).

You do not have to look up the runner version or paste registration tokens.
The role resolves the latest release from the GitHub API and mints a
short-lived registration token per runner, both from the control node.

## Requirements

- Ansible 2.14 or newer on the control node.
- `ansible.windows` (`ansible-galaxy collection install -r requirements.yml`),
  only if you target Windows.
- A GitHub token on the **control node**, with `repo` scope on a classic PAT or
  *Administration: read & write* on a fine-grained PAT.

The token is used only on the control node, via `delegate_to: localhost`. It is
never written to a target machine. What reaches the target is the hour-long
registration token GitHub mints from it.

```bash
export GITHUB_TOKEN=ghp_...
```

or set `gha_github_token` from a vault.

## Describing a machine's runners

Everything lives in `host_vars/<hostname>.yml`:

```yaml
gha_runners:
  - repo: boostorg/boost

  - repo: boostorg/boost
    labels:
      - big-memory

  - repo: boostorg/release-tools
    suffix: nightly
    install_as_service: false
```

On a Linux host called `build-linux-1` that produces:

| Directory | Registered with GitHub as | Repository |
| --- | --- | --- |
| `/home/gha/runners/boostorg_boost_1` | `build-linux-1_1` | `boostorg/boost` |
| `/home/gha/runners/boostorg_boost_2` | `build-linux-1_2` | `boostorg/boost` |
| `/home/gha/runners/boostorg_release-tools_nightly` | `build-linux-1_nightly` | `boostorg/release-tools` |

### Directory names

`<owner>_<repo>_<suffix>`, under `$HOME/runners` of the `gha` user. The suffix
is always present and always preceded by an underscore, so the first runner for
a repository is `boostorg_boost_1` rather than a bare `boostorg_boost`.

When you do not give a suffix, it is the 1-based position of that entry among
the entries for the *same repository*. Counting is per repository, so adding a
runner for a different repo never renumbers an existing one.

Reordering or deleting entries for a repository that uses auto-numbering will
shift the numbers of the entries after it. Nothing breaks — the old directories
still exist, so they are still skipped — but Ansible's idea of which entry maps
to which directory will have moved. Give those runners an explicit `suffix` if
you expect the list to churn.

### Runner names

A directory name only has to be unique on one machine, but the name registered
with GitHub has to be unique across every machine attached to a repository.
Two hosts both registering `boostorg_boost_1` would collide. So the registered
name defaults to `<hostname>_<suffix>` — the repository is already implied by
where the runner is listed. Override it per entry with `name:` if you want
something else.

### Keys in a runner entry

| Key | Default | Meaning |
| --- | --- | --- |
| `repo` | required | `owner/name` |
| `suffix` | position among same-repo entries | Any string; always rendered as `_<suffix>` |
| `labels` | `gha_runner_default_labels` | Extra labels, on top of GitHub's automatic ones |
| `name` | `<hostname>_<suffix>` | Name registered with GitHub |
| `install_as_service` | `gha_runner_install_as_service` | Set false to install but not start |
| `work_dir` | `_work` | Working directory, relative to the runner |
| `no_default_labels` | `false` | Suppress GitHub's `self-hosted`/OS/arch labels |
| `extra_config_args` | `""` | Extra flags for `config.sh`, e.g. `--ephemeral` |

## Naming the machine

Runners are identified in the GitHub UI by machine name, so a fleet of hosts
all still called `ubuntu` is unusable in practice. The inventory already knows
what each machine is called, so by default the role renames it to match:
`inventory_hostname_short` becomes the hostname, and where the platform keeps
the domain separately, `inventory_hostname` supplies the fully qualified name.

Linux gets a `127.0.1.1` line in `/etc/hosts` alongside `hostname`, the Debian
convention that lets `hostname -f` answer on a DHCP machine. macOS has three
names, and only `HostName` can hold a domain: `ComputerName` and
`LocalHostName` stay short, the latter because the Bonjour name rejects dots.
They are driven through `scutil` and each is read before it is written, so a
second run reports no change — `ansible.builtin.hostname` cannot express this,
as it forces all three names to the same value.
Windows stores the domain apart from the computer name, under `Domain` and
`NV Domain`, and does not adopt a new computer name until it reboots — the role
reports this rather than rebooting a machine that may be busy.

Because the rename leaves the hostname fact stale for the rest of the play, and
on Windows until that reboot, runner names are derived from the name being
applied rather than the one the machine currently reports.

An inventory addressed by IP has no name to derive, so the role stops instead
of renaming a machine to something like `10.0.0.5`. Set `gha_hostname`
yourself, or turn the whole thing off with `gha_set_hostname: false`.

## What happens per platform

`tasks/main.yml` validates and normalizes the list, sets the hostname, then
hands off to `linux.yml`, `macos.yml` or `windows.yml`.

**Linux** installs `gha_runner_packages` first. That list is `acl` by default,
which Ansible itself needs: the role becomes an unprivileged user to run
`config.sh`, and an unprivileged-to-unprivileged become only works if `setfacl`
can hand over the temp files.

It then runs the runner's own `bin/installdependencies.sh` once per host. The
runner is a .NET program, and while the tarball carries the .NET runtime it
does not carry the native libraries that runtime links against, so `config.sh`
otherwise aborts with `Libicu's dependencies is missing for Dotnet Core 6.0`.
Those package names are version-stamped and differ per release — GitHub's
script walks `libicu80` down to `libicu52` until one installs — so the role
calls the script that ships with the runner rather than pinning names that
break on the next Debian. Set `gha_runner_install_dependencies: false` if your
image already provides them.

After that it unpacks the runner, registers it, then `sudo ./svc.sh install
gha` and `./svc.sh start`, and waits for `systemctl is-active` to agree.

**macOS** unpacks and registers the runner, then bypasses `svc.sh` and writes
`/Library/LaunchDaemons/actions.runner.<owner>-<repo>.<name>.plist` directly.
The label is read back out of the `svc.sh` that `config.sh` generated, so it
matches GitHub's own naming and truncation rules rather than a reimplementation
of them. The plist is `root:wheel` and `0644`, without which launchd rejects it
as `Load failed: 5: Input/output error`. It is then loaded with
`launchctl bootstrap system`, falling back to `launchctl load -w`. Setting
`gha_macos_use_launch_daemon: false` reverts to the stock LaunchAgent
behaviour.

macOS needs no package step and no Homebrew. It already ships ICU, so the
dependency problem Linux has does not arise, and the one thing that did need a
package — `ansible.builtin.unarchive` rejecting macOS's bsdtar — is avoided by
unpacking with `tar` directly instead.

Whichever platform, the last step asks GitHub whether the runner actually
appears under the repository. A service can start cleanly and still never
register, and nothing else catches that. Presence in the list is the test, not
status, so a runner installed with `install_as_service: false` still passes.

**Windows** unpacks the runner and runs `config.cmd --runasservice`, which
registers and installs the service in one step. Runners default to
`C:\actions-runner\<owner>_<repo>_<n>` rather than a user profile, because the
service logs on as `NT AUTHORITY\NETWORK SERVICE` and cannot read another
account's profile. To use a real account instead, set
`gha_windows_logon_account` and `gha_windows_logon_password`; the password
travels via `ACTIONS_RUNNER_INPUT_WINDOWSLOGONPASSWORD` rather than the command
line, so metacharacters survive.

## How "skip if it exists" stays honest

A plain "directory exists, therefore skip" rule has a nasty failure mode: if a
download or registration dies halfway, the half-built directory is skipped
forever and silently never works.

So the install runs under a dotted staging name
(`.boostorg_boost_1.staging`) and is only renamed to its real name once the
runner is registered. If anything fails, a rescue block unregisters the runner
from GitHub, removes any service it created, and deletes the directory, so the
next run retries cleanly. An existing directory therefore always means a
finished runner. Set `gha_cleanup_on_failure: false` to keep the wreckage for
debugging instead.

## Reinstalling or removing a runner

The role deliberately has no uninstall path — that is what keeps it from being
able to break anything. To replace a runner, remove it by hand and re-run:

```bash
# Linux
cd ~gha/runners/boostorg_boost_1
sudo ./svc.sh stop && sudo ./svc.sh uninstall
./config.sh remove --token <removal token>
rm -rf ~gha/runners/boostorg_boost_1
```

```bash
# macOS
sudo launchctl bootout system/actions.runner.boostorg-boost.build-mac-1_1
sudo rm /Library/LaunchDaemons/actions.runner.boostorg-boost.build-mac-1_1.plist
cd ~gha/runners/boostorg_boost_1 && ./config.sh remove --token <removal token>
rm -rf ~gha/runners/boostorg_boost_1
```

A removal token comes from
`POST /repos/{owner}/{repo}/actions/runners/remove-token`.

## Role variables

The commonly useful ones; `defaults/main.yml` documents the rest.

| Variable | Default | Meaning |
| --- | --- | --- |
| `gha_runners` | `[]` | The list described above |
| `gha_runner_user` | `gha` | Account that owns and runs the runners |
| `gha_runner_manage_user` | `true` | Create that account if missing |
| `gha_runners_dir` | `<home>/runners` | Parent directory on Linux and macOS |
| `gha_runners_dir_windows` | `C:\actions-runner` | Parent directory on Windows |
| `gha_runner_version` | `latest` | Or pin, e.g. `2.336.0` |
| `gha_set_hostname` | `true` | Rename the machine to match its inventory entry |
| `gha_hostname` | `inventory_hostname_short` | Short name to apply |
| `gha_hostname_fqdn` | `inventory_hostname` if it has a dot | Fully qualified name |
| `gha_runner_packages` | `[acl]` | Packages installed on Linux before anything else |
| `gha_runner_install_dependencies` | `true` | Run the runner's `installdependencies.sh` |
| `gha_runner_default_labels` | `[]` | Labels for entries that specify none |
| `gha_runner_install_as_service` | `true` | Default for entries that do not say |
| `gha_github_token` | `$GITHUB_TOKEN` | Control-node token |
| `gha_cleanup_on_failure` | `true` | Roll back a failed install |
| `gha_verify_registration` | `true` | Confirm the runner appears in the repo afterwards |
| `gha_macos_use_launch_daemon` | `true` | LaunchDaemon instead of LaunchAgent |
| `gha_macos_launchctl_method` | `bootstrap` | Or `load` for the older form |
| `gha_windows_logon_account` | `NT AUTHORITY\NETWORK SERVICE` | Windows service account |

## Tests

```bash
./tests/run.sh
```

- `normalize.yml` — suffix auto-numbering, directory and runner naming, and
  per-entry overrides. Offline.
- `hostname.yml` — the short/domain split and the rejection of names that are
  not hostnames. The per-platform tasks are swapped for a probe, so it never
  renames the machine running it. Offline.
- `plist.yml` — renders the LaunchDaemon template and parses it with
  `plistlib`, since macOS itself cannot be tested from Linux CI. Offline.
- `skip.yml` — proves a pre-existing runner directory is left byte-for-byte
  alone while a second runner is still attempted. Offline.
- `rollback.yml` — runs the real Linux install path with a deliberately invalid
  token and asserts that the rollback leaves nothing behind. Downloads the real
  runner tarball; never registers anything with GitHub.

`ansible-lint` passes on the `production` profile.

## Prior art

[`monolithprojects.github_actions_runner`](https://github.com/MonolithProjects/ansible-github_actions_runner)
is the established role in this space and the only other one with real Windows,
macOS and Linux task files. Use it if your needs are simpler. It handles one
runner per invocation, updates and redeploys runners in place, and uses
`svc.sh` on macOS. The control-node approach to registration tokens and version
discovery here follows its lead.

Two roles do have a list-of-dicts runner variable —
[`kode3tech`](https://github.com/kode3tech/ansible-col-devtools) and
[`grzegorzfranus/github-runner`](https://github.com/grzegorzfranus/ansible-role-github-runner)
— but both are Linux-only, with no Darwin or Windows code at all. The
post-install registration check here was prompted by `grzegorzfranus`, which
does the same thing.

Worth knowing if you are evaluating alternatives: no existing role writes a
LaunchDaemon. They all delegate macOS service setup to `svc.sh`, so on every
one of them a headless Mac needs auto-login to survive a reboot. And looping
`include_role` over MonolithProjects to get multiple runners is booby-trapped —
its `set_fact` on `reinstall_runner` persists across iterations, so one runner
triggering a reinstall silently forces one on every later runner for that host.

## License

Boost
