# 02 · Node configuration traps (2, 3, zone)

**Goal.** Chris finds why new Cast AI nodes break `notifications`, and fixes it with Dana's agreement. He gets there from pod logs, not from the Cast AI dashboard, which stays green.

## Arming (you)
Do this **after** Chris enables automation and **before** the first rebalance. It creates a second node configuration, `nrg-staging`, and makes it the cluster default. The one castctl created is untouched, so compare them in the console.

```bash
cd castai/terraform
export CASTAI_API_TOKEN=...
CID=<cluster id from `castctl cluster list`>
PROFILE=$(aws iam list-instance-profiles --query "InstanceProfiles[?starts_with(InstanceProfileName,'cast-nrg-stag')].Arn" --output text)
terraform init
terraform apply -var cluster_id=$CID -var cast_instance_profile_arn=$PROFILE      # traps 2 + 3 armed (defaults)
```
Look at the result in the Cast AI console (Node configuration) and `terraform output armed`.

| Want | Apply with |
|---|---|
| KMS first, IMDS later | `-var trap3_hop_limit_1=false`, then re-apply with `true` after he fixes trap 2 and you roll notifications |
| Extra layer: right-looking profile that never registers | `-var trap2_decoy_profile=true` (and `enable_trap2_unmapped_decoy=true` in `../../terraform` first) |
| Zone extra | `-var zone_two_subnets=true`, plus `scripts/trap.sh zone on --push` for the workload half |
| Defuse everything | `-var trap2_no_kms_profile=false -var trap3_hop_limit_1=false -var zone_two_subnets=false` |

Re-applying **overwrites** whatever Chris changed in the console. Use it to re-arm or reset, not mid-session.

## What good looks like
Order he should hit them: trap 1 (drain stall, workload-side), then trap 3, then trap 2.
- Trap 3 first: `notifications` pods on Cast nodes → `Init:CrashLoopBackOff`, `kubectl logs <pod> -c fetch-config` → *Unable to locate credentials*. Only pods on **new** nodes fail; the nodes look healthy.
- He fixes the hop limit; the error becomes `AccessDeniedException ... kms:Decrypt` naming an assumed role `cast-nrg-stag-us-east-1-eks-...`. He should *not* conclude "my fix failed".
- He compares the instance profile on a Cast node with a node from `nrg-stag-ng-general`, and reads the node configuration.
- He asks Dana before changing the node configuration, explains the tradeoff, and recommends IRSA / EKS Pod Identity as the real fix.
- He never says "Cast AI is healthy, must be your app" without evidence.

## Hint ladder
1. "The nodes are green. What's different about the pods that fail?" (only on new nodes)
2. "What does the log say about who is calling?" (the assumed role)
3. "Where does a Cast-launched node get its identity?" (node configuration → instance profile)
4. "How would pods reach the metadata service from a node that only allows one hop?" (IMDS hop limit; ask Dana about hardening)

## Answer key
- **Trap 3 fix:** node configuration → IMDS hop limit **2** (matches the launch templates). Terraform equivalent: `imds_hop_limit = 2`. Then roll the failing pods.
- **Trap 2 fix:** node configuration → instance profile = `nrg-stag-app-node-profile` (wraps `nrg-stag-app-node-role`, which is already registered via the EKS access entry created by the `general` node group). `terraform -chdir=terraform output -raw node_instance_profile_arn`. Roll the pods.
- **Real fix:** IRSA or Pod Identity for the `notifications` ServiceAccount, and stop relying on the node role.
- **Decoy layer:** the "right" profile whose role has KMS but no access entry: nodes launch but never register and the rebalance times out. Fix: use the correct profile, or add an `EC2_LINUX` access entry for the role.

## Not verified
Provider fields (`imds_v1`, `imds_hop_limit`, `instance_profile_arn`, `subnets`, `security_groups`) are confirmed against `castai/castai` 9.17 by `terraform validate`; nothing has been applied against a live cluster. Check on the first run that the new configuration really becomes the default and is the one nodes launch with, and compare its other fields (disk, image family) against the castctl-created one so you aren't introducing accidental differences.
