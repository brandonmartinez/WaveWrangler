#!/usr/bin/env python3
"""Check native UI-plan coverage and exercise CLI routing without launching apps."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def check_plans():
    catalog = {}
    for path in (ROOT / "WaveWranglerUITests").glob("*.swift"):
        text = path.read_text()
        match = re.search(r"\bclass\s+(\w+)\s*:\s*XCTestCase\b", text)
        if match:
            catalog[match[1]] = set(re.findall(r"^\s*func\s+(test\w+)\s*\(", text, re.M))
    all_tests = {f"{suite}/{method}()" for suite, methods in catalog.items() for method in methods}

    def expand(selectors):
        result = set()
        for selector in selectors:
            suite, separator, method = selector.partition("/")
            assert suite in catalog, f"Unknown test class: {selector}"
            if separator:
                assert method.endswith("()") and method[:-2] in catalog[suite], f"Stale selector: {selector}"
                result.add(selector)
            else:
                result.update(f"{suite}/{name}()" for name in catalog[suite])
        return result

    plans = {}
    for name in ("PoC", "Regression", "Accessibility", "Performance"):
        plan = json.loads((ROOT / "TestPlans" / f"{name}.xctestplan").read_text())
        target, = plan["testTargets"]
        assert target["target"]["identifier"] == "77746556A807AB1774029007"
        assert target["parallelizable"] is False
        variables = {entry["key"]: entry["value"] for entry in plan["defaultOptions"]["environmentVariableEntries"]}
        assert variables["WW_UI_ACCESSIBILITY"] == ("1" if name == "Accessibility" else "0")
        selected = expand(target["selectedTests"]) if "selectedTests" in target else all_tests
        plans[name] = selected - expand(target.get("skippedTests", []))
        assert plans[name], f"Empty test plan: {name}"
    assert plans["PoC"] <= plans["Regression"], "PoC feature tests must also run in Regression"
    assert not plans["PoC"] & plans["Performance"], "Performance sampling is not a PoC gate"
    assert not any(selector.startswith(("ContrastEvidence", "SelectionContrast", "VoiceOver")) for selector in plans["PoC"])
    assert set.union(*plans.values()) == all_tests, "A test was lost from every plan"
    scheme = ET.parse(ROOT / "WaveWrangler.xcodeproj/xcshareddata/xcschemes/WaveWranglerUITests.xcscheme")
    references = scheme.findall("./TestAction/TestPlans/TestPlanReference")
    assert {entry.attrib["reference"] for entry in references} == {
        f"container:TestPlans/{name}.xctestplan" for name in plans
    }
    assert [entry.attrib["reference"] for entry in references if entry.attrib.get("default") == "YES"] == [
        "container:TestPlans/PoC.xctestplan"
    ]
    print(f"UI plans: {len(all_tests)} tests in {len(catalog)} classes; " +
          ", ".join(f"{name}={len(tests)}" for name, tests in plans.items()))


def check_cli():
    with tempfile.TemporaryDirectory(prefix="WaveWrangler-ui-plan-tests-") as directory:
        work = Path(directory)
        swift = work / "swift"
        swift.write_text("#!/bin/sh\nprintf '%s\\n' /synthetic-probe-build\n")
        swift.chmod(0o755)
        xcodebuild = work / "xcodebuild"
        xcodebuild.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$WW_CAPTURE_ARGS"\n')
        xcodebuild.chmod(0o755)
        capture = work / "arguments"
        env = dict(os.environ, PATH=f"{work}:{os.environ['PATH']}", WW_CAPTURE_ARGS=str(capture),
                   WW_JOBS="1", WW_ESTIMATOR_MAX_CONCURRENCY="2")
        cases = [
            (["--ui"], "PoC"),
            (["--ui", "-only-testing:WaveWranglerUITests/ControlsSidebarUITests"], "Regression"),
            (["--ui-profile=regression"], "Regression"),
            (["--ui-profile=accessibility"], "Accessibility"),
            (["--ui-profile=performance"], "Performance"),
            (["--ui-profile=poc", "-only-testing:WaveWranglerUITests/ControlsSidebarUITests"], "PoC"),
        ]
        for arguments, expected in cases:
            subprocess.run(["bash", str(ROOT / "scripts/test.sh"), *arguments], env=env,
                           check=True, capture_output=True, text=True)
            actual = capture.read_text().splitlines()
            assert actual[actual.index("-testPlan") + 1] == expected, (arguments, actual)
            for argument in arguments:
                if argument.startswith("-only-testing:"):
                    assert argument in actual, "Explicit selector was dropped"
        for arguments in [
            ["--ui-profile=unknown"], ["--ui", "--package-only"],
            ["-only-testing:WaveWranglerUITests/ControlsSidebarUITests"],
            ["--ui-profile=poc", "--ui-profile=accessibility"],
        ]:
            result = subprocess.run(["bash", str(ROOT / "scripts/test.sh"), *arguments], env=env,
                                    capture_output=True, text=True)
            assert result.returncode == 2, (arguments, result.returncode)
    print("UI CLI selection: 6 valid and 4 rejected invocations passed; no apps launched")


def check_built_plans(products):
    found = 0
    for name in ("PoC", "Regression", "Accessibility", "Performance"):
        paths = list(products.glob(f"WaveWranglerUITests_{name}_*.xctestrun"))
        if not paths:
            continue
        assert len(paths) == 1, f"Ambiguous generated {name} xctestrun: {paths}"
        expected = json.loads((ROOT / "TestPlans" / f"{name}.xctestplan").read_text())
        source, = expected["testTargets"]
        built = plistlib.loads(paths[0].read_bytes())
        assert built.get("TestConfigurations"), f"Missing plan configuration: {paths[0]}"
        for configuration in built["TestConfigurations"]:
            target, = configuration["TestTargets"]
            assert target["BlueprintName"] == "WaveWranglerUITests"
            assert set(target.get("OnlyTestIdentifiers", [])) == set(source.get("selectedTests", []))
            assert set(target.get("SkipTestIdentifiers", [])) == set(source.get("skippedTests", []))
            assert target["EnvironmentVariables"]["WW_UI_ACCESSIBILITY"] == ("1" if name == "Accessibility" else "0")
        print(f"Generated {name} xctestrun matches its source plan and audit admission")
        found += 1
    assert found, f"No plan-specific UI xctestruns in {products}; do not use a stale pre-plan file"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--static", action="store_true")
    parser.add_argument("--products", type=Path)
    options = parser.parse_args()
    check_plans()
    if not options.static:
        check_cli()
    if options.products:
        check_built_plans(options.products)
