#!/usr/bin/env python3
"""Archive verified contract sources from Etherscan into sources/<challenge>/."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Dict, Iterable, List, Optional, Tuple


CHAIN_IDS = {
    "ethereum": 1,
    "polygon": 137,
    "bsc": 56,
}

ROOT = Path(__file__).resolve().parent.parent
RECON = ROOT / "tools" / "recon.sh"
ENV = ROOT / ".env"
FILE_MARKER_RE = re.compile(r"^\s*// File:\s+(.+?)\s*$")
ADDR_RE = re.compile(r"^0x[a-fA-F0-9]{40}$")


@dataclass
class ContractSpec:
    address: str
    label: str
    requested: bool = False
    discovered_via: Optional[str] = None


@dataclass
class ArchiveResult:
    address: str
    label: str
    requested: bool
    discovered_via: Optional[str]
    contract_name: str
    source_format: str
    proxy: bool
    proxy_implementation: Optional[str]
    directory: str
    source_files: List[str] = field(default_factory=list)
    compiler_version: str = ""
    verified: bool = True


def load_env() -> Dict[str, str]:
    env: Dict[str, str] = {}
    if not ENV.exists():
        return env
    for line in ENV.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = value.strip().strip('"').strip("'")
    return env


def run_cmd(args: List[str]) -> str:
    proc = subprocess.run(args, cwd=ROOT, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"command failed: {' '.join(args)}\n{proc.stderr.strip()}")
    return proc.stdout


def etherscan_get_source_metadata(chain: str, address: str, api_key: str) -> dict:
    chain_id = CHAIN_IDS[chain]
    params = {
        "chainid": str(chain_id),
        "module": "contract",
        "action": "getsourcecode",
        "address": address,
        "apikey": api_key,
    }
    url = "https://api.etherscan.io/v2/api?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url) as resp:
        payload = json.loads(resp.read().decode())
    result = payload.get("result")
    if not isinstance(result, list) or not result or not isinstance(result[0], dict):
        raise RuntimeError(f"unexpected Etherscan getsourcecode result for {address}: {payload!r}")
    return result[0]


def fetch_source_via_recon(chain: str, address: str) -> str:
    return run_cmd([str(RECON), "src", chain, address])


def fetch_abi_via_recon(chain: str, address: str) -> Tuple[object, bool]:
    raw = run_cmd([str(RECON), "fetch_abi", chain, address]).strip()
    try:
        return json.loads(raw), True
    except json.JSONDecodeError:
        return {"verified": False, "raw": raw}, False


def sanitize_label(label: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", label.strip())
    return cleaned or "contract"


def sanitize_contract_filename(name: str, label: str, ext: str) -> str:
    base = sanitize_label(name or "")
    if not base or base == "Vyper_contract":
        base = sanitize_label(label)
    return f"{base}{ext}"


def safe_relpath(path_str: str, fallback_name: str) -> str:
    path_str = (path_str or "").strip().replace("\\", "/")
    if not path_str:
        return fallback_name
    raw = PurePosixPath(path_str)
    parts = []
    for part in raw.parts:
        if part in ("", ".", "/"):
            continue
        if part == "..":
            continue
        parts.append(part)
    if not parts:
        return fallback_name
    return str(PurePosixPath(*parts))


def normalize_source_map(source_obj: dict) -> Dict[str, str]:
    result: Dict[str, str] = {}
    sources = source_obj.get("sources") if "sources" in source_obj else source_obj
    if not isinstance(sources, dict):
        raise ValueError("source JSON did not contain a sources object")
    for path, entry in sources.items():
        if isinstance(entry, dict):
            if "content" in entry:
                content = entry["content"]
            elif "source" in entry:
                content = entry["source"]
            else:
                content = json.dumps(entry, indent=2)
        else:
            content = str(entry)
        result[safe_relpath(str(path), "Contract.sol")] = normalize_newlines(content)
    return result


def normalize_newlines(text: str) -> str:
    return text.replace("\r\n", "\n").replace("\r", "\n")


def parse_wrapped_json_source(raw_source: str) -> Optional[Dict[str, str]]:
    text = raw_source.strip()
    if not text:
        return None
    candidates = []
    if text.startswith("{{") and text.endswith("}}"):
        candidates.append(text[1:-1])
    if text.startswith("{") and text.endswith("}"):
        candidates.append(text)
    for candidate in candidates:
        try:
            obj = json.loads(candidate)
        except json.JSONDecodeError:
            continue
        if isinstance(obj, dict):
            try:
                return normalize_source_map(obj)
            except ValueError:
                continue
    return None


def parse_flattened_solidity(raw_source: str, contract_name: str, label: str) -> Optional[Dict[str, str]]:
    lines = normalize_newlines(raw_source).splitlines(keepends=True)
    markers = [idx for idx, line in enumerate(lines) if FILE_MARKER_RE.match(line)]
    if not markers:
        return None

    files: Dict[str, str] = {}
    current_path: Optional[str] = None
    current_lines: List[str] = []
    preamble: List[str] = []

    def flush_current() -> None:
        nonlocal current_path, current_lines, preamble
        content = "".join(current_lines)
        if current_path is None:
            preamble.extend(current_lines)
        else:
            files[current_path] = files.get(current_path, "") + content
        current_lines = []

    for line in lines:
        match = FILE_MARKER_RE.match(line)
        if match:
            flush_current()
            current_path = safe_relpath(match.group(1), sanitize_contract_filename(contract_name, label, ".sol"))
            continue
        current_lines.append(line)
    flush_current()

    if preamble:
        preamble_name = sanitize_contract_filename(contract_name, label, ".sol")
        files[preamble_name] = "".join(preamble) + files.get(preamble_name, "")

    normalized = {path: normalize_newlines(content).rstrip("\n") + "\n" for path, content in files.items()}
    return normalized if normalized else None


def detect_vyper(raw_source: str, compiler_version: str) -> bool:
    stripped = raw_source.lstrip()
    return compiler_version.lower().startswith("vyper") or stripped.startswith("#")


def parse_source_files(raw_source: str, compiler_version: str, contract_name: str, label: str) -> Tuple[str, Dict[str, str]]:
    cleaned = normalize_newlines(raw_source)
    stripped = cleaned.strip()
    if not stripped:
        return "unverified", {}

    json_sources = parse_wrapped_json_source(cleaned)
    if json_sources is not None:
        return "standard_json", json_sources

    if detect_vyper(cleaned, compiler_version):
        file_name = sanitize_contract_filename(contract_name, label, ".vy")
        return "vyper_raw", {file_name: cleaned.rstrip("\n") + "\n"}

    flattened = parse_flattened_solidity(cleaned, contract_name, label)
    if flattened is not None:
        return "flattened_markers", flattened

    file_name = sanitize_contract_filename(contract_name, label, ".sol")
    return "single_file", {file_name: cleaned.rstrip("\n") + "\n"}


def parse_boolish(value: str) -> Optional[bool]:
    value = (value or "").strip()
    if value == "1":
        return True
    if value == "0":
        return False
    return None


def parse_libraries(raw_value: str) -> List[str]:
    raw_value = (raw_value or "").strip()
    if not raw_value:
        return []
    parts = [part.strip() for part in raw_value.split(";")]
    return [part for part in parts if part]


def derive_impl_label(label: str, address: str) -> str:
    if label.endswith("_proxy"):
        return f"{label[:-6]}_current_impl"
    return f"{label}_impl_{address.lower()[2:8]}"


def unique_label(base_label: str, used: Iterable[str], address: str) -> str:
    if base_label not in used:
        return base_label
    return f"{base_label}_{address.lower()[2:8]}"


def write_json(path: Path, data: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=False) + "\n")


def archive_contract(
    root_dir: Path,
    chain: str,
    chain_id: int,
    spec: ContractSpec,
    source_meta: dict,
    raw_source: str,
    abi_obj: object,
    abi_verified: bool,
) -> ArchiveResult:
    address_lower = spec.address.lower()
    contract_dir = root_dir / f"{address_lower}_{sanitize_label(spec.label)}"
    src_dir = contract_dir / "src"
    src_dir.mkdir(parents=True, exist_ok=True)

    contract_name = source_meta.get("ContractName") or sanitize_label(spec.label)
    compiler_version = source_meta.get("CompilerVersion") or ""
    proxy_implementation = (source_meta.get("Implementation") or "").strip() or None
    source_format, file_map = parse_source_files(raw_source, compiler_version, contract_name, spec.label)
    verified = bool(file_map)

    written_files: List[str] = []
    for rel_path, content in sorted(file_map.items()):
        out_path = src_dir / rel_path
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(content)
        written_files.append(str(PurePosixPath("src") / PurePosixPath(rel_path)))

    metadata = {
        "address": spec.address,
        "address_lower": address_lower,
        "label": spec.label,
        "chain": chain,
        "chain_id": chain_id,
        "requested": spec.requested,
        "discovered_via": spec.discovered_via,
        "verified": verified,
        "contract_name": contract_name,
        "compiler_version": compiler_version,
        "optimizer_enabled": parse_boolish(source_meta.get("OptimizationUsed", "")),
        "optimizer_runs": int(source_meta["Runs"]) if str(source_meta.get("Runs", "")).isdigit() else source_meta.get("Runs", ""),
        "evm_version": source_meta.get("EVMVersion") or "",
        "libraries": parse_libraries(source_meta.get("Library", "")),
        "libraries_raw": source_meta.get("Library", ""),
        "license_type": source_meta.get("LicenseType") or "",
        "proxy": parse_boolish(source_meta.get("Proxy", "")),
        "proxy_implementation": proxy_implementation,
        "constructor_arguments": source_meta.get("ConstructorArguments") or "",
        "source_format": source_format,
        "source_file_count": len(written_files),
        "source_files": written_files,
        "abi_verified": abi_verified,
        "fetched_at_utc": datetime.now(timezone.utc).isoformat(),
        "swarm_source": source_meta.get("SwarmSource") or "",
        "similar_match": source_meta.get("SimilarMatch") or "",
    }

    write_json(contract_dir / "metadata.json", metadata)
    write_json(contract_dir / "abi.json", abi_obj)

    return ArchiveResult(
        address=spec.address,
        label=spec.label,
        requested=spec.requested,
        discovered_via=spec.discovered_via,
        contract_name=contract_name,
        source_format=source_format,
        proxy=bool(metadata["proxy"]),
        proxy_implementation=proxy_implementation,
        directory=str(contract_dir.relative_to(root_dir.parent)),
        source_files=written_files,
        compiler_version=compiler_version,
        verified=verified,
    )


def build_index(
    challenge: str,
    chain: str,
    results: List[ArchiveResult],
    output_path: Path,
) -> None:
    now = datetime.now(timezone.utc).isoformat()
    requested = [item for item in results if item.requested]
    discovered = [item for item in results if not item.requested]

    lines = [
        f"# {challenge} source archive",
        "",
        f"Generated: {now}",
        f"Chain: {chain} (chain_id={CHAIN_IDS[chain]})",
        "Fetch path: `tools/recon.sh src` + `tools/recon.sh fetch_abi` with Etherscan `getsourcecode` metadata.",
        "Constraint: archive-only generation under `sources/`; no challenge RPC touched.",
        "",
        "## Summary",
        "",
        f"- Requested contracts archived: {len(requested)}",
        f"- Additional proxy implementations archived: {len(discovered)}",
        f"- Total archived directories: {len(results)}",
        "",
        "## Contracts",
        "",
        "| Label | Address | Contract | Requested | Proxy | Impl | Format | Files | Path |",
        "| --- | --- | --- | --- | --- | --- | --- | ---: | --- |",
    ]

    for item in sorted(results, key=lambda x: (not x.requested, x.label.lower(), x.address.lower())):
        impl = item.proxy_implementation or ""
        lines.append(
            f"| {item.label} | `{item.address}` | `{item.contract_name}` | "
            f"{'yes' if item.requested else 'no'} | "
            f"{'yes' if item.proxy else 'no'} | "
            f"`{impl}` | `{item.source_format}` | {len(item.source_files)} | `{item.directory}` |"
        )

    proxy_mismatches = []
    label_map = {item.label: item for item in results}
    if "HVault_fUSDT_proxy" in label_map and "HVault_fUSDT_impl" in label_map:
        proxy_impl = (label_map["HVault_fUSDT_proxy"].proxy_implementation or "").lower()
        listed_impl = label_map["HVault_fUSDT_impl"].address.lower()
        if proxy_impl and proxy_impl != listed_impl:
            proxy_mismatches.append(
                f"- `HVault_fUSDT_proxy` currently reports Etherscan implementation `{proxy_impl}`, "
                f"while the assignment-relevant listed implementation is `{listed_impl}`."
            )

    if proxy_mismatches or discovered:
        lines.extend(["", "## Notes", ""])
        for note in proxy_mismatches:
            lines.append(note)
        for item in sorted(discovered, key=lambda x: x.label.lower()):
            if item.discovered_via:
                lines.append(
                    f"- `{item.label}` was archived recursively from proxy metadata on `{item.discovered_via}`."
                )

    output_path.write_text("\n".join(lines) + "\n")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--challenge", required=True)
    parser.add_argument("--chain", required=True, choices=sorted(CHAIN_IDS))
    parser.add_argument(
        "--contract",
        action="append",
        default=[],
        help="address=label",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    env = load_env()
    api_key = env.get("ETHERSCAN_API_KEY", "")
    if not api_key:
        print("ETHERSCAN_API_KEY is required", file=sys.stderr)
        return 1

    initial_specs: List[ContractSpec] = []
    seen_addresses: set[str] = set()
    used_labels: set[str] = set()
    queue: List[ContractSpec] = []

    for item in args.contract:
        if "=" not in item:
            raise SystemExit(f"invalid --contract value: {item}")
        address, label = item.split("=", 1)
        address = address.strip()
        if not ADDR_RE.match(address):
            raise SystemExit(f"invalid address: {address}")
        label = sanitize_label(label)
        spec = ContractSpec(address=address, label=label, requested=True)
        initial_specs.append(spec)
        queue.append(spec)
        seen_addresses.add(address.lower())
        used_labels.add(label)

    out_root = ROOT / "sources" / args.challenge
    out_root.mkdir(parents=True, exist_ok=True)

    results: List[ArchiveResult] = []
    chain_id = CHAIN_IDS[args.chain]

    while queue:
        spec = queue.pop(0)
        source_meta = etherscan_get_source_metadata(args.chain, spec.address, api_key)
        raw_source = fetch_source_via_recon(args.chain, spec.address)
        abi_obj, abi_verified = fetch_abi_via_recon(args.chain, spec.address)

        result = archive_contract(
            root_dir=out_root,
            chain=args.chain,
            chain_id=chain_id,
            spec=spec,
            source_meta=source_meta,
            raw_source=raw_source,
            abi_obj=abi_obj,
            abi_verified=abi_verified,
        )
        results.append(result)

        proxy_impl = result.proxy_implementation
        if (
            spec.requested
            and result.proxy
            and proxy_impl
            and ADDR_RE.match(proxy_impl)
            and proxy_impl.lower() not in seen_addresses
        ):
            derived = unique_label(derive_impl_label(spec.label, proxy_impl), used_labels, proxy_impl)
            queue.append(
                ContractSpec(
                    address=proxy_impl,
                    label=derived,
                    requested=False,
                    discovered_via=spec.label,
                )
            )
            seen_addresses.add(proxy_impl.lower())
            used_labels.add(derived)

    build_index(args.challenge, args.chain, results, out_root / "INDEX.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
