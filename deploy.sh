#!/usr/bin/env bash
set -Eeuo pipefail

REGION="${AWS_REGION:-us-east-1}"
REPO_NAME="${ECR_REPOSITORY:-myagent}"
CLUSTER_NAME="${ECS_CLUSTER:-myagent-cluster}"
SERVICE_NAME="${ECS_SERVICE:-myagent-service}"
TASK_FAMILY="${ECS_TASK_FAMILY:-myagent-task}"
VPC_ID="${VPC_ID:-vpc-0219b48ef223b5622}"
SUBNETS="${SUBNETS:-subnet-011541314b77dd42b,subnet-07aae9b81c0b62271,subnet-08961a16241534cfe}"
CPU="${ECS_CPU:-256}"
MEMORY="${ECS_MEMORY:-512}"
CONTAINER_NAME="app"
CONTAINER_PORT="8000"
LOG_GROUP="/ecs/${TASK_FAMILY}"
SECURITY_GROUP_NAME="myagent-sg"
TARGET_GROUP_NAME="myagent-tg"
LOAD_BALANCER_NAME="myagent-alb"
EXECUTION_ROLE_NAME="ecsTaskExecutionRole"
TASK_ROLE_NAME="ecsTaskRole"

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_command aws
require_command docker

[[ -n "$VPC_ID" ]] || die "VPC_ID must not be empty"
[[ -n "$SUBNETS" ]] || die "SUBNETS must contain at least one subnet ID"

IFS=',' read -r -a SUBNET_ARRAY <<< "$SUBNETS"
(( ${#SUBNET_ARRAY[@]} >= 2 )) || die "SUBNETS must contain at least two subnet IDs"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
IMAGE="${ECR_REGISTRY}/${REPO_NAME}:latest"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

echo ">> Checking AWS account ${ACCOUNT_ID} in ${REGION}"

echo ">> Ensuring ECR repository"
if ! aws ecr describe-repositories \
  --repository-names "$REPO_NAME" --region "$REGION" >/dev/null 2>&1; then
  aws ecr create-repository \
    --repository-name "$REPO_NAME" --region "$REGION" >/dev/null
fi

echo ">> Building and pushing ${IMAGE}"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY" >/dev/null
docker buildx build --platform linux/amd64 --tag "$IMAGE" --push .

ecs_trust_policy="$tmp_dir/ecs-trust-policy.json"
cat > "$ecs_trust_policy" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ecs-tasks.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

ensure_iam_role() {
  local role_name="$1"
  if ! aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
    echo "   creating IAM role ${role_name}"
    aws iam create-role \
      --role-name "$role_name" \
      --assume-role-policy-document "file://${ecs_trust_policy}" >/dev/null
  fi
}

echo ">> Ensuring ECS task roles"
ensure_iam_role "$EXECUTION_ROLE_NAME"
aws iam attach-role-policy \
  --role-name "$EXECUTION_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy >/dev/null
ensure_iam_role "$TASK_ROLE_NAME"

EXECUTION_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${EXECUTION_ROLE_NAME}"
TASK_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${TASK_ROLE_NAME}"

echo ">> Ensuring ECS cluster and log group"
if ! aws ecs describe-clusters --clusters "$CLUSTER_NAME" --region "$REGION" \
  --query 'clusters[?status==`ACTIVE`].clusterName' --output text | grep -qx "$CLUSTER_NAME"; then
  aws ecs create-cluster --cluster-name "$CLUSTER_NAME" --region "$REGION" >/dev/null
fi

if ! aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" --region "$REGION" \
  --query "logGroups[?logGroupName=='${LOG_GROUP}'].logGroupName" --output text \
  | grep -qx "$LOG_GROUP"; then
  aws logs create-log-group --log-group-name "$LOG_GROUP" --region "$REGION" >/dev/null
fi

container_definitions="$tmp_dir/container-definitions.json"
cat > "$container_definitions" <<JSON
[
  {
    "name": "${CONTAINER_NAME}",
    "image": "${IMAGE}",
    "essential": true,
    "portMappings": [
      { "containerPort": ${CONTAINER_PORT}, "protocol": "tcp" }
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "${LOG_GROUP}",
        "awslogs-region": "${REGION}",
        "awslogs-stream-prefix": "ecs"
      }
    }
  }
]
JSON

echo ">> Registering task definition"
aws ecs register-task-definition \
  --family "$TASK_FAMILY" \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu "$CPU" \
  --memory "$MEMORY" \
  --task-role-arn "$TASK_ROLE_ARN" \
  --execution-role-arn "$EXECUTION_ROLE_ARN" \
  --container-definitions "file://${container_definitions}" \
  --region "$REGION" >/dev/null

echo ">> Ensuring security group"
security_group_id="$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=${SECURITY_GROUP_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --region "$REGION" --query 'SecurityGroups[0].GroupId' --output text)"

if [[ "$security_group_id" == "None" || -z "$security_group_id" ]]; then
  security_group_id="$(aws ec2 create-security-group \
    --group-name "$SECURITY_GROUP_NAME" \
    --description "myagent application and load balancer" \
    --vpc-id "$VPC_ID" --region "$REGION" --query GroupId --output text)"
fi

authorize_ingress() {
  local port="$1"
  shift
  if ! aws ec2 authorize-security-group-ingress \
    --group-id "$security_group_id" --protocol tcp --port "$port" \
    --region "$REGION" "$@" >/dev/null 2>&1; then
    echo "   ingress rule already exists or is already authorized"
  fi
}

authorize_ingress 80 --cidr 0.0.0.0/0
authorize_ingress "$CONTAINER_PORT" --source-group "$security_group_id"

echo ">> Ensuring target group and load balancer"
target_group_arn="$(aws elbv2 describe-target-groups --names "$TARGET_GROUP_NAME" \
  --region "$REGION" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)"
if [[ "$target_group_arn" == "None" || -z "$target_group_arn" ]]; then
  target_group_arn="$(aws elbv2 create-target-group \
    --name "$TARGET_GROUP_NAME" \
    --protocol HTTP \
    --port "$CONTAINER_PORT" \
    --vpc-id "$VPC_ID" \
    --target-type ip \
    --health-check-path /health \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --region "$REGION" --query 'TargetGroups[0].TargetGroupArn' --output text)"
fi

load_balancer_arn="$(aws elbv2 describe-load-balancers --names "$LOAD_BALANCER_NAME" \
  --region "$REGION" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)"
if [[ "$load_balancer_arn" == "None" || -z "$load_balancer_arn" ]]; then
  load_balancer_arn="$(aws elbv2 create-load-balancer \
    --name "$LOAD_BALANCER_NAME" \
    --subnets "${SUBNET_ARRAY[@]}" \
    --security-groups "$security_group_id" \
    --scheme internet-facing \
    --type application \
    --region "$REGION" --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
fi

listener_arn="$(aws elbv2 describe-listeners --load-balancer-arn "$load_balancer_arn" \
  --region "$REGION" --query 'Listeners[?Port==`80`].ListenerArn' --output text 2>/dev/null || true)"
if [[ "$listener_arn" == "None" || -z "$listener_arn" ]]; then
  aws elbv2 create-listener \
    --load-balancer-arn "$load_balancer_arn" \
    --protocol HTTP \
    --port 80 \
    --default-actions "Type=forward,TargetGroupArn=${target_group_arn}" \
    --region "$REGION" >/dev/null
fi

network_configuration="awsvpcConfiguration={subnets=[${SUBNETS}],securityGroups=[${security_group_id}],assignPublicIp=ENABLED}"
service_arn="$(aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
  --region "$REGION" --query 'services[?status!=`INACTIVE`].serviceArn' --output text 2>/dev/null || true)"

if [[ "$service_arn" == "None" || -z "$service_arn" ]]; then
  echo ">> Creating ECS service"
  aws ecs create-service \
    --cluster "$CLUSTER_NAME" \
    --service-name "$SERVICE_NAME" \
    --task-definition "$TASK_FAMILY" \
    --desired-count 1 \
    --launch-type FARGATE \
    --platform-version LATEST \
    --network-configuration "$network_configuration" \
    --load-balancers "targetGroupArn=${target_group_arn},containerName=${CONTAINER_NAME},containerPort=${CONTAINER_PORT}" \
    --region "$REGION" >/dev/null
else
  echo ">> Updating ECS service"
  aws ecs update-service \
    --cluster "$CLUSTER_NAME" \
    --service "$SERVICE_NAME" \
    --task-definition "$TASK_FAMILY" \
    --desired-count 1 \
    --force-new-deployment \
    --region "$REGION" >/dev/null
fi

echo ">> Configuring autoscaling"
resource_id="service/${CLUSTER_NAME}/${SERVICE_NAME}"
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --scalable-dimension ecs:service:DesiredCount \
  --resource-id "$resource_id" \
  --min-capacity 1 \
  --max-capacity 2 \
  --region "$REGION" >/dev/null

aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --scalable-dimension ecs:service:DesiredCount \
  --resource-id "$resource_id" \
  --policy-name cpu-scaling-policy \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration '{
    "PredefinedMetricSpecification": {
      "PredefinedMetricType": "ECSServiceAverageCPUUtilization"
    },
    "TargetValue": 60.0,
    "ScaleInCooldown": 300,
    "ScaleOutCooldown": 60
  }' \
  --region "$REGION" >/dev/null

echo ">> Waiting for stable deployment"
aws ecs wait services-stable \
  --cluster "$CLUSTER_NAME" \
  --services "$SERVICE_NAME" \
  --region "$REGION"

load_balancer_dns="$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$load_balancer_arn" \
  --region "$REGION" --query 'LoadBalancers[0].DNSName' --output text)"

printf '\nApp URL:      http://%s\nHealth check: http://%s/health\nChat:         http://%s/chat?name=myname\n' \
  "$load_balancer_dns" "$load_balancer_dns" "$load_balancer_dns"
