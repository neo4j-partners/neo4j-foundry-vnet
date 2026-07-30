#!/usr/bin/env -S uv run --quiet
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "azure-ai-projects>=2.0.0",
#     "azure-identity",
#     "openai",
#     "python-dotenv",
# ]
# ///
"""E2E test for the network-secured Foundry + Neo4j MCP blueprint.

Creates a Responses-API agent whose MCP tool points at the PRIVATE Neo4j MCP
endpoint (internal-only Container App on the VNet's MCP subnet). The agent
runtime — VNet-injected via the Foundry account's networkInjections — is the
only thing that can reach it; this script itself only talks to the public (or
private, if you're on the VNet) Foundry project endpoint.

A successful run proves: agent -> data proxy -> injected VNet -> private DNS
-> internal ACA ingress -> Neo4j MCP -> Neo4j.
"""

import os
import sys
import time
from pathlib import Path

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import MCPTool, PromptAgentDefinition
from azure.identity import AzureCliCredential
from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parents[1] / ".env.deployed", override=True)

INSTRUCTIONS = """\
Role: reliability engineer for a wind-turbine fleet. Source of truth: a Neo4j
"digital twin" graph reached only through the get-schema and read-cypher tools
(read-only). The graph models Turbines -> Systems -> Components -> Sensors ->
Readings, plus Sites and MaintenanceEvents (relationships HAS_SYSTEM,
HAS_COMPONENT, HAS_SENSOR, GENERATES, HAS_EVENT, AFFECTS, LOCATED_AT). Be
thorough and data-driven.

## Grounding

Call get-schema once per conversation. You MUST call read-cypher before any
factual claim about a turbine, component, sensor reading, site, or maintenance
event. Answer only from read-cypher rows. Never use prior knowledge. If
read-cypher returns nothing, reply "the graph doesn't contain that". Use modern
Cypher (`WHERE x IS NOT NULL`). Project `id` properties so follow-ups can build
on them.
"""

# The MS sample notes intermittent data-proxy routing failures on some scale
# units; a couple of retries makes the E2E check reliable.
MAX_ATTEMPTS = 3


def main() -> None:
    project_endpoint = os.environ.get("FOUNDRY_PROJECT_ENDPOINT")
    tenant_id = os.environ.get("AZURE_TENANT_ID")
    mcp_endpoint = os.environ.get("NEO4J_MCP_ENDPOINT")
    if not (project_endpoint and tenant_id and mcp_endpoint):
        sys.exit(
            "Missing FOUNDRY_PROJECT_ENDPOINT, AZURE_TENANT_ID, or NEO4J_MCP_ENDPOINT. "
            "Run ./deploy.sh first."
        )

    # Auth (Authorization: Basic ...) lives in the 'neo4j-mcp-auth' project
    # connection created by the Bicep — the Agent Service rejects sensitive
    # headers passed inline and requires project_connection_id instead.
    connection_name = os.environ.get("NEO4J_MCP_CONNECTION_NAME", "neo4j-mcp-auth")

    mcp_tool = MCPTool(
        server_label="neo4j_mcp_private",
        server_url=mcp_endpoint,
        require_approval="never",
        allowed_tools=["get-schema", "read-cypher"],
        project_connection_id=connection_name,
    )

    project = AIProjectClient(
        endpoint=project_endpoint,
        credential=AzureCliCredential(tenant_id=tenant_id),
    )
    openai = project.get_openai_client()

    agent = project.agents.create_version(
        agent_name=os.environ.get("FOUNDRY_TEST_AGENT_NAME", "neo4j-vnet-mcp-agent"),
        definition=PromptAgentDefinition(
            model=os.environ.get("FOUNDRY_MODEL_DEPLOYMENT_NAME", "gpt-5-mini"),
            instructions=INSTRUCTIONS,
            tools=[mcp_tool],
        ),
    )
    print(f"Agent created: {agent.name} v{agent.version}")
    print(f"Private MCP endpoint: {mcp_endpoint}")

    question = os.environ.get(
        "FOUNDRY_QUESTION",
        "Which turbines have the most high-severity maintenance events, and what "
        "faults and components are involved? Cite turbine ids.",
    )
    agent_ref = {"agent_reference": {"name": agent.name, "type": "agent_reference"}}

    try:
        last_error = None
        for attempt in range(1, MAX_ATTEMPTS + 1):
            print(f"\n[attempt {attempt}/{MAX_ATTEMPTS}] > {question}")
            try:
                response = openai.responses.create(input=question, extra_body=agent_ref)
                mcp_calls = [
                    item for item in response.output
                    if getattr(item, "type", "") == "mcp_call"
                ]
                for call in mcp_calls:
                    args = getattr(call, "arguments", "") or ""
                    arg_str = args if len(str(args)) < 120 else str(args)[:117] + "..."
                    err = getattr(call, "error", None)
                    status = "ERROR: " + str(err) if err else "ok"
                    print(f"  → mcp_call {call.name}({arg_str}) [{status}]")

                failed = [c for c in mcp_calls if getattr(c, "error", None)]
                if mcp_calls and not failed:
                    print(f"\n{response.output_text}")
                    print("\n✓ E2E SUCCESS: agent reached the PRIVATE MCP endpoint through the VNet.")
                    return
                if not mcp_calls:
                    # Tool listing may already have failed server-side; surface output.
                    print(f"  (no mcp_call items; output: {response.output_text[:500]})")
                    last_error = "agent made no MCP calls"
                else:
                    last_error = f"{len(failed)} MCP call(s) errored"
            except Exception as e:  # noqa: BLE001 - report and retry
                print(f"  request failed: {e}")
                last_error = str(e)
            if attempt < MAX_ATTEMPTS:
                time.sleep(10)
        sys.exit(f"\n✗ E2E FAILED after {MAX_ATTEMPTS} attempts: {last_error}")
    finally:
        if os.environ.get("KEEP_AGENT", "") != "true":
            project.agents.delete_version(agent_name=agent.name, agent_version=agent.version)
            print("Agent deleted (set KEEP_AGENT=true to keep it for portal Playground).")


if __name__ == "__main__":
    main()
