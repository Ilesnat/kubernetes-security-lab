# ROLE
You are a senior Kubernetes security engineer, DevOps automation expert, and the ORCHESTRATOR of
a small team of specialist sub-agents. Build me a self-contained, reproducible Kubernetes
security research lab that I can spin up with a single command — either LOCALLY or in AZURE —
run offensive tests against, and tear down cleanly and completely. This is for legitimate,
isolated, self-owned security research and learning: a deliberately vulnerable ("defective")
environment. I will store it in a PRIVATE GitHub repo and clone it across machines and Azure
Cloud Shell.

# DEPLOYMENT AUTHORITY — build only, do NOT deploy to Azure
- Your job is to GENERATE the repo (scripts, manifests, docs) so it is complete and ready for me
  to deploy at a moment's notice. Do NOT actually deploy to the cloud yourself. Never run any
  command that creates, modifies, or costs Azure resources — specifically never run
  `az group create`, `az aks create`, `up.ps1 -Backend aks`, or anything that provisions Azure.
- I will run all Azure deployments myself, manually, when I choose to. When you finish, hand me
  the exact commands to run; do not run them on my behalf.
- Local kind testing: you MAY run kind/kubectl commands to validate scripts ONLY if you have a
  local Docker environment AND you tear everything down afterward. If unsure, do NOT run
  anything — just produce the files and tell me how to test them.
- The end state I want: a finished repo where, later and on my own, I can run one command to
  deploy locally or to Azure. This first pass BUILDS that; it does not execute the cloud deploy.

# EXECUTION MODEL — orchestrate with sub-agents; do NOT one-shot this
This project is large. Do not attempt to produce everything in a single pass. Instead, act as an
orchestrator that decomposes the work into phases and delegates to specialist sub-agents, with
review gates between phases. If your environment cannot literally spawn sub-agents, SIMULATE them
as clearly labeled internal roles and perform each role's pass explicitly and separately.

Sub-agent roles:
- ARCHITECT: designs the folder tree, backend-dispatch model, and phase plan. Produces the plan
  the others execute against.
- INTENT-REVIEWER: before building, restates MY intent and success criteria in its own words and
  checks the Architect's plan against them. Flags any drift from: push-button up/down, complete
  cloud teardown, cost control on a $150/mo credit, correct subscription targeting, build-only
  (no unsolicited cloud deploy), teaching notes per scenario, and private-repo safety. The build
  does not proceed until intent is confirmed aligned.
- BUILDER(s): implement one phase at a time (e.g. one builder for cluster provisioning, one for
  scenarios, one for tooling, one for docs). Each builder produces real file contents for its
  slice only.
- SECURITY-REVIEWER: after each phase, reviews the produced files for correctness AND for the
  safety guardrails (no public exposure, no secrets committed, fail-fast on wrong subscription,
  teardown completeness, build-only respected). Reports issues; builder fixes before moving on.
- COST-REVIEWER: reviews all AKS-related output specifically for cost safety (cheapest viable
  config, auto-destroy, cost printing, no orphan resources). Must sign off before AKS phase is
  considered done.
- INTEGRATION-REVIEWER: at the end, verifies the phases fit together (scripts reference real
  files, up/down/reset/status are consistent, README quickstart actually matches the built
  files) and that nothing was left as a stub.

Process:
1. ARCHITECT proposes the phase plan + folder tree.
2. INTENT-REVIEWER confirms alignment with my goals (or requests changes) BEFORE any building.
3. Build PHASE BY PHASE. After each phase, the relevant reviewer(s) pass and issues are fixed.
4. Recommended phase order (each phase independently usable):
     Phase 1: Repo skeleton + kind backend + up/down/status dispatcher + 2 starter scenarios
              (RBAC escalation, privileged escape) + README + .gitignore + .env.example.
     Phase 2: Remaining local scenarios (3-8) with full per-scenario READMEs.
     Phase 3: AKS backend (create/destroy scoped to one resource group) + cost controls +
              subscription fail-fast + the AKS-only cloud-metadata/managed-identity scenario.
     Phase 4: Tooling (scanners, Peirates, Falco, audit logging) + one-liners to run them.
     Phase 5: Docs polish, learning path, scenario index, integration review, final sign-off.
5. Announce which phase and which sub-agent is acting at each step so I can follow along.
6. Do not silently skip a phase or leave TODO stubs; if you must defer, say so explicitly.

# HIGH-LEVEL GOAL
"Push a button, have it deployed, then go do tests." I want:
- One command to create the cluster + deploy all vulnerable scenarios + install tooling.
- One command to DESTROY everything with zero leftovers (critical for cloud — no orphaned
  resource groups, load balancers, public IPs, disks, or clusters).
- The SAME vulnerable scenarios and tooling deploy to either backend unchanged.
- Per-scenario notes explaining each vulnerability, why it matters, how to exploit it, and how
  to detect/remediate it — the lab teaches me as I use it.

# ENVIRONMENT
- I'm at Microsoft; local host is Windows 11 + Docker Desktop (WSL2). PowerShell-first commands;
  bash in WSL/Git Bash where cleaner.
- Pluggable cluster backend, selected by a flag/variable:
    BACKEND=kind -> local Kubernetes-in-Docker (disposable, multi-node)
    BACKEND=aks  -> Azure Kubernetes Service via Azure CLI
- Tools I'll install: Docker, kind, kubectl, helm, Azure CLI. Give exact Windows install steps.
- Azure target is my PERSONAL Visual Studio Enterprise Subscription:
    Subscription ID: 4148d6cd-aa0f-4883-a849-69aa073d0c68
    Tenant: nateiles1132gmail.com.onmicrosoft.com (personal, NOT Microsoft corporate)
  This subscription has a ~$150/month Visual Studio Azure credit — money IS a concern, so cost
  control is a first-class requirement, not an afterthought.
- Every AKS script must, before creating anything:
    * read the target subscription ID from .env,
    * run `az account show` and FAIL FAST if the active subscription ID does not match
      4148d6cd-aa0f-4883-a849-69aa073d0c68, printing a clear "wrong subscription" error,
    * so I can never accidentally deploy the vulnerable lab into the wrong tenant/subscription.

# LOCAL RUNTIME (Docker Desktop + kind)
- Use kind as the local Kubernetes, running on Docker Desktop as the container engine. kind is
  the preferred local backend because it supports multi-node clusters, realistic node/kubelet
  boundaries for container-escape scenarios, fast full resets, and config-as-code — all better
  for security research than Docker Desktop's single-node built-in Kubernetes.
- Do NOT rely on Docker Desktop's built-in Kubernetes feature; kind is independent. Tell me to
  leave that toggle OFF to save resources.
- Docker Desktop must be RUNNING for the kind backend. `up.ps1` must pre-flight check that:
    * Docker is running (fail with a clear message if not),
    * enough resources appear available for a multi-node kind cluster + Falco + several scenario
      pods, and warn if low.
- In README prerequisites, recommend Docker Desktop resource allocation (>=4 CPU, >=8 GB RAM,
  a few GB free disk) and give the exact Settings path to change it on Windows.
- Provide a multi-node kind config (1 control-plane + 2 workers) so node-boundary and escape
  scenarios are meaningful, with instructions to drop to a single node if my machine is limited.
- Handle local images correctly: use `kind load docker-image` for any locally built image, set
  imagePullPolicy appropriately, and never depend on :latest.

# CLOUD (AKS) REQUIREMENTS — teardown is critical
- Put EVERYTHING in a single dedicated resource group (e.g. rg-k8s-sec-lab) so teardown is one
  `az group delete` that removes the cluster AND every dependent resource (node RG, LBs, IPs,
  disks, NSGs). Verify nothing is left behind.
- Private or IP-restricted by default: lock API server + any exposed service to MY IP only
  (never 0.0.0.0/0). A vulnerable cluster must never be internet-reachable.
- Idempotent up/down. `down` must succeed even after a partial failure (delete-by-RG,
  ignore-not-found). Provide a `status` command showing what's deployed and whether a cloud
  cluster is running.

# COST CONTROL (hard requirement — ~$150/mo credit, treat as scarce)
- Default to the cheapest working AKS config: 1 node, Standard_B2s (burstable), ephemeral OS
  disk, Standard_LRS, no autoscaler, no extra add-ons. Control plane on the free tier.
- On `up`, print estimated $/hour and $/day, and a "remember to run down" reminder.
- `--auto-destroy <hours>` (default 3) that guarantees teardown even if I forget.
- `status` must show whether a cluster is live and its estimated accrued cost this session.
- README "Cost" section with a table of node sizes vs $/hr and the golden rule: always `down`
  at the end of a session; never leave a vulnerable cluster running.

# DELIVERABLES (real files, Git repo layout)
  k8s-sec-lab/
    cluster/
      kind/           # kind config (1 control-plane + 2 workers) + create/destroy
      aks/            # az CLI create/destroy scripts, scoped to one resource group
    scenarios/        # one folder per vuln, manifests + README (backend-agnostic)
    tooling/          # scanners + runtime detection install manifests/scripts
    scripts/          # top-level up/down/reset/status that dispatch on BACKEND
    docs/             # architecture, learning path, how-to-add-a-scenario
    .env.example      # all env-specific values templated here
    .gitignore
    LICENSE
    README.md
- Push-button entry point: `up.ps1 -Backend kind|aks` (and/or `make up BACKEND=aks`) that
  creates the cluster, waits for readiness, deploys every scenario, installs tooling, and prints
  a summary of what's running + how to reach each scenario + how to tear down.
- `down.ps1 -Backend ...` fully deletes everything. `reset` for fast wipe + redeploy.

# VULNERABLE SCENARIOS (isolated, independently toggleable, one namespace each)
  1. RBAC privilege escalation (over-permissive ClusterRoleBinding to cluster-admin; a
     low-priv service account that can escalate).
  2. Privileged container / container escape (privileged: true, hostPID, hostNetwork).
  3. Mounted Docker/containerd socket (/var/run/docker.sock) enabling host takeover.
  4. hostPath mount escaping to the node filesystem.
  5. Secrets exposure (secrets in env vars + ConfigMaps, readable across pods).
  6. Missing NetworkPolicies (flat network, pod-to-pod lateral movement).
  7. Exposed/insecure kubelet or anonymous API access.
  8. Vulnerable web app (SSRF/RCE) as an initial-access foothold that chains into the above.
  9. AKS-only: cloud metadata / IMDS + managed-identity/node-identity abuse (real cloud path).
Optionally wire in Kubernetes Goat as additional scenarios, but ALSO give hand-built minimal
versions so I learn each defect from first principles. Note any scenario that behaves
differently on AKS vs kind.

# PER-SCENARIO README MUST INCLUDE
- What it is (plain language).
- Why it matters (real-world impact, map to MITRE ATT&CK for Containers).
- Deploy command (this scenario only).
- Exploit walkthrough (step-by-step commands + which tool: kubectl, Peirates, kube-hunter,
  kubeletctl, etc.).
- What success looks like when the exploit works.
- Detection (what it looks like in Falco / audit logs).
- Remediation (the secure config that fixes it, before/after diff).
- Difficulty rating + suggested order to attempt scenarios.

# TOOLING
- Assessment: kube-hunter, kube-bench, Trivy, kubescape.
- Post-exploitation: Peirates, kubeletctl.
- Cloud-specific: how to safely test AKS managed identity / IMDS / node identity abuse.
- Runtime detection: Falco (so I can watch attacks trigger alerts) + enable Kubernetes API
  audit logging with a sample policy.
Provide install steps and a one-liner to run each scanner against the lab.

# SOURCE CONTROL & PROJECT STORAGE
- Structure as a Git repo for a PRIVATE GitHub repo; assume cloning across machines and Azure
  Cloud Shell.
- I will create and push the private repo MYSELF. Do NOT run any git remote/push commands or
  create the GitHub repo. Produce a clean, commit-ready working tree with a complete .gitignore,
  .env.example, README, and LICENSE so my first commit is safe and self-explanatory. End with a
  short "How to publish this to your own private GitHub" note (git init / remote add / push) I
  can run when ready.
- Strong .gitignore excluding: kubeconfig files, .env/secrets, Azure creds, service principal
  JSON, *.pem/*.key, terraform state, generated cluster artifacts. Nothing sensitive committable.
- ALL environment-specific values (subscription ID, tenant ID, resource group, my IP, region,
  node size) live in `.env.example` -> copy to `.env` (gitignored). Scripts read .env; never
  hardcode identifiers in tracked files (the subscription ID above may appear only in
  .env.example as a default I can override).
- README must state: "Keep this repo PRIVATE — intentionally vulnerable configs + working
  exploit steps. Do not publish publicly without sanitizing." Plus an authorized-research-only
  disclaimer.
- Add a gitleaks (or git-secrets) pre-commit scan to block accidental credential commits.

# REPO POSITIONING & PRESENTATION
- Write the README as a proper project front page: one-line description, "authorized research
  only" disclaimer up top, architecture diagram (ASCII or mermaid), prerequisites, quickstart,
  scenario index table (name | vuln class | difficulty | local/AKS | MITRE technique), and a
  learning-path section.
- Make it skimmable and professional enough to show as a portfolio piece IF I later sanitize
  and fork a public version — but written assuming it stays private.
- Use per-scenario READMEs plus a docs/ folder so knowledge is easy to navigate.
- Consistent naming; include a "how to add a new scenario" doc so the lab is easy to extend.

# SAFETY & GUARDRAILS
- Local or cloud, the vulnerable cluster must never be publicly exposed — restrict to my IP,
  private API where possible. Offensive tools only ever target this lab.
- Cloud resources ephemeral by design; teardown complete and verifiable. Warn loudly that
  leaving a vulnerable AKS cluster exposed is a real risk to me and my employer.
- Never use production/corp credentials or a shared subscription; use ONLY my personal Visual
  Studio Enterprise Subscription (ID above) + a dedicated resource group.
- Prominent "authorized, self-owned research only" notice.

# OUTPUT FORMAT
- Start with the ARCHITECT's phase plan + folder tree, then the INTENT-REVIEWER's confirmation.
- Then build phase by phase. For each phase: name the acting sub-agent, produce the actual file
  contents (labeled by path), then show the reviewer's pass/fix notes before continuing.
- After the final phase, give a Quickstart: install prereqs -> copy .env.example to .env ->
  `up` (both kind and aks examples) -> verify -> pick scenario 1 -> `down` -> confirm zero
  leftover cloud resources.
- Then a 4-week learning path, easy -> hard, noting which scenarios to do locally vs on AKS.
- Explain key choices; call out anything I must decide.
- If you approach an output-length limit, STOP at a phase boundary and tell me to say "continue"
  rather than truncating a file mid-way.

# CONSTRAINTS
- Declarative YAML and idempotent scripts (safe to re-run).
- Explicit image tags, never :latest; correct imagePullPolicy for local kind.
- Each scenario independently toggleable so I can study one defect at a time.
- Teach as you go — I'm technically competent but newer to Kubernetes-specific attack/defense.

Begin: ARCHITECT, produce the phase plan and folder tree. Then INTENT-REVIEWER, confirm
alignment with my goals before any building starts.
