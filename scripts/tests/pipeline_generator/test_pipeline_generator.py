import pytest

from scripts.pipeline_generator.pipeline_generator import PipelineGenerator
from scripts.pipeline_generator.step import TestStep, BuildkiteStep, BuildkiteBlockStep

TEST_COMMIT = "123456789abcdef123456789abcdef123456789a"
TEST_FILE_PATH = "scripts/tests/pipeline_generator/tests.yaml"

def get_test_pipeline_generator():
    pipeline_generator = PipelineGenerator(run_all=False, list_file_diff=[])
    pipeline_generator.commit = TEST_COMMIT
    return pipeline_generator

def test_read_test_steps():
    pipeline_generator = get_test_pipeline_generator()
    steps = pipeline_generator.read_test_steps(TEST_FILE_PATH)
    assert len(steps) == 4
    for i in range(4):
        assert steps[i].label == f"Test {i}"
    assert steps[0].source_file_dependencies == ["dir1/", "dir2/file1"]
    assert steps[0].commands == ["pytest -v -s a", "pytest -v -s b.py"]
    assert steps[1].working_dir == "/tests"
    assert steps[2].num_gpus == 2
    assert steps[2].num_nodes == 2
    assert steps[3].gpu == "a100"
    assert steps[3].optional == True

@pytest.mark.parametrize(
    ("test_step", "expected_plugin_config"),
    [
        (
            TestStep(
                label="Test 0",
                source_file_dependencies=["dir1/", "dir2/file1"],
                commands=["test command 1", "test command 2"]
            ),
            {
                "plugin": "docker"
            }
        ),
        (
            TestStep(
                label="Test 1",
                commands=["test command 1", "test command 2"]
                gpu="a100"
            ),
            {
                "plugin": "kubernetes"
            }
        )
    ]
)
@mock.patch("scripts.pipeline_generator.pipeline_generator.get_docker_plugin_config")
@mock.patch("scripts.pipeline_generator.pipeline_generator.get_kubernetes_plugin_config")
@mock.patch("scripts.pipeline_generator.utils.get_full_test_command")
def test_get_plugin_config(mock_get_full_test_command, mock_get_kubernetes_plugin_config, mock_get_docker_plugin_config, test_step, expected_plugin_config):
    pipeline_generator = get_test_pipeline_generator()
    mock_get_full_test_command.return_value = "test command 1;\ntest command 2"
    mock_get_docker_plugin_config.return_value = {"plugin": "docker"}
    mock_get_kubernetes_plugin_config.return_value = {"plugin": "kubernetes"}
    container_image_path = f"{VLLM_ECR_REPO}:{TEST_COMMIT}"

    plugin_config = pipeline_generator.get_plugin_config(test_step)
    assert plugin_config == expected_plugin_config
    if test_step.gpu == "a100":
        assert mock_get_kubernetes_plugin_config.called_once_with(container_image_path, )


if __name__ == "__main__":
    sys.exit(pytest.main(["-v", __file__]))