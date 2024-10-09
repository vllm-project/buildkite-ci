import pytest
import sys
import os
import tempfile
import yaml

from scripts.pipeline_generator.pipeline_generator import PipelineGeneratorConfig, PipelineGenerator, write_buildkite_steps
from scripts.pipeline_generator.step import BuildkiteStep, BuildkiteBlockStep
from scripts.pipeline_generator.utils import AgentQueue

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


def test_write_buildkite_steps():
    current_dir = os.path.dirname(os.path.abspath(__file__))
    expected_output_path = os.path.join(current_dir, "test_files/expected_pipeline.yaml")
    with open(expected_output_path, "r") as f:
        expected_output = yaml.safe_load(f)

    steps = [
        BuildkiteStep(label="Test 1", commands=['echo "Test1.1"', 'echo "Test1.2"']),
        BuildkiteStep(label="Test 2", commands=["command3"], agents = {"queue": AgentQueue.AWS_1xL4.value}),
        BuildkiteBlockStep(block="Run Test 3", key="block-test-3"),
        BuildkiteStep(label="Test 3", commands=["command4"], depends_on="block-test-3"),
    ]
    with tempfile.TemporaryDirectory() as temp_dir:
        output_file_path = os.path.join(temp_dir, "output.yaml")
        write_buildkite_steps(steps, output_file_path)
        with open(output_file_path, "r") as f:
            output = yaml.safe_load(f)
        assert output == expected_output
        

if __name__ == "__main__":
    sys.exit(pytest.main(["-v", __file__]))
