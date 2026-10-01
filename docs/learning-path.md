# Four-week learning path

Use the kind backend for the first three weeks. Each exercise is isolated by namespace; apply only the scenario you are studying when you want a smaller lab. The exploit commands are for the disposable lab only.

| Week | Location | Scenarios | Focus |
|---|---|---|---|
| 1 | kind | 01, 05, 07 | Service-account tokens, RBAC, secret handling, anonymous API authorization |
| 2 | kind | 02, 03, 04 | Privileged pods, host namespaces, runtime sockets, and node-local hostPath data |
| 3 | kind | 06, 08 | Network segmentation, lateral movement, SSRF, command injection, and runtime alerts |
| 4 | AKS | 08, 09 | Carefully observe IMDS and the node/kubelet identity boundary; then destroy and verify the resource group |

## Suggested session loop

1. Read the scenario's “What it is” and “Why it matters” sections.
2. Start or confirm the lab with `./up.ps1 -Backend kind -Scenarios <folder-name>`.
3. Follow the exploit walkthrough and record the expected proof, not unrelated cluster data.
4. Watch Falco output and API audit events when the backend supports those signals.
5. Apply the remediation example, repeat the check, and note the behavior change.
6. Run `./reset.ps1 -Backend kind -Scenarios <folder-name>` or tear down with `./down.ps1 -Backend kind`.

## AKS week: additional controls

AKS incurs charges. Before starting, verify the personal subscription in `.env`, set `ALLOWED_IP` to your current public IPv4 `/32`, and keep the session short. Scenario 09 performs read-only metadata/token checks and deliberately does not print access tokens or modify Azure resources. Do not copy returned credentials into notes or logs. After the exercise, run `./down.ps1 -Backend aks` and verify `az group exists --name <AKS_RESOURCE_GROUP>` returns `false`.
