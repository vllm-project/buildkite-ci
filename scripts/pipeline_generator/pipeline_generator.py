import os
import re
from typing import List

from pydantic import BaseModel, field_validator

class PipelineGeneratorConfig(BaseModel):
    run_all: bool
    list_file_diff: List[str]
    container_registry: str
    container_registry_repo: str
    commit: str
    test_path: str # List of tests
    external_hardware_test_path: str # List of external hardware tests
    pipeline_file_path: str # Path to the output pipeline file

    @property
    def container_image(self) -> str:
        return f"{self.container_registry}/{self.container_registry_repo}:{self.commit}"
    
    @field_validator("test_path")
    @classmethod
    def check_test_path(cls, value: str) -> str:
        if not os.path.exists(value):
            raise ValueError(f"Test path {value} does not exist")
        return value
    
    @field_validator("external_hardware_test_path")
    @classmethod
    def check_external_hardware_test_path(cls, value: str) -> str:
        if not os.path.exists(value):
            raise ValueError(f"External hardware test path {value} does not exist")
        return value
        
    @field_validator("commit")
    @classmethod
    def check_commit(cls, value: str) -> str:
        # Check if commit is a valid Git commit hash
        pattern = r"^[0-9a-f]{40}$"
        if not re.match(pattern, value):
            raise ValueError(f"Commit {value} is not a valid Git commit hash")
        return value
        

class PipelineGenerator:
    def __init__(
            self, 
            config: PipelineGeneratorConfig
        ):
        self.config = config
