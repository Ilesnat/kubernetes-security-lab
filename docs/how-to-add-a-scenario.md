# How to add a scenario

1. Create `scenarios/NN-short-name/manifest.yaml` and `README.md`.
2. Put the scenario in its own namespace. Label the namespace `lab: k8s-sec-lab` and `scenario: NN-short-name`; label its pods `lab: k8s-sec-lab`.
3. Keep every exposed service `ClusterIP`. Do not add public IPs, `NodePort`, or `LoadBalancer` services. Use explicit image tags and set `imagePullPolicy` intentionally.
4. Make the vulnerable state obvious in the manifest comments, but constrain resources and avoid real credentials, keys, or production data.
5. Include what/why, MITRE ATT&CK mapping, backend differences, single-scenario deploy and cleanup commands, executable exploit proof, detection, and a before/after remediation example.
6. Confirm `./up.ps1 -Backend kind -Scenarios NN-short-name` and `./reset.ps1 -Backend kind -Scenarios NN-short-name` select only that folder. Unknown names should fail.
7. Update the scenario index and learning path. Run YAML linting and the Gitleaks pre-commit hook before committing.

Do not build an image unless the scenario needs one. If it does, pin its base image, build it locally, load it with `kind load docker-image`, and use a non-`latest` tag with an appropriate pull policy. Keep build commands and images usable from both backends or document a specific exception.
