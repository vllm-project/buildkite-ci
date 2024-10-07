import pytest
import sys

from scripts.pipeline_generator.pipeline_generator_helper import step_should_run
from scripts.pipeline_generator.step import TestStep

def _get_test_step():
    return TestStep(
        label="Test",
        command="echo 'Hello, World!'",
    )

@pytest.mark.parametrize(
    ("run_all, source_file_dependencies, list_file_diff, expected"), 
    [
        (False, None, [], True),
        (True, None, [], True),
        (False, ["file1", "file2"], [], False),
        (True, ["file1", "file2"], [], True),
        (False, ["file1", "file2"], ["file1"], True),
        (False, ["file1", "file2"], ["file3"], False),
        (True, ["file1", "file2"], ["file3"], True),
    ]
)
def test_step_should_run(run_all, source_file_dependencies, list_file_diff, expected):
    test_step = _get_test_step()
    test_step.source_file_dependencies = source_file_dependencies
    assert step_should_run(test_step, run_all, list_file_diff) == expected

@pytest.mark.parametrize(
    ("run_all, source_file_dependencies, list_file_diff"), 
    [
        (False, None, []),
        (True, None, []),
        (False, ["file1", "file2"], []),
        (True, ["file1", "file2"], []),
        (False, ["file1", "file2"], ["file1"]),
        (False, ["file1", "file2"], ["file3"]),
        (True, ["file1", "file2"], ["file3"]),
    ]
)
def test_step_should_run_optional(run_all, source_file_dependencies, list_file_diff):
    test_step = _get_test_step()
    test_step.optional = True # When optional is True, step should not run at all
    test_step.source_file_dependencies = source_file_dependencies

    assert step_should_run(test_step, run_all, list_file_diff) == False

if __name__ == "__main__":
    sys.exit(pytest.main(["-v", __file__]))
