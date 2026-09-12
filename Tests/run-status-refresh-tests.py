#!/usr/bin/env python3
"""Run AppModel's actual refresh scheduler without launching the user's app."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
source = (root / "Sources/HerdrM/AppModel.swift").read_text()
methods = []
for start, end in [
    ("    @discardableResult\n    func refresh(", "    private func performRefresh("),
    ("    private func scheduleRefresh(", "    private func refreshImmediately("),
    ("    private func refreshImmediately(", "    @discardableResult\n    private func applyAgentStatusEvent("),
]:
    offset = source.index(start)
    methods.append(source[offset:source.index(end, offset)].replace("private func", "func"))
harness = (root / "Tests/StatusRefreshTests.swift").read_text().replace(
    "    // PRODUCTION_METHODS", "\n".join(methods)
)
with tempfile.TemporaryDirectory(prefix="herdrm-refresh-tests-") as temp:
    directory = pathlib.Path(temp)
    swift = directory / "main.swift"
    swift.write_text(harness)
    binary = directory / "tests"
    subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", str(directory / "cache"),
                    str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
