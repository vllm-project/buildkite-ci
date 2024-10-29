from typing import List

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
    # TODO: Stop using . in docker build command
    docker_push_command = f"docker push {container_image}"
    return [ecr_login_command, image_check_command, docker_build_command, docker_push_command]
