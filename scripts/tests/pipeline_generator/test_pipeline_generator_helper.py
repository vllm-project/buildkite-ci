import pytest
import sys
from unittest import mock

from scripts.pipeline_generator.pipeline_generator_helper import get_plugin_config
from scripts.pipeline_generator.utils import GPUType

@mock.patch("scripts.pipeline_generator.pipeline_generator_helper.get_kubernetes_plugin_config")
@mock.patch("scripts.pipeline_generator.pipeline_generator_helper.get_docker_plugin_config")
@mock.patch("scripts.pipeline_generator.pipeline_generator_helper.get_full_test_command")
def test_get_plugin_config(mock_get_full_test_command, mock_get_docker_plugin_config, mock_get_kubernetes_plugin_config):
    mock_get_docker_plugin_config.return_value = {"docker": "plugin"}
    mock_get_kubernetes_plugin_config.return_value = {"kubernetes": "plugin"}
    mock_get_full_test_command.return_value = "full;\ntest;\ncommands"
    plugin = get_plugin_config(["echo 'hello world'"], "/path", "image:latest")
    assert plugin == {"docker": "plugin"}
    assert mock_get_docker_plugin_config.call_count == 1
    assert mock_get_docker_plugin_config.call_args[0] == ("image:latest", ["bash", "-c", "full;\ntest;\ncommands"], False)

@mock.patch("scripts.pipeline_generator.pipeline_generator_helper.get_kubernetes_plugin_config")
@mock.patch("scripts.pipeline_generator.pipeline_generator_helper.get_docker_plugin_config")
@mock.patch("scripts.pipeline_generator.pipeline_generator_helper.get_full_test_command")
def test_get_plugin_config_kubernetes(mock_get_full_test_command, mock_get_docker_plugin_config, mock_get_kubernetes_plugin_config):
    mock_get_docker_plugin_config.return_value = {"docker": "plugin"}
    mock_get_kubernetes_plugin_config.return_value = {"kubernetes": "plugin"}
    mock_get_full_test_command.return_value = "full;\ntest;\ncommands"
    plugin = get_plugin_config(commands=["echo 'hello world'"], working_dir="/path", container_image="image:latest", gpu_type=GPUType.A100, num_gpus=4)
    assert plugin == {"kubernetes": "plugin"}
    assert mock_get_kubernetes_plugin_config.call_count == 1
    assert mock_get_kubernetes_plugin_config.call_args[0] == ("image:latest", ["bash", "-c", "full;\ntest;\ncommands"], 4)



if __name__ == "__main__":
    sys.exit(pytest.main(["-v", __file__]))
