import pytest
import sys
from typing import List

from scripts.pipeline_generator.step import get_step_key, get_block_step, BuildkiteBlockStep

@pytest.mark.parametrize(
    ("step_label", "expected_result"),
    [
        ("Test Step", "test-step"),
        ("Test Step 2", "test-step-2"),
        ("Test (Step)", "test-step"),
        ("Test A, B, C", "test-a-b-c"),
    ],
)
def test_get_step_key(step_label: str, expected_result: str):
    assert get_step_key(step_label) == expected_result

@pytest.mark.parametrize(
    ("step_label", "expected_result"),
    [
        ("Test Step", BuildkiteBlockStep(block="Run Test Step", key="block-test-step")),
        ("Test Step 2", BuildkiteBlockStep(block="Run Test Step 2", key="block-test-step-2")),
        ("Test (Step)", BuildkiteBlockStep(block="Run Test (Step)", key="block-test-step")),
        ("Test A, B, C", BuildkiteBlockStep(block="Run Test A, B, C", key="block-test-a-b-c")),
    ],
)
def test_get_block_step(step_label: str, expected_result: BuildkiteBlockStep):
    assert get_block_step(step_label) == expected_result

if __name__ == "__main__":
    sys.exit(pytest.main(["-v", __file__]))
