# Contributing

Contributions are welcome after the repository is placed under its final Neo4j
owner. Open an issue before a large architecture change and keep pull requests
focused.

External contributors must sign the
[Neo4j contributor agreement](https://neo4j.com/developer/contributing-code/#sign-cla).

Before submitting:

1. Run `ruff check agent data scripts tests`, `ruff format --check agent data
   scripts tests`, and `python -m unittest discover -s tests -v`.
2. Run `shellcheck` and `bash -n` on all shell scripts, plus PowerShell parser
   checks on `scripts/*.ps1`.
3. Run `az bicep build --file infra/main.bicep` and address every error or
   warning.
4. Confirm the repository contains no secrets, tenant identifiers, real customer
   names, or customer data.
5. Keep Foundry behavior aligned with current Microsoft Learn documentation and
   the official `microsoft-foundry/foundry-samples` templates.
6. Update the README when parameters, costs, security controls, or limitations
   change.
7. For infrastructure changes, complete the lifecycle in `docs/TESTING.md` in a
   disposable subscription and attach redacted evidence to the pull request.

By contributing, you agree that your contribution is provided under the
repository license and applicable contributor agreements.
