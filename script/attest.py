#!/usr/bin/env python3
"""Reproduce or check the unsigned launch build record using installed Foundry and Python."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "launch-attestation.json"


def command(*args):
    result = subprocess.run(args, cwd=ROOT, text=True, capture_output=True, check=False)
    if result.returncode:
        raise SystemExit(result.stdout + result.stderr)
    return result.stdout.strip()


def sha256(path):
    return hashlib.sha256((ROOT / path).read_bytes()).hexdigest()


def build_record():
    command("forge", "build")
    manifest = json.loads((ROOT / "launch.json").read_text())
    assert set(manifest) == {"kind", "hook", "token", "pool", "notes"}
    assert manifest["kind"] == "univ4_hook"
    assert manifest["token"] == {
        "contract": "SovrnToken", "name": "SOVRN.ONE", "symbol": "SVO", "decimals": 18
    }
    assert manifest["hook"] == {
        "contract": "SovrnHook",
        "constructorArgs": ["$poolManager", "$token", "$factory"],
        "permissions": ["beforeInitialize", "beforeAddLiquidity", "beforeSwap", "afterSwap", "beforeSwapReturnDelta", "afterSwapReturnDelta"],
    }
    assert manifest["pool"] == {
        "pairedCurrency": "0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127",
        "fee": 12500, "tickSpacing": 60,
        "initialPrice": "45742400955009932534161870629490",
    }
    contracts = {}
    source_paths = set()
    constructor_types = {
        "SovrnToken": [], "SovrnHook": ["address", "address", "address"],
        "LifeForceVault": ["address", "address", "address"],
    }
    for name, types in constructor_types.items():
        artifact = json.loads((ROOT / "out" / (name + ".sol") / (name + ".json")).read_text())
        metadata = artifact["metadata"]
        assert metadata["compiler"]["version"] == "0.8.26+commit.8a97fa7a"
        settings = metadata["settings"]
        assert settings["optimizer"] == {"enabled": True, "runs": 200}
        assert settings["evmVersion"] == "cancun" and settings["viaIR"]
        assert settings["metadata"]["bytecodeHash"] == "none"
        ctor = next(entry for entry in artifact["abi"] if entry["type"] == "constructor")
        assert [item["type"] for item in ctor["inputs"]] == types
        code = artifact["bytecode"]["object"]
        size = len(bytes.fromhex(code.removeprefix("0x")))
        runtime_size = len(bytes.fromhex(artifact["deployedBytecode"]["object"].removeprefix("0x")))
        assert size + 32 * len(types) <= 49152 and runtime_size <= 24576
        contracts[name] = {
            "source": "src/" + name + ".sol",
            "constructorTypes": types,
            "creationBytecode": code,
            "creationBytecodeKeccak256": command("cast", "keccak", code),
            "creationBytecodeBytes": size,
            "runtimeTemplateBytes": runtime_size,
            "abi": artifact["abi"],
        }
        source_paths.update(metadata["sources"])
    delivery_paths = {"README.md", "launch.json", "foundry.toml", "script/attest.py"}
    delivery_paths.update(str(p.relative_to(ROOT)) for p in (ROOT / "src").glob("*.sol"))
    delivery_paths.update(str(p.relative_to(ROOT)) for p in (ROOT / "script").glob("*.sol"))
    delivery_paths.update(str(p.relative_to(ROOT)) for p in (ROOT / "test").rglob("*" )
                          if p.is_file() and "scratch" not in p.relative_to(ROOT / "test").parts)
    return {
        "format": "sovrn-launch-build-v1",
        "status": "unsigned reproducible local build; no deployment or independent certification",
        "chainId": 4663,
        "kind": "univ4_hook",
        "compiler": "0.8.26+commit.8a97fa7a",
        "settings": {"evmVersion": "cancun", "viaIR": True, "optimizerRuns": 200, "bytecodeHash": "none"},
        "hookFlags": 10444,
        "hookConstructorArgs": manifest["hook"]["constructorArgs"],
        "pool": manifest["pool"],
        "refuelSafe": "0xEb57c52272B90F989C41B739e2ccc5f00bF7697C",
        "vaultDeployment": "Created only by the SovrnHook constructor; discover through vault().",
        "initcodeNote": "Append ABI-encoded actual constructor arguments before hashing for CREATE2. Runtime immutables also depend on deployment addresses.",
        "sourceSha256": {p: sha256(p) for p in sorted(source_paths)},
        "deliverySha256": {p: sha256(p) for p in sorted(delivery_paths)},
        "contracts": contracts,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Compare the existing record without modifying it")
    args = parser.parse_args()
    record = build_record()
    if args.check:
        assert json.loads(OUTPUT.read_text()) == record, "launch attestation differs; regenerate after reviewing changes"
        print("Launch manifest and attestation match the current build.")
    else:
        OUTPUT.write_text(json.dumps(record, indent=2) + "\n")
        print("Wrote launch-attestation.json.")


if __name__ == "__main__":
    main()
