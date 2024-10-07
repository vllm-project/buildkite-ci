import pytest
import sys
import os
import tempfile

from scripts.pipeline_generator.pipeline_generator import PipelineGenerator, PipelineGeneratorConfig

TEST_COMMIT = "1234567890123456789012345678901234567890"
TEST_FILE_PATH = "tests.yaml"
EXTERNAL_HARDWARE_TEST_FILE_PATH = "external_hardware_tests.yaml"
PIPELINE_OUTPUT_FILE_PATH = "pipeline.yaml"

def test_get_pipeline_generator_config():
    with tempfile.TemporaryDirectory() as temp_dir:
        with open(os.path.join(temp_dir, TEST_FILE_PATH), "w") as f:
            f.write("content")
        with open(os.path.join(temp_dir, EXTERNAL_HARDWARE_TEST_FILE_PATH), "w") as f:
            f.write("content")
        pipeline_generator_config = PipelineGeneratorConfig(
            run_all=True,
            list_file_diff=[],
            container_registry="container.registry",
            container_registry_repo="test",
            commit=TEST_COMMIT,
            test_path=os.path.join(temp_dir, TEST_FILE_PATH),
            external_hardware_test_path=os.path.join(temp_dir, EXTERNAL_HARDWARE_TEST_FILE_PATH),
            pipeline_file_path=os.path.join(temp_dir, PIPELINE_OUTPUT_FILE_PATH)
        )

def test_pipeline_generator_config_get_container_image():
    with tempfile.TemporaryDirectory() as temp_dir:
        with open(os.path.join(temp_dir, TEST_FILE_PATH), "w") as f:
            f.write("content")
        with open(os.path.join(temp_dir, EXTERNAL_HARDWARE_TEST_FILE_PATH), "w") as f:
            f.write("content")
        container_registry = "container.registry"
        container_registry_repo = "test"
        pipeline_generator_config = PipelineGeneratorConfig(
            run_all=True,
            list_file_diff=[],
            container_registry=container_registry,
            container_registry_repo=container_registry_repo,
            commit=TEST_COMMIT,
            test_path=os.path.join(temp_dir, TEST_FILE_PATH),
            external_hardware_test_path=os.path.join(temp_dir, EXTERNAL_HARDWARE_TEST_FILE_PATH),
            pipeline_file_path=os.path.join(temp_dir, PIPELINE_OUTPUT_FILE_PATH)
        )
        assert pipeline_generator_config.container_image == f"{container_registry}/{container_registry_repo}:{TEST_COMMIT}"

def test_get_pipeline_generator_config_test_file_nonexist():
    with tempfile.TemporaryDirectory() as temp_dir:
        with open(os.path.join(temp_dir, EXTERNAL_HARDWARE_TEST_FILE_PATH), "w") as f:
            f.write("content")
        with pytest.raises(ValueError, match="Test path"):
            pipeline_generator_config = PipelineGeneratorConfig(
                run_all=True,
                list_file_diff=[],
                container_registry="container.registry",
                container_registry_repo="test",
                commit=TEST_COMMIT,
                test_path=os.path.join(temp_dir, TEST_FILE_PATH),
                external_hardware_test_path=os.path.join(temp_dir, EXTERNAL_HARDWARE_TEST_FILE_PATH),
                pipeline_file_path=os.path.join(temp_dir, PIPELINE_OUTPUT_FILE_PATH)
            )

def test_get_pipeline_generator_config_ext_hardware_test_file_nonexist():
    with tempfile.TemporaryDirectory() as temp_dir:
        with open(os.path.join(temp_dir, TEST_FILE_PATH), "w") as f:
            f.write("content")
        with pytest.raises(ValueError, match="External hardware test path"):
            pipeline_generator_config = PipelineGeneratorConfig(
                run_all=True,
                list_file_diff=[],
                container_registry="container.registry",
                container_registry_repo="test",
                commit=TEST_COMMIT,
                test_path=os.path.join(temp_dir, TEST_FILE_PATH),
                external_hardware_test_path=os.path.join(temp_dir, EXTERNAL_HARDWARE_TEST_FILE_PATH),
                pipeline_file_path=os.path.join(temp_dir, PIPELINE_OUTPUT_FILE_PATH)
            )

def test_get_pipeline_generator_config_invalid_commit():
    with tempfile.TemporaryDirectory() as temp_dir:
        with open(os.path.join(temp_dir, TEST_FILE_PATH), "w") as f:
            f.write("content")
        with open(os.path.join(temp_dir, EXTERNAL_HARDWARE_TEST_FILE_PATH), "w") as f:
            f.write("content")
        with pytest.raises(ValueError, match="not a valid Git commit hash"):
            pipeline_generator_config = PipelineGeneratorConfig(
                run_all=True,
                list_file_diff=[],
                container_registry="container.registry",
                container_registry_repo="test",
                commit=TEST_COMMIT[:-2],
                test_path=os.path.join(temp_dir, TEST_FILE_PATH),
                external_hardware_test_path=os.path.join(temp_dir, EXTERNAL_HARDWARE_TEST_FILE_PATH),
                pipeline_file_path=os.path.join(temp_dir, PIPELINE_OUTPUT_FILE_PATH)
            )

if __name__ == "__main__":
    sys.exit(pytest.main(["-v", __file__]))