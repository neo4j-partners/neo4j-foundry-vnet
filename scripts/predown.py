#!/usr/bin/env python3
"""Release Foundry VNet dependencies before azd deletes the deployment.

Foundry network injection creates capability hosts and an asynchronous service
association link (SAL) on the agent subnet. Deleting those resources in ARM's
default order can leave the VNet in use. This hook follows Microsoft's required
order: project capability hosts, account capability hosts, projects, account
delete and purge, then SAL removal.

The hook is intentionally scoped to the resource group and names emitted by
this azd environment. It is idempotent so a failed `azd down` can be retried.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Any
from urllib.parse import quote


API_VERSION = "2025-04-01-preview"
DEFAULT_OPERATION_TIMEOUT = 30 * 60
DEFAULT_SAL_TIMEOUT = 20 * 60
POLL_SECONDS = 30


class CommandError(RuntimeError):
    """An Azure CLI command failed."""


def log(message: str) -> None:
    print(f"[foundry-cleanup] {message}", flush=True)


def run(
    *args: str,
    check: bool = True,
    allow_not_found: bool = False,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        args,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode and allow_not_found:
        combined = f"{result.stdout}\n{result.stderr}".lower()
        if (
            "notfound" in combined
            or "not found" in combined
            or "resourcegroupnotfound" in combined
        ):
            return result
    if check and result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise CommandError(f"{' '.join(args[:3])} failed: {detail}")
    return result


def azd_value(name: str) -> str:
    result = run("azd", "env", "get-value", name, check=False)
    value = result.stdout.strip()
    if result.returncode or value.startswith("ERROR:"):
        return ""
    return value


def json_output(*args: str, allow_not_found: bool = False) -> Any:
    result = run(*args, allow_not_found=allow_not_found)
    if result.returncode or not result.stdout.strip():
        return None
    return json.loads(result.stdout)


def management_url(subscription_id: str, resource_group: str, path: str) -> str:
    encoded_rg = quote(resource_group, safe="")
    return (
        "https://management.azure.com/subscriptions/"
        f"{subscription_id}/resourceGroups/{encoded_rg}/providers/"
        f"Microsoft.CognitiveServices/{path}?api-version={API_VERSION}"
    )


def rest_json(method: str, url: str, *, allow_not_found: bool = False) -> Any:
    return json_output(
        "az",
        "rest",
        "--method",
        method,
        "--url",
        url,
        "--output",
        "json",
        allow_not_found=allow_not_found,
    )


def resource_exists(url: str) -> bool:
    result = run(
        "az",
        "rest",
        "--method",
        "get",
        "--url",
        url,
        "--output",
        "none",
        check=False,
    )
    return result.returncode == 0


def wait_until_absent(url: str, label: str, timeout_seconds: int) -> None:
    deadline = time.monotonic() + timeout_seconds
    while resource_exists(url):
        if time.monotonic() >= deadline:
            raise CommandError(
                f"Timed out waiting for {label} deletion after {timeout_seconds}s"
            )
        log(f"Waiting for {label} deletion...")
        time.sleep(POLL_SECONDS)
    log(f"Deleted {label}.")


@dataclass(frozen=True)
class CapabilityHost:
    url: str
    label: str
    subnet_id: str = ""


def list_capability_hosts(
    subscription_id: str,
    resource_group: str,
    account_name: str,
) -> tuple[list[CapabilityHost], list[CapabilityHost], list[str]]:
    account_path = f"accounts/{quote(account_name, safe='')}"
    projects_url = management_url(
        subscription_id, resource_group, f"{account_path}/projects"
    )
    projects_payload = rest_json("get", projects_url, allow_not_found=True) or {}
    projects: list[str] = []
    project_hosts: list[CapabilityHost] = []

    for project in projects_payload.get("value", []):
        project_name = project.get("name", "").split("/")[-1]
        if not project_name:
            continue
        projects.append(project_name)
        project_path = f"{account_path}/projects/{quote(project_name, safe='')}"
        hosts_url = management_url(
            subscription_id, resource_group, f"{project_path}/capabilityHosts"
        )
        hosts_payload = rest_json("get", hosts_url, allow_not_found=True) or {}
        for host in hosts_payload.get("value", []):
            host_name = host.get("name", "").split("/")[-1]
            if not host_name:
                continue
            project_hosts.append(
                CapabilityHost(
                    url=management_url(
                        subscription_id,
                        resource_group,
                        f"{project_path}/capabilityHosts/{quote(host_name, safe='')}",
                    ),
                    label=f"project capability host {account_name}/{project_name}/{host_name}",
                    subnet_id=host.get("properties", {}).get("customerSubnet", ""),
                )
            )

    account_hosts_url = management_url(
        subscription_id, resource_group, f"{account_path}/capabilityHosts"
    )
    account_hosts_payload = (
        rest_json("get", account_hosts_url, allow_not_found=True) or {}
    )
    account_hosts: list[CapabilityHost] = []
    for host in account_hosts_payload.get("value", []):
        host_name = host.get("name", "").split("/")[-1]
        if not host_name:
            continue
        account_hosts.append(
            CapabilityHost(
                url=management_url(
                    subscription_id,
                    resource_group,
                    f"{account_path}/capabilityHosts/{quote(host_name, safe='')}",
                ),
                label=f"account capability host {account_name}/{host_name}",
                subnet_id=host.get("properties", {}).get("customerSubnet", ""),
            )
        )

    return project_hosts, account_hosts, projects


def delete_capability_host(host: CapabilityHost, timeout_seconds: int) -> None:
    if not resource_exists(host.url):
        log(f"Already absent: {host.label}.")
        return
    log(f"Deleting {host.label}.")
    run(
        "az",
        "rest",
        "--method",
        "delete",
        "--url",
        host.url,
        "--output",
        "none",
        allow_not_found=True,
    )
    wait_until_absent(host.url, host.label, timeout_seconds)


def delete_project(
    subscription_id: str,
    resource_group: str,
    account_name: str,
    project_name: str,
    timeout_seconds: int,
) -> None:
    project_url = management_url(
        subscription_id,
        resource_group,
        f"accounts/{quote(account_name, safe='')}/projects/{quote(project_name, safe='')}",
    )
    if not resource_exists(project_url):
        return
    log(f"Deleting Foundry project {account_name}/{project_name}.")
    run(
        "az",
        "rest",
        "--method",
        "delete",
        "--url",
        project_url,
        "--output",
        "none",
        allow_not_found=True,
    )
    wait_until_absent(
        project_url, f"Foundry project {account_name}/{project_name}", timeout_seconds
    )


def delete_and_purge_account(
    subscription_id: str,
    resource_group: str,
    account_name: str,
    timeout_seconds: int,
) -> None:
    show = run(
        "az",
        "cognitiveservices",
        "account",
        "show",
        "--subscription",
        subscription_id,
        "--resource-group",
        resource_group,
        "--name",
        account_name,
        "--query",
        "location",
        "--output",
        "tsv",
        check=False,
    )
    location = show.stdout.strip()
    deadline = time.monotonic() + timeout_seconds
    if location:
        while True:
            log(f"Deleting Foundry account {account_name}.")
            result = run(
                "az",
                "cognitiveservices",
                "account",
                "delete",
                "--subscription",
                subscription_id,
                "--resource-group",
                resource_group,
                "--name",
                account_name,
                check=False,
            )
            if result.returncode == 0:
                break
            detail = (result.stderr or result.stdout).strip()
            if (
                "cannotdeleteresource" not in detail.lower()
                and "nested resources exist" not in detail.lower()
            ) or time.monotonic() >= deadline:
                raise CommandError(
                    f"Failed deleting Foundry account {account_name}: {detail}"
                )
            log(
                "Project deletion is still settling; retrying account deletion "
                "in 30 seconds."
            )
            time.sleep(POLL_SECONDS)
    else:
        deleted = (
            json_output(
                "az",
                "cognitiveservices",
                "account",
                "list-deleted",
                "--subscription",
                subscription_id,
                "--output",
                "json",
            )
            or []
        )
        match = next(
            (
                item
                for item in deleted
                if item.get("name", "").lower() == account_name.lower()
                and f"/resourceGroups/{resource_group}/".lower()
                in item.get("id", "").lower()
            ),
            None,
        )
        location = match.get("location", "") if match else ""

    if not location:
        log(
            f"Foundry account {account_name} is already absent with no soft-deleted record."
        )
        return

    while True:
        log(f"Purging Foundry account {account_name}.")
        result = run(
            "az",
            "cognitiveservices",
            "account",
            "purge",
            "--subscription",
            subscription_id,
            "--resource-group",
            resource_group,
            "--name",
            account_name,
            "--location",
            location,
            check=False,
        )
        if result.returncode == 0:
            log(f"Purged Foundry account {account_name}.")
            return
        if time.monotonic() >= deadline:
            detail = (result.stderr or result.stdout).strip()
            raise CommandError(
                f"Timed out purging Foundry account {account_name}: {detail}"
            )
        log("Account deletion is still settling; retrying purge in 30 seconds.")
        time.sleep(POLL_SECONDS)


def delete_resource(resource_id: str, label: str, timeout_seconds: int) -> None:
    exists = run(
        "az", "resource", "show", "--ids", resource_id, "--output", "none", check=False
    )
    if exists.returncode:
        return
    log(f"Deleting {label}.")
    # Return immediately from the ARM delete request so this function's
    # explicit deadline bounds the whole operation. Without --no-wait, the CLI
    # can block longer than operation_timeout before polling even begins.
    run("az", "resource", "delete", "--ids", resource_id, "--no-wait")
    deadline = time.monotonic() + timeout_seconds
    while (
        run(
            "az",
            "resource",
            "show",
            "--ids",
            resource_id,
            "--output",
            "none",
            check=False,
        ).returncode
        == 0
    ):
        if time.monotonic() >= deadline:
            raise CommandError(f"Timed out waiting for {label} deletion")
        time.sleep(POLL_SECONDS)
    log(f"Deleted {label}.")


def wait_for_sal(subnet_id: str, timeout_seconds: int) -> None:
    if not subnet_id:
        return
    deadline = time.monotonic() + timeout_seconds
    while True:
        result = run(
            "az",
            "network",
            "vnet",
            "subnet",
            "show",
            "--ids",
            subnet_id,
            "--query",
            "length(serviceAssociationLinks || `[]`)",
            "--output",
            "tsv",
            check=False,
        )
        if result.returncode:
            log(f"Subnet already absent: {subnet_id}.")
            return
        count = result.stdout.strip()
        if count in {"", "0"}:
            log(f"Service association link released: {subnet_id}.")
            return
        if time.monotonic() >= deadline:
            raise CommandError(
                "Foundry service association link is still present after "
                f"{timeout_seconds}s: {subnet_id}. Retry azd down later; Microsoft notes "
                "that backend cleanup can occasionally take up to 24 hours."
            )
        log(
            f"Waiting for Foundry service association link on {subnet_id} ({count} present)."
        )
        time.sleep(POLL_SECONDS)


def main() -> int:
    if (
        not run("az", "account", "show", "--output", "none", check=False).returncode
        == 0
    ):
        raise CommandError(
            "Azure CLI is not authenticated. Run az login before azd down."
        )

    subscription_id = (
        azd_value("AZURE_SUBSCRIPTION_ID")
        or run(
            "az", "account", "show", "--query", "id", "--output", "tsv"
        ).stdout.strip()
    )
    resource_group = (
        azd_value("foundryResourceGroup")
        or azd_value("AZURE_RESOURCE_GROUP")
        or azd_value("resourceGroupName")
    )
    if not resource_group:
        log("No deployed resource-group output was found; nothing to pre-clean.")
        return 0

    group_exists = (
        run(
            "az",
            "group",
            "exists",
            "--subscription",
            subscription_id,
            "--name",
            resource_group,
            "--output",
            "tsv",
        )
        .stdout.strip()
        .lower()
    )
    if group_exists != "true":
        log(f"Resource group {resource_group} is already absent.")
        return 0

    operation_timeout = int(
        os.getenv("FOUNDRY_CLEANUP_TIMEOUT_SECONDS", DEFAULT_OPERATION_TIMEOUT)
    )
    sal_timeout = int(os.getenv("FOUNDRY_SAL_TIMEOUT_SECONDS", DEFAULT_SAL_TIMEOUT))
    log(f"Preparing ordered teardown for {resource_group}.")

    # Release the template-owned MCP subnet before azd removes the VNet.
    app_name = azd_value("containerAppName")
    env_name = azd_value("containerAppsEnvironmentName")
    resource_prefix = f"/subscriptions/{subscription_id}/resourceGroups/{resource_group}/providers/Microsoft.App"
    if app_name:
        delete_resource(
            f"{resource_prefix}/containerApps/{app_name}",
            f"MCP container app {app_name}",
            operation_timeout,
        )
    if env_name:
        delete_resource(
            f"{resource_prefix}/managedEnvironments/{env_name}",
            f"MCP Container Apps environment {env_name}",
            operation_timeout,
        )

    account_names: list[str] = []
    configured_account = azd_value("foundryAccountName")
    if configured_account:
        account_names = [configured_account]
    else:
        discovered = (
            json_output(
                "az",
                "cognitiveservices",
                "account",
                "list",
                "--subscription",
                subscription_id,
                "--resource-group",
                resource_group,
                "--query",
                "[?kind=='AIServices'].name",
                "--output",
                "json",
            )
            or []
        )
        account_names = [str(name) for name in discovered]

    subnet_ids: set[str] = set()
    for account_name in account_names:
        project_hosts, account_hosts, projects = list_capability_hosts(
            subscription_id, resource_group, account_name
        )
        subnet_ids.update(
            host.subnet_id for host in project_hosts + account_hosts if host.subnet_id
        )
        for host in project_hosts:
            delete_capability_host(host, operation_timeout)
        for host in account_hosts:
            delete_capability_host(host, operation_timeout)
        for project_name in projects:
            delete_project(
                subscription_id,
                resource_group,
                account_name,
                project_name,
                operation_timeout,
            )
        delete_and_purge_account(
            subscription_id, resource_group, account_name, operation_timeout
        )

    vnet_name = azd_value("vnetName")
    if vnet_name:
        subnet_ids.add(
            f"/subscriptions/{subscription_id}/resourceGroups/{resource_group}/providers/"
            f"Microsoft.Network/virtualNetworks/{vnet_name}/subnets/agent-subnet"
        )
        # The bundled Neo4j subnet has a NAT association. Detaching it avoids
        # an ARM delete-order race; absence is harmless for BYO Neo4j.
        run(
            "az",
            "network",
            "vnet",
            "subnet",
            "update",
            "--subscription",
            subscription_id,
            "--resource-group",
            resource_group,
            "--vnet-name",
            vnet_name,
            "--name",
            "neo4j-subnet",
            "--remove",
            "natGateway",
            "--output",
            "none",
            check=False,
        )

    for subnet_id in sorted(subnet_ids):
        wait_for_sal(subnet_id, sal_timeout)

    log(
        "Foundry and VNet dependencies are released; azd can finish deleting the environment."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (CommandError, json.JSONDecodeError, ValueError) as exc:
        print(f"[foundry-cleanup] ERROR: {exc}", file=sys.stderr, flush=True)
        raise SystemExit(1) from exc
