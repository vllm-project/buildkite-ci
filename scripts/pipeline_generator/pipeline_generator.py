import yaml
import click
from typing import List, Dict, Union
import os
from pydantic import BaseModel

from .plugin import (
    get_kubernetes_plugin_config,
    get_docker_plugin_config,
)
from .utils import (
    AgentQueue,
    AMD_REPO,
    A100_GPU,
    TEST_PATH,
    EXTERNAL_HARDWARE_TEST_PATH,
    PIPELINE_FILE_PATH,
    STEPS_TO_BLOCK,
    VLLM_ECR_URL,
    VLLM_ECR_REPO,
    get_agent_queue,
    get_full_test_command,
    get_multi_node_test_command,
)
from .step import (
    TestStep,
    BuildkiteStep,
    BuildkiteBlockStep,
    get_block_step,
    get_step_key
)
from .pipeline_generator_helper import (
    step_should_run,
    get_plugin_config,
    create_buildkite_step,
    get_build_commands,
)

class PipelineGeneratorConfig(BaseModel):
    run_all: bool
    list_file_diff: List[str]
    container_registry: str
    container_registry_repo: str
    commit: str
    test_path: str
    external_hardware_test_path: str
    pipeline_file_path: str

    @property
    def container_image(self) -> str:
        return f"{self.container_registry}/{self.container_registry_repo}:{self.commit}"

class PipelineGenerator:
    def __init__(
            self, 
            config: PipelineGeneratorConfig
        ):
        self.config = config

    def generate_build_step(self) -> BuildkiteStep:
        """Build the Docker image and push it to container registry."""
        build_commands = get_build_commands(self.config.container_registry, self.config.commit, self.config.container_image)

        return BuildkiteStep(
            label=":docker: build image",
            key="build",
            agents={"queue": AgentQueue.AWS_CPU.value},
            env={"DOCKER_BUILDKIT": "1"},
            retry={
                "automatic": [
                    {"exit_status": -1, "limit": 2},
                    {"exit_status": -10, "limit": 2}
                ]
            },
            commands=build_commands,
            depends_on=None,
        )

    def read_test_steps(self, file_path: str) -> List[TestStep]:
        """Read test steps from test pipeline yaml and parse them into Step objects."""
        with open(file_path, "r") as f:
            content = yaml.safe_load(f)
        return [TestStep(**step) for step in content["steps"]]

    def convert_test_step_to_buildkite_steps(self, step: TestStep) -> List[Union[BuildkiteStep, BuildkiteBlockStep]]:
        """Process test step and return corresponding BuildkiteStep."""
        steps = []
        current_step = create_buildkite_step(step, self.config.container_image)

        if not step_should_run(step, self.config.run_all, self.config.list_file_diff):
            block_step = get_block_step(step.label)
            steps.append(block_step)
            current_step.depends_on = block_step.key

        steps.append(current_step)
        return steps

    def get_external_hardware_tests(self, test_steps: List[TestStep]) -> List[Union[BuildkiteStep, BuildkiteBlockStep]]:
        """Process the external hardware tests from the yaml file and convert to Buildkite steps."""
        buildkite_steps = self._process_external_hardware_steps()
        buildkite_steps.extend(self._mirror_amd_test_steps(test_steps))
        return buildkite_steps


    def _process_external_hardware_steps(self) -> List[Union[BuildkiteStep, BuildkiteBlockStep]]:
        with open(EXTERNAL_HARDWARE_TEST_PATH, "r") as f:
            content = yaml.safe_load(f)
        buildkite_steps = []
        amd_docker_image = f"{AMD_REPO}:{self.config.commit}"
        for step in content["steps"]:
            step["commands"] = [cmd.replace("DOCKER_IMAGE_AMD", amd_docker_image) for cmd in step["commands"]]
            buildkite_step = BuildkiteStep(**step)
            buildkite_step.depends_on = "bootstrap"

            # Add block step if step is in blocklist
            if buildkite_step.key in STEPS_TO_BLOCK:
                block_step = get_block_step(buildkite_step.label)
                buildkite_steps.append(block_step)
                buildkite_step.depends_on = block_step.key
            buildkite_steps.append(buildkite_step)
        return buildkite_steps

    def _mirror_amd_test_steps(self, test_steps: List[TestStep]) -> List[BuildkiteStep]:
        mirrored_buildkite_steps = []
        for test_step in test_steps:
            if test_step.mirror_hardwares and "amd" in test_step.mirror_hardwares:
                test_commands = [test_step.command] if test_step.command else test_step.commands
                amd_test_command = [
                    "bash",
                    ".buildkite/run-amd-test.sh",
                    f"'{get_full_test_command(test_commands, test_step.working_dir)}'",
                ]
                mirrored_buildkite_step = BuildkiteStep(
                    label=f"AMD: {test_step.label}",
                    key=f"amd_{get_step_key(test_step.label)}",
                    depends_on="amd-build",
                    agents={"queue": AgentQueue.AMD_GPU.value},
                    soft_fail=test_step.soft_fail,
                    env={"DOCKER_BUILDKIT": "1"},
                    commands=[" ".join(amd_test_command)],
                )
                mirrored_buildkite_steps.append(mirrored_buildkite_step)
        return mirrored_buildkite_steps

    def write_buildkite_steps(
            self,
            buildkite_steps: List[Union[BuildkiteStep, BuildkiteBlockStep]],
            output_file_path: str
            ) -> None:
        """Output the buildkite steps to the Buildkite pipeline yaml file."""
        buildkite_steps_dict = {"steps": [step.dict(exclude_none=True) for step in buildkite_steps]}
        with open(output_file_path, "w") as f:
            yaml.dump(buildkite_steps_dict, f, sort_keys=False)

    def generate(self):
        test_steps = self.read_test_steps(self.config.test_path)
        buildkite_steps = [self.generate_build_step()]

        for test_step in test_steps:
            test_buildkite_steps = self.convert_test_step_to_buildkite_steps(test_step)
            buildkite_steps.extend(test_buildkite_steps)
        buildkite_steps.extend(self.get_external_hardware_tests(test_steps))

        self.write_buildkite_steps(buildkite_steps, self.config.pipeline_file_path)


@click.command()
@click.option("--run_all", type=str)
@click.option("--list_file_diff", type=str)
def main(run_all: str = "-1", list_file_diff: str = None):
    list_file_diff = list_file_diff.split("|") if list_file_diff else []
    pipeline_generator_config = PipelineGeneratorConfig(
        run_all=run_all == "1",
        list_file_diff=list_file_diff,
        container_registry=VLLM_ECR_URL,
        container_registry_repo=VLLM_ECR_REPO,
        commit=os.getenv("BUILDKITE_COMMIT"),
        test_path=TEST_PATH,
        external_hardware_test_path=EXTERNAL_HARDWARE_TEST_PATH,
        pipeline_file_path=PIPELINE_FILE_PATH
    )
    pipeline_generator = PipelineGenerator(pipeline_generator_config)
    pipeline_generator.generate()


if __name__ == "__main__":
    main()
