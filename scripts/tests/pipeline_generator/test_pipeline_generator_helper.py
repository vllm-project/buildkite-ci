import pytest
import sys

from scripts.pipeline_generator.pipeline_generator_helper import get_build_commands

TEST_CONTAINER_REGISTRY = "container.registry"
TEST_CONTAINER_IMAGE = "container.registry/test:abcdef0123456789abcdef0123456789abcdef01"

def test_get_build_commands():
    commands = get_build_commands(TEST_CONTAINER_REGISTRY, TEST_CONTAINER_IMAGE)
    assert len(commands) == 4

    ecr_login_command = commands[0]
    assert ecr_login_command == (
        "aws ecr-public get-login-password --region us-east-1 | "
        f"docker login --username AWS --password-stdin container.registry"
    )

    image_check_command = commands[1]
    assert image_check_command.startswith("#!/bin/bash")
    assert "$(docker manifest inspect container.registry/test:abcdef0123456789abcdef0123456789abcdef01)" in image_check_command

    docker_build_command = commands[2]
    assert docker_build_command.startswith("docker build")
    assert "--tag container.registry/test:abcdef0123456789abcdef0123456789abcdef01" in docker_build_command

    docker_push_command = commands[3]
    assert docker_push_command == "docker push container.registry/test:abcdef0123456789abcdef0123456789abcdef01"

if __name__ == "__main__":
    sys.exit(pytest.main(["-v", __file__]))