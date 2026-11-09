#!/usr/bin/env python3
import os
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


class LocalInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ww-local-install-")
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name).resolve()
        self.repo = self.folder / "checkout with spaces"
        scripts = self.repo / "scripts"
        scripts.mkdir(parents=True)
        for name in ("build.sh", "install-local.sh"):
            shutil.copy2(ROOT / "scripts" / name, scripts / name)
        self.install = self.folder / "Applications"
        self.install.mkdir()
        self.destination = self.install / "WaveWrangler.app"
        self.fixture = self.folder / "fixture.app"
        self.make_app(self.fixture, "new")
        self.tools = self.folder / "tools"
        self.tools.mkdir()
        self.environment = {
            **os.environ,
            "PATH": f"{self.tools}:{os.environ['PATH']}",
            "WW_INSTALL_DIR": str(self.install),
            "WW_DERIVED_DATA": ".build/local output",
            "WW_JOBS": "2",
            "FIXTURE": str(self.fixture),
            "BUILD_ARGUMENTS": str(self.folder / "build-arguments"),
            "VERIFY_LOG": str(self.folder / "verify-log"),
            "PGREP_COUNT": str(self.folder / "pgrep-count"),
        }
        for name in ("FAIL_BUILD", "FAIL_VERIFY", "FAIL_COPY", "RUNNING_ON_CHECK", "PGREP_ERROR"):
            self.environment.pop(name, None)
        self.tool("xcodebuild", """
printf '%s\\n' "$@" > "$BUILD_ARGUMENTS"
[[ "${FAIL_BUILD:-0}" == 0 ]] || exit 1
while [[ $# -gt 0 ]]; do
  case "$1" in
    -derivedDataPath) derived="$2"; shift ;;
    -configuration) configuration="$2"; shift ;;
  esac
  shift
done
mkdir -p "$derived/Build/Products/$configuration"
/usr/bin/ditto "$FIXTURE" "$derived/Build/Products/$configuration/WaveWrangler.app"
""")
        self.tool("codesign", """
app="${@: -1}"
printf '%s\\n' "$app" >> "$VERIFY_LOG"
case "${FAIL_VERIFY:-}" in
  build) [[ "$app" != */Build/Products/* ]] || exit 1 ;;
  stage) [[ "$app" != */.WaveWrangler.install.*/* ]] || exit 1 ;;
  installed) [[ "$app" != "$WW_INSTALL_DIR/WaveWrangler.app" ]] || exit 1 ;;
esac
""")
        self.tool("pgrep", """
[[ "${PGREP_ERROR:-0}" == 0 ]] || exit 2
count=0
[[ ! -f "$PGREP_COUNT" ]] || count=$(<"$PGREP_COUNT")
count=$((count + 1))
printf '%s' "$count" > "$PGREP_COUNT"
[[ "${RUNNING_ON_CHECK:-0}" != "$count" ]] || exit 0
exit 1
""")
        self.tool("ditto", """
[[ "${FAIL_COPY:-0}" == 0 ]] || exit 1
exec /usr/bin/ditto "$@"
""")

    def tool(self, name, body):
        path = self.tools / name
        path.write_text("#!/bin/bash\nset -euo pipefail\n" + body)
        path.chmod(0o755)

    def make_app(self, path, marker, identity="com.brandonmartinez.wavewrangler"):
        contents = path / "Contents"
        contents.mkdir(parents=True)
        (contents / "marker").write_text(marker)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": identity,
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "20261108190000000",
        }))

    def run_installer(self, *arguments, success=True):
        result = subprocess.run(
            ["bash", str(self.repo / "scripts/install-local.sh"), *arguments],
            env=self.environment, text=True, capture_output=True, timeout=20,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def assert_clean(self):
        self.assertEqual(list(self.install.glob(".WaveWrangler.install.*")), [])

    def test_install_and_replace_both_configurations(self):
        for configuration in ("Debug", "Release"):
            with self.subTest(configuration=configuration):
                result = self.run_installer(configuration)
                self.assertIn("Installed WaveWrangler 1.0 (build 20261108190000000)", result.stdout)
                self.assertEqual((self.destination / "Contents/marker").read_text(), "new")
                arguments = (self.folder / "build-arguments").read_text().splitlines()
                self.assertIn("CODE_SIGN_IDENTITY=-", arguments)
                self.assertEqual(arguments[arguments.index("-jobs") + 1], "2")
                self.assertEqual(arguments[arguments.index("-configuration") + 1], configuration)
                self.assertEqual(arguments[arguments.index("-derivedDataPath") + 1],
                                 str(self.repo / ".build/local output"))
                self.assert_clean()

    def test_default_derived_data_is_separate(self):
        del self.environment["WW_DERIVED_DATA"]
        self.run_installer()
        self.assertIn(str(self.repo / ".build/LocalInstallDerivedData"),
                      (self.folder / "build-arguments").read_text())

    def test_failures_preserve_previous_installation(self):
        self.make_app(self.destination, "previous")
        failures = [
            ("FAIL_BUILD", "1"), ("FAIL_VERIFY", "build"), ("FAIL_VERIFY", "stage"),
            ("FAIL_VERIFY", "installed"), ("FAIL_COPY", "1"),
            ("RUNNING_ON_CHECK", "1"), ("RUNNING_ON_CHECK", "2"), ("PGREP_ERROR", "1"),
        ]
        for variable, value in failures:
            with self.subTest(variable=variable, value=value):
                self.environment[variable] = value
                (self.folder / "pgrep-count").unlink(missing_ok=True)
                self.run_installer(success=False)
                self.assertEqual((self.destination / "Contents/marker").read_text(), "previous")
                self.assert_clean()
                del self.environment[variable]

    def test_failed_first_install_leaves_no_app(self):
        self.environment["FAIL_VERIFY"] = "installed"
        self.run_installer(success=False)
        self.assertFalse(self.destination.exists())
        self.assert_clean()

    def test_unrelated_app_and_symlink_are_preserved(self):
        self.make_app(self.destination, "unrelated", identity="another.app")
        self.run_installer(success=False)
        self.assertEqual((self.destination / "Contents/marker").read_text(), "unrelated")
        shutil.rmtree(self.destination)
        self.destination.symlink_to(self.fixture, target_is_directory=True)
        self.run_installer(success=False)
        self.assertTrue(self.destination.is_symlink())
        self.assert_clean()

    def test_existing_lock_is_not_reclaimed(self):
        lock = self.install / ".WaveWrangler.install.lock"
        lock.mkdir()
        self.run_installer(success=False)
        self.assertTrue(lock.exists())
        self.assertFalse((self.folder / "build-arguments").exists())

    def test_invalid_arguments_fail_before_build(self):
        for arguments in (("invalid",), ("Debug", "extra")):
            self.run_installer(*arguments, success=False)
        self.assertFalse((self.folder / "build-arguments").exists())


if __name__ == "__main__":
    unittest.main()
