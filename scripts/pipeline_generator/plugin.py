from pydantic import BaseModel, Field
from typing import List, Dict, Any, Optional
from utils import HF_HOME   

DOCKER_PLUGIN_NAME = "docker#v5.2.0"
KUBERNETES_PLUGIN_NAME = "kubernetes"

class DockerPluginConfig(BaseModel):
    image: str = ""
    always_pull: bool = Field(default=True, alias="always-pull")
    propagate_environment: bool = Field(default=True, alias="propagate-environment")
    gpus: Optional[str] = "all"
    mount_buildkite_agent: Optional[bool] = Field(default=False, alias="mount-buildkite-agent")
    command: List[str] = Field(default_factory=list)
    environment: List[str] = [f"HF_HOME={HF_HOME}", "VLLM_USAGE_SOURCE=ci-test", "HF_TOKEN", "BUILDKITE_ANALYTICS_TOKEN"]
    volumes: List[str] = ["/dev/shm:/dev/shm", f"{HF_HOME}:{HF_HOME}"]

class KubernetesPodSpec(BaseModel):
    containers: List[Dict[str, Any]]
    node_selector: Dict[str, Any] = Field(default_factory=dict)
    volumes: List[Dict[str, Any]] = Field(default_factory=list)

class KubernetesPluginConfig(BaseModel):
    pod_spec: KubernetesPodSpec

def get_kubernetes_plugin_config(docker_image_path: str, test_bash_command: List[str]) -> Dict:
    pod_spec = KubernetesPodSpec(
        containers=[{
            "image": docker_image_path, 
            "command": test_bash_command
        }]
    )
    return {KUBERNETES_PLUGIN_NAME: KubernetesPluginConfig(pod_spec=pod_spec).dict(by_alias=True)}

def get_docker_plugin_config(docker_image_path: str, test_bash_command: List[str], no_gpu: bool) -> Dict:
    docker_plugin_config = DockerPluginConfig(
        image=docker_image_path, 
        command=test_bash_command
    )
    if no_gpu:
        docker_plugin_config.gpus = None
    return {DOCKER_PLUGIN_NAME: docker_plugin_config.dict(exclude_none=True, by_alias=True)}