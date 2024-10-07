from typing import List

from .step import TestStep

def step_should_run(step: TestStep, run_all: bool, list_file_diff: List[str]) -> bool:
    """Determine whether the step should automatically run or not."""
    if step.optional:
        return False
    if not step.source_file_dependencies or run_all:
        return True
    return any(source_file in diff_file
        for source_file in step.source_file_dependencies
        for diff_file in list_file_diff
    )
