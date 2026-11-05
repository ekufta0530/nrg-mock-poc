# nrg-mock-poc

The environment for the Northwind Retail Group (NRG) Cast AI role-play and POC. It is one real EKS cluster, **`nrg-stag-us-east-1`** (the staging counterpart of the fictional `nrg-prod-us-east-1`), with five planted POC traps. Cast AI is connected with `castctl`; everything else on the cluster is delivered by **Argo CD**.

The design is in [spec.md](spec.md). How to run a session is in [facilitator-guide.md](facilitator-guide.md). Chris gets only [trainee-brief.md](trainee-brief.md).

## Layout

```
terraform/             VPC, EKS 1.35, 3 self-managed node groups (general m5 / memory r5 / burst c5, AL2023, IMDSv2 hop 2),
                       nrg-stag-app-node-role + kms:Decrypt, KMS key/alias, ECR, Cluster Autoscaler IRSA, Argo CD;
                       writes the cloud-derived GitOps files (CA Application, notifications ConfigMap, root app)
images/nrg-worker/     http + queue modes; queue mode self-sizes workers (Super: cgroup cpu.weight / Hard: Downward API)
images/nrg-loadgen/    fixed-rate HTTP load / Redis job producer; /status shows queue depth
manifests/base/        namespaces, gp3 StorageClass, checkout, routing (queue + producer), cache, label, postgres, elasticsearch
manifests/traps/<id>/  armed variant of each trap (Kustomize dir)      manifests/safe/<id>/  defused variant, same object names
manifests/overlays/staging/   the trap switchboard Argo CD syncs (+ generated images component and KMS ConfigMap)
gitops/                root app-of-apps, platform Applications (CA, metrics-server, ingress-nginx), workloads, castai/
castai/terraform/      facilitator only: Cast AI node configuration with traps 2/3/zone armed or fixed by variable
guides/                facilitator answer keys for what Chris does by hand (castctl connect, node-config traps, Argo handoff)
scripts/               deploy.sh (images), bootstrap-gitops.sh, trap.sh (toggle in Git), queue-status.sh, verify-cpu-weight.sh
reset.sh               reset for the next run / full teardown
```

## Prerequisites

`terraform` ≥ 1.6, `aws` CLI v2, `kubectl` (with built-in Kustomize), `helm`, `jq`, `python3`, `docker` with buildx, `castctl` ≥ 0.15 (`castctl auth login`), `git`, and AWS credentials for account **445567108000** (the CLI's default credentials). Terraform (`allowed_account_ids`) and every script (`ensure_account`) refuse to run against any other account. To use a named profile, set `AWS_PROFILE` for the scripts and `aws_profile` in `terraform.tfvars`. `CASTAI_API_TOKEN` (full-access key) is needed for `castai/terraform` and `reset.sh`.

**Argo CD needs a Git remote.** Push this project to a GitHub repo first and set `gitops_repo_url` in `terraform.tfvars`. For a private repo, register credentials after the install (`argocd repo add …` or a repository Secret in `argocd`).

## Build

```bash
# 1. infrastructure + Argo CD (~20 min)
cd terraform
cp terraform.tfvars.example terraform.tfvars   # set gitops_repo_url, admin_principal_arns
terraform init && terraform apply
cd ..

# 2. images -> ECR, and point the overlay at them
scripts/deploy.sh --build                       # writes manifests/overlays/staging/components/images/

# 3. commit + push everything Terraform and deploy.sh generated (gitops/, manifests/overlays/staging/)
git add -A && git commit -m "nrg staging" && git push

# 4. hand the cluster to Argo CD
scripts/bootstrap-gitops.sh                     # applies the root app, waits for Synced/Healthy
kubectl -n argocd port-forward svc/argocd-server 8080:80   # UI/CLI; see `terraform output argocd_port_forward`

scripts/verify-cpu-weight.sh                    # once per AMI: confirms trap 5's cpu.weight model
scripts/trap.sh list
scripts/queue-status.sh                         # queue_depth ~0, throughput ~6/s
```

Trap 5 defaults to **Super** (worker count read from cgroup `cpu.weight`, invisible in the pod spec). Use `scripts/trap.sh 5-hard on --push` for the Downward API version.

## During a session

**Chris connects Cast AI himself** with `castctl` (read-only first, then automation). There are no wrapper scripts for that, or for the Argo handoff, on purpose. The answer keys are in [guides/](guides/).

**You arm the Cast AI side** right after he enables automation, before the first rebalance (this is the one thing worth automating, and it's Terraform so you can see the result):

```bash
cd castai/terraform
export CASTAI_API_TOKEN=...
terraform init
terraform apply -var cluster_id=<id> -var cast_instance_profile_arn=<cast-generated profile arn>   # traps 2 + 3
terraform output armed
```
Variables switch each trap (`trap3_hop_limit_1`, `trap2_no_kms_profile`, `trap2_decoy_profile`, `zone_two_subnets`). See [guides/02-node-configuration-traps.md](guides/02-node-configuration-traps.md).

**Workload traps are Git changes** (Argo CD self-heal reverts `kubectl apply`):

```bash
scripts/trap.sh 1 off --push                    # 1, 2, 4, 5, 5-hard, zone, all. --push = commit + push + Argo refresh
scripts/trap.sh list
scripts/queue-status.sh -w                      # trap 5 business metric
```

## Reset and teardown

```bash
./reset.sh reset [--delete-cast-iam] [--push]   # drop Argo's castai app, disconnect/delete from CAST AI, strip CAST components,
                                                # restore the 3 ASGs, re-arm traps in Git, flush queue (~20-30 min)
./reset.sh teardown                             # everything, including terraform destroy
```

Always reset or tear down through `reset.sh`. If you go straight to `terraform destroy` while CAST AI nodes are still running, their ENIs block VPC deletion.

## Cost (us-east-1, on-demand, rough)

| Item | $/month |
|---|---|
| EKS control plane (1.35) | ~$73 |
| 3 × m5.xlarge + 2 × r5.large + 1 × c5.xlarge | ~$730 |
| NAT gateway (single) + data | ~$40 |
| EBS (6 × 50Gi root + 20Gi postgres + 20Gi elasticsearch), KMS, ECR | ~$35 |
| **Total** | **≈ $880/month (~$29/day)** |

Tear down between runs. A rebuild is about 30 minutes end to end.

## Validated vs not yet validated

Validated locally in this rework:
- `terraform validate` passes (providers aws 5.x, eks module 20.x, helm 2.x, local 2.x). The cached EKS module supports self-managed AL2023 groups, `autoscaling_group_tags` and per-group access entries.
- Every Kustomize combination renders (`kubectl kustomize manifests/overlays/staging`), including each trap on/off/hard/zone state, and `scripts/trap.sh` edits the overlay correctly.
- Shell scripts pass `bash -n`.
- From the earlier Parcelwise build: the images were run locally on cgroup v2 / runc and the trap 5 model reproduces (2000m → 8 workers, no backlog; 600m → 2 workers, backlog grows, CPU *falls*).

**Not yet exercised against AWS, Argo CD or Cast AI:** `terraform plan/apply`, `bootstrap-gitops.sh`, `deploy.sh --build`, `reset.sh`, every `castctl` invocation in the guides (flag combinations come from `castctl --help` 0.15.1 and the published docs; the read-only flag pair and in-place upgrade to automation need confirming), `castai/terraform` (field names are confirmed against provider `castai/castai` 9.17 by `terraform validate`, but nothing has been applied; check on the first run that the new configuration becomes the default), and the Argo handoff in the guide (umbrella chart 0.46.6, `apiKeySecretRef`).
