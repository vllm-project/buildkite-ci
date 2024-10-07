import os
import re
from typing import List, Optional

from pydantic import BaseModel, field_validator


class PipelineGeneratorConfig:
    def __init__(
        self,
        container_registry: str,
        container_registry_repo: str,
        commit: str,
        list_file_diff: List[str],
        test_path: str,  # List of tests
        external_hardware_test_path: str,  # List of external hardware tests
        pipeline_file_path: str,  # Path to the output pipeline file
        run_all: bool = False,
    ):
        self.run_all = run_all
        self.list_file_diff = list_file_diff
        self.container_registry = container_registry
        self.container_registry_repo = container_registry_repo
        self.commit = commit
        self.test_path = test_path
        self.external_hardware_test_path = external_hardware_test_path
        self.pipeline_file_path = pipeline_file_path
    
    @property
    def container_image(self):
        return f"{self.container_registry}/{self.container_registry_repo}:{self.commit}"
    
    def validate(self):
        """Validate the configuration."""
        # Check if commit is a valid Git commit hash
        pattern = r"^[0-9a-f]{40}$"
        if not re.match(pattern, self.commit):
            raise ValueError(f"Commit {self.commit} is not a valid Git commit hash")

        # Check if test_path exists
        if not os.path.exists(self.test_path):
            raise FileNotFoundError(f"Test file {self.test_path} not found")
        
        # Check if external_hardware_test_path exists
        if not os.path.exists(self.external_hardware_test_path):
            raise FileNotFoundError(f"External hardware test file {self.external_hardware_test_path} not found")


class PipelineGenerator:
    def __init__(
            self, 
            config: PipelineGeneratorConfig
        ):
        self.config = config
        self.config.validate()
