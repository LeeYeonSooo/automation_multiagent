#!/usr/bin/env python3
import importlib.util
import pathlib
import sys


ROOT = pathlib.Path("/Users/dldustn/Desktop/AssignmentC")
CH_DIR = ROOT / "challenges" / "ch5_superfluid_v2"
MODULE_PATH = CH_DIR / "runs" / "broadcast_1776541057.py"


def main() -> int:
    spec = importlib.util.spec_from_file_location("broadcast_1776541057", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)

    module.RUN_ID = "1776543622"
    module.LOG_PATH = CH_DIR / "runs" / "exploit_1776543622.log"
    module.PREFLIGHT_PATH = CH_DIR / "runs" / "exploit_1776543622_preflight.json"
    module.POSTFLIGHT_PATH = CH_DIR / "runs" / "exploit_1776543622_postflight.json"

    return module.main()


if __name__ == "__main__":
    raise SystemExit(main())
