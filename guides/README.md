# Facilitator guides (answer keys)

> **Not for Chris.** These show what "good" looks like for the parts he is meant to work out himself. Chris gets [../trainee-brief.md](../trainee-brief.md) and the public Cast AI docs, nothing else.

There are deliberately no scripts for these steps. The environment tooling (`terraform/`, `scripts/`, `reset.sh`) builds, resets and arms the cluster. What Chris does with Cast AI he does by hand.

| Guide | Chris's task | Your side |
|---|---|---|
| [01-connect-with-castctl.md](01-connect-with-castctl.md) | Connect `nrg-stag-us-east-1` read-only, then enable automation | Nothing to run. Watch, answer questions as Dana. |
| [02-node-configuration-traps.md](02-node-configuration-traps.md) | Find and fix traps 2 and 3 (and the zone extra) | `castai/terraform` arms them so you can see the node configuration |
| [03-argo-handoff.md](03-argo-handoff.md) | (optional) Put Cast AI under Argo CD | Nothing to run. Use it as the answer key. |

Each guide has the same shape: **goal → what good looks like → hint ladder (give these one at a time, only when he's stuck) → answer key → things I haven't verified.**
