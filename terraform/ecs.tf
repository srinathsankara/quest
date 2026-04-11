resource "aws_ecs_cluster" "main" {
  name = "quest"
}

resource "aws_iam_role" "ecs_task_execution" {
  name = "quest-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_cloudwatch_log_group" "quest" {
  name              = "/ecs/quest"
  retention_in_days = 7
}

resource "aws_ecs_task_definition" "quest" {
  family                   = "quest"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([{
    name  = "quest"
    image = var.image
    portMappings = [{
      containerPort = 3000
      protocol      = "tcp"
    }]
    environment = [{
      name  = "SECRET_WORD"
      value = var.secret_word
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = "/ecs/quest"
        awslogs-region        = var.region
        awslogs-stream-prefix = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "quest" {
  name            = "quest"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.quest.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.main.arn
    container_name   = "quest"
    container_port   = 3000
  }

  depends_on = [aws_lb_listener.https]
}
