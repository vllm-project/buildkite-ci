resource "buildkite_agent_token" "tf_managed" {
  description = "token used by the build fleet"
}

resource "buildkite_cluster_agent_token" "perf_benchmark" {
  cluster_id  = "Q2x1c3Rlci0tLWUxNjMwOGZjLTVkYTEtNGE2OC04YzAzLWI1YjdkYzA1YzcyZA=="
  description = "token used by the perf benchmark fleet"
}

resource "buildkite_cluster_agent_token" "ci" {
  cluster_id  = "Q2x1c3Rlci0tLTljZWNjNmIxLTk0Y2QtNDNkMS1hMjU2LWFiNDM4MDgzZjRmNQ=="
  description = "token used by the CI AWS fleet"
}

resource "aws_ssm_parameter" "bk_agent_token" {
  name  = "/bk_agent_token"
  type  = "String"
  value = buildkite_agent_token.tf_managed.token
}

resource "aws_ssm_parameter" "bk_agent_token_cluster_perf_benchmark" {
  name  = "/bk_agent_token_cluster_perf_benchmark"
  type  = "String"
  value = buildkite_cluster_agent_token.perf_benchmark.token
}

resource "aws_ssm_parameter" "bk_agent_token_cluster_ci" {
  name  = "/bk_agent_token_cluster_ci"
  type  = "String"
  value = buildkite_cluster_agent_token.ci.token
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
    elastic_ci_stack_version             = var.elastic_ci_stack_version
    BuildkiteAgentTokenParameterStorePath = aws_ssm_parameter.bk_agent_token.name
    MinSize                              = 0
    EnableECRPlugin                      = "true"
    VpcId                               = module.vpc.vpc_id
    SecurityGroupIds                     = module.vpc.default_security_group_id
    Subnets                             = join(",", module.vpc.public_subnets)
    RootVolumeSize                      = 512   # Gb
    EnableDockerUserNamespaceRemap      = false # Turn off remap so we can run dind
    BuildkiteAgentTimestampLines        = true
    BuildkiteTerminateInstanceAfterJob  = true
  }

  queues_parameters_premerge = {
    small-cpu-queue-premerge = {
      BuildkiteAgentTokenParameterStorePath = aws_ssm_parameter.bk_agent_token_cluster_ci.name
      BuildkiteQueue                       = "small_cpu_queue_premerge"
      InstanceTypes                        = "r6in.large" # Intel Ice Lake with AVX-512 for vLLM CPU backend
      MaxSize                              = 10
      ECRAccessPolicy                      = "readonly"
      InstanceOperatingSystem              = "linux"
      OnDemandPercentage                   = 100
      EnableInstanceStorage                = "true"
    }

    cpu-queue-premerge = {
      BuildkiteAgentTokenParameterStorePath = aws_ssm_parameter.bk_agent_token_cluster_ci.name
      BuildkiteQueue                       = "cpu_queue_premerge"
      InstanceTypes                        = "r6in.16xlarge" # 512GB memory for CUDA kernel compilation
      MaxSize                              = 10
      ECRAccessPolicy                      = "readonly"
      InstanceOperatingSystem              = "linux"
      OnDemandPercentage                   = 100
      EnableInstanceStorage                = "true"
    }
  }

  queues_parameters_postmerge = {
    small-cpu-queue-postmerge = {
      BuildkiteAgentTokenParameterStorePath = aws_ssm_parameter.bk_agent_token_cluster_ci.name
      BuildkiteQueue                       = "small_cpu_queue_postmerge"
      InstanceTypes                        = "r6in.large" # Intel Ice Lake with AVX-512 for vLLM CPU backend
      MaxSize                              = 10
      ECRAccessPolicy                      = "poweruser"
      InstanceOperatingSystem              = "linux"
      OnDemandPercentage                   = 100
      EnableInstanceStorage                = "true"
      BuildkiteTerminateInstanceAfterJob   = true
    }

    cpu-queue-postmerge = {
      BuildkiteAgentTokenParameterStorePath = aws_ssm_parameter.bk_agent_token_cluster_ci.name
      BuildkiteQueue                       = "cpu_queue_postmerge"
      InstanceTypes                        = "r6in.16xlarge" # 512GB memory for CUDA kernel compilation
      MaxSize                              = 10
      ECRAccessPolicy                      = "poweruser"
      InstanceOperatingSystem              = "linux"
      OnDemandPercentage                   = 100
      EnableInstanceStorage                = "true"
      BuildkiteTerminateInstanceAfterJob   = true
    }
  }

  ci_gpu_queues_parameters = {
    gpu-1-queue-ci = {
      BuildkiteAgentTokenParameterStorePath = aws_ssm_parameter.bk_agent_token_cluster_ci.name
      BuildkiteQueue                       = "gpu_1_queue"
      InstanceTypes                        = "g6.4xlarge"  # 1 Nvidia L4 GPU, 64GB memory
      MaxSize                              = 64
      ECRAccessPolicy                      = "readonly"
      InstanceOperatingSystem              = "linux"
      OnDemandPercentage                   = 100
      ImageId                              = "ami-03d9992ee575904da" # Custom AMI with CUDA 12.0
    }

    gpu-4-queue-ci = {
      BuildkiteAgentTokenParameterStorePath = aws_ssm_parameter.bk_agent_token_cluster_ci.name
      BuildkiteQueue                       = "gpu_4_queue"
      InstanceTypes                        = "g6.12xlarge" # 4 Nvidia L4 GPUs, 192GB memory
      MaxSize                              = 12
      ECRAccessPolicy                      = "readonly"
      InstanceOperatingSystem              = "linux"
      OnDemandPercentage                   = 100
      ImageId                              = "ami-03d9992ee575904da" # Custom AMI with CUDA 12.0
    }
  }

  queues_parameters = {
    bootstrap = {
      BuildkiteAgentTokenParameterStorePath = aws_ssm_parameter.bk_agent_token_cluster_perf_benchmark.name
      BuildkiteQueue                       = "bootstrap"
      InstanceTypes                        = "r6in.large" # Intel Ice Lake with AVX-512 for vLLM CPU backend
      MaxSize                              = 10
      ECRAccessPolicy                      = "poweruser"
      InstanceOperatingSystem              = "linux"
      OnDemandPercentage                   = 100
      EnableInstanceStorage                = "true"
    }
  }

  merged_parameters_premerge = {
    for name, params in local.queues_parameters_premerge :
    name => merge(local.default_parameters, params)
  }

  merged_parameters_postmerge = {
    for name, params in local.queues_parameters_postmerge :
    name => merge(local.default_parameters, params)
  }

  merged_parameters_ci_gpu = {
    for name, params in local.ci_gpu_queues_parameters :
    name => merge(local.default_parameters, params)
  }

  merged_parameters = {
    for name, params in local.queues_parameters :
    name => merge(local.default_parameters, params)
  }
}

resource "aws_cloudformation_stack" "bk_queue_premerge" {
  for_each   = local.merged_parameters_premerge
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

resource "aws_cloudformation_stack" "bk_queue_postmerge" {
  for_each   = local.merged_parameters_postmerge
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

resource "aws_cloudformation_stack" "bk_queue_ci_gpu" {
  for_each   = local.merged_parameters_ci_gpu
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

resource "aws_iam_policy" "premerge_ecr_public_read_access_policy" {
  name        = "premerge-ecr-public-read-access-policy"
  description = "Policy to pull images from premerge ECR"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action = [
        "ecr-public:GetAuthorizationToken",
        "ecr-public:BatchCheckLayerAvailability", 
        "ecr-public:GetDownloadUrlForLayer",
        "ecr-public:GetRepositoryCatalogData",
        "ecr-public:DescribeRepositories",
        "ecr-public:DescribeImageTags",
        "ecr-public:DescribeRegistries",
        "sts:GetServiceBearerToken"
      ]
      Resource = "arn:aws:ecr-public::936637512419:repository/vllm-ci-test-repo"
    }]
  })
}

resource "aws_iam_policy" "premerge_ecr_public_write_access_policy" {
  name        = "premerge-ecr-public-write-access-policy"
  description = "Policy to push and pull images from premerge ECR"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action = [
        "ecr-public:BatchCheckLayerAvailability",
        "ecr-public:CompleteLayerUpload",
        "ecr-public:DescribeImageTags",
        "ecr-public:DescribeImages",
        "ecr-public:DescribeRegistries",
        "ecr-public:DescribeRepositories",
        "ecr-public:GetAuthorizationToken",
        "ecr-public:GetRegistryCatalogData",
        "ecr-public:GetRepositoryCatalogData",
        "ecr-public:GetRepositoryPolicy",
        "ecr-public:InitiateLayerUpload",
        "ecr-public:ListTagsForResource",
        "ecr-public:PutImage",
        "ecr-public:PutRegistryCatalogData",
        "ecr-public:TagResource",
        "ecr-public:UploadLayerPart",
        "sts:GetServiceBearerToken"
      ]
      Resource = "arn:aws:ecr-public::936637512419:repository/vllm-ci-test-repo"
    },
    {
      Effect   = "Allow"
      Action = [
        "ecr-public:GetAuthorizationToken",
        "sts:GetServiceBearerToken"
      ],
      Resource = "*"
    }]
  })
}

resource "aws_iam_policy" "postmerge_ecr_public_read_access_policy" {
  name        = "postmerge-ecr-public-read-access-policy"
  description = "Policy to pull images from postmerge ECR"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action = [
        "ecr-public:GetAuthorizationToken",
        "ecr-public:BatchCheckLayerAvailability", 
        "ecr-public:GetDownloadUrlForLayer",
        "ecr-public:GetRepositoryCatalogData",
        "ecr-public:DescribeRepositories",
        "ecr-public:DescribeImageTags",
        "ecr-public:DescribeRegistries",
        "sts:GetServiceBearerToken"
      ]
      Resource = "arn:aws:ecr-public::936637512419:repository/vllm-ci-postmerge-repo"
    }]
  })
}

resource "aws_iam_policy" "postmerge_ecr_public_read_write_access_policy" {
  name        = "postmerge-ecr-public-read-write-access-policy"
  description = "Policy to push and pull images from postmerge ECR"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action = [
        "ecr-public:BatchCheckLayerAvailability",
        "ecr-public:CompleteLayerUpload",
        "ecr-public:DescribeImageTags",
        "ecr-public:DescribeImages",
        "ecr-public:DescribeRegistries", 
        "ecr-public:DescribeRepositories",
        "ecr-public:GetAuthorizationToken",
        "ecr-public:GetRegistryCatalogData",
        "ecr-public:GetRepositoryCatalogData",
        "ecr-public:GetRepositoryPolicy",
        "ecr-public:InitiateLayerUpload",
        "ecr-public:ListTagsForResource",
        "ecr-public:PutImage",
        "ecr-public:PutRegistryCatalogData",
        "ecr-public:TagResource",
        "ecr-public:UploadLayerPart",
        "sts:GetServiceBearerToken"
      ]
      Resource = "arn:aws:ecr-public::936637512419:repository/vllm-ci-postmerge-repo"
    }]
  })
}

resource "aws_iam_policy" "release_ecr_public_read_write_access_policy" {
  name        = "release-ecr-public-read-write-access-policy"
  description = "Policy to push and pull images from release ECR"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action = [
        "ecr-public:BatchCheckLayerAvailability",
        "ecr-public:CompleteLayerUpload",
        "ecr-public:DescribeImageTags",
        "ecr-public:DescribeImages",
        "ecr-public:DescribeRegistries", 
        "ecr-public:DescribeRepositories",
        "ecr-public:GetAuthorizationToken",
        "ecr-public:GetRegistryCatalogData",
        "ecr-public:GetRepositoryCatalogData",
        "ecr-public:GetRepositoryPolicy",
        "ecr-public:InitiateLayerUpload",
        "ecr-public:ListTagsForResource",
        "ecr-public:PutImage",
        "ecr-public:PutRegistryCatalogData",
        "ecr-public:TagResource",
        "ecr-public:UploadLayerPart",
        "sts:GetServiceBearerToken"
      ]
      Resource = "arn:aws:ecr-public::936637512419:repository/vllm-release-repo"
    }]
  })
}

resource "aws_iam_policy" "cpu_release_ecr_public_read_write_access_policy" {
  name        = "cpu-release-ecr-public-read-write-access-policy"
  description = "Policy to push and pull images from release ECR"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action = [
        "ecr-public:BatchCheckLayerAvailability",
        "ecr-public:CompleteLayerUpload",
        "ecr-public:DescribeImageTags",
        "ecr-public:DescribeImages",
        "ecr-public:DescribeRegistries", 
        "ecr-public:DescribeRepositories",
        "ecr-public:GetAuthorizationToken",
        "ecr-public:GetRegistryCatalogData",
        "ecr-public:GetRepositoryCatalogData",
        "ecr-public:GetRepositoryPolicy",
        "ecr-public:InitiateLayerUpload",
        "ecr-public:ListTagsForResource",
        "ecr-public:PutImage",
        "ecr-public:PutRegistryCatalogData",
        "ecr-public:TagResource",
        "ecr-public:UploadLayerPart",
        "sts:GetServiceBearerToken"
      ]
      Resource = "arn:aws:ecr-public::936637512419:repository/vllm-cpu-release-repo"
    }]
  })
}

resource "aws_iam_policy" "bk_stack_secrets_access" {
  name = "access-to-bk-stack-secrets"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = ["secretsmanager:GetSecretValue"],
      Effect = "Allow",
      Resource = [
        aws_secretsmanager_secret.ci_hf_token.arn,
        aws_secretsmanager_secret.bk_analytics_token.arn
      ]
    }]
  })
}

resource "aws_iam_policy" "bk_stack_sccache_bucket_read_access" {
  name = "read-access-to-sccache-bucket"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = [
        "s3:Get*",
        "s3:List",
      ],
      Effect = "Allow",
      Resource = [
        "arn:aws:s3:::vllm-build-sccache/*",
        "arn:aws:s3:::vllm-build-sccache"
      ]
    }]
  })
}

resource "aws_iam_policy" "bk_stack_sccache_bucket_read_write_access" {
  name = "read-write-access-to-sccache-bucket"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = [
        "s3:Get*",
        "s3:List",
        "s3:PutObject"
      ],
      Effect = "Allow",
      Resource = [
        "arn:aws:s3:::vllm-build-sccache/*",
        "arn:aws:s3:::vllm-build-sccache"
      ]
    }]
  })
}

resource "aws_iam_policy" "vllm_wheels_bucket_read_write_access" {
  name = "read-write-access-to-vllm-wheels-bucket"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = [
        "s3:Get*",
        "s3:List",
        "s3:PutObject"
      ],
      Effect = "Allow",
      Resource = [
        "arn:aws:s3:::vllm-wheels/*",
        "arn:aws:s3:::vllm-wheels"
      ]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "premerge_ecr_public_read_access" {
  for_each   = merge(
    aws_cloudformation_stack.bk_queue_ci_gpu
  )
  role       = each.value.outputs.InstanceRoleName
  policy_arn = aws_iam_policy.premerge_ecr_public_read_access_policy.arn
}

resource "aws_iam_role_policy_attachment" "premerge_ecr_public_write_access" {
  for_each   = merge(
    aws_cloudformation_stack.bk_queue,
    aws_cloudformation_stack.bk_queue_premerge,
    aws_cloudformation_stack.bk_queue_postmerge
  )
  role       = each.value.outputs.InstanceRoleName
  policy_arn = aws_iam_policy.premerge_ecr_public_write_access_policy.arn
}

resource "aws_iam_role_policy_attachment" "postmerge_ecr_public_read_access" {
  for_each   = merge(
    aws_cloudformation_stack.bk_queue_ci_gpu
  )
  role       = each.value.outputs.InstanceRoleName
  policy_arn = aws_iam_policy.postmerge_ecr_public_read_access_policy.arn
}

resource "aws_iam_role_policy_attachment" "postmerge_ecr_public_read_write_access" {
  for_each   = merge(
    aws_cloudformation_stack.bk_queue_postmerge
  )
  role       = each.value.outputs.InstanceRoleName
  policy_arn = aws_iam_policy.postmerge_ecr_public_read_write_access_policy.arn
}

resource "aws_iam_role_policy_attachment" "release_ecr_public_read_write_access" {
  for_each   = merge(
    aws_cloudformation_stack.bk_queue_postmerge
  )
  role       = each.value.outputs.InstanceRoleName
  policy_arn = aws_iam_policy.release_ecr_public_read_write_access_policy.arn
}

resource "aws_iam_role_policy_attachment" "cpu_release_ecr_public_read_write_access" {
  for_each   = merge(
    aws_cloudformation_stack.bk_queue_postmerge
  )
  role       = each.value.outputs.InstanceRoleName
  policy_arn = aws_iam_policy.cpu_release_ecr_public_read_write_access_policy.arn
}

resource "aws_iam_role_policy_attachment" "bk_stack_secrets_access" {
  for_each = merge(
    aws_cloudformation_stack.bk_queue,
    aws_cloudformation_stack.bk_queue_premerge,
    aws_cloudformation_stack.bk_queue_postmerge,
    aws_cloudformation_stack.bk_queue_ci_gpu,
  )
  role       = each.value.outputs.InstanceRoleName
  policy_arn = aws_iam_policy.bk_stack_secrets_access.arn
}

resource "aws_iam_role_policy_attachment" "bk_stack_sccache_bucket_read_access" {
  for_each = {
    for k, v in aws_cloudformation_stack.bk_queue_premerge : k => v
    if v.name == "bk-cpu-queue-premerge"
  }
  role       = each.value.outputs.InstanceRoleName
  policy_arn = aws_iam_policy.bk_stack_sccache_bucket_read_access.arn
}

resource "aws_iam_role_policy_attachment" "bk_stack_sccache_bucket_read_write_access" {
  for_each = merge(
    {
      for k, v in aws_cloudformation_stack.bk_queue : k => v
      if v.name == "bk-cpu-queue"
    },
    {
      for k, v in aws_cloudformation_stack.bk_queue_postmerge : k => v
      if v.name == "bk-cpu-queue-postmerge" 
    }
  )
  role       = each.value.outputs.InstanceRoleName
  policy_arn = aws_iam_policy.bk_stack_sccache_bucket_read_write_access.arn
}

resource "aws_iam_role_policy_attachment" "vllm_wheels_bucket_read_write_access" {
  for_each = {
    for k, v in aws_cloudformation_stack.bk_queue_postmerge : k => v
  }
  role       = each.value.outputs.InstanceRoleName
  policy_arn = aws_iam_policy.vllm_wheels_bucket_read_write_access.arn
}
