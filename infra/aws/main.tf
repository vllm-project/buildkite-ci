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
  public_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24", "10.0.4.0/24"]

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
    cpu-queue = {
      BuildkiteQueue          = "cpu_queue"
      InstanceTypes           = "r6in.16xlarge"
      MaxSize                 = 2
      ECRAccessPolicy         = "poweruser"
      InstanceOperatingSystem = "linux"
      OnDemandPercentage      = 100
      EnableInstanceStorage   = "true"
    },

    gpu-1-queue = {
      BuildkiteQueue          = "gpu_1_queue"
      InstanceTypes           = "g6.4xlarge"
      MaxSize                 = 60
      ECRAccessPolicy         = "readonly"
      InstanceOperatingSystem = "linux"
      OnDemandPercentage      = 100
      ImageId                 = "ami-060f16e7ab30bfef6"
    },

    gpu-4-queue = {
      BuildkiteQueue          = "gpu_4_queue"
      InstanceTypes           = "g6.12xlarge"
      MaxSize                 = 2
      ECRAccessPolicy         = "readonly"
      InstanceOperatingSystem = "linux"
      OnDemandPercentage      = 100
      ImageId                 = "ami-060f16e7ab30bfef6"
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
        "arn:aws:secretsmanager:us-west-2:936637512419:secret:hf_token-JD4TSm"
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