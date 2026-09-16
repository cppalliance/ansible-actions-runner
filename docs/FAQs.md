# FAQs

Questions that come up around the runners this role installs, but that the role
itself does not answer — it has no uninstall path, and never touches a runner
once it exists.

## Remove a runner

Run it locally on the runner machine. That is the graceful path:

```bash
cd <runner-dir>
sudo ./svc.sh stop && sudo ./svc.sh uninstall   # if installed as a service
./config.sh remove --token <REMOVAL_TOKEN>       # config.cmd remove on Windows
```

The removal token comes from the repository's Settings → Actions → Runners →
Remove, or from `POST /repos/{owner}/{repo}/actions/runners/remove-token` — the
same family of endpoint this role calls for registration tokens.

`config.sh remove` unregisters the runner from GitHub *and* deletes the local
`.runner` and `.credentials` files, so both sides end up clean. The directory
can go afterwards.

Deleting the runner from the GitHub website also works — it disappears from the
repository and jobs stop being routed to it — but it only cleans up GitHub's
side. The service is left installed and running locally, spinning on failed
connections until somebody stops it. That is the right tool when the machine is
already dead and cannot run anything; otherwise prefer the local removal.

An idle runner that stays offline for 14 days (30 if ephemeral) is removed by
GitHub automatically, so a decommissioned machine that was simply switched off
eventually cleans itself up on the GitHub side regardless.

See also [Reinstalling or removing a runner](../README.md#reinstalling-or-removing-a-runner)
in the README, which gives the same commands with the paths and service names
this role actually creates, including the macOS LaunchDaemon.
