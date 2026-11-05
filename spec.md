# Northwind Retail Group (NRG) Mock Customer: SE Role-Play & POC Environment Spec

> **Owner:** Eric Kufta (plays the customer, "Dana Whitfield", and grades)
> **Trainee:** Chris Bickram, Sales Engineer
> **Source brief:** "Role-Play Brief: Cast AI SA Discovery & Value Pitch" (Chris Bickram → Eric, 2026-11-03). That brief supersedes the earlier Parcelwise spec; this file carries the build requirements and the planted problems forward.
> **Audience for this spec:** Eric, and anyone or anything building the environment. **Do not share the trap sections with the trainee.** Only the brief in [trainee-brief.md](trainee-brief.md) is safe to share.

---

## 1. Goal

Give Chris a realistic end-to-end rehearsal of a mid-market-to-enterprise Cast AI motion: **discover, pitch the value, propose a POC**, and then, if Eric (as Dana) says yes, actually run that POC on a real cluster.

The customer is fictional (NRG, a $1.2B omnichannel retailer on AWS, GCP and Azure). Eric role-plays its VP of Platform Engineering. The POC runs on one real EKS cluster, `nrg-stag-us-east-1`, which mirrors the crown-jewel `nrg-prod-us-east-1`. Chris connects it with `castctl`, enables the autoscaler and Workload Autoscaler (WOOP), and has to get through the same five planted problems as before.

**What changed from the Parcelwise version**

| | Parcelwise (old) | NRG (this spec) |
|---|---|---|
| Opening | Discovery call with a platform lead | 45-60 min live role-play with the **VP of Platform Eng (economic buyer)**: discover, pitch, propose POC; debrief; Eric decides move to POC / need more / no |
| Customer | $90k/mo, AWS only, 3 EKS clusters | ~$310k/mo, ~9 clusters on EKS + GKE + AKS, AWS EDP commitment |
| Pain | Cost, board ask | **20% (~$62k/mo) cost cut + a hidden SLO breach that caused blanket over-provisioning** |
| Competition | none | Karpenter (DIY, mid-trial on staging), ScaleOps |
| Objections | none scripted | "only need to rightsize once"; "no lock-in / no vendor-caused incident"; security concerns |
| Nodes | Managed node group, m6i | **Self-managed** node groups: `general` (m5), `memory` (r5), `burst` (c5), plus OSS Cluster Autoscaler, as in prod |
| Stateful | postgres | Elasticsearch **and** in-cluster Postgres, both on EBS |
| Install | Cast AI onboarding script, kubectl for traps | **`castctl`**, and everything on the cluster delivered by **Argo CD** (GitOps) |
| Trap toggling | `kubectl apply` | A Git change to a Kustomize overlay, synced by Argo CD |

**What we're testing**

1. **Discovery quality.** The hidden pain (SLO breach, over-provisioning), the budget path (CTO signs on Dana's recommendation), the competitors, and the stack facts that pre-empt traps: "Does anything rely on the node IAM role?", "How do your services size concurrency?", "Any single-replica workloads with PDBs?"
2. **Value mapping.** Tying Cast AI to *this* pain (rightsizing continuously, bin-packing, a safe stateful story, commitments utilization for the EDP) instead of a feature dump.
3. **Objection handling.** "Rightsize once" (workloads drift, the SLO breach is exactly what continuous rightsizing guards) and "vendor-caused incident" (read-only first, automation only on say-so, exit path, ask-before-change). Trap 5 is the second objection made real.
4. **Troubleshooting beyond the dashboard.** At least two traps leave Cast AI looking healthy. The hard traps are deliberately invisible to snapshot analysis.
5. **Customer handling and the close.** Ask before changing anything, explain tradeoffs, propose a scoped POC with 2-3 success metrics, and leave the decision with the customer.

**Out of scope as built:** Karpenter (discussed as a competitor and a "trial on staging" story; not installed, because it would fight the Cluster Autoscaler and Cast AI), the GKE and AKS clusters and the prod EKS cluster (fictional context only), commitments tooling beyond a discovery conversation, and GPU workloads.

---

## 2. Format & phases

| Phase | What happens | Traps in play | Exit gate |
|---|---|---|---|
| 1. Role-play: discover → pitch → close | 45-60 min. Chris interviews Dana (Eric), maps value to the pain he earned, proposes a scoped POC. No environment needed. | Discovery can pre-empt traps 2, 3 and 5 | Eric decides: ☐ move to POC ☐ need more ☐ no. Debrief with the §6 rubric. |
| 2. Connect (read-only) | `castctl` connects `nrg-stag-us-east-1` read-only; Chris runs the cluster checks | Traps 1 and 4 visible | Chris presents findings and a pre-flight plan |
| 3. POC: autoscaler | Automation enabled via `castctl`; initial rebalance | Traps 1, 2 and 3 | Rebalance completes with all workloads Ready |
| 4. GitOps handoff (optional) | The Cast AI umbrella chart is handed to Argo CD so mode changes become Git changes | Cluster Autoscaler extra | Argo shows `castai` Healthy |
| 5. POC: WOOP | WOOP on the agreed workloads | Traps 4 and 5 (trap 5 surfaces ~1 day later) | Savings with no regressions |
| 6. Readout | Results and recommendations to Dana (and the CTO) | n/a | Graded against §6 |

---

## 3. Customer profile

### 3.1 Shareable brief
See [trainee-brief.md](trainee-brief.md). It is Chris's own §3-§4 (facts only, no pain).

### 3.2 Customer script (Eric only)

**Dana Whitfield, VP Platform Engineering.** Economic buyer. Owns the K8s budget and the platform org (~25 people). Accountable for the annual cloud line. Reports to the CTO, who signs off but takes her recommendation. Busy, skeptical, will push back.

**Canvas (from Eric's §5 of the brief)**
- **Primary pain:** costs have risen significantly; Dana has been told to cut K8s spend by **20%**.
- **Hidden pain:** an **SLO was breached a few months ago**. The response was to over-provision heavily so it can't happen again. That is what's driving the cost.
- **Impact:** about **$62,000/month** in avoidable cost. No time impact: it's so over-provisioned nobody worries about capacity.
- **Drivers:** cost this quarter; last quarter was the incident. Trigger: rising spend caused by the over-provisioning.
- **Budget:** CTO signs, on Dana's recommendation. Competing priorities: DIY Karpenter, headcount.
- **Competitors:** Karpenter (trial on staging), ScaleOps.
- **Success metric:** reduce K8s cost by 20% (~$62k/mo).
- **Objections:** "I only need to rightsize once and we're good." "I don't want to be locked in, or have an external vendor cause an incident." Plus the stock ones: "we already have Cluster Autoscaler", "security won't approve another agent", "we're mid-Karpenter trial", "we tried a cost tool before".
- **Decision:** CTO must say yes; results needed this quarter. **No** if security isn't satisfied. **Yes** if the POC is read-only first, scoped, and measured against the 20% target without touching the SLO.
- **Stakeholders to voice (names are yours to pick):** FinOps / cloud finance lead (asks how savings interact with the AWS EDP), SRE / reliability manager (owns the SLO, will ask about blast radius), acquired-unit (Fenwick) app-team lead. `[Eric: name these]`

**Say freely:** costs are up and I have a 20% target; nodes are over-provisioned; I have ~9 clusters across three clouds; we're trialling Karpenter on staging.

**Reveal only when earned** (the trainee asks a good question):

| If the trainee asks… | Dana says… | Pre-empts |
|---|---|---|
| What broke recently / why is spend up? | "We breached an SLO last quarter. We over-provisioned to make sure it never happens again, and now I'm paid to take it back out." | Hidden pain |
| What does it cost you? | "About $62k a month of it is just padding." | Impact |
| Who signs, what else competes for the money? | "My CTO signs, but he'll take my recommendation. I'm also weighing DIY Karpenter and a headcount." | Decision process |
| Does anything depend on the node IAM role / how do apps get AWS creds? | "Notifications decrypts its config with KMS using the node role. We never got around to IRSA. Staging nodes run under a custom role, `nrg-stag-app-node-role`." | Trap 2 (hints at 3) |
| Any IMDS / launch template hardening? | "Security made us require IMDSv2. Our launch templates set hop limit 2 so pods can still reach it." | Trap 3 |
| Any single-replica workloads / PDBs? | "The session cache Redis is one replica, and someone put a PDB on it. It's just a cache, restarting is fine." | Trap 1 |
| Any HPAs? | "checkout-api scales on CPU at 50%." | Trap 4 |
| How do services size threads / workers / concurrency? | "routing-engine auto-tunes its worker count to the CPU it's given. The team was proud of that." | Trap 5 |
| Stateful workloads? | "Elasticsearch and a few Postgres instances on EBS. Nobody touches them." Opens the Live Migration / Spot conversation. | Stateful story |
| Will Argo CD fight WOOP? | Have them explain it. WOOP mutates at admission, so manifests in Git don't drift. (Argo CD **is** installed in this env, so they can show it.) | n/a |
| How do savings interact with the EDP? | FinOps pushes. Trainee should explain EDP is a spend commitment, so reduced usage can eat into discount-tier headroom; model it, don't overclaim. | n/a |
| Karpenter? | "We're trialling it on staging." Test whether Chris can compare it fairly (no workload rightsizing, no SLO-aware guardrails, you own the upgrades). | Competitor |

**POC success criteria** (make Chris pull these out of you; don't volunteer them):
- Cut K8s compute cost by **20%** (staging, on the way to ~$62k/mo account-wide) within the POC window
- **Zero SLO breaches / customer-visible incidents**
- WOOP running on at least 5 workloads
- A safe story for stateful workloads (Elasticsearch, Postgres)
- An exit path: no lock-in, nothing the vendor does that can't be switched off

---

## 4. Environment build requirements

### 4.1 Infrastructure (Terraform)

- **Cluster:** EKS 1.35 `nrg-stag-us-east-1` in us-east-1, 3 AZs, private + public subnets. Staging counterpart of prod `nrg-prod-us-east-1`.
- **Node pools:** three **self-managed** node groups, AL2023 (cgroup v2, which trap 5 needs), on-demand, mirroring prod's pools at staging scale:
  - `nrg-stag-ng-general`: 2-4 × m5.xlarge (desired 3)
  - `nrg-stag-ng-memory`: 1-3 × r5.large (desired 2)
  - `nrg-stag-ng-burst`: 1-3 × c5.xlarge (desired 1)
  - All nodes carry label `nrg.io/pool=<pool>`; the memory-heavy stateful workloads softly prefer `memory`.
- **Node IAM role:** `nrg-stag-app-node-role` with the standard EKS worker, CNI, ECR and SSM policies **plus** an inline `kms:Decrypt` on `alias/nrg-stag-app`, wrapped in instance profile `nrg-stag-app-node-profile` and shared by all three pools. Launch templates: IMDSv2 required, **hop limit 2**.
- **KMS:** customer-managed key `alias/nrg-stag-app`. A KMS ciphertext is written into a ConfigMap (committed to Git) for trap 2.
- **Cluster Autoscaler:** the OSS Cluster Autoscaler, auto-discovering the three ASGs by tag, as in prod.
- **Argo CD:** installed by Terraform (Helm). Every other add-on and all workloads are Argo CD Applications from this repo (see §4.4).
- **Over-provisioning:** staging is deliberately over-provisioned so there is a real savings story (and it models the SLO-breach padding).

### 4.2 Workloads

| Namespace | Workload | Purpose |
|---|---|---|
| `checkout` | `checkout-api` Deployment + HPA + steady load generator | Trap 4 |
| `routing` | `routing-engine` worker Deployment + its own `redis-queue` + job producer | Trap 5 (order-to-store routing) |
| `notifications` | `notifications` Deployment with a KMS init container, 2 replicas | Traps 2 and 3 |
| `cache` | `redis` (session cache) Deployment, 1 replica, zero-disruption PDB | Trap 1 |
| `label` | `label-renderer` Deployment | Filler / optional zone trap |
| `db` | `postgres` StatefulSet on EBS gp3 | Stateful + Spot / Live Migration conversation |
| `search` | `elasticsearch` StatefulSet (single node) on EBS gp3 | Stateful + Live Migration conversation |
| `ingress-nginx` | ingress-nginx | Realism |

Requests on everything are inflated (roughly 2-4× actual usage) so both the autoscaler and WOOP have savings to show.

*Honest limit:* the story says prod is a Java/Spring, Node.js, Go and Python mix. The staging workloads are one small Python image plus stock Redis, Postgres and Elasticsearch images. Dana tells the language story; the environment doesn't reproduce it. The JVM `availableProcessors` / Go `automaxprocs` / gunicorn variants of trap 5 are talking points.

### 4.3 Images to build

1. **`nrg-worker`**: one small Python image with two modes: `http` mode for checkout-api (~20ms CPU per request) and `queue` mode for routing-engine (see trap 5).
2. **`nrg-loadgen`**: produces HTTP load at a fixed rate (checkout-api) or pushes jobs to Redis at a fixed rate (routing-engine), and exposes **queue depth** on `/status` so Eric can "notice" the backlog as the customer.

### 4.4 Install: castctl and GitOps

**Platform and workloads: Argo CD.** Terraform installs Argo CD and writes the few files that depend on cloud state (the Cluster Autoscaler Application with its IRSA role, the KMS ciphertext ConfigMap, the Application manifests carrying the repo URL). After the repo is pushed, `scripts/bootstrap-gitops.sh` applies one root Application (app-of-apps) and Argo CD installs metrics-server, the Cluster Autoscaler, ingress-nginx and the workloads from `manifests/overlays/staging`. The trap switchboard is that overlay: each trap is one tagged line pointing at `traps/<x>` (armed) or `safe/<x>` (defused).

**Cast AI: castctl, by hand.** Chris runs `castctl cluster connect` himself: read-only first (agent + kvisor only), then automation (node autoscaler + Workload Autoscaler). There are deliberately no wrapper scripts for anything he is meant to work out. `castctl` creates the IAM role, the CAST-generated instance profile (`cast-nrg-stag-us-east-1-eks-*`, the trap 2 default) and installs the umbrella chart `castai-helm/castai` in `castai-agent`. Optionally `--import-config` turns the three node groups into Cast AI node templates.

**Cast AI under GitOps (optional phase 4).** Chris reads the live release (`helm get values`), commits values without secrets (`apiKeySecretRef`) and an Argo CD Application, and hands ownership over; [guides/03-argo-handoff.md](guides/03-argo-handoff.md) is the answer key. From then on the Cast AI mode (`tags.readonly` → `workload-autoscaler` → `node-autoscaler`/`full`) is a Git change.

**Facilitator side.** The node-configuration traps (2, 3, zone) are armed with a small Terraform module, `castai/terraform`, applied after Chris enables automation (it creates a second node configuration and makes it the default). Answer keys for everything Chris does by hand are in [guides/](guides/).

**Consequences of GitOps worth knowing**
- A `kubectl scale`/`apply` on an Argo-managed object is reverted by self-heal. The Cluster Autoscaler fix ("scale it to 0") is a Git change (`replicaCount: 0`). That is a good teaching moment, not a bug.
- `checkout-api`'s replica count belongs to its HPA, so the workloads Application ignores `/spec/replicas` on it. Without that, Argo and the HPA fight.
- WOOP mutates pods at admission (and resizes in place), so Deployments in Git don't drift. That is the answer to "will Argo fight WOOP?"

---

## 5. Traps

There are five traps: two easy and three hard, one of which is the super challenge. During the first rebalance, the order he hits them in is roughly trap 1, then trap 3, then trap 2 (see the note in trap 3).

### Trap 1 — Zero-disruption PDB on the Redis cache · Easy · Autoscaler/rebalance

**Setup:**
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: { name: redis-pdb, namespace: cache }
spec:
  minAvailable: 1
  selector: { matchLabels: { app: redis } }
# redis Deployment: replicas: 1
```

- **Symptom:** The initial rebalance stalls draining the node that hosts Redis. The rebalance plan flags it as a problematic workload.
- **Detection:** `scheduling-constraints-check` (#1), and the rebalance plan UI.
- **Expected resolution:** Trainee **asks the customer** whether Redis is safe to restart (Dana says yes). Then they change the PDB to `maxUnavailable: 1` or exclude the workload from the rebalance.
- **Grading signal:** Did they ask before changing it?

### Trap 2 — Instance profile without KMS permissions · Hard · IAM / autoscaler

**Setup:**
- `notifications` has an init container:
  ```yaml
  initContainers:
  - name: fetch-config
    image: amazon/aws-cli:2.17.0
    command: ["sh","-c","aws kms decrypt --key-id alias/nrg-stag-app --ciphertext-blob fileb:///cfg/config.enc --query Plaintext --output text > /dev/null"]
    volumeMounts: [{ name: cfg, mountPath: /cfg }]
  ```
- Leave the CAST AI default node configuration on the onboarding-generated instance profile (`cast-nrg-stag-us-east-1-eks-*`), which has no KMS access.

**Symptom:** CAST AI nodes launch, join and look healthy. `notifications` pods on CAST AI nodes go into `Init:CrashLoopBackOff` with `AccessDeniedException ... kms:Decrypt`. The rebalance can't finish because the replacement pods never become Ready.

**Why it's hard:** It only fails on new nodes. CAST AI shows green, and the error lives in pod logs and in AWS.

**Detection path:**
1. Pod events and logs on the new nodes.
2. Compare the instance profile on the new nodes with the one on the node group.
3. CAST AI node configuration → instance profile ARN.

**Expected resolution:**
- Point the node configuration's instance profile ARN at the customer's profile for `nrg-stag-app-node-role` (the role is already mapped via the EKS access entry the `general` node group creates).
- Recommend IRSA or EKS Pod Identity as the long-term fix.

**Optional extra layer:** Give the trainee a typo'd ARN, or a profile for a role that isn't mapped in `aws-auth`/access entries. Nodes then either fail to launch (invalid profile) or launch but never register, and the rebalance times out.

**Pre-empted by:** the discovery question "how do apps get AWS credentials?"

### Trap 3 — IMDS hop limit on CAST AI nodes · Hard · IAM / autoscaler

**Setup:** In the CAST AI node configuration, set IMDSv2 required with **hop limit 1**. The customer's launch template uses hop limit 2.

**Symptom:** On CAST AI nodes, pods can't reach IMDS, so `notifications` fails with `Unable to locate credentials` (or a timeout) instead of `AccessDenied`. Host processes are unaffected, so the node looks fine.

**Sequencing note:** Because pods can't get any credentials, this error shows **before** trap 2's `AccessDenied`. The intended experience:
1. He fixes the hop limit.
2. The error changes to `AccessDenied` and he thinks the fix failed.
3. He finds trap 2.

If you'd rather have him hit KMS first, enable trap 3 only after trap 2 is fixed.

- **Expected resolution:** Set the hop limit to 2 in the CAST AI node configuration (matching the launch template), or move to IRSA/Pod Identity.
- **⚠ Verify before building:** Confirm the node configuration that `castctl cluster connect` creates exposes IMDS settings (hop limit / IMDSv1 toggle) and check its default.

### Trap 4 — HPA on CPU fighting WOOP · Easy · WOOP

**Setup:**
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: { name: checkout-api, namespace: checkout }
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: checkout-api }
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource: { name: cpu, target: { type: Utilization, averageUtilization: 50 } }
```
The load generator keeps checkout-api at a steady, moderate load.

- **Symptom:** After WOOP lowers the CPU requests, utilization percentages jump and the HPA scales out. Replica count climbs and the net savings flatten or go negative.
- **Detection:** `hpa-target-utilization-check`, and the HPA indicator in the WOOP UI.
- **Expected resolution:** Use WOOP's HPA-aware handling, or vertical-scale memory only while the HPA owns CPU. Explain the tradeoff to the customer.
- **⚠ Verify:** the current WOOP default behavior for workloads that have a CPU-based HPA.

### Trap 5 — Self-throttling worker "death spiral" · Super challenge · WOOP

**Concept:** `routing-engine` sizes its worker pool from its own CPU request. When WOOP rightsizes it, the pool shrinks, throughput drops and CPU usage falls further. WOOP then recommends even lower, and the queue backs up. Every CAST AI signal looks healthy and the workload looks like a savings win. The only evidence is a business metric (queue depth) that Eric reports as the customer.

**Job model** (this is what makes the spiral real):
- Each job takes about **100ms of CPU plus about 900ms of simulated downstream I/O** (sleep), so each worker handles about 1 job/s.
- The producer pushes about **6 jobs/s**.
- At `requests.cpu: 2`, the pool has 8 workers and capacity is about 8 jobs/s. Usage is about 0.6 cores, or 30% of the request, which looks over-provisioned (the bait).
- After WOOP drops the request to about 600–700m, the pool has about 2–3 workers and capacity is about 2–3 jobs/s, below the arrival rate. The queue grows while usage falls to about 0.25 cores. WOOP lowers again and the spiral continues.

**Difficulty levels** (pick one):

| Level | How the worker count is derived | Visibility |
|---|---|---|
| Hard | Downward API: `resourceFieldRef: { resource: requests.cpu, divisor: 1m }` → `WORKERS = CPU_REQUEST_MILLI / 250` | Visible in the pod spec. A careful reviewer or a well-prompted LLM can spot it. |
| **Super (recommended)** | Entrypoint reads `/sys/fs/cgroup/cpu.weight` (cgroup v2, derived from the CPU request) → `WORKERS = round(weight / 10)`. On a 2-core request the weight is about 79 → 8 workers; on 600m it's about 24 → 2 workers. | Not in the spec. He has to ask Dana how the service sizes workers, or exec in and read the code. |

**Customer symptom (Eric delivers this about 1 day after WOOP is enabled):** "Since Tuesday the order-routing queue keeps backing up and ship-from-store ETAs are slipping. Did you change something?"

**Detection path:**
1. Correlate when the backlog started with WOOP apply events or the policy change history for `routing-engine`.
2. Notice that **CPU usage dropped after rightsizing**. CPU-bound work doesn't use less CPU when you give it less, so that's the tell.
3. Find that concurrency is coupled to the request, by asking the customer or reading the code.

**Expected resolution:**
- **Immediate:** Exclude `routing-engine` from WOOP, or set a minimum CPU floor in its scaling policy, and restore the request.
- **Real fix:** Decouple concurrency from requests (a fixed `WORKERS` config, or scale on queue depth with KEDA). Then rightsize on true usage.
- **Talking point:** The same failure hits JVM `availableProcessors`, Go `automaxprocs` and gunicorn worker formulas. The readout should turn this into a customer-facing pre-flight check.

**⚠ Verify before building:**
- That WOOP's minimums and its apply mode (immediate vs. deferred) on the chosen policy actually let the request drop far enough.
- The cpu.weight formula on the AL2023 kubelet: weight = 1 + ((shares − 2) × 9999) / 262142, where shares = millicores × 1024 / 1000.
- That the container sees its own cgroup at `/sys/fs/cgroup`.

### 5.6 Optional extras (not part of the core five)

- **Cluster Autoscaler still running:** Leave the OSS Cluster Autoscaler running with the three self-managed ASGs at their minimums (2/1/1). After the rebalance it scales the node groups back up and fights CAST AI. Expected fix: **in Git**, set `replicaCount: 0` on the `cluster-autoscaler` Application (a `kubectl scale` is reverted by Argo self-heal), and adjust the ASG min/max.
- **Zone mismatch:** Give `label-renderer` a `topologySpreadConstraint` with `DoNotSchedule` and `maxSkew: 1` across 3 AZs, and list subnets from only 2 AZs in the CAST AI node configuration. Pods go Pending after the rebalance. Detection: `scheduling-constraints-check` (#8) plus the node configuration subnets.

---

## 6. Grading rubric

### 6a. Role-play (phase 1): Chris's own scorecard, 1-5 each

Framed the meeting / set the agenda · Discovery quality (open → depth → quantification) · Identified pain and impact (the 20% / $62k target **and** the SLO-breach-driven over-provisioning) · Identified economic buyer and decision process (Dana recommends, CTO signs, security gates) · Mapped value to *their* pain, not a feature dump · Handled objections ("rightsize once", lock-in / vendor-caused incident, Karpenter, ScaleOps) · Proposed a crisp, low-risk next step (read-only first, 2-3 success metrics, leave the decision with Dana) · **Overall SA readiness**. Then: three things done well, three to change, and Eric's decision (☐ move to POC ☐ need more ☐ no).

### 6b. POC execution (phases 2-6)


| Area | Strong | Weak |
|---|---|---|
| Discovery | Uncovers node-role/KMS, IMDS, PDB, HPA and worker-sizing context **before** enabling anything. Gets the success criteria and stakeholders. | Jumps to the demo. Learns about the traps only when they break. |
| Pre-flight | Runs the cluster checks, presents findings, and gets agreement on changes | Enables the autoscaler blind |
| Trap 1 | Asks before modifying the PDB | Deletes the PDB unilaterally |
| Traps 2 and 3 | Goes from pod logs to node identity to the node configuration. Recommends IRSA/Pod Identity. | Blames CAST AI or escalates without evidence |
| Trap 4 | Explains HPA and WOOP interaction and picks a policy deliberately | Disables WOOP on the workload with no explanation |
| Trap 5 | Correlates the timeline, spots that usage fell, and finds the coupling | Says "CAST AI shows it's healthy" |
| Customer handling | Calm and transparent. Turns incidents into trust-building moments. | Defensive, or hides issues |
| Readout | Savings with evidence, risks found, and a prod rollout plan with pre-flight checks | Savings number only |

---

## 7. Deliverables

```
nrg-mock-poc/
├── spec.md                      # this file
├── terraform/                   # VPC, EKS, 3 self-managed node groups, node role + KMS, KMS key, ECR, CA IRSA, Argo CD,
│                                # and the generated GitOps files
├── images/
│   ├── nrg-worker/              # http + queue modes; Hard/Super worker-sizing switch
│   └── nrg-loadgen/             # HTTP load + job producer + queue-depth endpoint
├── manifests/
│   ├── base/                    # namespaces, workloads, ingress, postgres, elasticsearch
│   ├── traps/<id>/              # armed variants, one Kustomize dir each
│   ├── safe/<id>/               # defused variants under the same object names
│   └── overlays/staging/        # the trap switchboard Argo CD syncs (+ generated images/ConfigMap)
├── gitops/
│   ├── bootstrap/root-app.yaml  # app-of-apps (generated)
│   ├── apps/                    # Applications: platform (CA, metrics-server, ingress-nginx) + workloads
│   └── (castai/ is Chris's to create in the Argo handoff)
├── castai/terraform/            # facilitator-only: arms the Cast AI node configuration (traps 2/3/zone)
├── guides/                      # facilitator answer keys: castctl connect, node-config traps, Argo handoff
├── trainee-brief.md             # Chris's facts-only brief (§3-§4 of his document)
├── facilitator-guide.md         # script, trap cards, rubric
└── reset.sh                     # restore traps for the next run; teardown
```

**Build acceptance:**
- Each trap reproduces its symptom on a fresh build.
- Each documented fix clears it.
- Traps can be toggled independently (by Git change).
- The environment can be reset for the next run in under 30 minutes.

## 8. Open items

- [ ] Name the FinOps lead, SRE manager and Fenwick app-team lead (brief §4 `[MENTOR INPUT]`).
- [ ] Confirm the Karpenter-trial story: built as story-only (not installed). Install a Karpenter nodepool as a decoy only if you want a live comparison.
- [ ] Push this repo to GitHub and set `gitops_repo_url` (Argo CD needs a remote; private repo needs credentials registered in Argo).
- [ ] Verify `castctl cluster connect` behaviour end to end on a live build: the read-only flag combination, that re-running with the premium flags upgrades in place, and the IMDS fields it writes on the node configuration (trap 3).
- [ ] Verify WOOP default behaviour with a CPU HPA (trap 4).
- [ ] Verify WOOP policy minimums and apply mode, and the cpu.weight math on AL2023 (trap 5).
- [ ] Choose trap 5's difficulty (Hard or Super; Super is the default).
- [ ] Decide whether trap 2's extra layer (bad ARN / unmapped role) is on.
- [ ] Decide the AWS account/budget and a teardown schedule.
