# 01 · Connect with castctl

**Goal.** Chris connects `nrg-stag-us-east-1` to Cast AI read-only, shows Dana what he sees, then (with Dana's say-so) enables automation.

## What good looks like
- He asks Dana before enabling anything, and agrees what "read-only" means (agent and kvisor only, no node changes, no pod mutation).
- He previews before changing: `castctl cluster connect --dry-run`.
- He runs the cluster checks after the read-only connect and presents findings: traps 1 (PDB) and 4 (HPA) are visible here; 2, 3 and 5 are not.
- He enables automation only after a pre-flight conversation with Dana, and treats the Cluster Autoscaler as something to decide on, not ignore.

## Hint ladder
1. "Is there a CLI for this?" → `castctl` (installed via the docs). `castctl auth login`, then `castctl cluster --help`.
2. "How do I see what it will do first?" → `--dry-run`.
3. "How do I connect without turning on autoscaling?" → `castctl cluster connect --help`: the feature flags `--cluster-optimization` and `--workload-autoscaler` default to true; read-only means turning them off.
4. "What happens to our existing node groups?" → `--import-config` (or `castctl cluster import-config --file plan.yaml` to review first, then `apply-config`).

## Answer key
```bash
castctl auth login
castctl cluster connect --dry-run                       # resolve cluster, region, IAM names; no changes
castctl cluster connect --cluster-optimization=false --workload-autoscaler=false     # read-only
castctl cluster list                                    # cluster ID for later
kubectl -n castai-agent get pods                        # agent, kvisor, ...

# later, with Dana's approval
castctl cluster connect --cluster-optimization=true --workload-autoscaler=true [--import-config]
# or review the node pools as a plan before importing them:
castctl cluster import-config --file nrg-plan.yaml && castctl cluster apply-config --file nrg-plan.yaml
```
What it creates in AWS: an IAM role Cast AI assumes, a node role and **instance profile** `cast-nrg-stag-us-east-1-eks-<id>` for Cast-launched nodes. That profile has no KMS access: it is trap 2's setup. He should *notice it exists* during the connect, which is a good discovery moment.

The umbrella Helm chart is `castai-helm/castai` in `castai-agent`; its mode is a tag (`readonly`, `workload-autoscaler`, `node-autoscaler`, `full`).

To back out: `castctl cluster disconnect` (removes the Helm releases and, unless skipped, the cloud IAM it created). Good answer to the "no lock-in" objection: he should know it before Dana asks.

## Not verified
Built from `castctl` 0.15.1 `--help` and the public docs, not a live run. Confirm: that the two `=false` flags give a read-only install, that re-running connect upgrades in place (the chart docs flip tags with `helm upgrade --reset-then-reuse-values`, which is the fallback), and what `--import-config` does to the three self-managed node groups.
