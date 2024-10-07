import pytest
import sys
import os
import tempfile

from scripts.pipeline_generator.pipeline_generator import PipelineGeneratorConfig

TEST_COMMIT = "1234567890123456789012345678901234567890"
TEST_FILE_PATH = "tests.yaml"
EXTERNAL_HARDWARE_TEST_FILE_PATH = "external_hardware_tests.yaml"
PIPELINE_OUTPUT_FILE_PATH = "pipeline.yaml"


def test_pipeline_generator_config_get_container_image():
    container_registry = "container.registry"
    container_registry_repo = "test"
    pipeline_generator_config = PipelineGeneratorConfig(
        run_all=True,
        list_file_diff=[],
        container_registry=container_registry,
        container_registry_repo=container_registry_repo,
        commit=TEST_COMMIT,
        test_path=TEST_FILE_PATH,
        external_hardware_test_path=EXTERNAL_HARDWARE_TEST_FILE_PATH,
        pipeline_file_path=PIPELINE_OUTPUT_FILE_PATH
    )
    assert pipeline_generator_config.container_image == f"{container_registry}/{container_registry_repo}:{TEST_COMMIT}"


def test_get_pipeline_generator_config_invalid_commit():
    with pytest.raises(ValueError, match="not a valid Git commit hash"):
        _ = PipelineGeneratorConfig(
            run_all=True,
            list_file_diff=[],
            container_registry="container.registry",
            container_registry_repo="test",
            commit=TEST_COMMIT[:-2],
            test_path=TEST_FILE_PATH,
    external_hardware_test_path=EXTERNAL_HARDWARE_TEST_FILE_PATH,
    pipeline_file_path=PIPELINE_OUTPUT_FILE_PATH
        )


if __name__ == "__main__":
    sys.exit(pytest.main(["-v", __file__]))
