provider "aws" {
  region = "us-east-1"
}

# ------------------------
# VPC
# ------------------------
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

# ------------------------
# Subnet
# ------------------------
resource "aws_subnet" "public_1" {
  vpc_id            = aws_vpc.main.id # Ensure this matches your VPC resource name
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"
}

# Second Subnet (e.g., in us-east-1b)
resource "aws_subnet" "public_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.9.0/24"
  availability_zone = "us-east-1b"
}

# ------------------------
# Internet Gateway
# ------------------------
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
}

# ------------------------
# Route Table
# ------------------------
resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route" "internet_access" {
  route_table_id         = aws_route_table.rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.gw.id
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.rt.id
}

# ------------------------
# Security Group
# ------------------------
resource "aws_security_group" "sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ------------------------
# ECS Cluster
# ------------------------
resource "aws_ecs_cluster" "cluster" {
  name = "nginx-cluster-dev"
}

# ------------------------
# CloudWatch Logs
# ------------------------
resource "aws_cloudwatch_log_group" "ecs" {
  name = "/ecs/nginx"
}

# ------------------------
# IAM Role
# ------------------------
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "nginx-ecs_task_execution_role-unique"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ------------------------
# ECS Task Definition
# ------------------------
resource "aws_ecs_task_definition" "task" {
  family                   = "nginx-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name  = "nginx"
      image = "485104726407.dkr.ecr.us-east-1.amazonaws.com/nginx-static-main1:latest"
      portMappings = [
        {
          containerPort = 80
        }
      ]
    }
  ])
}

# ------------------------
# ALB
# ------------------------
resource "aws_lb" "alb" {
  name               = "nginx-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.sg.id] # Ensure this matches your SG resource name
  
  # Pass BOTH subnets here:
  subnets            = [aws_subnet.public_1.id, aws_subnet.public_2.id]
}

# ------------------------
# Target Group
# ------------------------
resource "aws_lb_target_group" "tg" {
  name     = "nginx-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  target_type = "ip"

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 5 # Gives it 5 sequential failures before killing the task
    matcher             = "200-399"
  }
}

# ------------------------
# Listener
# ------------------------
resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

# ------------------------
# ECS Service
# ------------------------
resource "aws_ecs_service" "service" {
  name            = "nginx-service"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.task.arn
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = [aws_subnet.public_1.id, aws_subnet.public_2.id]
    assign_public_ip = true
    security_groups = [aws_security_group.sg.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.tg.arn
    container_name   = "nginx"
    container_port   = 80
  }

  desired_count = 1
}