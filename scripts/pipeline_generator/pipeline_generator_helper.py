from typing import Dict, List, Optional

from .utils import GPUType, get_agent_queue, get_full_test_command, get_multi_node_test_command
from .step import TestStep, BuildkiteStep, get_step_key
from .plugin import get_docker_plugin_config, get_kubernetes_plugin_config

def get_plugin_config(
        commands: List[str],
        working_dir: str,
        container_image: str,
        no_gpu: Optional[bool] = None,
        gpu_type: Optional[GPUType] = None,
        num_gpus: Optional[int] = None
    ) -> Dict:
    """Returns the plugin configuration for the Buildkite step."""
    test_bash_command = [
        "bash",
        "-c",
        get_full_test_command(commands, working_dir)
    ]
    if gpu_type and gpu_type == GPUType.A100 and num_gpus:
        return get_kubernetes_plugin_config(
            container_image,
            test_bash_command,
            num_gpus
        )
    return get_docker_plugin_config(
        container_image,
        test_bash_command,
        no_gpu or False,
    )


def convert_test_step_to_buildkite_step(step: TestStep, container_image: str) -> BuildkiteStep:
    """Convert TestStep into BuildkiteStep."""
    buildkite_step = BuildkiteStep(
        label=step.label,
        key=get_step_key(step.label),
        parallelism=step.parallelism,
        soft_fail=step.soft_fail,
        plugins=[get_plugin_config(step.commands, step.working_dir, container_image, step.no_gpu, step.gpu, step.num_gpus)],
        agents={"queue": get_agent_queue(step.no_gpu, step.gpu, step.num_gpus).value}
    )
    # If test is multi-node, configure step to run with custom script
    if step.num_nodes and step.num_nodes > 1:
        buildkite_step.commands = [get_multi_node_test_command(
                step.commands,
                step.working_dir,
                step.num_nodes,
                step.num_gpus,
                container_image
            )
        ]
        buildkite_step.plugins = None
    return buildkite_step