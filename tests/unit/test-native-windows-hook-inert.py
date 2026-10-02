#!/usr/bin/env python3
"""Every registered Claude Code hook must be inert on native Windows shells."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NativeWindowsHooks(unittest.TestCase):
    def test_registered_hooks_leave_fresh_home_untouched(self):
        config = json.loads((ROOT / "hooks/hooks.json").read_text())
        commands = {h["command"] for groups in config["hooks"].values()
                    for group in groups for h in group["hooks"]
                    if h.get("type") == "command"}
        for platform in ["MINGW64_NT-10.0", "MSYS_NT-10.0", "CYGWIN_NT-10.0"]:
            with tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary)
                home, binary = base / "home", base / "bin"
                home.mkdir()
                binary.mkdir()
                uname = binary / "uname"
                uname.write_text("#!/bin/sh\necho " + platform + "\n")
                uname.chmod(0o755)
                env = dict(os.environ, HOME=str(home), CLAUDE_PLUGIN_ROOT=str(ROOT),
                           PATH=str(binary) + os.pathsep + os.environ["PATH"])
                for command in sorted(commands):
                    with self.subTest(platform=platform, command=command):
                        script = command.replace("${CLAUDE_PLUGIN_ROOT}", str(ROOT))
                        result = subprocess.run(["bash", *shlex.split(script)], input='{"tool_name":"Bash"}',
                                                text=True, capture_output=True, timeout=3, env=env)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(result.stdout, "")
                        self.assertEqual(result.stderr, "")
                        self.assertEqual(list(home.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
