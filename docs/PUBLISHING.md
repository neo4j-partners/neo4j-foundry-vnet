# Publishing `neo4j-foundry-vnet`

The recommended Neo4j repository name is **`neo4j-foundry-vnet`**. It describes
the durable integration—Neo4j and Microsoft Foundry inside a VNet—without
locking the repository name to the current MCP example. A future hosted-agent
or direct-driver example can be added later without renaming the template.

Use this GitHub description:

> Deploy Microsoft Foundry Basic Agent Setup with VNet injection, a private
> Neo4j MCP endpoint, and an optional private Neo4j Enterprise database using
> Azure Developer CLI.

Recommended topics:

`azd-templates`, `ai-azd-templates`, `azure`, `bicep`, `foundry`, `mcp`,
`neo4j`, `private-network`, `vnet`

## Where to publish

The best first destination is an Azure Developer CLI collection such as the AI
Apps Gallery or Awesome AZD. The project is not primarily an ARM Quickstart: it
uses azd hooks, a data loader, an SDK E2E test, and lifecycle automation.

Keep this as one Neo4j-owned repository for the first submission. A repository
root containing `azure.yaml` gives users the simplest `azd init` experience and
reduces validation configuration. If Neo4j later maintains several independent
azd templates, a monorepo can hold one folder per template and each gallery
entry can set its working directory. Do not create a VNet and a non-VNet variant
in this repository until the second design is real, deployable, and separately
tested.

## First-approval checklist

Microsoft's publishing guide requires a public GitHub repository with Issues
enabled. Complete every item before sending the collection request:

- [ ] Publish or transfer the repository to the approved Neo4j GitHub
      organization as `neo4j-foundry-vnet`.
- [ ] Confirm Neo4j approval for the Apache-2.0 license, NOTICE, trademarks,
      Enterprise evaluation language, and security/support ownership.
- [ ] Enable Issues, secret scanning, Dependabot, and branch protection.
- [ ] Add the repository description and all recommended topics above.
- [ ] Require `Template validation` on `main`; use a `develop` branch for
      post-publication feature work.
- [ ] Configure GitHub OIDC with `azd pipeline config`, then review the created
      federated credential and least-privilege role assignments.
- [ ] Configure repository variables `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
      `AZURE_SUBSCRIPTION_ID`, `AZURE_ENV_NAME`, and `AZURE_LOCATION` against a
      disposable validation subscription.
- [ ] Verify `azd init --template neo4j/neo4j-foundry-vnet` from an empty
      directory.
- [ ] Run the clean lifecycle in [Testing](TESTING.md), including the real MCP
      call and the new ordered `azd down` hook.
- [ ] Confirm no active resources, soft-deleted Key Vault, or reusable-subnet
      service association remains after teardown.
- [ ] Obtain a `CONFORMING` result from Microsoft's validation action on the
      public repository.
- [ ] Ask the gallery curator to confirm the Basic/private-MCP support ambiguity
      documented in the README. Include the successful E2E evidence; do not
      claim that the conflicting Learn limitation has been resolved.
- [ ] Submit the [collection request form](https://forms.office.com/r/cy1ACkEGK5)
      as a Neo4j partner/template owner.

## Gallery metadata

Use this draft after the final owner path is confirmed:

```json
{
  "name": "Neo4j on Microsoft Foundry with private networking",
  "description": "Deploy Foundry Basic Agent Setup with VNet injection, a private Neo4j MCP endpoint, and an optional private Neo4j Enterprise database.",
  "repositoryPath": "neo4j/neo4j-foundry-vnet",
  "tags": [
    "ai",
    "agents",
    "azure",
    "bicep",
    "foundry",
    "mcp",
    "neo4j",
    "private-network",
    "vnet"
  ]
}
```

## What the validator checks

The checked-in workflow uses the current tagged Microsoft validation action and
its required checks:

- README `##` sections: Important Security Notice, Features, Getting Started,
  Resources, and Guidance;
- LICENSE, SECURITY, CONTRIBUTING, CODE_OF_CONDUCT, and issue template;
- `azure.yaml`, `infra/`, `.devcontainer/`, and an Azure deployment workflow;
- repository topics `azd-templates` and `ai-azd-templates`;
- PSRule's `TemplateValidation.MI_2024_10` security baseline;
- successful `azd up --no-prompt` and
  `azd down --force --purge --no-prompt`.

The repository intentionally sets `validateTests: None` because the application
test requires private VNet reachability and is not a Playwright browser test.
The manual/private-runner MCP gate in [Testing](TESTING.md) supplies the missing
E2E evidence.

## Review-sensitive points

- **Basic setup is deliberate.** Platform-managed state avoids customer-managed
  Storage, Cosmos DB, and AI Search. Standard is not a more secure default; it
  is the choice for customer-managed agent data and specific residency policy.
- **Private MCP documentation conflicts.** One part of Microsoft's MCP guide
  points no-BYO-resource users to Basic template 11; the limitation section
  still says Standard-only. The implementation works in the tested tenant, but
  curator confirmation remains an approval dependency.
- **Enterprise license acceptance is explicit.** The template cannot deploy the
  bundled database unattended unless the operator sets
  `NEO4J_ACCEPT_LICENSE_AGREEMENT=yes`. Using an existing Neo4j URI skips it.
- **Teardown is ordered.** The `predown` hook follows Microsoft's cleanup order
  and waits for the Foundry subnet service association before azd removes the
  VNet.
- **The sample is not production-certified.** The README clearly identifies
  the self-signed Bolt certificate and other production-hardening work.

## Authoritative references

- [Microsoft azd template publishing guidelines](https://github.com/Azure-Samples/azd-template-artifacts/blob/main/publishing-guidelines.md)
- [Microsoft azd template definition of done](https://github.com/Azure-Samples/azd-template-artifacts/blob/main/docs/development-guidelines/definition-of-done.md)
- [Microsoft template validation action](https://github.com/microsoft/template-validation-action)
- [Configure azd template sources](https://learn.microsoft.com/azure/developer/azure-developer-cli/configure-template-sources)
- [Foundry networking options](https://learn.microsoft.com/azure/foundry/agents/concepts/networking-options)
- [Foundry MCP tools](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/model-context-protocol)
