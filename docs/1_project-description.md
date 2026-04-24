# Project 1: Multi-Stack DevOps Infrastructure Automation

## Multiple Micro-Services Voting Application

This application is intentionally a **"polyglot" stack**. It's not an example of a perfect architecture, but rather a way to expose you to:

- Multiple languages (Python, Node.js, C#/.NET)
- Multiple frameworks (Flask, Express, .NET Worker)
- Multiple data stores (Redis, Postgres)
- Dockerization of diverse applications

> The original project is taken from **Docker Samples** — with a few tweaks for simplicity.

---

## Micro-Services Overview

| Service | Technology | Description |
|---------|-----------|-------------|
| **Vote Application** | Python / Flask | Frontend where users cast their votes. Exposes an HTTP interface, stores/retrieves votes via Redis. Main file: `app.py` |
| **Redis** | In-memory DB | Used as a queue for processing votes. Handles high-throughput (e.g., 2000 votes in 5 seconds) faster than SQL. |
| **Result** | Node.js | Displays results in real-time. Main entrypoint: `server.js`. Serves a web page with Angular.js components connected via WebSocket. |
| **Worker** | .NET (C#) | Processes votes and stores them in DB. Consumes votes from Redis and writes to PostgreSQL. Files: `Program.cs`, `Worker.cs` |
| **PostgreSQL** | Relational DB | Stores persistent vote data retrieved by Result. |

---

## Connections Overview

The worker expects a running Redis and PostgreSQL instance to function correctly. Without them, it will likely fail to connect or idle while waiting.

**Note:** There are a total of **four connections** for the whole network of applications to run correctly:

- `Vote` → `redis`
- `Worker` → `redis`
- `Worker` → `postgresql`
- `Result` → `postgresql`

This also means:

- The container `vote` needs **1 environment variable** to point to redis
- The container `result` needs **1 environment variable** to point to postgres
- The container `worker` needs **2 environment variables** — one for redis and one for postgresql

> Having local/remote targets is a great start to really grasp different kinds of connections, within Docker Network and within a Private Network. Since we have different instances, chances are we might have to call a Public IP instead of a container name. If we map ports from the container to the host, then the container becomes available to the outside world, too.

---

## Working as a Team / Alone

Work as an **adapted Scrum team**. Have the Instructor as the Product Owner, with:
- Daily stand-ups
- Two sprint cycles (one for a couple of days each)
- 15-minute retrospective meetings

### Guidelines:
- Decide what can be done in the first two–three days, and what can be done in the following couple of days.
- Divide tasks — e.g., two people on infrastructure, one person on Ansible setup.
- Use a task board (Jira or Trello) to manage work:
  - **Jira** is a more real-life working scenario.
  - **Trello** is well adapted for small teams and smaller projects.

The final presentation should work as a **Final Sprint Review**, demonstrating your work at project end.

---

# Part 1 — Application Setup

## Part 1.1 - Cloning the Application

Make sure to **fork** the main branch of the repository. Forking means creating your own version of the repository.

Inspect the folder structures to understand what technologies belong to the respective folders, and find the `Dockerfiles`, along with the main scripts.

---

## Part 1.2 - Dockerizing the Applications

**Most of this work is done on one of the earlier labs** — make sure to also publish your images in Dockerhub.

You'll build and run these services in Docker containers. Review the provided Dockerfiles in each directory (`vote`, `result`, `worker`). Inspect each Dockerfile to better understand the process of building docker images for the three types of stack.

### Key Points About the Dockerfiles:

- **vote (Python):** Installs dependencies via `pip`, sets up the Python environment, and uses `gunicorn` for a production-ready server. There's also a `dev` stage allowing you to run the application with file watching.
- **result (Node.js):** Installs dependencies, uses `nodemon` for development, and runs the Node.js server on port 80.
- **worker (.NET):** Uses multi-stage builds to restore, build, and publish a .NET 7 app, then runs it in the runtime-only container.

### Note on Architectures (arm64 vs amd64):

If you're on an Apple Silicon (M1/M2) Mac or another arm64-based machine, you might face compatibility issues. Use Docker Buildx to create multi-arch images:

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t your_dockerhub_username/vote:latest .
```

> **Why don't we build an image for redis and postgres?** Because we're not building databases from scratch, we're building apps. We use existing database images built by someone else, and configure them to our needs (you also wouldn't need to build an image for Linux, they already exist out there).

---

## Part 1.3 - Using Docker Compose Locally

**This work is done on one of the earlier labs.**

We have a `docker-compose.yml` file that ties all services together (`vote`, `result`, `worker`, `redis`, and `db`). It sets up networks and volumes, ensuring all containers can communicate seamlessly.

**Your objective is to use your own published images instead.**

### Run the Whole Stack with Docker Compose:

```bash
docker compose up
```

This will:
- Start `redis` and `db`
- Build and start `vote` and `result` apps
- Start the `worker`
- Create one network `back-tier` to isolate traffic

Cast votes and watch them appear in the result app. The worker moves votes from Redis to Postgres, ensuring data persistence.

> If you're struggling, you can use the already available images in the `docker-compose.yml` file.

---

# Part 2 — Provisioning Infrastructure Using Terraform

Now that you understand and can run everything locally, you will provision the required infrastructure on AWS using Terraform.

## Application Distribution

- **Instance A (Application Tier - Frontend):** An EC2 instance launched in any AZ that runs the **Vote** (Python/Flask) and **Result** (Node.js/Express) services.
- **Instance B (Data/Backend Services):** Runs **Redis** and the **Worker** (.NET) in a private subnet (single AZ or multi-AZ for high availability).
- **Instance C (Database Tier):** Runs **PostgreSQL** in its own private subnet, optionally with a read-replica in a second AZ.

## Setting up the Infrastructure

### Infrastructure Setup:

- Create a **VPC** with one public subnet in any AZ and one private subnet in any AZ.
- Create your EC2 instances:
  - **A** in a public subnet from Vote + Result — **this instance will be used as a Bastion Host**
  - **B** in a private subnet for Redis + Worker
  - **C** in a private subnet for PostgreSQL
- Create Security Groups for each tier, locking down inbound/outbound traffic as outlined below.
- **Public Subnets:** Place instance A here so it's internet-accessible.
- **Private Subnets:** Place instances B and C in private subnets. They should not be directly exposed to the internet.

### Security Groups:

- **Vote/Result SG:** Allows incoming HTTP/HTTPS from the internet.
- **Redis/Worker SG:** Allows inbound traffic from Vote/Result EC2 to Redis port (6379), and allows outbound to Postgres.
- **Postgres SG:** Allows inbound traffic on port 5432 only from the Worker SG (and possibly from Vote/Result if needed directly).

### Remote State and Locking:

- Store your `terraform.tfstate` file in a **remote backend** and enable state locking with **DynamoDB** or a similar mechanism.

---

# Part 3 — Configuration Management with Ansible

**Note - Connecting to Private Subnet Instances with Ansible:** Because your EC2 instances live in private subnets (and do not have public IP addresses), you cannot directly SSH into them from the public internet. In real-world production, best practices dictate that your private services remain inaccessible directly from the internet. However, you still need a way to configure or manage them using Ansible (or other tools).

## 3.1. Using Front-End instance as a Bastion Host

The proper production approach is to have a Bastion host where you clone your git repository with the Ansible playbooks, and from there configure all other instances. But for your initial setup, let's configure all instances from your computer. To access the instances in the private subnets, Ansible first connects to the public subnet instance (frontend) and from there configures private instances.

### Update the `ssh_config` in your WSL or MacBook:

```
Host frontend-instance-1
    HostName <FRONTEND_PUBLIC_IP_OR_DNS>
    User ubuntu
    IdentityFile ~/.ssh/mykey.pem

Host backend-instance-1
    HostName <BACKEND_IP_or_DNS>
    User ubuntu
    ProxyJump frontend
    IdentityFile ~/.ssh/mykey.pem
# ...
```

Then, in your Ansible inventory, you can refer to the private EC2 hosts by their internal DNS names (e.g., `backend`), and Ansible will automatically route through the bastion (in this case, `frontend`).

### Ansible Inventory Example (Using SSH Config):

If you've configured the SSH Config correctly, the inventory should be very simple:

```ini
[frontend]
frontend-instance-1

[backend]
backend-instance-1

[db]
db-instance-1
```

## 3.2. Install or Verify Docker on EC2:

- If your AMI does **not** include Docker, use Ansible playbooks to connect to your newly provisioned EC2 instances (via SSH) and install Docker.
- If your AMI **already** includes Docker, you can skip or modify those tasks accordingly.
- Ensure Docker is running, and your user is in the `docker` group to run containers without `sudo`.

## 3.3. Deploying Containers to EC2:

- Pull your images from DockerHub on the EC2 instances.
- Run the containers using `docker run` commands or `docker-compose` (for single-machine deployments).
- Ensure environment variables are correctly set (e.g., database credentials, Redis hostnames).

### Example Ansible Tasks to Install and Start Docker on Ubuntu:

```yaml
- name: Update apt package index
  ansible.builtin.apt:
    update_cache: yes

- name: Install Docker if not present
  ansible.builtin.package:
    name: docker.io
    state: present

- name: Pull Docker Image
  docker_image:
    name: <your-dockerhub-username>/vote
    source: pull
    tag: latest

- name: Run Container
  docker_container:
    name: client
    image: <your-dockerhub-username>/client:latest  # Change!
    ports:
      - "80:80"  # port mappings
    state: started
```

> For Ubuntu (Debian), the package `docker.io` is used. For RHEL (Amazon Linux), the package `docker` is used.

## 3.4. Connection Configuration

- To know if the **vote** microservice is working, cast a vote. If a tick appears, it's working!
- To know if the **result** microservice is working, you should see the number of votes in the bottom right corner.
- Make sure to inspect logs on all docker containers to see connections are made:

```bash
docker logs name-of-container
```

If you want to debug whether a certain container can connect to another (in the same instance or in another one), check the environment variables for each container. For example, `vote` needs the `REDIS_HOST` environment variable to point to `<BACKEND-IP>`.

Hop into a container using:

```bash
docker exec -it <container-name> bash
```

and watch the environment variables by typing the `env` command.

Another good way to check if connections can be made is by using `telnet`. Install it using apt and try to connect to your desired service:

```bash
# syntax: telnet <host> <port>
telnet 4.220.70.19 6379   # to test redis
telnet 31.240.22.8 5432   # to test postgres
```

If it connects, you'll see a response or a blank screen indicating the port is open. If it fails, you likely have a **security group** issue.

---

# Project Add-Ons

This is your time to shine **after completing the actual project**. The following add-ons are complementary, but they will give you hands-on experience on important DevOps topics. Choose and plan wisely — give yourself enough time to do the project and, for example, 4 hours to do one or two of the extras. You can always come back after the project is done.

## 🟢 (Easy) Add-Ons

### 🟢 Proper Security Group Configs
Security Groups should have proper Inbound rules. For example, the `backend` security group should only accept `ssh` connections from the `frontend` security group, and inbound connections on the port `6739` from frontend security group too.

### 🟢 Create a Volume for PostgreSQL
This task is pretty easy — just assign a volume when running the image with Ansible. To test it, take the container down, run the Ansible playbook again, and see if the prior data still exists.

### 🟢 Provision DynamoDB and S3 used in Terraform
In an individual folder, you can create the DynamoDB table and S3 Buckets that are used in the actual main project.

## 🟡 (Medium) Add-Ons

### 🟡 Your own Dockerfiles and Docker Compose
Feel like a real-work DevOps challenge to fully learn writing Dockerfiles and Docker Compose files? Erase all the `Dockerfiles`. Erase `docker-compose.yaml`. Don't think about the content or memorizing anything. Just erase them. Try to rewrite all of them by yourself and have them working (**No ChatGPT!**).

### 🟡 Individual Bastion Host
Create a specific Bastion host to configure all other EC2 machines. This means the `frontend` instance is no longer used as a bastion and only accepts SSH connections from this bastion host. You can install Ansible directly on the bastion host and run playbooks from there.

### 🟡 Logging & Monitoring
In this project, we need to ask ourselves: *"What kind of data am I looking to monitor? Is it just infrastructure metrics? Are there other metrics I can get?"*

- **Logs** — For this project, we can use CloudWatch Agent to scrape logs from docker containers into CloudWatch Logs.
- **Metrics** — We're looking for **Infrastructure** metrics in this project. We can set up CloudWatch metrics to monitor CPU, memory, and container health tracking.
- **Alarms** — Define alarms (e.g., CPU usage, container restart counts) so you are alerted (via e-mail) if something goes wrong.

### 🟡 Running the Apps locally without Docker
If you really want to get comfortable with each stack, run the services directly on your local machine.

**How to run all services in your computer?**
In Visual Studio Code, create five terminals, one for each microservice. Rename the terminals to the respective microservice. You can switch and debug between them easily.

- First, run the `postgres` and `redis` databases in docker.
- Second, run the `worker`. It will initialize postgresql tables once it establishes a connection.
- Finally, run `vote` and `result` applications.

**Prerequisites:** You must have Python, Node.js, and .NET SDK installed locally. The .NET version should be `8.0`. Make sure to override ports and hosts to match your local machine.

> This step is sometimes harder than it looks, because you need to configure your computer with all the right runtime environments and virtual environment (for Python).

## 🟠 (Harder) Add-Ons

### 🟠 Load Balancer
The Load Balancer is going to serve:

- **As a Gateway:** The guardian where all inbound connections from the internet come to, and all outbound connections are directed to.
- **As a Proper Load Balancer:** Able to have target groups with multiple instances running the same microservice.
- **As a Reverse Proxy:** A target the internet points to, and creates new connections to instances within the Private Network depending on the contents of the request.

**This is a step that involves separating each container into its own EC2 instance.** The only reason we don't do this in the beginning is for students to get real experience on a very common situation — having one server for multiple services to save money and addressing local vs remote communications in that scenario.

**What services can use load balancing?** With this project, only the `vote` and `result`. Worker doesn't expose any HTTP endpoints, so there's no real way to load balance into it. While there is a way to scale redis and postgres with a database replication strategy, the applications (clients) would have to be aware of that.

As for the requirements of the Load Balancer, you will need:

- 2 Availability Zones — different **public subnets** for each AZ
- All instances to be placed in **private subnets**, except for the **bastion host**, which lies in a public subnet.
- Target Groups for `vote` and `result` (only one instance for each).
- All running images now have to point to the ALB's **endpoint** — the ALB will decide which microservice to point to depending on the path:
  - `/vote` goes to the voting instance
  - `/result` goes to the result instance

> 👉 **Tip:** If you want to make the Load Balancer work in Terraform, first have it working manually and write down all the steps until you get the final working result, so you have a better picture of all its needs and configurations when setting it up on Terraform.

---

# Submission Guidelines

- Push your final code/infrastructure files to a GitHub repository (remember **not** to push any secrets).
- Prepare a **15-minute presentation and live demo** to be done in class. You'll show:
  - The infrastructure you created (Terraform plan, subnets, EC2 arrangement).
  - Your Ansible playbooks or approach used for container deployment.
  - The final working URL from your AWS Load Balancer or public IPs, demonstrating vote casting and result viewing.

> ✨ **Final Tip** — Spend some time writing a LinkedIn post on this project, and making it a GitHub public project to showcase your skills. ✨

---

# Quick-Reference Summary

## Tech Stack
- **Languages:** Python, Node.js, C#/.NET 7/8
- **Frameworks:** Flask, Express, .NET Worker, Angular.js
- **Data Stores:** Redis, PostgreSQL
- **Containerization:** Docker, Docker Compose, DockerHub
- **IaC:** Terraform (with remote state in S3 + DynamoDB locking)
- **Configuration Management:** Ansible (via SSH + Bastion ProxyJump)
- **Cloud:** AWS (VPC, EC2, Subnets, Security Groups, optional ALB, CloudWatch)

## Key Ports
| Service | Port |
|---------|------|
| Vote (HTTP) | 80 |
| Result (HTTP) | 80 |
| Redis | 6379 |
| PostgreSQL | 5432 |

## Environment Variables Needed
| Container | Variables |
|-----------|-----------|
| `vote` | `REDIS_HOST` |
| `result` | Postgres connection info |
| `worker` | Redis host + Postgres connection info |

## Project Phases Timeline (Suggested)
1. **Sprint 1 (Days 1–3):** Fork repo → Dockerize → Docker Compose locally → Push images to DockerHub
2. **Sprint 2 (Days 4–6):** Terraform (VPC, subnets, EC2, SGs, remote state) → Ansible (SSH config, playbooks, deploy containers) → Verification
3. **Add-Ons (Optional):** Pick 1–2 based on remaining time (start with Easy — Security Groups & Postgres Volume)
4. **Final:** Presentation + GitHub polish + LinkedIn post
