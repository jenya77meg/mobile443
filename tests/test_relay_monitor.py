"""Regression tests for relay-mode event handling, without host side effects.

Run with ``python3 -m unittest discover -s tests -v``. To test another revision,
set MOBILE443_MONITOR to its mobile443-monitor.sh path. Only two function
definitions are loaded; the monitor's startup code and common.sh are never run.
Firewall, user lookup, notifications, and sleeps are replaced with local mocks.
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


def extract_function(source, name):
    match = re.search(
        r"^" + re.escape(name) + r"\(\) \{\n.*?^\}", source, re.MULTILINE | re.DOTALL
    )
    if match is None:
        raise ValueError("Missing shell function: " + name)
    return match.group(0)


MOCKS = r'''
set -Eeuo pipefail
mkdir -p pending
PENDING_BLOCK_DIR="$PWD/pending"
STATS_BLOCKED_FILE="$PWD/stats"
IPSET_DEFERRED_BLOCK_NAME="test_only"
DEFERRED_BLOCK_DELAY=3
ENABLE_TELEGRAM=true
RELAY_MODE=true
BLOCKED_IP=""
LOOKUP_RESULT=""
EMAIL_RESULT=""
HEALTHCHECK=false
bool_is_true() { [[ "${1:-false}" == true ]]; }
log() { :; }
ipset() {
  if [[ "$1" != test || "$2" != "$IPSET_DEFERRED_BLOCK_NAME" ]]; then
    printf 'unexpected_ipset_operation\n' >> calls
    return 99
  fi
  [[ "$3" == "$BLOCKED_IP" ]]
}
add_to_deferred_block() { printf '%s\n' "$1" >> added; }
sleep() { printf '%s\n' "$1" >> sleeps; }
find_xray_line_by_ip_with_retry() {
  printf 'lookup\n' >> calls
  printf '%s' "$LOOKUP_RESULT"
}
extract_email_from_xray_line() { printf '%s' "$EMAIL_RESULT"; }
xray_line_is_healthcheck() { [[ "$HEALTHCHECK" == true ]]; }
get_remnawave_user() { printf 'api\n' >> calls; }
unexpected_command() {
  printf 'unexpected_%s\n' "$1" >> calls
  return 99
}
send_tg() { unexpected_command send_tg; }
curl() { unexpected_command curl; }
jq() { unexpected_command jq; }
iptables() { unexpected_command iptables; }
journalctl() { unexpected_command journalctl; }
'''


class RelayMonitorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        default = Path(__file__).resolve().parents[1] / "scripts/mobile443-monitor.sh"
        source_path = Path(os.environ.get("MOBILE443_MONITOR", str(default)))
        source = source_path.read_text(encoding="utf-8")
        cls.functions = "\n\n".join(
            extract_function(source, name)
            for name in ("schedule_deferred_block", "process_blocked")
        )
        cls.bash = shutil.which("bash")
        if cls.bash is None:
            raise RuntimeError("These shell regression tests require bash on PATH")

    def run_scenario(self, commands):
        with tempfile.TemporaryDirectory(prefix="mobile443-relay-test-") as temp_dir:
            # Feed the shell over stdin, and keep all writes in the temporary cwd.
            # BASH_ENV/ENV are removed so external startup files cannot be sourced.
            env = dict(os.environ)
            for variable in ("BASH_ENV", "ENV"):
                env.pop(variable, None)
            result = subprocess.run(
                [self.bash, "--noprofile", "--norc"],
                input=MOCKS + "\n" + self.functions + "\n" + commands + "\nwait\n",
                text=True,
                encoding="utf-8",
                capture_output=True,
                cwd=temp_dir,
                env=env,
                timeout=10,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            root = Path(temp_dir)

            def records(name):
                path = root / name
                return path.read_text(encoding="utf-8").splitlines() if path.exists() else []

            return {
                "added": records("added"),
                "calls": records("calls"),
                "sleeps": records("sleeps"),
                "pending": sorted(path.name for path in (root / "pending").iterdir()),
            }

    def test_relay_bypasses_stale_user_lookup_and_api(self):
        result = self.run_scenario('''
LOOKUP_RESULT="stale user record"
EMAIL_RESULT="synthetic-test-user"
process_blocked 192.0.2.10 443
''')
        self.assertEqual(result["calls"], [])
        self.assertEqual(result["added"], ["192.0.2.10"])
        self.assertEqual(result["sleeps"], ["3"])
        self.assertEqual(result["pending"], [])

    def test_relay_without_user_record_still_schedules_block(self):
        result = self.run_scenario("process_blocked 192.0.2.10 443")
        self.assertEqual(result["calls"], [])
        self.assertEqual(result["added"], ["192.0.2.10"])

    def test_existing_ban_does_not_lookup_or_schedule_again(self):
        result = self.run_scenario('''
BLOCKED_IP=192.0.2.10
process_blocked 192.0.2.10 443
''')
        self.assertEqual(result["calls"], [])
        self.assertEqual(result["added"], [])
        self.assertEqual(result["sleeps"], [])

    def test_pending_ban_does_not_lookup_or_schedule_again(self):
        result = self.run_scenario('''
touch pending/192.0.2.10
process_blocked 192.0.2.10 443
''')
        self.assertEqual(result["calls"], [])
        self.assertEqual(result["added"], [])
        self.assertEqual(result["sleeps"], [])
        self.assertEqual(result["pending"], ["192.0.2.10"])

    def test_duplicate_event_batch_never_enters_lookup_or_sleep(self):
        result = self.run_scenario('''
BLOCKED_IP=192.0.2.10
for i in {1..60}; do process_blocked 192.0.2.10 443; done
''')
        self.assertEqual(result["calls"], [])
        self.assertEqual(result["added"], [])
        self.assertEqual(result["sleeps"], [])

    def test_disabled_notifications_preserve_existing_guard(self):
        result = self.run_scenario('''
ENABLE_TELEGRAM=false
process_blocked 192.0.2.10 443 || true
''')
        self.assertEqual(result["calls"], [])
        self.assertEqual(result["added"], [])
        self.assertEqual(result["sleeps"], [])

    def test_xray_mode_without_user_does_not_ban(self):
        result = self.run_scenario('''
RELAY_MODE=false
process_blocked 192.0.2.10 443
''')
        self.assertEqual(result["calls"], ["lookup"])
        self.assertEqual(result["added"], [])
        self.assertEqual(result["sleeps"], [])

    def test_unset_relay_mode_defaults_to_xray_behavior(self):
        result = self.run_scenario('''
unset RELAY_MODE
process_blocked 192.0.2.10 443
''')
        self.assertEqual(result["calls"], ["lookup"])
        self.assertEqual(result["added"], [])

    def test_xray_healthcheck_does_not_notify_or_ban(self):
        result = self.run_scenario('''
RELAY_MODE=false
LOOKUP_RESULT="synthetic healthcheck"
EMAIL_RESULT="synthetic-test-user"
HEALTHCHECK=true
process_blocked 192.0.2.10 443
''')
        self.assertEqual(result["calls"], ["lookup"])
        self.assertEqual(result["added"], [])
        self.assertEqual(result["sleeps"], [])

    def test_xray_api_failure_preserves_deferred_block(self):
        result = self.run_scenario('''
RELAY_MODE=false
LOOKUP_RESULT="synthetic user record"
EMAIL_RESULT="synthetic-test-user"
process_blocked 192.0.2.10 443
''')
        self.assertEqual(result["calls"], ["lookup", "api"])
        self.assertEqual(result["added"], ["192.0.2.10"])
        self.assertEqual(result["sleeps"], ["3"])


if __name__ == "__main__":
    unittest.main()
