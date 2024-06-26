variable "region" {
  type    = string
  default = "us-west-2"
}

locals { timestamp = regex_replace(timestamp(), "[- TZ:]", "") }

source "amazon-ebs" "gpu_box" {
  ami_name        = "vllm-buildkite-stack-linux-gpu-${local.timestamp}"
  ami_description = "vLLM Buildkite Elastic Stack (Amazon Linux 2 LTS w/ nvidia-docker)"
  ami_groups      = ["all"]
  instance_type   = "g6.4xlarge"
  launch_block_device_mappings {
    delete_on_termination = true
    device_name           = "/dev/xvda"
    volume_size           = 50
    volume_type           = "gp2"
  }
  region = var.region
  source_ami_filter {
    filters = {
      architecture = "x86_64"
      # Sync this with the default buildkite elastic stack AMI
      # https://s3.amazonaws.com/buildkite-aws-stack/v6.21.0/aws-stack.yml
      # Mappings: AWSRegion2AMI: us-west-2: linuxamd64
      # The name can be retrieved by querying the AMI on AWS
      name         = "buildkite-stack-linux-x86_64-2024-05-27T04-51-04Z-us-west-2" 
    }
    most_recent = true
    owners      = ["172840064832"] # Buildkite AWS account ID
  }
  ssh_username = "ec2-user"
}

build {
  sources = ["source.amazon-ebs.gpu_box"]

  provisioner "file" {
    destination = "/tmp"
    source      = "conf"
  }
  provisioner "shell" {
    script = "scripts/install-nvidia-docker.sh"
  }
}
