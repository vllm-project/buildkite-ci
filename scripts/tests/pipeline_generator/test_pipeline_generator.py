import pytest
import sys
from unittest import mock


from scripts.pipeline_generator.pipeline_generator import PipelineGenerator
from scripts.pipeline_generator.step import TestStep, BuildkiteStep, BuildkiteBlockStep
from scripts.pipeline_generator.utils import (
    AgentQueue,
    VLLM_ECR_REPO,
    MULTI_NODE_TEST_SCRIPT,
)
from scripts.pipeline_generator.plugin import (
    DEFAULT_DOCKER_ENVIRONMENT_VARIBLES,
    DEFAULT_DOCKER_VOLUMES,
    DEFAULT_KUBERNETES_CONTAINER_VOLUME_MOUNTS,
    DEFAULT_KUBERNETES_CONTAINER_ENVIRONMENT_VARIABLES,
    DEFAULT_KUBERNETES_NODE_SELECTOR,
    DEFAULT_KUBERNETES_POD_VOLUMES,
)

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
    assert steps[3].optional is True


@pytest.mark.parametrize(
    ("test_step", "expected_plugin_config"),
    [
        (
            TestStep(
                label="Test 0",
                source_file_dependencies=["dir1/", "dir2/file1"],
                commands=["test command 1", "test command 2"],
            ),
            {
                "docker#v5.2.0": {
                    "image": f"{VLLM_ECR_REPO}:{TEST_COMMIT}",
                    "always-pull": True,
                    "propagate-environment": True,
                    "gpus": "all",
                    "mount-buildkite-agent": False,
                    "command": [
                        "bash",
                        "-c",
                        "(command nvidia-smi || true);\nexport VLLM_LOGGING_LEVEL=DEBUG;\nexport VLLM_ALLOW_DEPRECATED_BEAM_SEARCH=1;\ncd /vllm-workspace/tests;\ntest command 1;\ntest command 2",
                    ],
                    "environment": DEFAULT_DOCKER_ENVIRONMENT_VARIBLES,
                    "volumes": DEFAULT_DOCKER_VOLUMES,
                }
            },
        ),
        (
            TestStep(
                label="Test 1",
                commands=["test command 1", "test command 2"],
                gpu="a100",
                num_gpus=4,
            ),
            {
                "kubernetes": {
                    "podSpec": {
                        "containers": [
                            {
                                "image": f"{VLLM_ECR_REPO}:{TEST_COMMIT}",
                                "command": [
                                    'bash -c "(command nvidia-smi || true);\nexport VLLM_LOGGING_LEVEL=DEBUG;\nexport VLLM_ALLOW_DEPRECATED_BEAM_SEARCH=1;\ncd /vllm-workspace/tests;\ntest command 1;\ntest command 2"'
                                ],
                                "resources": {"limits": {"nvidia.com/gpu": 4}},
                                "volumeMounts": DEFAULT_KUBERNETES_CONTAINER_VOLUME_MOUNTS,
                                "env": DEFAULT_KUBERNETES_CONTAINER_ENVIRONMENT_VARIABLES,
                            }
                        ],
                        "priorityClassName": "ci",
                        "nodeSelector": DEFAULT_KUBERNETES_NODE_SELECTOR,
                        "volumes": DEFAULT_KUBERNETES_POD_VOLUMES,
                    }
                }
            },
        ),
    ],
)
def test_get_plugin_config(test_step, expected_plugin_config):
    pipeline_generator = get_test_pipeline_generator()
    plugin_config = pipeline_generator.get_plugin_config(test_step)
    assert plugin_config == expected_plugin_config


@pytest.mark.parametrize(
    ("test_step", "expected_buildkite_step"),
    [
        (
            TestStep(
                label="Test 0",
                source_file_dependencies=["dir1/", "dir2/file1"],
                commands=["test command 1", "test command 2"],
            ),
            BuildkiteStep(
                label="Test 0",
                key="test-0",
                agents={"queue": AgentQueue.AWS_1xL4.value},
                plugins=[
                    {
                        "docker#v5.2.0": {
                            "image": "public.ecr.aws/q9t5s3a7/vllm-ci-test-repo:123456789abcdef123456789abcdef123456789a",
                            "always-pull": True,
                            "propagate-environment": True,
                            "gpus": "all",
                            "mount-buildkite-agent": False,
                            "command": [
                                "bash",
                                "-c",
                                "(command nvidia-smi || true);\nexport VLLM_LOGGING_LEVEL=DEBUG;\nexport VLLM_ALLOW_DEPRECATED_BEAM_SEARCH=1;\ncd /vllm-workspace/tests;\ntest command 1;\ntest command 2",
                            ],
                            "environment": DEFAULT_DOCKER_ENVIRONMENT_VARIBLES,
                            "volumes": DEFAULT_DOCKER_VOLUMES,
                        }
                    }
                ],
            ),
        ),
        # A100 test
        (
            TestStep(
                label="Test 1",
                commands=["test command 1", "test command 2"],
                gpu="a100",
                num_gpus=4,
            ),
            BuildkiteStep(
                label="Test 1",
                key="test-1",
                agents={"queue": AgentQueue.A100.value},
                plugins=[
                    {
                        "kubernetes": {
                            "podSpec": {
                                "containers": [
                                    {
                                        "image": f"{VLLM_ECR_REPO}:{TEST_COMMIT}",
                                        "command": [
                                            'bash -c "(command nvidia-smi || true);\nexport VLLM_LOGGING_LEVEL=DEBUG;\nexport VLLM_ALLOW_DEPRECATED_BEAM_SEARCH=1;\ncd /vllm-workspace/tests;\ntest command 1;\ntest command 2"'
                                        ],
                                        "resources": {"limits": {"nvidia.com/gpu": 4}},
                                        "volumeMounts": DEFAULT_KUBERNETES_CONTAINER_VOLUME_MOUNTS,
                                        "env": DEFAULT_KUBERNETES_CONTAINER_ENVIRONMENT_VARIABLES,
                                    }
                                ],
                                "priorityClassName": "ci",
                                "nodeSelector": DEFAULT_KUBERNETES_NODE_SELECTOR,
                                "volumes": DEFAULT_KUBERNETES_POD_VOLUMES,
                            }
                        }
                    },
                ],
            ),
        ),
        # Multi node test
        (
            TestStep(
                label="Test 2",
                num_gpus=2,
                num_nodes=2,
                commands=["test command 1", "test command 2"],
                working_dir="/tests",
            ),
            BuildkiteStep(
                label="Test 2",
                key="test-2",
                agents={"queue": AgentQueue.AWS_4xL4.value},
                commands=[
                    f"{MULTI_NODE_TEST_SCRIPT} /tests 2 2 {VLLM_ECR_REPO}:{TEST_COMMIT} 'test command 1' 'test command 2'"
                ],
            ),
        ),
    ],
)
def test_create_buildkite_step(test_step, expected_buildkite_step):
    pipeline_generator = get_test_pipeline_generator()

    buildkite_step = pipeline_generator.create_buildkite_step(test_step)
    assert buildkite_step == expected_buildkite_step


@pytest.mark.parametrize(
    ("test_step", "expected_value_without_runall", "expected_value_with_runall"),
    [
        (
            TestStep(
                label="Test 0",
                source_file_dependencies=["dir1/", "dir2/file1"],
                commands=["test command 1", "test command 2"],
            ),
            True,
            True,
        ),
        (
            TestStep(
                label="Test 0",
                commands=["test command 1", "test command 2"],
            ),
            True,
            True,
        ),
        (
            TestStep(
                label="Test 0",
                source_file_dependencies=["dir2/", "dir3/file1"],
                commands=["test command 1", "test command 2"],
            ),
            False,
            True,
        ),
        (
            TestStep(
                label="Test 1",
                commands=["test command 1", "test command 2"],
                gpu="a100",
                optional=True,
                num_gpus=4,
            ),
            False,
            False,
        ),
    ],
)
def test_step_should_run(
    test_step, expected_value_without_runall, expected_value_with_runall
):
    pipeline_generator = get_test_pipeline_generator()
    pipeline_generator.list_file_diff = ["dir1/a.py", "dir3/file2.py"]
    assert (
        pipeline_generator.step_should_run(test_step) == expected_value_without_runall
    )

    # With run_all
    pipeline_generator.run_all = True
    assert pipeline_generator.step_should_run(test_step) == expected_value_with_runall


@pytest.mark.parametrize(
    ("test_step", "expected_buildkite_steps"),
    [
        # Test always run so no block step
        (
            TestStep(
                label="Test 0",
                commands=["test command 1", "test command 2"],
            ),
            [
                BuildkiteStep(
                    label="Test 0",
                    key="test-0",
                    agents={"queue": AgentQueue.AWS_1xL4.value},
                    plugins=[
                        {
                            "docker#v5.2.0": {
                                "image": "public.ecr.aws/q9t5s3a7/vllm-ci-test-repo:123456789abcdef123456789abcdef123456789a",
                                "always-pull": True,
                                "propagate-environment": True,
                                "gpus": "all",
                                "mount-buildkite-agent": False,
                                "command": [
                                    "bash",
                                    "-c",
                                    "(command nvidia-smi || true);\nexport VLLM_LOGGING_LEVEL=DEBUG;\nexport VLLM_ALLOW_DEPRECATED_BEAM_SEARCH=1;\ncd /vllm-workspace/tests;\ntest command 1;\ntest command 2",
                                ],
                                "environment": DEFAULT_DOCKER_ENVIRONMENT_VARIBLES,
                                "volumes": DEFAULT_DOCKER_VOLUMES,
                            }
                        }
                    ],
                ),
            ],
        ),
        # Test doesn't automatically run because dependencies are not matched -> with block step
        (
            TestStep(
                label="Test 0",
                source_file_dependencies=["dir1/", "dir2/file1"],
                commands=["test command 1", "test command 2"],
            ),
            [
                BuildkiteBlockStep(block="Run Test 0", key="block-test-0"),
                BuildkiteStep(
                    label="Test 0",
                    key="test-0",
                    agents={"queue": AgentQueue.AWS_1xL4.value},
                    depends_on="block-test-0",
                    plugins=[
                        {
                            "docker#v5.2.0": {
                                "image": "public.ecr.aws/q9t5s3a7/vllm-ci-test-repo:123456789abcdef123456789abcdef123456789a",
                                "always-pull": True,
                                "propagate-environment": True,
                                "gpus": "all",
                                "mount-buildkite-agent": False,
                                "command": [
                                    "bash",
                                    "-c",
                                    "(command nvidia-smi || true);\nexport VLLM_LOGGING_LEVEL=DEBUG;\nexport VLLM_ALLOW_DEPRECATED_BEAM_SEARCH=1;\ncd /vllm-workspace/tests;\ntest command 1;\ntest command 2",
                                ],
                                "environment": DEFAULT_DOCKER_ENVIRONMENT_VARIBLES,
                                "volumes": DEFAULT_DOCKER_VOLUMES,
                            }
                        }
                    ],
                ),
            ],
        ),
    ],
)
def test_process_step(test_step, expected_buildkite_steps):
    pipeline_generator = get_test_pipeline_generator()
    buildkite_steps = pipeline_generator.process_step(test_step)
    assert buildkite_steps == expected_buildkite_steps


def test_generate_build_step():
    pipeline_generator = get_test_pipeline_generator()
    pipeline_generator.get_build_commands = mock.MagicMock(
        return_value=["build command 1", "build command 2"]
    )
    build_step = pipeline_generator.generate_build_step()
    expected_build_step = BuildkiteStep(
        label=":docker: build image",
        key="build",
        agents={"queue": AgentQueue.AWS_CPU.value},
        env={"DOCKER_BUILDKIT": "1"},
        retry={
            "automatic": [
                {"exit_status": -1, "limit": 2},
                {"exit_status": -10, "limit": 2},
            ]
        },
        commands=["build command 1", "build command 2"],
        depends_on=None,
    )
    assert build_step == expected_build_step


if __name__ == "__main__":
    sys.exit(pytest.main(["-v", __file__]))
import pytest
import sys
import os
import tempfile

from scripts.pipeline_generator.pipeline_generator import PipelineGeneratorConfig, PipelineGenerator

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

if __name__ == "__main__":
    sys.exit(pytest.main(["-v", __file__]))
