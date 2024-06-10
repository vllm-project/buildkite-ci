resource "buildkite_agent_token" "tf_managed" {
  description = "token used by the build fleet"
}

resource "aws_ssm_parameter" "bk_agent_token" {
  name  = "/bk_agent_token"
  type  = "String"
  value = buildkite_agent_token.tf_managed.token
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name = "vllm-ci-vpc"
  cidr = "10.0.0.0/16"

  azs            = ["us-west-2a", "us-west-2b", "us-west-2c", "us-west-2d"]
  public_subnets = ["10.0.0.0/18", "10.0.64.0/18", "10.0.128.0/18", "10.0.192.0/18"]

  enable_dns_hostnames          = true
  map_public_ip_on_launch       = true
  manage_default_network_acl    = false
  manage_default_route_table    = false
  manage_default_security_group = false

  tags = {
    Name = "vLLM CI VPC"
  }
}

locals {
  default_parameters = {
    elastic_ci_stack_version = var.elastic_ci_stack_version

    BuildkiteAgentTokenParameterStorePath = aws_ssm_parameter.bk_agent_token.name
    MinSize                               = 0
    EnableECRPlugin                       = "true"
    VpcId                                 = module.vpc.vpc_id
    SecurityGroupIds                      = module.vpc.default_security_group_id
    Subnets                               = join(",", module.vpc.public_subnets)
    RootVolumeSize                        = 512   # Gb
    EnableDockerUserNamespaceRemap        = false # Turn off remap so we can run dind
    BuildkiteAgentTimestampLines          = true
    BuildkiteTerminateInstanceAfterJob    = true
  }

  queues_parameters = {
    small-cpu-queue = {
      BuildkiteQueue          = "small_cpu_queue"
      InstanceTypes           = "r6in.large" # r6in uses Intel Ice Lake which supports AVX-512 required by vLLM CPU backend.
      MaxSize                 = 1
      ECRAccessPolicy         = "poweruser"
      InstanceOperatingSystem = "linux"
      OnDemandPercentage      = 100
      EnableInstanceStorage   = "true"
    }
    cpu-queue = {
      BuildkiteQueue          = "cpu_queue"
      InstanceTypes           = "r6in.16xlarge" # r6in uses Intel Ice Lake which supports AVX-512 required by vLLM CPU backend. 16x large comes with 512GB memory, required for compiling CUDA kernel.
      MaxSize                 = 5
      ECRAccessPolicy         = "poweruser"
      InstanceOperatingSystem = "linux"
      OnDemandPercentage      = 100
      EnableInstanceStorage   = "true"
    },

    gpu-1-queue = {
      BuildkiteQueue          = "gpu_1_queue" # Queue for jobs running on 1 GPU
      InstanceTypes           = "g6.4xlarge"  # 1 Nvidia L4 GPU and 64GB memory.
      MaxSize                 = 80
      ECRAccessPolicy         = "readonly"
      InstanceOperatingSystem = "linux"
      OnDemandPercentage      = 100
      ImageId                 = "ami-03d9992ee575904da" # Custom AMI based on Buildkite Linux AMI with CUDA 12.0
    },

    gpu-4-queue = {
      BuildkiteQueue          = "gpu_4_queue" # Queue for jobs running on 4 GPUs
      InstanceTypes           = "g6.12xlarge" # 4 Nvidia L4 GPUs and 192GB memory.
      MaxSize                 = 10
      ECRAccessPolicy         = "readonly"
      InstanceOperatingSystem = "linux"
      OnDemandPercentage      = 100
      ImageId                 = "ami-03d9992ee575904da" # Custom AMI based on Buildkite Linux AMI with CUDA 12.0
    }
  }

  merged_parameters = {
    for name, params in local.queues_parameters :
    name => merge(local.default_parameters, params)
  }
}


resource "aws_cloudformation_stack" "bk_queue" {
  for_each   = local.merged_parameters
  name       = "bk-${each.key}"
  parameters = { for k, v in each.value : k => v if k != "elastic_ci_stack_version" }

  template_url = "https://s3.amazonaws.com/buildkite-aws-stack/v${each.value["elastic_ci_stack_version"]}/aws-stack.yml"
  capabilities = ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM", "CAPABILITY_AUTO_EXPAND"]

  lifecycle {
    ignore_changes = [
      tags["AppManagerCFNStackKey"],
      tags_all["AppManagerCFNStackKey"],
    ]
  }
}

resource "aws_iam_policy" "ecr_public_access_policy" {
  name        = "ecr-public-access-policy"
  description = "Policy to push and pull images from ECR"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ecr-public:DescribeImageTags",
          "ecr-public:DescribeRegistries",
          "ecr-public:DescribeRepositories",
          "ecr-public:BatchCheckLayerAvailability",
          "ecr-public:DescribeImages",
          "ecr-public:GetAuthorizationToken",
          "ecr-public:GetRegistryCatalogData",
          "ecr-public:GetRepositoryCatalogData",
          "ecr-public:GetRepositoryPolicy",
          "ecr-public:ListTagsForResource",
          "ecr-public:CompleteLayerUpload",
          "ecr-public:InitiateLayerUpload",
          "ecr-public:PutImage",
          "ecr-public:PutRegistryCatalogData",
          "ecr-public:UploadLayerPart",
          "ecr-public:TagResource",
          "sts:GetServiceBearerToken"
        ],
        Resource = "*"
      }
    ]
  })
}


resource "aws_iam_policy" "bk_stack_secrets_access" {
  name = "access-to-bk-stack-secrets"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = ["secretsmanager:GetSecretValue"],
      Effect : "Allow",
      Resource = [
        aws_secretsmanager_secret.ci_hf_token.arn
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_public_access" {
  for_each   = aws_cloudformation_stack.bk_queue
  role       = each.value.outputs.InstanceRoleName
  policy_arn = aws_iam_policy.ecr_public_access_policy.arn
}

resource "aws_iam_role_policy_attachment" "bk_stack_secrets_access" {
  for_each   = aws_cloudformation_stack.bk_queue
  role       = each.value.outputs.InstanceRoleName
  policy_arn = aws_iam_policy.bk_stack_secrets_access.arn
}
