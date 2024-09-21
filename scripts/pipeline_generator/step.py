from pydantic import BaseModel, Field
from typing import List, Dict, Any, Optional

from .utils import AgentQueue


class BuildkiteBlockStep(BaseModel):
    """This class represents a block step in Buildkite format."""
    block: str
    depends_on: Optional[str] = "build"
    key: str


def get_step_key(step_label: str) -> str:
    step_label = step_label.replace(", ", ",")
    step_key = ""
    skip_chars = "()%"
    for char in step_label.lower():
        if char in ", ":
            step_key += "-"
        elif char not in skip_chars:
            step_key += char

    return step_key


def get_block_step(step_label: str) -> BuildkiteBlockStep:
    return BuildkiteBlockStep(block=f"Run {step_label}", key=f"block-{get_step_key(step_label)}")
