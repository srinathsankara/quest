# Deployment Approach — Rearc Quest

---

## 1. Approach Used (AWS Deployment)

### The Problem
The quest app is a Node.js/Express server that shells out to precompiled Go binaries. It needs to:
- Run in a container
- Be publicly accessible over HTTPS
- Sit behind a load balancer
- Have `SECRET_WORD` injected as an environment variable

### Decisions Made

**Container Image — Docker Hub**

Instead of using a cloud-specific registry (ECR for AWS, ACR for Azure), the image was pushed to Docker Hub as a public image (`charlesragen/quest:latest`). This keeps the solution cloud-agnostic — the same image is pulled by both AWS and Azure without any registry authentication configuration.

The Dockerfile uses `node:18-alpine` as the base image — Alpine keeps the image small (~180MB vs ~900MB for the full Debian-based image). The Go binaries need `chmod +x` because the execute bit isn't guaranteed when files are copied from a Windows machine or from git.

**Infrastructure as Code — Terraform**

Terraform was chosen because it's cloud-agnostic, declarative, and the most widely used IaC tool in the industry. The configuration is split across 8 files by concern:

```
terraform/
├── main.tf       → provider versions
├── variables.tf  → region, secret_word, image
├── vpc.tf        → VPC, subnets, IGW, route tables
├── sg.tf         → security groups for ALB and ECS
├── acm.tf        → self-signed cert imported into ACM
├── alb.tf        → load balancer, listeners, target group
├── ecs.tf        → cluster, task definition, service, IAM, logs
└── outputs.tf    → prints the ALB URL when done
```

**Compute — ECS Fargate**

ECS Fargate was chosen over EC2-based ECS or EKS because:
- No infrastructure to manage — AWS handles the underlying compute
- Pay per task runtime — no idle EC2 costs
- Integrates natively with ALB via `awsvpc` network mode
- Scales to zero when not needed

Each Fargate task gets its own Elastic Network Interface (`awsvpc` mode), which is why `target_type=ip` is used in the ALB target group — the ALB registers each task by its private IP directly.

**Networking — VPC with 2 Public Subnets**

A custom VPC was created with 2 public subnets across 2 Availability Zones. The ALB requires at least 2 subnets in different AZs. Public subnets were used (rather than private + NAT Gateway) to keep the setup simple and avoid NAT Gateway costs, while still securing the containers via security groups.

Security group rules enforce traffic flow:
- ALB accepts 80 and 443 from anywhere (`0.0.0.0/0`)
- ECS only accepts port 3000 from the ALB security group (not from the internet directly)

**Load Balancer — Application Load Balancer**

An ALB was used because:
- It operates at Layer 7 (HTTP/HTTPS) — understands paths and headers
- Handles TLS termination — containers receive plain HTTP
- Injects `X-Forwarded-For`, `X-Forwarded-Proto` headers — required for the `/loadbalanced` and `/tls` checks
- HTTP listener on port 80 does a 301 redirect to HTTPS
- HTTPS listener on port 443 forwards to the ECS target group

**TLS — Self-Signed Certificate via ACM**

A real ACM certificate requires a domain name you control. Since this deployment uses the ALB's auto-generated hostname, DNS validation isn't possible. A self-signed certificate was generated with OpenSSL and imported into ACM.

Note: During setup, an ACM clock skew error occurred — the certificate's `Not Before` timestamp was slightly ahead of AWS's server time due to Windows clock drift. Fix was to run a clock sync and regenerate the cert with `-set_serial 1`.

**The Full Architecture**

```
User Browser
     │
     │ HTTPS (443)
     ▼
Application Load Balancer
     │  - Terminates TLS (ACM self-signed cert)
     │  - Injects X-Forwarded-* headers
     │  - HTTP → HTTPS redirect on port 80
     │
     │ HTTP (3000) — internal VPC only
     ▼
ECS Fargate Task
     │  - charlesragen/quest:latest
     │  - SECRET_WORD injected as env var
     │  - CloudWatch logs
     │
     ▼
Node.js Express (port 3000)
     └── shells out to Go binaries (bin/001–006)
```

**VPC Layout**

```
VPC (10.0.0.0/16)
├── Public Subnet A (10.0.0.0/24) — us-east-2a
│     └── Fargate Task + ALB node
└── Public Subnet B (10.0.1.0/24) — us-east-2b
      └── Fargate Task + ALB node
          └── Internet Gateway → 0.0.0.0/0
```

**SECRET_WORD Flow**

1. Run app locally → hit `/` → binary returns "You don't seem to be running in AWS or GCP or Azure"
2. Deploy to AWS → hit `/` → binary detects ECS/AWS → returns "TwelveFactor"
3. Inject `SECRET_WORD=TwelveFactor` into the ECS task definition via Terraform variable
4. `/secret_word` endpoint validates the env var is set correctly

---

## 2. Other Ways to Deploy on AWS

The approach used (ECS Fargate + ALB) is one of several valid options. Here are the alternatives:

### Option A — EC2 with Docker (Simplest)

Spin up an EC2 instance, install Docker, run the container directly.

```
Internet → EC2 Instance (Docker container on port 3000)
```

**Pros:** Simple, full control, cheapest for sustained workloads  
**Cons:** You manage patching, scaling, availability. No automatic restarts. Single point of failure unless you add an ASG.  
**When to use:** Quick demos, dev environments, when you need specific instance types (GPU, bare metal)

To add load balancing and TLS:
- Put an ALB in front
- Use an Auto Scaling Group of EC2 instances
- More moving parts than Fargate

### Option B — ECS on EC2 (What we did, but with EC2 backing)

Same ECS service and task definition, but `launch_type = "EC2"` instead of `"FARGATE"`. You manage a cluster of EC2 instances as the underlying compute.

**Pros:** Cheaper at scale, can use spot instances, GPU support  
**Cons:** You manage the EC2 cluster — AMIs, patching, capacity planning  
**When to use:** High-volume production workloads where Fargate cost adds up

### Option C — App Runner (Simplest AWS Container Service)

AWS App Runner is fully managed — you point it at a container image and it handles everything: load balancing, TLS, autoscaling, zero-downtime deploys.

```
Internet → App Runner Service (HTTPS built-in) → Container
```

**Pros:** Zero infrastructure config, automatic HTTPS, autoscaling  
**Cons:** Less control, can't configure networking details, more expensive per unit  
**When to use:** When you just want the app to run and don't care about the infrastructure details

Terraform resource:
```hcl
resource "aws_apprunner_service" "quest" {
  service_name = "quest"
  source_configuration {
    image_repository {
      image_identifier      = "charlesragen/quest:latest"
      image_repository_type = "ECR_PUBLIC"
      image_configuration {
        port = "3000"
        runtime_environment_variables = {
          SECRET_WORD = var.secret_word
        }
      }
    }
  }
}
```

### Option D — EKS (Kubernetes)

Deploy to an EKS cluster using Kubernetes Deployment + Service + Ingress.

```
Internet → Ingress Controller (ALB) → K8s Service → Pod
```

**Pros:** Full Kubernetes ecosystem, better for microservices, portable  
**Cons:** Significant overhead for a single service — cluster management, node groups, add-ons  
**When to use:** When you're already running Kubernetes or have multiple services to orchestrate

Requires: Deployment manifest, Service manifest, Ingress manifest, cert-manager for TLS

### Option E — Lambda + API Gateway (Serverless)

Wrap the Express app with `aws-serverless-express` and deploy as a Lambda function behind API Gateway.

```
Internet → API Gateway (HTTPS) → Lambda (Express app)
```

**Pros:** True pay-per-request, zero idle cost, automatic scaling  
**Cons:** Cold starts, 15-minute timeout limit, the Go binary exec approach might not work cleanly in Lambda's sandboxed environment  
**When to use:** Low-traffic APIs, event-driven workloads

**Note:** This wouldn't work cleanly for the quest because the precompiled Go binaries rely on a persistent filesystem and process model that Lambda's ephemeral environment complicates.

### Comparison

| Approach | Complexity | Cost | Control | TLS Built-in |
|---|---|---|---|---|
| EC2 + Docker | Low | Low | High | No (need ALB) |
| ECS Fargate + ALB | Medium | Medium | Medium | No (need ACM) |
| ECS EC2 + ALB | Medium-High | Low at scale | High | No (need ACM) |
| App Runner | Very Low | Higher | Low | Yes |
| EKS | High | High | Very High | No (need cert-manager) |
| Lambda + API Gateway | Medium | Very Low | Low | Yes |

**Why ECS Fargate + ALB was the right call for this quest:**
- No infrastructure to manage (rules out EC2, EKS)
- Full control over networking and security groups (rules out App Runner)
- Native ALB integration satisfies the load balancer check
- Standard enough that anyone reviewing the code knows exactly what it does

---

## 3. Azure Deployment — Changes and Approach

### What Changed and Why

The core principle stayed the same — containerized app, load balanced, HTTPS — but the specific services differ because Azure and AWS have different managed offerings.

| Concern | AWS | Azure | Why Different |
|---|---|---|---|
| Container runtime | ECS Fargate | Container Apps | Azure's equivalent managed container service |
| Load balancer | ALB (separate resource) | Built into Container Apps ingress | Container Apps bundles LB + TLS together |
| TLS | ACM + self-signed cert | Auto-managed by Azure | Container Apps manages certs for its default domain |
| Networking | Custom VPC, subnets, SGs | Managed by Container Apps | Container Apps abstracts the networking layer |
| Logging | CloudWatch Logs | Log Analytics Workspace | Each cloud's native logging service |
| IaC provider | `hashicorp/aws` | `hashicorp/azurerm` | Different Terraform providers |

### What Stayed the Same

- Docker image: `charlesragen/quest:latest` from Docker Hub — no changes needed
- `SECRET_WORD` injected as environment variable — same concept, different Terraform syntax
- Terraform as the IaC tool
- Port 3000 inside the container

### Terraform Changes for Azure

**AWS ECS task definition (ecs.tf):**
```hcl
resource "aws_ecs_task_definition" "quest" {
  family                   = "quest"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512

  container_definitions = jsonencode([{
    name  = "quest"
    image = var.image
    environment = [{
      name  = "SECRET_WORD"
      value = var.secret_word
    }]
    ...
  }])
}
```

**Azure Container App (container_app.tf) — equivalent:**
```hcl
resource "azurerm_container_app" "quest" {
  name                         = "quest"
  container_app_environment_id = azurerm_container_app_environment.quest.id
  resource_group_name          = azurerm_resource_group.quest.name
  revision_mode                = "Single"

  ingress {
    external_enabled = true
    target_port      = 3000
    transport        = "auto"
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  template {
    container {
      name   = "quest"
      image  = var.image
      cpu    = 0.25
      memory = "0.5Gi"
      env {
        name  = "SECRET_WORD"
        value = var.secret_word
      }
    }
  }
}
```

Key differences in the Terraform:
- No separate `aws_lb`, `aws_lb_listener`, `aws_lb_target_group` — the `ingress` block replaces all of that
- No VPC, subnets, security groups — Container Apps manages its own networking
- No ACM certificate resource — Azure handles TLS automatically
- No IAM role — Azure Container Apps doesn't need an equivalent of the ECS task execution role for basic deployments
- Added `azurerm_log_analytics_workspace` — required by Container Apps environment (equivalent of CloudWatch log group)

### Azure-Specific Prerequisites

```bash
# Login
az login
az account set --subscription "your-subscription-id"

# Enable required APIs (one-time)
# Not needed for Container Apps — APIs are pre-enabled
```

### How to Deploy on Azure

```bash
cd terraform-azure

# Initialize providers
terraform init

# Preview what will be created
terraform plan -var="secret_word=TwelveFactor"

# Deploy
terraform apply -var="secret_word=TwelveFactor"

# Output will print the URL:
# url = "https://quest--xxxxx.eastus2.azurecontainerapps.io"

# Tear down when done
terraform destroy -var="secret_word=TwelveFactor"
```

### Known Limitation on Azure

The `/` index page shows "You don't seem to be running in AWS or GCP or Azure" on Azure Container Apps. The precompiled Go binary detects cloud environments by querying the Azure Instance Metadata Service (IMDS) at `169.254.169.254`. Container Apps is a multi-tenant managed service and blocks IMDS access from containers for security reasons.

All five quest checks pass — this is purely a display limitation in the binary's detection logic.

To fix it properly, the deployment would need to move to Azure Container Instances or AKS, both of which have direct IMDS access. That would require adding an Application Gateway for load balancing and TLS, significantly increasing the Terraform complexity.

### Side-by-Side: AWS vs Azure Terraform File Count

| | AWS | Azure |
|---|---|---|
| Files | 8 | 4 |
| Lines of Terraform | ~150 | ~60 |
| Manual cert generation | Yes (OpenSSL) | No |
| Separate LB config | Yes (alb.tf) | No (built into container_app.tf) |

Azure Container Apps is genuinely simpler to configure — TLS and load balancing are bundled. The trade-off is less control over networking, which is why AWS was the primary deployment target and Azure was the secondary.

---

## 4. Interview Q&A

### Docker

**Q: Why did you choose `node:18-alpine` over `node:18`?**
Alpine is a minimal Linux distribution — the full node:18 image is 900MB+ because it's Debian-based and carries a lot you don't need at runtime. Alpine gets you down to around 150-180MB. For this app we're just running an Express server and shelling out to precompiled Go binaries, so we don't need compilers or system libraries. Smaller image means faster pulls, less attack surface, cheaper registry storage.

**Q: What does `--production` flag do in `npm install`?**
It tells npm to skip anything in `devDependencies` — testing frameworks, linters, type definitions. Stuff you only need during development has no business being in a runtime image. The risk is if someone accidentally puts a runtime dependency in devDependencies, but that's a packaging discipline issue, not a Docker issue.

**Q: Why did you need `chmod +x bin/*`?**
The Go binaries get COPYed from the host filesystem but the execute bit isn't guaranteed to carry over — especially building on Windows or when files were checked into git without the executable flag. When Node's `child_process.exec` tries to run `bin/001` and it's not executable, you get permission denied. The `chmod +x` is insurance that ensures all binaries are runnable regardless of what happened on the build machine.

**Q: What's the difference between CMD and ENTRYPOINT?**
ENTRYPOINT is the fixed executable that always runs. CMD provides default arguments to it, or if there's no ENTRYPOINT, it's the default command. The practical difference is override behavior — you can override CMD completely by passing arguments at `docker run`, but to override ENTRYPOINT you need the explicit `--entrypoint` flag. Using `CMD ["node", "src/000.js"]` without a separate ENTRYPOINT makes it easy to swap in a shell during debugging.

**Q: How would you reduce the image size further?**
The biggest win would be a multi-stage build — use one stage to do the npm install, then COPY only node_modules and source into a clean final Alpine stage. Also add a `.dockerignore` so things like `.git`, test files, and terraform state don't get pulled in during the COPY.

**Q: What happens if you don't specify EXPOSE?**
Nothing breaks at runtime — EXPOSE is documentation, not a firewall rule. The container still listens on port 3000 if the app binds to it. It's a signal to other tooling and developers about which port is intended to be published. Think of it as the comment you're required to write.

**Q: How do you pass secrets into a container securely without hardcoding them?**
In this project SECRET_WORD is passed as a plain environment variable through the ECS task definition. That's fine for a demo but the value ends up in the Terraform state file in plaintext. The proper way is AWS Secrets Manager or SSM Parameter Store — store the value there, give the task execution role permission to read it, and reference it in the task definition as a `secrets` entry rather than `environment`. The actual value never appears in code, state, or logs.

---

### Terraform

**Q: What is `terraform.tfstate` and why shouldn't it be in git?**
The state file is Terraform's source of truth — it maps your resource blocks to real AWS IDs, ARNs, and IP addresses. It shouldn't be in git for two reasons: it can contain sensitive values in plaintext (our secret_word ends up in there), and if two people pull the same state and both apply, they'll corrupt things. The right pattern is remote state in S3 with a DynamoDB lock table. Kept it local for this project since it was solo work, and added it to `.gitignore`.

**Q: What's the difference between `terraform plan` and `terraform apply`?**
Plan is a dry run — it reads current state, queries AWS APIs to see what actually exists, compares to your config, and shows exactly what it would create, change, or destroy. Apply does the same diff then executes it. Always run plan first, especially on networking and security groups. You can save a plan with `-out` and apply that exact file, which is what you'd do in a CI pipeline to prevent drift between the plan and apply steps.

**Q: What does `depends_on` do and why did you use it in `ecs.tf`?**
Terraform figures out most dependencies from resource references automatically. But `depends_on` handles implicit dependencies it can't infer. The ECS service has `depends_on = [aws_lb_listener.https]`. The service references the target group, but the listener is what activates it on the ALB. Without it, ECS can start registering targets before the listener exists, causing a race condition where health checks fail and the service never reaches steady state.

**Q: Why did you use `count = 2` for subnets instead of hardcoding two resources?**
Reduces repetition and makes it easier to change. With `count=2`, Terraform creates both subnets using `count.index` (0 and 1) to vary the CIDR and AZ. The CIDR ends up as `10.0.0.0/24` and `10.0.1.0/24`, the AZ is pulled from the data source dynamically. Count is also easy to promote to a variable if needed.

**Q: What happens if you run `terraform apply` twice with no changes?**
Nothing — Terraform diffs against state, finds nothing to change, and exits with "No changes. Your infrastructure matches the configuration." It's idempotent, so you can run it safely in a CI pipeline on every merge without worrying about double-creating things.

**Q: What is a data source vs a resource in Terraform?**
A resource creates and manages infrastructure — Terraform owns its lifecycle. A data source is read-only; it queries existing infrastructure and pulls in values. In vpc.tf, `data "aws_availability_zones" "available"` dynamically fetches which AZs exist in the region so we don't hardcode `us-east-2a` and `us-east-2b`. If a resource block were used there, Terraform would try to create an AZ, which doesn't make sense.

**Q: Why did you separate files instead of one big `main.tf`?**
Terraform doesn't care — it loads all `.tf` files in the directory as one configuration. The separation is purely for human navigation. When something goes wrong with the ALB, open `alb.tf` and see just that. It also makes git diffs cleaner when only changing one layer of the stack.

**Q: What is state drift and how do you detect it?**
State drift is when actual infrastructure diverges from what Terraform's state thinks it is — usually because someone changed something manually in the console. You detect it by running `terraform plan` — if it shows changes even though you haven't touched your code, that's drift. The fix is either reconcile your code to match reality, or revert the manual change and re-apply.

---

### AWS Networking

**Q: Why did you use 2 public subnets across 2 AZs?**
An ALB requires at least two subnets in different AZs — AWS enforces this at creation time. AZs are physically separate data centers, so spreading across two means if one goes down the load balancer still has a subnet to operate from. It's the minimum viable HA setup. In production you'd go to three AZs with private subnets for the compute layer.

**Q: What is an Internet Gateway and why does the VPC need one?**
When you create a VPC it's completely isolated — nothing in or out. The IGW connects it to the public internet. Without one, the ALB has no path to receive traffic and Fargate tasks can't pull the image from Docker Hub. The route table has a default route pointing `0.0.0.0/0` at the IGW, which is what makes the subnets "public."

**Q: What's the difference between a security group and a NACL?**
Security groups are stateful firewalls attached to individual resources — they track connection state, so if you allow inbound on port 3000 the response is automatically allowed out. NACLs are stateless and operate at the subnet level — you have to explicitly allow both directions. For most apps, security groups are the primary layer. NACLs are belt-and-suspenders. Only security groups were used here: ALB allows 80/443 from anywhere, ECS only allows 3000 from the ALB security group.

**Q: Why does the ECS security group only allow traffic from the ALB security group?**
Principle of least privilege. The Fargate tasks should never be directly accessible from the internet — all traffic should flow through the ALB. By setting the ECS ingress rule to reference the ALB security group as the source instead of a CIDR block, only traffic originating from the ALB can reach port 3000. If someone finds the Fargate task's public IP and tries to hit it directly, the security group blocks them.

**Q: What is `assign_public_ip = true` doing for the Fargate task?**
Fargate tasks in a public subnet need a public IP to reach the internet for pulling the container image from Docker Hub. AWS assigns an ephemeral public IP to the task's ENI at launch. The alternative is private subnets with a NAT Gateway, which is more secure but adds cost and complexity. For this project, public subnets with public IP assignment is simpler and cheaper.

**Q: What is `awsvpc` network mode and why does Fargate require it?**
`awsvpc` gives each ECS task its own Elastic Network Interface — its own private IP within the VPC, just like an EC2 instance. It's the only mode Fargate supports. Older modes like `bridge` and `host` were for EC2-based ECS where tasks shared the underlying instance's network stack. With awsvpc, each task is a first-class network citizen and the ALB registers it by IP directly — which is exactly why `target_type=ip` is required.

---

### AWS ECS Fargate

**Q: What's the difference between ECS EC2 launch type and Fargate?**
With EC2, you manage a cluster of instances yourself — AMI, instance type, patching, capacity. Fargate is serverless — you declare CPU and memory, AWS finds capacity and runs it. EC2 is cheaper at scale and gives more control. Fargate is simpler to operate and you only pay per task runtime. For a single-container demo, Fargate is obviously right.

**Q: What is a task definition vs a service?**
The task definition is the blueprint — container image, CPU/memory, env vars, log config, IAM role. Think of it like a pod spec in Kubernetes. It's versioned; every update creates a new revision. The service is what keeps that blueprint running — "I want 1 copy of task definition X running at all times, connected to this ALB." The service handles scaling, restarts on failure, and rolling deployments.

**Q: What does the ECS task execution role do? Why does it need `AmazonECSTaskExecutionRolePolicy`?**
It's what ECS itself uses to set up the task — not what your app assumes. It needs permission to create CloudWatch log streams and fetch secrets from SSM/Secrets Manager if you're injecting them. `AmazonECSTaskExecutionRolePolicy` bundles exactly those permissions. Without it, ECS can't bootstrap the container — it fails trying to create the log stream. It's separate from the task role, which is what the running application would use to call AWS APIs.

**Q: Why is `desired_count=1`? How would you make it highly available?**
Desired count of 1 is sufficient for a demo and avoids paying for multiple running tasks. For HA, bump to at least 2 — with subnets already in two AZs, ECS schedules one task per AZ with the default spread strategy. Add autoscaling based on CPU or request count, set minimum 2, and configure rolling update settings so a deploy doesn't take both tasks down simultaneously.

**Q: What is the CloudWatch log group used for?**
Captures stdout and stderr from the container. The `awslogs` driver points to `/ecs/quest` with 7-day retention. Without this you have zero visibility into what's happening inside the container — no startup errors, no request logs, no Go binary output. In production this feeds into dashboards and alerting.

**Q: Why did you set CPU to 256 and memory to 512?**
Those are the minimum values Fargate allows — 0.25 vCPU and 512MB. For this app it's more than enough: a lightweight Express server shelling out to small Go binaries. Fargate pricing is per vCPU-second and GB-second, so these minimums keep costs low for a demo.

---

### Load Balancer & TLS

**Q: What's the difference between an ALB and an NLB?**
ALB operates at layer 7 — understands HTTP/HTTPS, routes by URL path and headers, terminates TLS. NLB operates at layer 4 — routes TCP/UDP by IP and port, designed for extreme throughput and low latency. For a web application serving HTTP, ALB is almost always right. NLB is for game servers, IoT, or when you need to preserve the client IP at the TCP level.

**Q: Why does the HTTP listener redirect to HTTPS?**
You don't want users accidentally hitting the app over plaintext HTTP. The 301 tells browsers permanently that this domain only speaks HTTPS — modern browsers cache that and go straight to HTTPS on future visits. Closing port 80 entirely is worse UX — users who type the domain without `https://` get connection refused. Most compliance frameworks require HTTPS enforcement and this is how you do it at the infrastructure layer.

**Q: What is `ELBSecurityPolicy-2016-08` and why does it matter?**
It's an AWS-managed TLS policy defining which SSL/TLS protocol versions and cipher suites the ALB negotiates. The 2016-08 policy is one of the older ones — it supports TLS 1.0, 1.1, and 1.2. For production you'd want a newer policy that drops TLS 1.0/1.1 and prioritizes modern ciphers. Used 2016-08 because it was the working default — it's something to tighten before going live.

**Q: Why did you use a self-signed cert instead of ACM DNS validation?**
ACM DNS validation requires adding a CNAME to a domain you own. This project uses the ALB's auto-generated hostname — ACM won't issue a cert for an AWS-generated URL. So a self-signed certificate was generated with OpenSSL and imported into ACM. Browsers show a warning but TLS is enforced end-to-end. A real domain with Route53 + ACM would fix the warning.

**Q: What is the ACM clock skew error and why did it happen?**
When you generate a self-signed cert, the `Not Before` field is set to your machine's current time. If your local clock is even slightly ahead of AWS's servers, ACM rejects the import because the cert appears not yet valid. This happened on Windows where the clock had drifted a few minutes. Fix: force a clock sync and regenerate the cert with `-set_serial 1`.

**Q: How does the ALB health check work and what path did you use?**
The ALB sends periodic HTTP GET requests to the container on the configured path and checks for a 2xx response. Used `/` — interval 30 seconds, healthy threshold 2, unhealthy threshold 3. If a task fails health checks, the ALB stops sending it traffic and ECS replaces it. Health checks go directly to the container IP on port 3000, bypassing TLS since it's internal VPC traffic.

**Q: Why is `target_type=ip` needed for Fargate?**
ALB target groups have two types: `instance` (registers the EC2 instance ID) and `ip` (registers the task's private IP directly). Fargate doesn't run on instances you own, so there's no EC2 instance ID to register. Each task gets its own ENI via awsvpc mode, so `target_type=ip` routes directly to that IP on port 3000. If you set `target_type=instance` with Fargate, target registration fails and health checks never pass.

---

### Azure

**Q: Why Container Apps over ACI or AKS?**
ACI is great for one-off tasks but has no built-in ingress, TLS, or autoscaling — you'd wire all that yourself. AKS is full Kubernetes, powerful but overkill for a single web service. Container Apps sits in the middle — managed serverless built on Kubernetes and KEDA under the hood, but you don't manage any of that. You get automatic HTTPS, external ingress, and scaling out of the box. It's roughly the Azure equivalent of ECS Fargate + ALB, but with less configuration.

**Q: What is `transport=auto` doing in the ingress block?**
Tells Container Apps to automatically negotiate the protocol — HTTP/2 if the client supports it, HTTP/1.1 if not. Using `http` forces HTTP/1.1 only. `auto` is the sensible default — you get HTTP/2 performance benefits for browser clients without breaking older clients.

**Q: Why doesn't Azure Container Apps need a separate TLS certificate?**
Container Apps automatically provisions and manages a TLS certificate for the default `*.azurecontainerapps.io` domain. You get HTTPS out of the box with a valid trusted cert — no OpenSSL, no ACM import, no renewal to worry about. The higher abstraction of Container Apps removes that operational burden that had to be handled manually on AWS.

**Q: Why does `/` show "You don't seem to be running in AWS or GCP or Azure" on Azure?**
The binary detects cloud provider by querying the Instance Metadata Service at `169.254.169.254`. Azure Container Apps blocks access to IMDS from containers — it's a multi-tenant managed service and exposing the host's IMDS across tenants would be a security risk. The binary tries to hit Azure IMDS, gets nothing back, and falls through to the "unknown cloud" message. All quest checks still pass — it's purely a display issue.

**Q: What is the Azure IMDS?**
Instance Metadata Service — available at `http://169.254.169.254/metadata/instance` on Azure VMs. Returns instance info like subscription ID, resource group, VM name. Used for cloud detection and identity. Container Apps blocks it because there's no legitimate reason a managed workload would need raw host IMDS access, and it would risk leaking infrastructure details across tenants.

**Q: What is the Log Analytics workspace used for?**
It's the centralized logging backend for Container Apps — stdout and stderr stream to it automatically once attached to the Container App Environment. You query logs using KQL in the Azure portal, set alerts, and build dashboards. It's Azure's equivalent of CloudWatch Logs. The Container App Environment requires it at creation time, so it's not optional.

---

### General Cloud & Architecture

**Q: Why Docker Hub instead of ECR or ACR?**
Simplicity. Docker Hub is public, free for public images, and accessible without authentication configuration. Using ECR would mean creating the repo in Terraform, setting up ECR permissions on the task execution role, and authenticating pushes. Since the image is public and not sensitive, Docker Hub removes an entire layer of credential and registry management that isn't the point of this project. In production you'd use a private registry — ECR integrates directly with IAM and has no rate limits.

**Q: What would you change to make this production-ready?**
Several things — move to private subnets with a NAT Gateway so containers aren't directly internet-routable. Replace the self-signed cert with a real domain and ACM DNS validation. Store SECRET_WORD in SSM Parameter Store injected as a secret. Increase desired_count to at least 2 and add autoscaling. Tighten the TLS policy to drop 1.0/1.1. Move Terraform state to S3 with DynamoDB locking. Set up CI/CD so deploys aren't manual. The core architecture is sound — it's about hardening the edges.

**Q: How would you add auto-scaling to the ECS service?**
Use Application Autoscaling with ECS as the target. Define a scalable target pointing at the service, then a target tracking policy on CPU utilization — scale out when CPU hits 70%, for example. Set minimum 2 and maximum based on expected load. ECS launches new tasks in available subnets and registers them with the ALB automatically. Also configure scale-in protection on tasks handling long-running requests.

**Q: How would you store SECRET_WORD more securely?**
Store it in SSM Parameter Store as a SecureString or in Secrets Manager. In the ECS task definition, reference it in the `secrets` array instead of `environment`. The task execution role needs `ssm:GetParameters` or `secretsmanager:GetSecretValue` permission. The value never appears in Terraform code, CI logs, or state file — ECS fetches and injects it at task startup.

**Q: What is the difference between horizontal and vertical scaling?**
Vertical is making the individual unit bigger — bumping CPU from 256 to 1024, memory from 512MB to 2GB. Simple but there's a ceiling and requires a restart. Horizontal is adding more copies — going from `desired_count=1` to 3. Higher ceiling, enables zero-downtime scaling, and gives fault tolerance. For stateless web servers like this, horizontal is always the right model.

**Q: What would break if you deployed to a single AZ?**
ALB creation fails immediately — AWS requires at least two subnets in different AZs. Beyond that, if the AZ experienced an outage everything would be down with no failover. With two AZs the ALB routes around a failed AZ and ECS reschedules tasks in the healthy one.

**Q: How would you set up CI/CD for this?**
GitHub Actions. On push to main: build Docker image, push to ECR, run `terraform plan`. On merge approval: `terraform apply`. Use `aws-actions/amazon-ecs-deploy-task-definition` to handle registering the new task definition revision and updating the service. Store credentials as GitHub secrets using OIDC-based IAM role assumption — no long-lived keys. Add image vulnerability scanning with Trivy before the push step.

---

### App-Specific

**Q: What does `bin/004` check to validate the load balancer?**
Looking at `000.js` — it's called as `exec('bin/004 ' + JSON.stringify(req.headers), ...)` so it receives the full HTTP headers as a JSON argument. The ALB injects `X-Forwarded-For`, `X-Forwarded-Proto`, and `X-Forwarded-Port` headers. The binary inspects those to confirm the request came through a load balancer. If those headers are absent, it concludes the app is not load-balanced.

**Q: Why does the Docker check say "You don't seem to be running in a Docker container" on Fargate?**
The `bin/003` binary detects Docker by looking for `/.dockerenv` or checking cgroup entries for "docker" in `/proc/1/cgroup`. Fargate uses its own container runtime and cgroups are structured differently — they reference Fargate's namespace rather than "docker." The heuristic the binary uses doesn't match the Fargate environment even though you're definitely running in a container. It's a false negative from a detection heuristic written with standard Docker in mind.

**Q: What is the difference between SECRET_WORD locally vs in AWS?**
Locally you set it as an env var before starting the server — `SECRET_WORD=myword node src/000.js`. In AWS it's defined in Terraform variables and injected as an `environment` entry in the container definition. ECS sets it when it starts the container. The app sees it identically either way — it's always just an environment variable. The difference is only in how it gets there.

**Q: Why does `/tls` check HTTP headers rather than the certificate itself?**
Once TLS is terminated at the ALB, the connection from ALB to container is plain HTTP inside the VPC. By the time the request reaches Node.js on port 3000 there's no TLS — the certificate is gone from the picture. The app has no way to inspect the cert the user saw. Instead `bin/005` looks at the `X-Forwarded-Proto` header the ALB injects, which is `https` if the original connection was HTTPS. That's how virtually all reverse-proxied applications detect TLS.

**Q: What would you need to change to run this on ARM (Graviton)?**
Two things. First, the base image needs the ARM64 variant — specify `--platform=linux/arm64` in the FROM line. Second, the Go binaries in `bin/` are compiled for a specific architecture. If they're AMD64, they will not run on ARM64. You'd need to recompile targeting `GOARCH=arm64 GOOS=linux`. On the Terraform side, add `runtime_platform { cpu_architecture = "ARM64" }` to the task definition. Graviton typically saves around 20% in cost for the same performance.

---

### The One They'll Definitely Ask

**Q: Walk me through what happens from when a user hits the HTTPS URL to when they see the response.**

The user types the ALB's DNS name. Their browser does a DNS lookup which resolves to the ALB's IPs — multiple because it spans two AZs. The browser initiates a TCP connection to port 443 and starts a TLS handshake. The ALB presents the certificate imported from ACM — self-signed in this case, so the browser shows a warning — and the TLS session is established.

The encrypted HTTP request arrives at the ALB. The HTTPS listener matches and the default action forwards to the target group. The ALB picks a healthy target — the Fargate task's private IP on port 3000 — and opens a plain HTTP connection to it inside the VPC, adding headers like `X-Forwarded-For` with the client's IP and `X-Forwarded-Proto: https`.

The request hits the Node.js Express server. Depending on the path — say `/` — Express calls `bin/001` via `child_process.exec`. The Go binary runs, detects the cloud environment, writes the response to stdout, and exits. Node captures that stdout and sends it back as the HTTP response body.

The response travels back to the ALB, gets wrapped in the TLS session, and sent back to the browser. Total round trip is roughly 20-50ms — mostly network latency and the child_process fork overhead.
