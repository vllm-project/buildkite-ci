import pytest
import sys

from scripts.pipeline_generator.pipeline_generator_helper import get_plugin_config
from scripts.pipeline_generator.step import TestStep
from scripts.pipeline_generator.plugin import DOCKER_PLUGIN_NAME, KUBERNETES_PLUGIN_NAME
from scripts.pipeline_generator.utils import TEST_DEFAULT_COMMANDS, DEFAULT_WORKING_DIR, GPUType, get_full_test_command


TEST_COMMIT = "abcdef0123456789abcdef0123456789abcdef01"
TEST_CONTAINER_IMAGE = f"test_image:{TEST_COMMIT}"


def _get_test_step():
    return TestStep(
        label="Test",
        command="echo 'Hello, World!'",
    )


def test_get_plugin_config_docker():
    test_step = _get_test_step()
    plugin_config = get_plugin_config(test_step, TEST_CONTAINER_IMAGE)
    assert plugin_config == {
        DOCKER_PLUGIN_NAME: {
            "image": TEST_CONTAINER_IMAGE,
            "always-pull": True,
            "propagate-environment": True,
            "gpus": "all",
            "command": ["bash", "-c", get_full_test_command(test_step.commands, DEFAULT_WORKING_DIR)],
            "environment": [
                "HF_HOME=/root/.cache/huggingface",
                "VLLM_USAGE_SOURCE=ci-test",
                "HF_TOKEN",
                "BUILDKITE_ANALYTICS_TOKEN"
            ],
            "mount-buildkite-agent": False,
            "volumes": [
                "/dev/shm:/dev/shm",
                "/root/.cache/huggingface:/root/.cache/huggingface"
            ]
        }
    }


def test_get_plugin_config_kubernetes():
    test_step = _get_test_step()
    test_step.gpu = GPUType.A100.value
    test_step.num_gpus = 4
    plugin_config = get_plugin_config(test_step, TEST_CONTAINER_IMAGE)

    full_bash_command = ["bash", "-c", get_full_test_command(test_step.commands, DEFAULT_WORKING_DIR)]
    expected_command = [" ".join(full_bash_command)]
    assert plugin_config == {
        KUBERNETES_PLUGIN_NAME: {
            "podSpec": {
                "containers": [
                    {
                        "image": TEST_CONTAINER_IMAGE,
                        "command": expected_command,
                        "resources": {"limits": {"nvidia.com/gpu": 4}},
                        "volumeMounts": [
                            {"name": "devshm", "mountPath": "/dev/shm"},
                            {"name": "hf-cache", "mountPath": "/root/.cache/huggingface"}
                        ],
                        "env": [
                            {"name": "HF_HOME", "value": "/root/.cache/huggingface"},
                            {"name": "VLLM_USAGE_SOURCE", "value": "ci-test"},
                            {
                                "name": "HF_TOKEN",
                                "valueFrom": {
                                    "secretKeyRef": {
                                        "name": "hf-token-secret",
                                        "key": "token"
                                    }
                                }
                            },
                        ],
                    }
                ],
                "priorityClassName": "ci",
                "nodeSelector": {"nvidia.com/gpu.product": "NVIDIA-A100-SXM4-80GB"},
                "volumes": [
                    {"name": "devshm", "emptyDir": {"medium": "Memory"}},
                    {"name": "hf-cache", "hostPath": {"path": "/root/.cache/huggingface", "type": "Directory"}}
                ]
            }
        }
    }


if __name__ == "__main__":
    sys.exit(pytest.main(["-v", __file__]))
