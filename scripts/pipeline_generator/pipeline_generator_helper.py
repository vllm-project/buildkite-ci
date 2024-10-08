from typing import Dict

from .step import TestStep, BuildkiteStep
from .plugin import get_kubernetes_plugin_config, get_docker_plugin_config
from .utils import GPUType, get_full_test_command

def get_plugin_config(step: TestStep, container_image: str) -> Dict:
    """Returns the plugin configuration for the step."""
    test_step_commands = [step.command] if step.command else step.commands
    test_bash_command = [
        "bash",
        "-c",
        get_full_test_command(test_step_commands, step.working_dir)
    ]
    if step.gpu == GPUType.A100.value:
        print(step.num_gpus)
        return get_kubernetes_plugin_config(
            container_image,
            test_bash_command,
            step.num_gpus or 1
        )
    return get_docker_plugin_config(
        container_image,
        test_bash_command,
        step.no_gpu
    )
