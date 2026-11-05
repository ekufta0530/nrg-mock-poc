# NRG Role-Play & POC: Facilitator Guide

> **Facilitator only.** Don't share this with the trainee. The trainee gets [trainee-brief.md](trainee-brief.md).

This guide covers how to run each phase, what the trainee (Chris Bickram) should find, the answers, and the rubric. For building the environment, see [README.md](README.md).

**How a session flows.** Phase 1 is the 45-60 min role-play (you are Dana Whitfield, VP Platform Engineering) and needs no environment. You decide at the end whether Chris moves to a POC. If you say yes, phases 2-6 run on the live cluster `nrg-stag-us-east-1`.

**GitOps note.** Argo CD owns the cluster. Workload traps are toggled with `scripts/trap.sh <id> on|off --push` (a Git change to `manifests/overlays/staging/kustomization.yaml`). A direct `kubectl apply` or `kubectl scale` on anything Argo manages is reverted by self-heal. The Cast AI node configuration (traps 2, 3, zone) is not in Git: `castai/terraform` arms it. Everything Chris does by hand (connect, node-config fixes, Argo handoff) has an answer key in [guides/](guides/); none of it is scripted.

---

## 0. Before the trainee starts

- [ ] `terraform apply`, `scripts/deploy.sh --build`, the push, and `scripts/bootstrap-gitops.sh` are done (see README). `kubectl -n argocd get applications` shows everything Synced/Healthy.
- [ ] `scripts/trap.sh list` shows traps 1, 2, 4 and 5 armed.
- [ ] `scripts/verify-cpu-weight.sh` says **quadratic** (weight 174 for 2 CPU), which matches the nrg-worker default. If it says legacy, rebuild with `CGROUP_WEIGHT_MODEL=legacy`.
- [ ] `scripts/queue-status.sh` shows `queue_depth` near 0 and `throughput_per_sec_1m` ≈ 6.
- [ ] The trainee's IAM principal is in `admin_principal_arns` (kubectl), and they have read access to EC2/IAM in the console so they can compare instance profiles.
- [ ] CAST AI is **not** connected (if it is, run `./reset.sh reset` first).
- [ ] Chris has `castctl` ≥ 0.15 and can `castctl auth login` into the org he'll connect to.

### Where requests sit (for the savings story)

| Workload | Requests (each) | Replicas | Real usage |
|---|---|---|---|
| checkout-api | 1 CPU / 1Gi | 2 (HPA 2–10) | ~0.3 CPU each |
| checkout-loadgen | 250m / 256Mi | 1 | ~0.1 CPU |
| routing-engine | 2 CPU / 1Gi | 1 | ~0.6 CPU |
| routing redis-queue + producer | 250m / 1Gi, 250m / 256Mi | 1 each | tiny |
| notifications | 500m / 1Gi | 2 | idle |
| cache/redis (session cache) | 1 CPU / 2Gi | 1 | idle |
| label-renderer | 500m / 1Gi | 3 | idle |
| postgres | 1 CPU / 4Gi | 1 | idle |
| elasticsearch | 1 CPU / 4Gi | 1 | ~0.2 CPU, ~2Gi |
| ingress-nginx | 500m / 512Mi | 2 | idle |

That's about 11 CPU requested against ~2 CPU actually used (plus ~1 CPU of platform tooling: Argo CD, Cluster Autoscaler, metrics-server), on 3 × m5.xlarge + 2 × r5.large + 1 × c5.xlarge (~19 allocatable CPU). That is the over-provisioning story Dana tells ("we padded after the SLO breach"). Plenty of room for both the rebalance and WOOP to show savings.

---

## 1. Phase-by-phase runbook

| Phase | Trainee does | You do |
|---|---|---|
| 1. Role-play | Discovers, pitches, proposes a POC | Play Dana per §2. Note which reveal-questions he asks and which objections he handles. Score with §4a. At the end say: move to POC / need more / no. |
| 2. Connect (read-only) | Connects read-only with `castctl cluster connect` (autoscaling and WOOP off), runs cluster checks. [Guide 01](guides/01-connect-with-castctl.md). | Nothing. Traps 1 and 4 should show in `scheduling-constraints-check` (#1) and `hpa-target-utilization-check` (Critical band, ≤50%). |
| 3a. Enable automation | Enables automation with `castctl cluster connect` (node autoscaler + WOOP; creates IAM and the default node configuration). `--import-config` turns the three node groups into node templates. | **Right after it finishes, before any rebalance:** apply `castai/terraform` ([guide 02](guides/02-node-configuration-traps.md)). It creates a second node configuration, makes it the default, keeps the CAST-generated instance profile (trap 2) and sets IMDSv2-only with hop limit 1 (trap 3). |
| 3b. Autoscaler + rebalance | Enables policies, runs the initial rebalance | Watch. Expected order: trap 1 (drain stall), then trap 3 (`Unable to locate credentials`), then trap 2 (`AccessDenied`). The fix for trap 1 is a Git change too, or a rebalance exclusion. |
| 4. GitOps handoff (optional) | Puts the Cast AI chart under Argo by hand ([guide 03](guides/03-argo-handoff.md)). Shows Dana what Argo ownership of Cast AI looks like (mode changes via `tags.*` in Git). | Good moment for "will Argo fight WOOP?" and "can I roll back?". Also where the Cluster Autoscaler extra bites: the fix is `replicaCount: 0` in Git. |
| 5. WOOP | Enables WOOP on agreed workloads | Trap 4 shows within hours. For trap 5, wait about a day, then deliver the customer complaint (§3, trap 5). Track the backlog with `scripts/queue-status.sh -w`. |
| 6. Readout | Presents to Dana (and the CTO) | Grade with §4b. Tie results back to the 20% / ~$62k target and the SLO. |

**Want KMS before IMDS?** Apply `castai/terraform` with `-var trap3_hop_limit_1=false` first. Once the trainee fixes trap 2, re-apply with `true` and roll notifications.

---

## 2. Customer script ("Dana Whitfield, VP Platform Engineering")

You are the economic buyer: busy, accountable for the cloud line, skeptical. The CTO signs but will take your recommendation. Stay in character until the debrief. Reveal pain only when Chris earns it with a good question. The full canvas and reveal table are in [spec.md §3.2](spec.md); the essentials:

**Canvas**
- **Primary pain:** costs are up; you've been told to cut K8s spend **20%** (~**$62k/mo** of ~$310k).
- **Hidden pain:** an **SLO breach** a few months ago → you over-provisioned heavily so it can't recur → that padding is the cost problem. About **$62k/mo** of it, no time impact.
- **Drivers:** cost this quarter; last quarter was the incident. **Budget:** CTO signs, on your recommendation; DIY Karpenter and headcount compete. **Competitors:** Karpenter (trial on staging), ScaleOps.
- **Objections:** "I only need to rightsize once." "I don't want lock-in, or an external vendor causing an incident." Also available: "we already have Cluster Autoscaler", "security won't approve another agent", "we're mid-Karpenter trial", "we tried a cost tool before".
- **Yes if:** read-only first, scoped, success metrics agreed up front, no SLO risk, an exit path. **No if:** security isn't satisfied.
- **Other voices (name them yourself):** FinOps lead, SRE / reliability manager, Fenwick app-team lead.

**Say freely:** costs are up and you have a 20% target; nodes are heavily over-provisioned; ~9 clusters across three clouds; Karpenter trial on staging.

**Reveal only when asked:**

| If the trainee asks… | Dana says… | Pre-empts |
|---|---|---|
| What broke recently / why is spend up? | "We breached an SLO last quarter. We over-provisioned so it can't happen again, and now I'm paid to take it back out." | Hidden pain |
| What does it cost? | "About $62k a month of it is padding." | Impact |
| Who signs / what competes for the money? | "My CTO signs, on my recommendation. I'm also weighing DIY Karpenter and a headcount." | Decision |
| Does anything depend on the node IAM role / how do apps get AWS creds? | "Notifications decrypts its config with KMS using the node role. We never got around to IRSA. Staging nodes run under a custom role, `nrg-stag-app-node-role`." | Trap 2 (hints at 3) |
| Any IMDS / launch template hardening? | "Security made us require IMDSv2. Our launch templates set hop limit 2 so pods can still reach it." | Trap 3 |
| Any single-replica workloads / PDBs? | "The session cache Redis is one replica and someone put a PDB on it. It's just a cache, restarting is fine." | Trap 1 |
| Any HPAs? | "checkout-api scales on CPU at 50%." | Trap 4 |
| How do services size threads / workers / concurrency? | "routing-engine auto-tunes its worker count to the CPU it's given. The team was proud of that." | Trap 5 |
| Stateful workloads? | "Elasticsearch and a few Postgres instances on EBS. Nobody touches them." (opens Live Migration / Spot) | Stateful story |
| Will Argo CD fight WOOP? | Have him explain: WOOP mutates at admission / resizes in place, so the manifests in Git don't drift. Argo CD is installed here, so he can show it. | n/a |
| How do savings interact with the EDP? | FinOps pushes. He should explain EDP is a spend commitment: model discount-tier headroom, don't overclaim. | n/a |
| How does this compare to Karpenter / ScaleOps? | "We're trialling Karpenter on staging." See whether he compares fairly (no workload rightsizing or SLO guardrails; you own upgrades and the pager). | Competitor |

**POC success criteria** (make him pull these out of you; don't volunteer):
- Cut K8s compute cost by **20%** within the POC window (staging, on the way to ~$62k/mo account-wide)
- **Zero SLO breaches / customer-visible incidents**
- WOOP running on at least 5 workloads
- A safe story for stateful workloads (Elasticsearch and Postgres are here for this)
- An exit path: nothing that can't be switched off, no lock-in

---

## 3. Trap cards

### Trap 1: Zero-disruption PDB on the Redis cache (Easy)

| | |
|---|---|
| Armed by | `scripts/trap.sh 1 on` → `PodDisruptionBudget cache/redis-pdb` with `minAvailable: 1`, Deployment `replicas: 1` |
| Symptom | The rebalance stalls draining the node that hosts Redis. The rebalance plan flags `cache/redis` as problematic. |
| Detection | `scheduling-constraints-check` #1; rebalance plan UI; `kubectl get pdb -A` (ALLOWED DISRUPTIONS = 0) |
| Expected fix | **Ask Dana first**, then set `maxUnavailable: 1` (= `scripts/trap.sh 1 off`) or exclude Redis from the rebalance |
| Grade on | Did they ask before changing it? |

### Trap 3: IMDS hop limit 1 on CAST AI nodes (Hard). Usually shows before trap 2.

| | |
|---|---|
| Armed by | `castai/terraform` (`trap3_hop_limit_1=true`, the default) → node config `imds_v1=false`, `imds_hop_limit=1` |
| Why both settings | The CAST AI default is `imdsV1=true` and hop limit 2. With hop limit 1 *and* IMDSv1 still on, the AWS CLI falls back to IMDSv1 and succeeds, so the trap needs IMDSv1 off. |
| Symptom | `notifications-*` pods on CAST AI nodes: `Init:CrashLoopBackOff`. `kubectl logs <pod> -c fetch-config` → `Unable to locate credentials` (or a metadata timeout). The node itself is fine because host-network processes are one hop. |
| Detection path | Pod events/logs → only pods on new nodes fail → `aws ec2 describe-instances --instance-ids <cast node> --query 'Reservations[].Instances[].MetadataOptions'` vs the `nrg-stag-ng-general` launch template (hop limit 2) → CAST AI node configuration IMDS settings |
| Expected fix | Hop limit 2 in the CAST AI node configuration (Terraform equivalent: `trap3_hop_limit_1=false`), then roll the failing pods. Long term: IRSA / Pod Identity. |
| Then | The error changes to `AccessDeniedException`. Expect "my fix didn't work". That's the moment to see whether they keep digging. |

### Trap 2: Instance profile without KMS permission (Hard)

| | |
|---|---|
| Armed by | Workload: `scripts/trap.sh 2 on` (KMS init container). CAST AI: `castai/terraform` with `trap2_no_kms_profile=true`, the default (CAST-generated `cast-nrg-stag-us-east-1-eks-*` profile; it's also the onboarding default). |
| Symptom | CAST AI nodes are green. `notifications` replacement pods: `Init:CrashLoopBackOff`, logs `An error occurred (AccessDeniedException) when calling the Decrypt operation: User: arn:aws:sts::…:assumed-role/cast-nrg-stag-us-east-1-eks-…/i-… is not authorized to perform: kms:Decrypt…`. The rebalance can't finish. |
| Detection path | The pod log names the assumed role, which is the giveaway → compare the instance profile on a CAST AI node with a `nrg-stag-ng-general` node (`aws ec2 describe-instances … IamInstanceProfile`) → node configuration → instance profile ARN |
| Expected fix | Set the node configuration instance profile to `terraform output -raw node_instance_profile_arn` (`nrg-stag-app-node-profile`, which wraps `nrg-stag-app-node-role`; that role is already in access entries via the node group). Terraform equivalent: `trap2_no_kms_profile=false`. Roll the pods. **Recommend IRSA or EKS Pod Identity** for `notifications/notifications` as the real fix. |
| Extra layer (optional) | `terraform apply -var enable_trap2_unmapped_decoy=true`, then give the trainee `terraform output -raw trap2_decoy_instance_profile_arn` as "the profile to use". Its role has KMS but **isn't in access entries**, so nodes launch but never register, and the rebalance times out. To fix, use the right profile or add an EC2_LINUX access entry for the v2 role. A typo'd ARN is the low-effort version: nodes fail to launch with an invalid-profile error. |
| Pre-empted by | "How do your apps get AWS credentials?" |

### Trap 4: HPA on CPU vs WOOP (Easy)

| | |
|---|---|
| Armed by | `scripts/trap.sh 4 on` → HPA `checkout/checkout-api`, CPU 50%, 2–10 replicas. Loadgen holds ~30 rps (~0.6 CPU total, ~30% of requests). |
| Symptom (naive vertical CPU scaling) | WOOP cuts CPU requests → utilization % jumps → HPA scales out → replicas climb and savings flatten or go negative. Watch `kubectl -n checkout get hpa -w`. |
| Detection | `hpa-target-utilization-check` (50% = Critical band); HPA indicator in the WOOP UI |
| Expected answer | The trainee explains that utilization is usage ÷ request, so the two autoscalers are coupled. Then they pick a policy deliberately: WOOP's HPA-aware behaviour, memory-only vertical scaling while the HPA owns CPU, or move the HPA target. Removing WOOP from the workload with no explanation is weak. |
| ⚠ Verified behaviour | Current CAST AI docs say WOOP **coordinates with native HPA by default**. It simulates HPA replica behaviour for each CPU recommendation and ignores the manually set CPU percentile. So on a current build, the runaway scale-out may not happen on its own. Grade on the explanation and the policy choice. To *force* the visible symptom, check whether the policy lets you disable HPA-aware CPU handling and do that before WOOP is enabled. |

### Trap 5: Self-throttling worker "death spiral" (Super challenge)

| | |
|---|---|
| Armed by | **Default: Super.** `scripts/trap.sh 5 on`: worker count read from `/sys/fs/cgroup/cpu.weight`, nothing in the pod spec, re-read every 30 s. Alternative: `scripts/trap.sh 5-hard on --push` (Hard): Downward API `CPU_REQUEST_MILLI` visible in the spec, with `resizePolicy: RestartContainer` on CPU so the env var refreshes after an in-place resize. |
| Mechanics | Each job is 100ms CPU + 900ms I/O sleep, so ~1 job/s per worker. The producer sends 6 jobs/s. Workers = round(request millicores / 250). At 2 CPU: 8 workers, ~8 jobs/s capacity, ~0.6 CPU used (30% of the request, which is the bait). |
| Verified locally (runc, cgroup v2) | 2000m → 8 workers → throughput 5.9/s, queue 0, 0.60 CPU. **600m → 2 workers → throughput 2.0/s, queue +300 in 75 s, CPU *fell* to 0.20.** At ≤330m it drops to 1 worker. Changing CPU on a running container resized the pool live (8 → 2 → 1). On the 1.35 AMI (runc 1.3.6, quadratic) the weights are 174 / 67 / 43 instead of 79 / 24 / 13, with the same worker counts. |
| Your cue (~1 day after WOOP applies) | "Since Tuesday the order-routing queue keeps backing up and ship-from-store ETAs are slipping. Did you change something?" (This is the "vendor-caused incident" objection coming true.) Use `scripts/queue-status.sh` for real numbers (`queue_depth`, `oldest_job_age_seconds`). |
| Detection path | 1) Line up the backlog start with WOOP apply events / policy change history for `routing/routing-engine`. 2) **CPU usage dropped after rightsizing.** CPU-bound work doesn't use less CPU when you give it less, so that's the tell. 3) Find the coupling: ask Dana ("auto-tunes to the CPU it's given"), read the startup log (`worker pool auto-tuned: 2 workers (cpu≈590m via cgroup)`), or `kubectl exec` and read `/app/concurrency.py`. |
| Expected fix | **Immediate:** exclude routing-engine from WOOP or set a CPU minimum (≥ 2 CPU) in its policy, and restore the request. **Real fix:** decouple concurrency from requests, either with a fixed `WORKERS` (= `scripts/trap.sh 5 off --push`, which sets `WORKERS=8`) or KEDA on queue depth. Then rightsize on real usage. **Talking point:** JVM `availableProcessors`, Go `automaxprocs` and gunicorn `2*CPU+1` all fail the same way. It belongs in the prod pre-flight checklist. |
| ⚠ Before running | WOOP must actually apply below ~1 CPU. Use a policy with **immediate** apply and a CPU minimum well under 600m. On 1.35, in-place pod resize is GA, so WOOP may change the request **without** restarting the pod. Super follows that live (30 s re-check) and Hard restarts the container. Either way the spiral starts. If the trainee asks why there was no restart, that's a good conversation. |

### Note: Graviton nodes

The `v20260930` AL2023 AMIs have an open kernel-panic bug on **arm64** under heavy page-cache reclaim ([amazon-eks-ami#2845](https://github.com/awslabs/amazon-eks-ami/issues/2845)). The self-managed node groups are x86, but if CAST AI picks Graviton instances you may see containers exit with `Unknown`/255. That isn't one of the traps. Keep the CAST AI node template on amd64, or pin a newer AMI once one ships.

### Optional extra: Cluster Autoscaler still running

The OSS Cluster Autoscaler is an Argo CD application and is left running by design; the three self-managed ASGs have minimums of 2/1/1. After the rebalance it can scale the node groups back up and fight CAST AI. The fix is **in Git**: `replicaCount: 0` on `gitops/apps/platform/cluster-autoscaler.yaml`, plus the ASG min/max (CAST AI's connect flow often prompts for this). A `kubectl scale` is reverted by Argo's self-heal, which is itself a good lesson. `./reset.sh reset` restores the ASGs and warns if the Git fix is still in place.

### Optional extra: Zone mismatch

`scripts/trap.sh zone on` applies a strict 3-AZ `topologySpreadConstraint` (`maxSkew: 1`, `DoNotSchedule`) to label-renderer, and sets the CAST AI node configuration to 2 of the 3 private subnets. After the rebalance, one label-renderer pod stays Pending. Detection: `scheduling-constraints-check` #8 plus the node configuration subnets. Fix: `scripts/trap.sh zone off --push`, or add the third subnet.

---

## 4. Grading rubric

### 4a. Role-play (phase 1), 1-5 each, from Chris's brief

Framed the meeting / set the agenda · Discovery quality (open → depth → quantification) · Identified pain and impact (20% / $62k **and** the SLO-breach over-provisioning) · Identified economic buyer and decision process (Dana recommends, CTO signs, security gates) · Mapped value to *his* pain, not a feature dump · Handled objections ("rightsize once", lock-in / vendor-caused incident, Karpenter, ScaleOps) · Proposed a crisp, low-risk next step (read-only first, 2-3 metrics, decision left with Dana) · **Overall SA readiness**. Then three things done well, three to change, and your decision (☐ move to POC ☐ need more ☐ no).

Good answers to the two scripted objections: *"Rightsize once"* → workloads drift with every release and traffic shift, and the SLO breach is exactly what a one-time cut risks; continuous, SLO-aware rightsizing is the safeguard. *"Vendor causes an incident"* → read-only first, automation only on Dana's say-so, ask-before-change, per-workload exclusions, and a documented exit (disconnect removes everything; nodes stay up).

### 4b. POC execution (phases 2-6)

| Area | Strong | Weak |
|---|---|---|
| Discovery | Uncovers the node-role/KMS, IMDS, PDB, HPA and worker-sizing context **before** enabling anything. Gets the success criteria and stakeholders. | Jumps to the demo. Learns about the traps only when they break. |
| Pre-flight | Runs the cluster checks, presents findings, and gets agreement on changes | Enables the autoscaler blind |
| Trap 1 | Asks before modifying the PDB, and makes the change through Git | Deletes the PDB unilaterally |
| Traps 2 and 3 | Goes from pod logs to node identity to the node configuration. Recommends IRSA/Pod Identity. | Blames CAST AI or escalates without evidence |
| Trap 4 | Explains the HPA and WOOP interaction and picks a policy deliberately | Disables WOOP on the workload with no explanation |
| Trap 5 | Correlates the timeline, spots that usage fell, and finds the coupling | Says "CAST AI shows it's healthy" |
| Customer handling | Calm and transparent. Turns incidents into trust-building moments. | Defensive, or hides issues |
| Readout | Savings with evidence against the 20% target, SLO unaffected, risks found, and a prod rollout plan with pre-flight checks | Savings number only |

---

## 5. Open items: status

| Spec item | Status |
|---|---|
| CAST AI node configuration IMDS fields and defaults (trap 3) | **Verified** (CAST AI Terraform provider docs + API model): `imds_v1` (default **true**) and `imds_hop_limit` (default **2**). `castai/terraform` sets both for trap 3. |
| WOOP default with a CPU HPA (trap 4) | **Verified in docs:** HPA-aware coordination is on by default. See the trap 4 card. Confirm on the first live run. |
| WOOP minimums / apply mode (trap 5) | **Open.** Confirm on the first live run (see the trap 5 card). |
| cpu.weight math on AL2023 (trap 5) | **Resolved for 1.35.** The current AL2023 1.35 AMI (`1.35.8-20260930`) ships runc 1.3.6, which uses the quadratic mapping (2000m → 174, 600m → 67). nrg-worker defaults to `CGROUP_WEIGHT_MODEL=quadratic`, and the legacy model is still supported. Confirm once with `scripts/verify-cpu-weight.sh`. |
| Trap 5 difficulty | **Decided: Super** (default). Hard is still available: `scripts/trap.sh 5-hard on --push`. |
| Trap 2 extra layer | Built, **off** by default (`enable_trap2_unmapped_decoy`). |
| AWS account, budget, teardown schedule | **Account decided:** 445567108000 (default CLI credentials), enforced by Terraform and the scripts. Kubernetes **1.35** (standard support, ~$880/month all in). Budget and teardown schedule are still your call. |
| `castctl` behaviour (flag combinations, in-place upgrade from read-only to automation, IMDS fields on the node configuration it creates) | **Open.** Built from `castctl` 0.15.1 `--help` and the docs; confirm on the first live run. |
| Cast AI umbrella handoff to Argo CD | **Open.** Built on chart `castai-helm/castai` 0.46.6 (`apiKeySecretRef`, `tags.*`); confirm adoption is clean on a live cluster (hooks, CRDs). |
| Stakeholder names (FinOps, SRE manager, Fenwick lead) | **Yours to name.** |
| Karpenter trial on staging | Story only. Nothing is installed. |
