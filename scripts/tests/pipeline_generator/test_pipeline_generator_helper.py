import pytest
import sys

from scripts.pipeline_generator.pipeline_generator_helper import step_should_run



if __name__ == "__main__":
    sys.exit(pytest.main(["-v", __file__]))
