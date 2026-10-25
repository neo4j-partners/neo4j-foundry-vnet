# Testing

Before releasing a change, run a complete lifecycle test in a disposable Azure
subscription:

1. Initialize the template from an empty directory.
2. Run `azd up --no-prompt`.
3. Load the neutral graph data.
4. Verify network isolation.
5. Execute a real Foundry agent MCP tool call.
6. Run `azd down --force --purge --no-prompt` and confirm the resource group is
   absent.

## Repository checks

The `Code quality` workflow runs linting, formatting, unit tests, and shell
syntax checks on every pull request. The manually triggered `Template
validation` workflow runs Microsoft's template validator in the Dev Container,
including the PSRule baseline, `azd up`, and `azd down`.

The E2E Python test is separate because a private Foundry project endpoint is
not reachable from a public GitHub-hosted runner. Run it from a private runner,
VPN-connected workstation, or VNet VM:

```bash
./load-data.sh
./test-private.sh
uv run agent/create_and_test_agent.py
```

`test-private.sh` must report that the MCP hostname is not publicly resolvable.
The agent test must show successful `get-schema` and `read-cypher` MCP calls and
return turbine results from the synthetic graph.

For a disposable evaluation only, `FOUNDRY_PUBLIC_NETWORK_ACCESS=Enabled` lets
the agent SDK test run from a public workstation. It does not make MCP or Neo4j
public and it does not change Foundry agent egress. Do not use this shortcut for
sensitive data.

## Release evidence

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
| Template validator | `CONFORMING` issue or workflow artifact |
