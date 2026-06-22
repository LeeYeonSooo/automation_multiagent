#!/usr/bin/env python3
"""Archive verified contract sources and ABIs from Etherscan/BscScan.

This task is intentionally Etherscan-only. It avoids fork RPC calls and uses
`tools/recon.sh src` for the source fetch path requested by the harness prompt.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
OUT_ROOT = ROOT / "sources" / "ch1_uranium"
CHAIN = "bsc"
CHAIN_ID = 56

CONTRACTS: list[tuple[str, str]] = [
    ("UraniumFactory", "0xA943eA143cd7E79806d670f4a7cf08F8922a454F"),
    ("UraniumPair_WBNB_BUSD", "0x9B9baD4c6513E0fF3fB77c739359D59601c7cAfF"),
    ("WBNB", "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c"),
    ("BUSD", "0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56"),
    ("USDT_BEP20", "0x55d398326f99059fF775485246999027B3197955"),
    ("ETH_BEP20", "0x2170Ed0880ac9A755fd29B2688956BD959F933F8"),
    ("BTCB", "0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c"),
    ("PancakeRouter_V2", "0x10ED43C718714eb63d5aA57B78B54704E256024E"),
]


def load_dotenv(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if not path.exists():
        return env
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in raw_line:
            continue
        key, value = raw_line.split("=", 1)
        env[key] = value.strip().strip("'").strip('"')
    return env


def call_recon(*args: str) -> str:
    result = subprocess.run(
        [str(ROOT / "tools" / "recon.sh"), *args],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout


def etherscan_request(action: str, address: str, env: dict[str, str]) -> dict[str, Any]:
    params = {
        "chainid": str(CHAIN_ID),
        "module": "contract",
        "action": action,
        "address": address,
        "apikey": env.get("ETHERSCAN_API_KEY", ""),
    }
    url = "https://api.etherscan.io/v2/api?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url) as response:
        return json.load(response)


def parse_bool_flag(value: str | None) -> bool | None:
    if value is None or value == "":
        return None
    return value == "1"


def parse_int(value: str | None) -> int | None:
    if value is None or value == "":
        return None
    try:
        return int(value)
    except ValueError:
        return None


def parse_libraries(raw: str | None) -> dict[str, str]:
    if not raw:
        return {}
    libraries: dict[str, str] = {}
    for chunk in raw.split(";"):
        item = chunk.strip()
        if not item or ":" not in item:
            continue
        name, address = item.split(":", 1)
        libraries[name.strip()] = address.strip()
    return libraries


def clean_relative_path(path: str) -> str:
    cleaned = path.replace("\\", "/").strip()
    cleaned = re.sub(r"^[A-Za-z]:", "", cleaned)
    cleaned = cleaned.lstrip("/")
    while cleaned.startswith("./"):
        cleaned = cleaned[2:]
    return cleaned or "Contract.sol"


def source_extension(record: dict[str, Any], source_code: str) -> str:
    compiler_type = (record.get("CompilerType") or "").lower()
    if "vyper" in compiler_type:
        return ".vy"
    contract_name = (record.get("ContractName") or "").lower()
    if contract_name.endswith(".vy"):
        return ""
    if contract_name.endswith(".sol"):
        return ""
    stripped = source_code.lstrip()
    if stripped.startswith("# @version") or stripped.startswith("# pragma"):
        return ".vy"
    return ".sol"


def single_file_name(record: dict[str, Any], source_code: str) -> str:
    contract_name = record.get("ContractName") or "Contract"
    safe_name = re.sub(r"[^A-Za-z0-9_.-]+", "_", contract_name).strip("_") or "Contract"
    return safe_name + source_extension(record, source_code)


def parse_standard_json(source_code: str) -> dict[str, Any] | None:
    payload = source_code.strip()
    if payload.startswith("{{") and payload.endswith("}}"):
        payload = payload[1:-1]
    if not payload.startswith("{"):
        return None
    try:
        data = json.loads(payload)
    except json.JSONDecodeError:
        return None
    if not isinstance(data, dict) or not isinstance(data.get("sources"), dict):
        return None
    return data


def extract_source_files(record: dict[str, Any], source_code: str) -> tuple[str, list[tuple[str, str]]]:
    payload = source_code.strip()
    if not payload or payload == "Contract source code not verified":
        return "unverified", []

    standard_json = parse_standard_json(payload)
    if standard_json is not None:
        files: list[tuple[str, str]] = []
        for original_path, entry in standard_json["sources"].items():
            content = ""
            if isinstance(entry, dict):
                if isinstance(entry.get("content"), str):
                    content = entry["content"]
                elif isinstance(entry.get("source"), str):
                    content = entry["source"]
            elif isinstance(entry, str):
                content = entry
            files.append((clean_relative_path(original_path), content))
        return "standard_json", files

    return "single_file", [(single_file_name(record, payload), source_code)]


def abi_payload(raw_abi: str) -> Any:
    stripped = raw_abi.strip()
    if not stripped or stripped == "Contract source code not verified":
        return {"verified": False, "raw": stripped}
    try:
        return json.loads(stripped)
    except json.JSONDecodeError:
        return {"verified": False, "raw": stripped}


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def write_json(path: Path, payload: Any) -> None:
    ensure_dir(path.parent)
    path.write_text(json.dumps(payload, indent=2, sort_keys=False) + "\n")


def archive_one(label: str, address: str, env: dict[str, str]) -> dict[str, Any]:
    source_via_tool = call_recon("src", CHAIN, address)
    full_response = etherscan_request("getsourcecode", address, env)
    result_list = full_response.get("result") or []
    record = result_list[0] if result_list else {}
    source_code = record.get("SourceCode", "")

    # The harness requested recon.sh src for the source fetch path. Keep the
    # response and Etherscan metadata aligned, but trust the full response when
    # they differ because it contains the parsing fields we need.
    if source_via_tool.strip() and not source_code:
        source_code = source_via_tool

    raw_abi = call_recon("fetch_abi", CHAIN, address)
    verified = bool(source_code.strip()) and source_code.strip() != "Contract source code not verified"
    layout, files = extract_source_files(record, source_code)

    target_dir = OUT_ROOT / f"{address.lower()}_{label.lower()}"
    src_dir = target_dir / "src"
    ensure_dir(src_dir)

    for relative_path, content in files:
        file_path = src_dir / clean_relative_path(relative_path)
        ensure_dir(file_path.parent)
        file_path.write_text(content)

    proxy_impl = (record.get("Implementation") or "").strip() or None
    metadata = {
        "label": label,
        "address": address,
        "chain": CHAIN,
        "chain_id": CHAIN_ID,
        "contract_name": record.get("ContractName") or None,
        "compiler_version": record.get("CompilerVersion") or None,
        "compiler_type": record.get("CompilerType") or None,
        "optimizer_enabled": parse_bool_flag(record.get("OptimizationUsed")),
        "optimizer_runs": parse_int(record.get("Runs")),
        "evm_version": record.get("EVMVersion") or None,
        "libraries": parse_libraries(record.get("Library")),
        "license_type": record.get("LicenseType") or None,
        "proxy": parse_bool_flag(record.get("Proxy")),
        "proxy_implementation": proxy_impl,
        "verified": verified,
        "source_layout": layout,
        "source_files": [path for path, _ in files],
    }

    write_json(target_dir / "metadata.json", metadata)
    write_json(target_dir / "abi.json", abi_payload(raw_abi))
    return {
        "label": label,
        "address": address,
        "path": str(target_dir.relative_to(ROOT)),
        "verified": verified,
        "contract_name": record.get("ContractName") or "",
        "proxy_implementation": proxy_impl,
    }


def write_index(entries: list[dict[str, Any]]) -> None:
    lines = [
        "# ch1_uranium Archived Sources",
        "",
        "| Role | Address | Verified | Contract | Proxy Implementation | Path |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    for entry in entries:
        lines.append(
            "| {label} | `{address}` | {verified} | {contract_name} | {proxy_impl} | `{path}` |".format(
                label=entry["label"],
                address=entry["address"],
                verified="yes" if entry["verified"] else "no",
                contract_name=entry["contract_name"] or "-",
                proxy_impl=entry["proxy_implementation"] or "-",
                path=entry["path"],
            )
        )
    lines.append("")
    (OUT_ROOT / "INDEX.md").write_text("\n".join(lines))


def main() -> int:
    env = {**os.environ, **load_dotenv(ROOT / ".env")}
    entries: list[dict[str, Any]] = []

    for label, address in CONTRACTS:
        entries.append(archive_one(label, address, env))

    ensure_dir(OUT_ROOT)
    write_index(entries)
    return 0


if __name__ == "__main__":
    sys.exit(main())
