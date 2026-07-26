#!/usr/bin/env python3
"""Self-tests for the FWK-011 evaluator."""

from __future__ import annotations

import importlib.util
import json
import math
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EVALUATOR_PATH = ROOT / "Demos" / "00_Framework" / "Tools" / "evaluate_result_contract.py"
EXAMPLES = ROOT / "Demos" / "00_Framework" / "Examples"

spec = importlib.util.spec_from_file_location("fwk011_evaluator", EVALUATOR_PATH)
if spec is None or spec.loader is None:
    raise RuntimeError("evaluator module could not be loaded")
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


class ResultContractTests(unittest.TestCase):
    def test_pass_example(self) -> None:
        output, exit_code = module.run(
            EXAMPLES / "FWK-011_ResultContract.example.json",
            EXAMPLES / "FWK-011_Evidence.pass.example.json",
        )
        self.assertEqual(exit_code, 0)
        self.assertEqual(output[-1]["outcome"], "PASS")
        self.assertTrue(all(row["outcome"] == "PASS" for row in output[:-1]))

    def test_fail_example(self) -> None:
        output, exit_code = module.run(
            EXAMPLES / "FWK-011_ResultContract.example.json",
            EXAMPLES / "FWK-011_Evidence.fail.example.json",
        )
        self.assertEqual(exit_code, 1)
        self.assertEqual(output[-1]["outcome"], "FAIL")
        self.assertTrue(any(row["code"] == "FAIL_RESULT_CONTRACT" for row in output[:-1]))

    def test_non_finite_input_is_rejected(self) -> None:
        contract = json.loads(
            (EXAMPLES / "FWK-011_ResultContract.example.json").read_text(encoding="utf-8")
        )
        evidence = json.loads(
            (EXAMPLES / "FWK-011_Evidence.pass.example.json").read_text(encoding="utf-8")
        )
        evidence["comparison"]["logical_reads"] = math.nan

        with tempfile.TemporaryDirectory() as tmp:
            contract_path = Path(tmp) / "contract.json"
            evidence_path = Path(tmp) / "evidence.json"
            contract_path.write_text(json.dumps(contract), encoding="utf-8")
            evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
            with self.assertRaises(module.ContractError):
                module.run(contract_path, evidence_path)

    def test_zero_ratio_baseline_is_rejected(self) -> None:
        contract = json.loads(
            (EXAMPLES / "FWK-011_ResultContract.example.json").read_text(encoding="utf-8")
        )
        evidence = json.loads(
            (EXAMPLES / "FWK-011_Evidence.pass.example.json").read_text(encoding="utf-8")
        )
        evidence["baseline"]["logical_reads"] = 0

        with tempfile.TemporaryDirectory() as tmp:
            contract_path = Path(tmp) / "contract.json"
            evidence_path = Path(tmp) / "evidence.json"
            contract_path.write_text(json.dumps(contract), encoding="utf-8")
            evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
            with self.assertRaises(module.ContractError):
                module.run(contract_path, evidence_path)


if __name__ == "__main__":
    unittest.main()
