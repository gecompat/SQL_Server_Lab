#!/usr/bin/env python3
"""Validate the LAB-001 Welle 5 Hyper-V image-pipeline foundation."""

from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path


EXPECTED_PARENTS = {
    "2019": (15, "W5-WINCORE-SQL2019", "SQL_SERVER_2019_DEVELOPER_WINDOWS"),
    "2022": (16, "W5-WINCORE-SQL2022", "SQL_SERVER_2022_DEVELOPER_WINDOWS"),
    "2025": (17, "W5-WINCORE-SQL2025", "SQL_SERVER_2025_DEVELOPER_WINDOWS"),
}

EXPECTED_STAGES = [
    "RESOLVE_LOCAL_BINDINGS",
    "VERIFY_MEDIA_CHECKSUMS",
    "CREATE_BUILD_DISK",
    "INSTALL_WINDOWS_SERVER_CORE",
    "INSTALL_SQL_SERVER",
    "APPLY_SYNTHETIC_GUEST_CONFIGURATION",
    "SEAL_PARENT",
    "REGISTER_IMMUTABLE_PARENT",
    "CREATE_DIFFERENCING_CHILD",
    "VERIFY_POWERSHELL_DIRECT",
    "DISPOSE_CHILD",
]

REQUIRED_MEDIA = {
    "WINDOWS_SERVER_CORE": ("WINDOWS_SERVER", "SUPPORTED_RELEASE_REQUIRED"),
    "SQL_SERVER_2019_DEVELOPER_WINDOWS": ("SQL_SERVER", "2019"),
    "SQL_SERVER_2022_DEVELOPER_WINDOWS": ("SQL_SERVER", "2022"),
    "SQL_SERVER_2025_DEVELOPER_WINDOWS": ("SQL_SERVER", "2025"),
}

REQUIRED_GATES = {
    "LAB-GATE-WAVE5-PARENT-BUILD": {
        "ScenarioGroup": "HYPERV_IMAGE_PIPELINE",
        "RequiredPlatform": "HYPER_V_WINDOWS",
        "RequiredCapability": "HYPER_V_IMAGE_BUILD",
        "ExecutionMode": "WINDOWS_SINGLE_HOST",
        "Status": "NOT_EXECUTED",
        "EvidencePolicy": "SYNTHETIC_SUMMARY_ONLY",
        "BlockingScope": "WAVE5_RUNTIME_NOT_IMPLEMENTED",
    },
    "LAB-GATE-WAVE5-CHILD-RESET": {
        "ScenarioGroup": "HYPERV_CHILD_RESET",
        "RequiredPlatform": "HYPER_V_WINDOWS",
        "RequiredCapability": "HYPER_V_DIFFERENCING_DISK_RESET",
        "ExecutionMode": "WINDOWS_SINGLE_HOST",
        "Status": "NOT_EXECUTED",
        "EvidencePolicy": "SYNTHETIC_SUMMARY_ONLY",
        "BlockingScope": "WAVE5_RUNTIME_NOT_IMPLEMENTED",
    },
}

REQUIRED_FILES = {
    ".github/workflows/lab-contract-validation.yml",
    "Code/Tests/Static/Validate_LAB001_Wave5_ImagePipelineFoundation.py",
    "Lab/.gitignore",
    "Lab/Config/image-lock.example.json",
    "Lab/Contracts/hyperv-image-pipeline.schema.json",
    "Lab/HyperV/Images/README.md",
    "Lab/HyperV/Images/image-pipeline-contract.json",
    "Lab/Validation/Invoke-LabValidation.ps1",
    "Metadata/Quality/Lab_External_Evidence_Gates.csv",
    "Metadata/Quality/Lab_Wave_Status.csv",
}

FORBIDDEN_IMAGE_SUFFIXES = {".avhdx", ".iso", ".vhd", ".vhdx", ".wim"}
ACTUAL_SHA256 = re.compile(r"(?i)\b[0-9a-f]{64}\b")


def load_json(path: Path) -> object:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def load_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def require(condition: bool, message: str, findings: list[str]) -> None:
    if not condition:
        findings.append(message)


def validate_contract(root: Path, findings: list[str]) -> dict[str, object]:
    contract = load_json(root / "Lab/HyperV/Images/image-pipeline-contract.json")
    if not isinstance(contract, dict):
        findings.append("Welle 5 image-pipeline contract root is not an object.")
        return {}

    require(
        contract.get("SchemaVersion") == "1.0"
        and contract.get("WaveId") == "LAB-001-WAVE5"
        and contract.get("ContractStatus") == "VALIDATED_FOUNDATION"
        and contract.get("RuntimeStatus") == "NOT_EXECUTED"
        and contract.get("DataClassification") == "SYNTHETIC",
        "Welle 5 contract status or classification is invalid.",
        findings,
    )

    adapters = {
        item.get("AdapterId"): item
        for item in contract.get("BuilderAdapters", [])
        if isinstance(item, dict)
    }
    require(
        set(adapters) == {"NATIVE_POWERSHELL", "PACKER"}
        and len(contract.get("BuilderAdapters", [])) == len(adapters),
        "Welle 5 builder adapter set is invalid.",
        findings,
    )
    native = adapters.get("NATIVE_POWERSHELL", {})
    packer = adapters.get("PACKER", {})
    require(
        native.get("SupportLevel") == "REQUIRED"
        and native.get("ExecutionStatus") == "NOT_EXECUTED"
        and native.get("LocalExecutableBindingRequired") is False,
        "Native PowerShell adapter contract is invalid.",
        findings,
    )
    require(
        packer.get("SupportLevel") == "OPTIONAL"
        and packer.get("ExecutionStatus") == "NOT_EXECUTED"
        and packer.get("LocalExecutableBindingRequired") is True,
        "Optional Packer adapter contract is invalid.",
        findings,
    )

    parent_rows = contract.get("ParentMatrix", [])
    parents = {
        str(item.get("SqlVersion")): item
        for item in parent_rows
        if isinstance(item, dict)
    }
    require(
        set(parents) == set(EXPECTED_PARENTS) and len(parent_rows) == len(parents),
        "Welle 5 parent matrix must contain exactly SQL Server 2019, 2022, and 2025.",
        findings,
    )
    for version, (major, parent_id, sql_media_id) in EXPECTED_PARENTS.items():
        row = parents.get(version, {})
        require(
            row.get("SqlMajorVersion") == major
            and row.get("ParentLogicalId") == parent_id
            and row.get("WindowsMediaLogicalId") == "WINDOWS_SERVER_CORE"
            and row.get("SqlMediaLogicalId") == sql_media_id,
            f"SQL Server {version} parent mapping is invalid.",
            findings,
        )
        require(
            row.get("ParentState") == "UNBUILT_EXAMPLE"
            and row.get("ParentImmutable") is True
            and row.get("AllowInPlaceMutation") is False
            and row.get("ChecksumPolicy") == "SHA256_REQUIRED"
            and row.get("OutputPolicy") == "LOCAL_IGNORED_ONLY"
            and row.get("GuestManagementChannel") == "POWERSHELL_DIRECT",
            f"SQL Server {version} parent safety boundary is invalid.",
            findings,
        )

    stages = contract.get("PipelineStages", [])
    require(
        [item.get("StageId") for item in stages if isinstance(item, dict)]
        == EXPECTED_STAGES
        and [item.get("Ordinal") for item in stages if isinstance(item, dict)]
        == list(range(1, 12)),
        "Welle 5 pipeline stage order is invalid.",
        findings,
    )
    for stage in stages:
        if not isinstance(stage, dict):
            findings.append("Welle 5 pipeline stage is not an object.")
            continue
        guards = stage.get("RequiredGuards", [])
        require(
            stage.get("ExecutionStatus") == "NOT_EXECUTED"
            and isinstance(guards, list)
            and bool(guards)
            and len(guards) == len(set(guards)),
            f"{stage.get('StageId')}: execution status or guards are invalid.",
            findings,
        )

    reset = contract.get("ChildResetContract", {})
    require(
        isinstance(reset, dict)
        and reset.get("ResetMethod") == "NEW_DIFFERENCING_DISK"
        and reset.get("ParentReadOnly") is True
        and reset.get("AllowParentMutation") is False
        and reset.get("AllowCheckpointAsCanonicalReset") is False
        and reset.get("RequireRegisteredObjectIds") is True
        and reset.get("AllowNameOnlyDeletion") is False
        and reset.get("ChildStateClassification") == "LOCAL_RUNTIME_STATE"
        and reset.get("FailedChildReusePolicy") == "DISCARD_AND_RECREATE",
        "Welle 5 child-reset contract is unsafe or incomplete.",
        findings,
    )
    return contract


def validate_media_example(
    root: Path,
    contract: dict[str, object],
    findings: list[str],
) -> None:
    image_lock = load_json(root / "Lab/Config/image-lock.example.json")
    if not isinstance(image_lock, dict):
        findings.append("Image-lock example root is not an object.")
        return
    require(
        image_lock.get("DataClassification") == "PUBLIC_AND_SYNTHETIC",
        "Image-lock example classification is invalid.",
        findings,
    )

    media_rows = image_lock.get("Media", [])
    media = {
        item.get("LogicalMediaId"): item
        for item in media_rows
        if isinstance(item, dict)
    }
    require(
        set(media) == set(REQUIRED_MEDIA) and len(media_rows) == len(media),
        "Image-lock example media set is incomplete or duplicated.",
        findings,
    )

    referenced_media = set()
    for row in contract.get("ParentMatrix", []):
        if isinstance(row, dict):
            referenced_media.add(row.get("WindowsMediaLogicalId"))
            referenced_media.add(row.get("SqlMediaLogicalId"))
    require(
        referenced_media == set(REQUIRED_MEDIA),
        "Parent matrix media references do not match the public image-lock example.",
        findings,
    )

    forbidden_fields = {
        "Path",
        "FileName",
        "Uri",
        "ProductKey",
        "Credential",
        "Password",
    }
    for media_id, (family, version) in REQUIRED_MEDIA.items():
        row = media.get(media_id, {})
        require(
            row.get("ProductFamily") == family
            and row.get("ProductVersion") == version
            and row.get("Language") == "CONFIGURED_LANGUAGE_REQUIRED"
            and row.get("Checksum") == "SHA256_CHECKSUM_REQUIRED"
            and row.get("Status") == "LOCAL_BINDING_REQUIRED",
            f"{media_id}: public media binding is not an unresolved placeholder.",
            findings,
        )
        require(
            forbidden_fields.isdisjoint(row),
            f"{media_id}: public media binding exposes a local or sensitive field.",
            findings,
        )


def validate_evidence_gates(
    root: Path,
    contract: dict[str, object],
    findings: list[str],
) -> None:
    contract_rows = contract.get("ExternalEvidenceGates", [])
    contract_gates = {
        item.get("GateId"): item
        for item in contract_rows
        if isinstance(item, dict)
    }
    require(
        set(contract_gates) == set(REQUIRED_GATES)
        and len(contract_rows) == len(contract_gates),
        "Welle 5 contract evidence-gate set is incomplete.",
        findings,
    )

    global_gates = {
        row.get("GateId"): row
        for row in load_csv(root / "Metadata/Quality/Lab_External_Evidence_Gates.csv")
    }
    for gate_id, expected in REQUIRED_GATES.items():
        local = contract_gates.get(gate_id, {})
        global_row = global_gates.get(gate_id, {})
        require(
            local.get("Status") == "NOT_EXECUTED"
            and local.get("EvidencePolicy") == "SYNTHETIC_SUMMARY_ONLY"
            and local.get("RequiredPlatform") == "HYPER_V_WINDOWS"
            and local.get("RequiredCapability") == expected["RequiredCapability"],
            f"{gate_id}: contract evidence status is missing or overstated.",
            findings,
        )
        require(
            all(global_row.get(key) == value for key, value in expected.items()),
            f"{gate_id}: canonical external evidence gate is missing or overstated.",
            findings,
        )


def validate_status_and_ignore(root: Path, findings: list[str]) -> None:
    wave = next(
        (
            row
            for row in load_csv(root / "Metadata/Quality/Lab_Wave_Status.csv")
            if row.get("WaveId") == "LAB-001-WAVE5"
        ),
        {},
    )
    require(
        wave.get("ContractStatus") == "PLANNED"
        and wave.get("RuntimeStatus") == "NOT_EXECUTED",
        "Welle 5 global status must remain PLANNED and NOT_EXECUTED.",
        findings,
    )

    ignore = (root / "Lab/.gitignore").read_text(encoding="utf-8")
    for fragment in (
        "/HyperV/Images/output-*/",
        "/HyperV/Images/*.iso",
        "/HyperV/Images/*.vhd",
        "/HyperV/Images/*.vhdx",
        "/HyperV/Images/*.avhdx",
    ):
        require(fragment in ignore, f"Lab ignore boundary lacks {fragment}.", findings)

    for path in (root / "Lab/HyperV/Images").rglob("*"):
        if path.is_file() and path.suffix.lower() in FORBIDDEN_IMAGE_SUFFIXES:
            findings.append(
                f"Versioned Hyper-V image artifact is forbidden: {path.as_posix()}"
            )


def validate_integration(root: Path, findings: list[str]) -> None:
    workflow = (root / ".github/workflows/lab-contract-validation.yml").read_text(
        encoding="utf-8"
    )
    validation = (root / "Lab/Validation/Invoke-LabValidation.ps1").read_text(
        encoding="utf-8"
    )
    readme = (root / "Lab/HyperV/Images/README.md").read_text(
        encoding="utf-8"
    )

    for fragment in (
        "Validate_LAB001_Wave5_ImagePipelineFoundation.py",
        "Validate LAB-001 Wellen 0 to 5",
        "Validate Welle 5 image-pipeline foundation",
    ):
        require(fragment in workflow, f"Workflow integration lacks {fragment}.", findings)

    for fragment in (
        "image-pipeline-contract.json",
        "hyperv-image-pipeline.schema.json",
        "Validate_LAB001_Wave5_ImagePipelineFoundation.py",
    ):
        require(
            fragment in validation,
            f"PowerShell validation integration lacks {fragment}.",
            findings,
        )

    for fragment in (
        "validated contract foundation",
        "NOT_EXECUTED",
        "immutable",
        "differencing",
        "PowerShell Direct",
        "registered child resources",
    ):
        require(
            fragment.lower() in readme.lower(),
            f"Welle 5 README lacks the boundary '{fragment}'.",
            findings,
        )


def validate_privacy(root: Path, findings: list[str]) -> None:
    paths = [
        root / "Lab/Config/image-lock.example.json",
        root / "Lab/Contracts/hyperv-image-pipeline.schema.json",
        root / "Lab/HyperV/Images/README.md",
        root / "Lab/HyperV/Images/image-pipeline-contract.json",
    ]
    combined = "\n".join(path.read_text(encoding="utf-8") for path in paths)
    require(
        ACTUAL_SHA256.search(combined) is None,
        "Welle 5 public scope contains a resolved checksum or digest.",
        findings,
    )
    for forbidden in ("C:\\Users\\", "/home/", "@example."):
        require(
            forbidden.lower() not in combined.lower(),
            "Welle 5 public scope contains a local or identity-like value.",
            findings,
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", default=".")
    args = parser.parse_args()
    root = Path(args.repository_root).resolve()
    findings: list[str] = []

    for relative_path in sorted(REQUIRED_FILES):
        require(
            (root / relative_path).is_file(),
            f"Missing required Welle 5 contract file: {relative_path}",
            findings,
        )

    contract = validate_contract(root, findings)
    if contract:
        validate_media_example(root, contract, findings)
        validate_evidence_gates(root, contract, findings)
    validate_status_and_ignore(root, findings)
    validate_integration(root, findings)
    validate_privacy(root, findings)

    if findings:
        for finding in findings:
            print(f"ERROR: {finding}")
        return 1

    print(
        "LAB-001 Welle 5 image-pipeline foundation validated: "
        "parents=3 stages=11 external_gates=2 runtime=NOT_EXECUTED."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
