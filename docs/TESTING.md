# Testing the template

The release gate is a clean lifecycle test in a disposable Azure subscription:

1. Initialize the template from an empty directory.
2. Run `azd up --no-prompt`.
3. Load the neutral graph data.
4. Verify network isolation.
5. Execute a real Foundry agent MCP tool call.
6. Run `azd down --force --purge --no-prompt` and confirm the resource group is
   absent.

## Automated static checks

The `template-validation.yml` workflow runs Microsoft's gallery validator in
the Dev Container. It checks required repository files and README sections,
builds and scans the Bicep with the gallery PSRule baseline, executes `azd up`,
and executes `azd down`.

The E2E Python test is separate because a private Foundry project endpoint is
not reachable from a public GitHub-hosted runner. Run it from a private runner,
VPN-connected workstation, or VNet VM:

```bash
./load-data.sh
./test-private.sh
uv run agent/create_and_test_agent.py
```

`test-private.sh` must report that the MCP hostname is not publicly resolvable.
The agent test must show an MCP approval request for `read-cypher`, approve it,
and return turbine results from the synthetic graph.

For a disposable evaluation only, `FOUNDRY_PUBLIC_NETWORK_ACCESS=Enabled` lets
the agent SDK test run from a public workstation. It does not make MCP or Neo4j
public and it does not change Foundry agent egress. Do not use this shortcut for
sensitive data.

## Last verified deployment

On August 26, 2026, the Basic VNet deployment completed in Sweden Central with
`gpt-4.1` Global Standard at 30K TPM. The loader created 24 turbines, 288
components, 120 sensors, 28,800 readings, and 180 events. A Responses API agent
then called the private Neo4j MCP `read-cypher` tool and returned actual graph
results.

That deployment also exposed the Foundry capability-host deletion-order issue.
The repository now includes a `predown` hook based on Microsoft's official
ordered cleanup sequence. A fresh full lifecycle run is required before the
gallery submission is sent so the new teardown path is validated, not merely
reviewed statically.

## Manual release record

Record the following in the release issue without including subscription,
tenant, endpoint, IP address, or secret values:

| Check | Evidence |
| --- | --- |
| Commit | Full Git commit SHA |
| Region and model | Region, model name/version, SKU, capacity |
| `azd up` | Successful workflow/run link |
| Synthetic data | Counts reported by `load-data.sh` |
| Private DNS | Pass output from `test-private.sh` |
| MCP call | Tool name and redacted result summary |
| `azd down` | Successful workflow/run link and resource-group absence |
| Gallery validator | `CONFORMING` issue or workflow artifact |
