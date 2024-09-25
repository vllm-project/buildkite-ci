from pydantic import BaseModel, Field
from typing import List, Dict, Any, Optional

from utils import AgentQueue

BUILD_STEP_KEY = "build"

class TestStep(BaseModel):
    """This class represents a test step defined in the test configuration file."""
    label: str
    fast_check: bool = False
    mirror_hardwares: List[str] = Field(default_factory=list)
    gpu: str = ""
    num_gpus: int = 1
    num_nodes: int = 1
    working_dir: str = "/vllm-workspace/tests"
    source_file_dependencies: List[str] = Field(default_factory=list)
    no_gpu: bool = False
    soft_fail: bool = False
    parallelism: int = 1
    optional: bool = False
    command: Optional[str] = None
    commands: Optional[List[str]] = None

class BuildkiteStep(BaseModel):
    """This class represents a step in Buildkite format."""
    label: str
    key: str
    agents: Dict[str, Any] = {"queue": AgentQueue.AWS_CPU}
    commands: Optional[List[str]] = None
    plugins: Optional[List[Dict]] = None
    parallelism: Optional[int] = None
    soft_fail: Optional[bool] = None
    depends_on: Optional[str] = "build"
    env: Optional[Dict[str, str]] = None
    retry: Optional[Dict[str, Any]] = None

class BuildkiteBlockStep(BaseModel):
    """This class represents a block step in Buildkite format."""
    block: str
    depends_on: Optional[str] = BUILD_STEP_KEY
    key: str


def get_step_key(step_label: str) -> str:
    step_key = ""
    skip_chars = "()% "
    for char in step_label.lower():
        if char in ", " and step_key[-1] != "-":
            step_key += "-"
        elif char not in skip_chars:
            step_key += char

    return step_key


def get_block_step(step_label: str) -> BuildkiteBlockStep:
    return BuildkiteBlockStep(block=f"Run {step_label}", key=f"block-{get_step_key(step_label)}")
