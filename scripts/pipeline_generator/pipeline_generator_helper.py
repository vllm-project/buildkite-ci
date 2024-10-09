from typing import List, Dict
from .plugin import get_kubernetes_plugin_config, get_docker_plugin_config
from .utils import get_agent_queue, get_full_test_command, get_multi_node_test_command, GPUType
from .step import BuildkiteStep, TestStep, get_step_key

def step_should_run(step: TestStep, run_all: bool, list_file_diff: List[str]) -> bool:
    """Determine whether the step should automatically run or not."""
    if step.optional:
        return False
    if not step.source_file_dependencies or run_all:
        return True
    return any(source_file in diff_file
                for source_file in step.source_file_dependencies
                for diff_file in list_file_diff)

def get_plugin_config(step: TestStep, container_image: str) -> Dict:
    """Returns the plugin configuration for the step."""
    test_step_commands = [step.command] if step.command else step.commands
    test_bash_command = [
        "bash",
        "-c",
        get_full_test_command(test_step_commands, step.working_dir)
    ]
    if step.gpu == GPUType.A100:
        return get_kubernetes_plugin_config(
            container_image,
            test_bash_command,
            step.num_gpus
        )
    return get_docker_plugin_config(
        container_image,
        test_bash_command,
        step.no_gpu
    )


def create_buildkite_step(step: TestStep, container_image: str) -> BuildkiteStep:
    """Convert TestStep into BuildkiteStep."""
    buildkite_step = BuildkiteStep(
        label=step.label,
        key=get_step_key(step.label),
        parallelism=step.parallelism,
        soft_fail=step.soft_fail,
        plugins=[get_plugin_config(step, container_image)],
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


def get_build_commands(container_registry: str, buildkite_commit: str, container_image: str) -> List[str]:
    ecr_login_command = (
        "aws ecr-public get-login-password --region us-east-1 | "
        f"docker login --username AWS --password-stdin {container_registry}"
    )
    image_check_command = f"""#!/bin/bash
if [[ -z $(docker manifest inspect {container_image}) ]]; then
echo "Image not found, proceeding with build..."
else
echo "Image found"
exit 0
fi
"""
    docker_build_command = (
        f"docker build "
        f"--build-arg max_jobs=64 "
        f"--build-arg buildkite_commit={buildkite_commit} "
        f"--build-arg USE_SCCACHE=1 "
        f"--tag {container_image} "
        f"--target test "
        f"--progress plain ."
    )
    docker_push_command = f"docker push {container_image}"
    return [ecr_login_command, image_check_command, docker_build_command, docker_push_command]