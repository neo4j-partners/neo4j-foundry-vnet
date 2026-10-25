from __future__ import annotations

import subprocess
import unittest
from unittest.mock import patch

from scripts import predown


class PredownTests(unittest.TestCase):
    def test_management_url_encodes_resource_group(self) -> None:
        url = predown.management_url("sub", "rg with spaces", "accounts/account")
        self.assertIn("resourceGroups/rg%20with%20spaces/", url)
        self.assertTrue(url.endswith(f"api-version={predown.API_VERSION}"))

    @patch("scripts.predown.rest_json")
    def test_capability_host_discovery_keeps_project_before_account(
        self, rest_json
    ) -> None:
        rest_json.side_effect = [
            {"value": [{"name": "account/project"}]},
            {
                "value": [
                    {
                        "name": "account/project/caphostproj",
                        "properties": {"customerSubnet": "/subnets/agent"},
                    }
                ]
            },
            {
                "value": [
                    {
                        "name": "account/account-host",
                        "properties": {"customerSubnet": "/subnets/agent"},
                    }
                ]
            },
        ]

        project_hosts, account_hosts, projects = predown.list_capability_hosts(
            "sub", "rg", "account"
        )

        self.assertEqual(projects, ["project"])
        self.assertEqual(
            project_hosts[0].label,
            "project capability host account/project/caphostproj",
        )
        self.assertEqual(
            account_hosts[0].label, "account capability host account/account-host"
        )
        self.assertEqual(project_hosts[0].subnet_id, "/subnets/agent")

    @patch("scripts.predown.run")
    def test_sal_wait_returns_when_link_is_absent(self, run) -> None:
        run.return_value = subprocess.CompletedProcess([], 0, "0\n", "")
        predown.wait_for_sal("/subnets/agent", timeout_seconds=1)
        run.assert_called_once()

    @patch("scripts.predown.run")
    def test_generic_resource_delete_is_non_blocking(self, run) -> None:
        run.side_effect = [
            subprocess.CompletedProcess([], 0, "", ""),
            subprocess.CompletedProcess([], 0, "", ""),
            subprocess.CompletedProcess([], 1, "", "not found"),
        ]

        predown.delete_resource("/resources/example", "example", timeout_seconds=1)

        self.assertEqual(
            run.call_args_list[1].args,
            ("az", "resource", "delete", "--ids", "/resources/example", "--no-wait"),
        )

    @patch("scripts.predown.time.sleep")
    @patch("scripts.predown.run")
    def test_account_delete_retries_while_project_is_settling(self, run, sleep) -> None:
        run.side_effect = [
            subprocess.CompletedProcess([], 0, "swedencentral\n", ""),
            subprocess.CompletedProcess(
                [], 1, "", "CannotDeleteResource: nested resources exist"
            ),
            subprocess.CompletedProcess([], 0, "", ""),
            subprocess.CompletedProcess([], 0, "", ""),
        ]

        predown.delete_and_purge_account("sub", "rg", "account", timeout_seconds=1)

        delete_calls = [
            call
            for call in run.call_args_list
            if call.args[:4] == ("az", "cognitiveservices", "account", "delete")
        ]
        self.assertEqual(len(delete_calls), 2)
        sleep.assert_called_once_with(predown.POLL_SECONDS)

    @patch("scripts.predown.run")
    @patch("scripts.predown.azd_value")
    def test_main_is_safe_when_no_resource_group_was_deployed(
        self, azd_value, run
    ) -> None:
        azd_value.side_effect = lambda name: (
            "sub" if name == "AZURE_SUBSCRIPTION_ID" else ""
        )
        run.return_value = subprocess.CompletedProcess([], 0, "", "")
        self.assertEqual(predown.main(), 0)


if __name__ == "__main__":
    unittest.main()
