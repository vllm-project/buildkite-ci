import pytest
import sys
import os
import tempfile

from scripts.pipeline_generator.pipeline_generator import PipelineGeneratorConfig, PipelineGenerator, read_test_steps
from scripts.pipeline_generator.step import DEFAULT_TEST_WORKING_DIR

TEST_COMMIT = "abcdef0123456789abcdef0123456789abcdef01"
TEST_FILE_PATH = "tests.yaml"
EXTERNAL_HARDWARE_TEST_FILE_PATH = "external_hardware_tests.yaml"
PIPELINE_OUTPUT_FILE_PATH = "pipeline.yaml"
TEST_CONTAINER_REGISTRY = "container.registry"
TEST_CONTAINER_REGISTRY_REPO = "test"


def _get_pipeline_generator_config(test_dir: str):
    with open(os.path.join(test_dir, TEST_FILE_PATH), "w") as f:
        f.write("test-content")
    with open(os.path.join(test_dir, EXTERNAL_HARDWARE_TEST_FILE_PATH), "w") as f:
        f.write("external-hardware-test-content")

    return PipelineGeneratorConfig(
        container_registry=TEST_CONTAINER_REGISTRY,
        container_registry_repo=TEST_CONTAINER_REGISTRY_REPO,
        commit=TEST_COMMIT,
        list_file_diff=[],
        test_path=os.path.join(test_dir, TEST_FILE_PATH),
        external_hardware_test_path=os.path.join(test_dir, EXTERNAL_HARDWARE_TEST_FILE_PATH),
        pipeline_file_path=os.path.join(test_dir, PIPELINE_OUTPUT_FILE_PATH)
    )


def test_pipeline_generator_config_get_container_image():
    with tempfile.TemporaryDirectory() as temp_dir:
        config = _get_pipeline_generator_config(temp_dir)
        config.validate()
        assert config.container_image == "container.registry/test:abcdef0123456789abcdef0123456789abcdef01"


@pytest.mark.parametrize(
    "commit",
    [
        "abcdefghijklmnopqrstuvwxyz1234567890abcd", # Invalid, not in a-f 0-9
        "1234567890abcdef", # Invalid, not 40 characters
    ]
)
def test_get_pipeline_generator_config_invalid_commit(commit):
    with tempfile.TemporaryDirectory() as temp_dir:
        config = _get_pipeline_generator_config(temp_dir)
        config.commit = commit
        with pytest.raises(ValueError, match="not a valid Git commit hash"):
            config.validate()


def test_get_pipeline_generator_fail_nonexistent_test_file():
    with tempfile.TemporaryDirectory() as temp_dir:
        config = _get_pipeline_generator_config(temp_dir)
        config.test_path = "non-existent-file"
        with pytest.raises(FileNotFoundError, match="Test file"):
            _ = PipelineGenerator(config)


def test_read_test_steps():
    current_dir = os.path.dirname(os.path.abspath(__file__))
    test_path = os.path.join(current_dir, "test_files/test-pipeline.yaml")
    test_steps = read_test_steps(test_path)
    assert len(test_steps) == 4
    assert test_steps[0].commands == ['echo "Test 1"']
    assert test_steps[0].command is None
    assert test_steps[0].working_dir == DEFAULT_TEST_WORKING_DIR

    assert test_steps[1].working_dir == "/tests2/"
    assert test_steps[1].no_gpu is True

    assert test_steps[2].commands == ['echo "Test 3"', 'echo "Test 3.1"']
    assert test_steps[2].source_file_dependencies == ["file1", "src/file2"]

    assert test_steps[3].commands == ['echo "Test 4.1"', 'echo "Test 4.2"']
    assert test_steps[3].num_nodes == 2
    assert test_steps[3].num_gpus == 4


if __name__ == "__main__":
    sys.exit(pytest.main(["-v", __file__]))
