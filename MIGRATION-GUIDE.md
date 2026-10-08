# Migrating an existing AWS EC2 instance from S3 state to HCP Terraform

**Audience:** platform / cloud engineers already using Terraform CLI with an S3 remote backend.
**Goal:** move one real EC2 instance from an S3 state backend into an HCP Terraform workspace — **without destroying, recreating or touching the instance itself**.
**Live demo time:** ~15 minutes (Part 1 is pre-work, do it before the session).

Every change in this demo happens in a single file: **`main.tf`**. There are no extra files to rename, enable or disable.

---

## 1. Prerequisites

### 1.1 Accounts and access

| # | Requirement | How to check |
|---|---|---|
| 1 | An **HCP Terraform account** and an **organization** you can create workspaces in | Log in at <https://app.terraform.io> → the org name is in the top-left selector |
| 2 | Role of **Owner** or a team with *Manage Workspaces* permission | Organization → Settings → Teams |
| 3 | An **AWS account** you can create/destroy a `t3.micro` EC2 instance in | `aws sts get-caller-identity` |
| 4 | An **S3 bucket** for the "before" state, in a known region | `aws s3 ls` |
| 5 | AWS permissions: `ec2:Describe*`, `ec2:RunInstances`, `ec2:CreateTags`, `ec2:TerminateInstances`, plus `s3:GetObject`/`s3:PutObject` on the state bucket | — |
| 6 | A **default VPC** (or an explicit `subnet_id` in the config) in the instance region | `aws ec2 describe-vpcs --filters Name=isDefault,Values=true` |

### 1.2 Tooling

| Tool | Minimum version | Check |
|---|---|---|
| Terraform CLI | **1.6+** (`cloud` block needs 1.1+, `import` blocks need 1.5+) | `terraform version` |
| AWS CLI | v2 | `aws --version` |

### 1.3 Network

Outbound **HTTPS (443)** to `app.terraform.io`, `registry.terraform.io` and `releases.hashicorp.com`.

> Behind a proxy, set `HTTPS_PROXY` / `NO_PROXY` first. If egress is blocked entirely, this demo needs a self-hosted **HCP Terraform Agent** — out of scope, flag it as a follow-up.

### 1.4 Credentials — read this before you start

Terraform does **not** read `.env` files automatically. Load them into the shell yourself, in every new terminal:

```bash
set -a; source .env; set +a
aws sts get-caller-identity      # must succeed before any terraform command
```

Two traps worth knowing:

- **Environment variables override `~/.aws/credentials`.** A half-populated `.env` will shadow a working profile and produce confusing errors.
- **Temporary credentials need all three values.** If your identity is an assumed role or SSO (`Arn` contains `assumed-role`), you must set `AWS_SESSION_TOKEN` alongside the key and secret, and they expire — typically in 1–12 hours. Refresh them immediately before the session.

### 1.5 Files in this folder

| File | Purpose |
|---|---|
| `main.tf` | Backend block, provider, and the EC2 instance. **Everything changes here.** |
| `variables.tf` | Region, instance type, tags. |
| `.gitignore` | Keeps state files, `.env` and tfvars out of version control. |

### 1.6 Cost

One `t3.micro` for the length of the session: a few cents, or free under the AWS free tier. Part 6 destroys it.

---

## 2. Part 1 — Build the "before" picture *(pre-work, ~5 min)*

This creates the instance the customer watches us migrate, managed by an **S3 backend** — their current-state-management stand-in. **Do this before the session.**

Open `main.tf` and confirm the `terraform` block points at your bucket:

```hcl
terraform {
  backend "s3" {
    bucket = "demo-state-bucket-main"
    key    = "terraform.tfstate"
    region = "us-west-2"
  }

  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

> **Bucket names are exact.** A stray trailing space produces `ParamValidation: Invalid bucket name` — check for whitespace inside the quotes.
>
> The backend `region` is the **bucket's** region. It is independent of `var.aws_region`, which is where the EC2 instance is created. They do not have to match.

```bash
set -a; source .env; set +a
terraform init
terraform apply
```

Type `yes`. After ~30 seconds:

```
Apply complete! Resources: 1 added, 0 changed, 0 destroyed.

Outputs:
instance_id = "i-0b39706815d75603d"
```

**Record the instance id** — it's the proof point for the whole demo. Then show what "current state management" looks like today:

```bash
aws s3 ls s3://demo-state-bucket-main/       # state is an object in a bucket you run
terraform state list                          # what Terraform is tracking
```

> **Talking point:** *"This works — the state is remote and shared. But look at what you're maintaining to get here: a bucket, a bucket policy, encryption settings, versioning, and historically a DynamoDB table just for locking. And you still have no run history, no approval gates, no RBAC, and no idea who applied what. You're maintaining plumbing, not getting a workflow."*

---

## 3. Part 2 — Swap the backend in `main.tf` *(~2 min)*

### 3.1 Log in from the CLI

```bash
terraform login
```

Press `yes`, the browser opens, click **Generate token**, paste it back. The token is stored in `~/.terraform.d/credentials.tfrc.json`.

### 3.2 Replace the `backend "s3"` block with a `cloud` block

In `main.tf`, delete this:

```hcl
  backend "s3" {
    bucket = "demo-state-bucket-main"
    key    = "terraform.tfstate"
    region = "us-west-2"
  }
```

and put this in its place:

```hcl
  cloud {
    organization = "luisroset-org"

    workspaces {
      name = "aws-ec2-migration-demo"
    }
  }
```

The `terraform` block now reads:

```hcl
terraform {
  cloud {
    organization = "luisroset-org"

    workspaces {
      name = "aws-ec2-migration-demo"
    }
  }

  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

Nothing else in the file changes. The provider, the data source, the `aws_instance` resource and the outputs are all untouched.

> **Talking point:** *"That's the migration. One block swapped for another, in one file. No resource was rewritten, nothing was re-imported, and the rest of the configuration didn't move. This is the same edit whether you're moving one instance or a thousand."*

---

## 4. Part 3 — Migrate the state *(~2 min)*

```bash
terraform init
```

Terraform detects the backend change and prompts:

```
Migrating from backend "s3" to HCP Terraform.

  Do you wish to proceed?
  Terraform will copy the existing state to HCP Terraform.

  Enter a value: yes
```

Type **`yes`**. Terraform creates the workspace `aws-ec2-migration-demo` if it doesn't exist, uploads the state, and confirms:

```
Success! Terraform has migrated to HCP Terraform from a previous "s3" backend.
```

### What just happened

- State now lives in HCP Terraform: encrypted at rest, versioned, locked on every run.
- The S3 object is no longer read or written.
- **The EC2 instance was not touched.** Nothing created, changed or destroyed.

### Show it in the UI

<https://app.terraform.io> → your org → workspace **aws-ec2-migration-demo**:

| Tab | What to point at |
|---|---|
| **States** | The state version just uploaded, with timestamp and author |
| **States → the version** | The resource tree, with the EC2 instance and its attributes |
| **Settings → Locking** | Locking is on by default — no DynamoDB table to run |

---

## 5. Part 4 — Give the workspace its AWS credentials *(~2 min)*

The workspace defaults to **Remote** execution: `plan` and `apply` now run on HCP Terraform's infrastructure. So the *workspace* — not your laptop — needs AWS credentials.

Workspace → **Variables** → **Add variable**, as **Environment variables**:

| Key | Value | Sensitive |
|---|---|---|
| `AWS_ACCESS_KEY_ID` | the access key | ☐ |
| `AWS_SECRET_ACCESS_KEY` | the secret key | ☑ **yes** |
| `AWS_SESSION_TOKEN` | *required if using temporary/SSO credentials* | ☑ **yes** |
| `AWS_REGION` | e.g. `eu-west-1` | ☐ |

> **Talking point:** *"Secrets now live in the platform, write-only, not in a `.env` file or someone's shell history. In production you wouldn't use static keys at all — HCP Terraform issues short-lived AWS credentials via OIDC, so there's no long-lived secret to rotate or leak."* (Appendix 9.3.)

**Recommended for a live session: use Local execution instead.** Settings → General → Execution Mode → **Local**. State stays in HCP Terraform, plans run on your laptop with your existing credentials, and there is nothing to expire mid-demo. You lose the remote-run visual but keep the entire state story. If your AWS credentials are an assumed role, take this option.

---

## 6. Part 5 — Prove the resource is now managed remotely *(~4 min)*

### 6.1 Nothing drifted

```bash
terraform plan
```

Expected:

```
Running plan in HCP Terraform. Output will stream here.
Preview: https://app.terraform.io/app/luisroset-org/aws-ec2-migration-demo/runs/run-XXXXXXXX

No changes. Your infrastructure matches the configuration.
```

> **Important:** this first CLI plan is also what uploads your configuration to the workspace. Until it runs, the workspace has state but no configuration, and the UI's **Start new run** button fails with *"Configuration version is missing"*. That is expected, not a fault — see Troubleshooting.

> **Talking point:** *"`No changes` is the proof. Same instance, same id, now managed from HCP Terraform. And that run link — the whole team can watch the same run, with the same output. That's not something a state file in S3 can give you."*

### 6.2 Make a real change through the platform

Edit the `ManagedBy` tag in `main.tf`:

```hcl
  tags = {
    Name        = var.instance_name
    Environment = "demo"
    ManagedBy   = "hcp-terraform"   # was "terraform-s3-backend"
    Owner       = var.owner
  }
```

```bash
terraform apply
```

Terraform queues a remote run, streams the plan, asks to confirm, applies:

```
Apply complete! Resources: 0 added, 1 changed, 0 destroyed.
```

**Instance id unchanged** — an in-place tag update, not a replacement.

### 6.3 The payoff

| Where in the UI | What to show |
|---|---|
| **Runs** | Full audit trail: who ran what, when, plan output, who approved |
| **States** | Every state version, diffable, rollback-able |
| **Variables** | Secrets stored write-only, separate from code |
| **Settings → Team Access** | Who can plan vs. who can apply |
| **Actions → Start new run** | The laptop isn't required any more |

> **Closing talking point:** *"We swapped one block in one file and answered one prompt. In exchange: encrypted remote state, locking, versioning, audit trail, RBAC and centralised secrets — and we decommissioned a bucket, a bucket policy and a lock table. That's the migration, and it's identical for your 5th project and your 500th."*

---

## 7. Part 6 — Cleanup

```bash
terraform destroy
```

Then UI: workspace → **Settings → Destruction and Deletion → Delete workspace**.

Locally, restore the S3 backend block in `main.tf` if you want to re-run the demo, then:

```bash
rm -rf .terraform .terraform.lock.hcl terraform.tfstate*
```

---

## 8. Scaling this up: modules and state management

Migrating one workspace is the easy part. What follows is how the same platform handles fifty teams and five hundred workspaces — this is the section that answers *"fine, but how do we actually run this at Telefónica scale?"*

### 8.1 First, move configuration into a repository

The CLI-driven workflow you just used uploads your local directory on every run. It's the right on-ramp for a migration, but it leaves the laptop as the source of truth for *code* — the same problem you just solved for *state*.

| Workflow | How config arrives | Use for |
|---|---|---|
| **CLI-driven** | `terraform plan/apply` uploads the local directory | Migration, experimentation |
| **VCS-driven** | HCP Terraform pulls from a repo branch on every push | **Production — the recommended pattern** |
| **API-driven** | Your CI/CD uploads configuration versions via API | When an existing pipeline must stay the orchestrator |

To convert: workspace → **Settings → Version Control → Connect to version control**, pick the VCS provider, choose the repo and branch, and set **Terraform Working Directory** if the repo holds several projects. Leave **Auto-apply off**.

What you gain: speculative plans posted on every pull request, merge-triggered applies, policy checks between plan and apply, drift detection against the repo, and no AWS credentials on any laptop.

> **Know before you demo it:** once a workspace is VCS-connected, `terraform apply` from the CLI stops working — CLI runs become speculative plans only, and applies must come from a merge. Present it as the safety property it is: *"the CLI can still show you a plan, but only Git can change production."*

A repo is also a hard prerequisite for the private module registry, below.

### 8.2 Modules: the unit of reuse

A module is a reusable, versioned package of Terraform configuration. The EC2 instance in this demo is a good candidate: instead of every team writing their own `aws_instance` block, they consume one reviewed module that has the tagging standard, the AMI policy and the security group baked in.

**Publishing to the private registry:**

1. Repo naming must follow **`terraform-<PROVIDER>-<NAME>`**, e.g. `terraform-aws-ec2-instance`. The registry will reject other names.
2. Standard layout at the repo root: `main.tf`, `variables.tf`, `outputs.tf`, `README.md`, plus `examples/`.
3. Tag releases with **semantic version** git tags: `v1.0.0`, `v1.1.0`.
4. In HCP Terraform: **Registry → Publish → Module**, select the VCS provider and repo. New tags are picked up automatically as new versions.

**Consuming it:**

```hcl
module "web_server" {
  source  = "app.terraform.io/luisroset-org/ec2-instance/aws"
  version = "~> 1.1.0"

  instance_type = "t3.micro"
  environment   = "production"
}
```

> **Always pin `version`.** `~> 1.1.0` accepts patches but not breaking changes. An unpinned module means a teammate's merge can change your infrastructure without your code changing at all.

**Module rules that prevent the most common failures:**

- **Never put a `backend` or `cloud` block inside a module.** Only the root module configures state. A `cloud` block in a shared module will hijack every consumer's workspace.
- **Never put `provider` blocks inside a module.** Declare `required_providers` there, and let the root module configure and pass providers. Provider blocks in modules break `terraform destroy` and prevent version flexibility.
- **Modules do not have their own state.** Everything a module creates is stored in the *calling workspace's* state file, namespaced as `module.web_server.aws_instance.this`. Adding modules doesn't split state — see below.
- **Version the module, not the environment.** One module, consumed at different versions by dev and prod, beats copy-pasted per-environment forks.

### 8.3 State management: how to split workspaces

Since modules don't split state, the workspace is your unit of state separation — and getting this boundary right is the single highest-impact design decision.

**Anti-pattern: one giant workspace** holding network, databases, Kubernetes and applications. Plans take 20 minutes, every change locks everyone out, and one bad apply has an enormous blast radius.

**Pattern: one workspace per (component × environment).**

```
networking-prod       networking-dev
database-prod         database-dev
app-platform-prod     app-platform-dev
```

Split on these boundaries:

| Split when… | Because |
|---|---|
| A different **team** owns it | RBAC and approval gates follow the workspace |
| It changes at a different **rate** | Networking changes monthly, apps change hourly |
| It has a different **blast radius** | A bad app deploy shouldn't be able to touch the VPC |
| Plans are getting **slow** | Run time is proportional to resources in state |

**Naming convention:** `<component>-<environment>`, consistently. HCP Terraform **Projects** group related workspaces and carry team permissions across them — use a project per application or per business unit.

### 8.4 Wiring workspaces together

Split workspaces still need each other's outputs. The networking workspace produces a VPC id; the app workspace consumes it.

```hcl
data "tfe_outputs" "networking" {
  organization = "luisroset-org"
  workspace    = "networking-prod"
}

module "app" {
  source  = "app.terraform.io/luisroset-org/app/aws"
  version = "~> 2.0"

  vpc_id     = data.tfe_outputs.networking.values.vpc_id
  subnet_ids = data.tfe_outputs.networking.values.private_subnet_ids
}
```

`tfe_outputs` reads only the published **outputs** of the other workspace, not its whole state — so the consuming team never gets access to the producer's secrets. Prefer it over `terraform_remote_state`, which requires broader access.

Pair this with **Run Triggers** (workspace → Settings → Run Triggers): when `networking-prod` applies successfully, automatically queue a plan in the workspaces that depend on it.

### 8.5 Reducing repetition across many workspaces

- **Variable sets** — define AWS credentials, region and standard tags once at the organization level, attach to many workspaces. No more copying variables per workspace.
- **Dynamic provider credentials (OIDC)** — as a variable set, this gives every workspace short-lived AWS credentials with no static keys anywhere. See Appendix 9.3.
- **No-code modules** — publish a module so application teams can provision it from a form in the UI, with no Terraform knowledge and no repo access. This is how platform teams scale self-service without becoming a ticket queue.
- **Policy as code (Sentinel / OPA)** — enforce "all resources must carry a cost-centre tag" or "no public S3 buckets" between plan and apply, across every workspace at once.

### 8.6 A sensible adoption order

1. Migrate existing state into workspaces (what this guide covers).
2. Connect workspaces to VCS — get PR-based plans.
3. Split oversized workspaces along team and blast-radius boundaries.
4. Extract repeated HCL into registry modules; pin versions.
5. Introduce variable sets and dynamic credentials to remove static secrets.
6. Add policy as code once the workflow is established — not before, or it feels like an obstacle rather than a guardrail.

---

## 9. Appendices

### 9.1 If the customer's current state is local, not S3

Identical procedure. They simply have no `backend` block at all — Terraform defaults to a local `terraform.tfstate`. Add the `cloud` block to the `terraform` block in `main.tf` and run `terraform init`; the prompt reads *"Terraform has detected you're using HCP Terraform… Should Terraform migrate your existing state?"*. Answer `yes`.

### 9.2 If the EC2 instance was **never** managed by Terraform

That's an *import*, not a state migration. From Terraform 1.5+:

```hcl
import {
  to = aws_instance.demo
  id = "i-0b39706815d75603d"
}
```

```bash
terraform plan -generate-config-out=generated.tf   # writes the HCL for you
terraform apply                                     # adopts it into state
```

Review `generated.tf`, fold it into `main.tf`, re-plan until `No changes`, then delete the `import` block. Works with the `cloud` block in place, so the resource lands directly in HCP Terraform state.

### 9.3 Dynamic credentials (no static AWS keys)

1. In AWS IAM, create an OIDC identity provider for `app.terraform.io`.
2. Create a role trusting it, scoped to your org/workspace.
3. Set workspace variables `TFC_AWS_PROVIDER_AUTH = true` and `TFC_AWS_RUN_ROLE_ARN = arn:aws:iam::...:role/...`.
4. Delete the static key variables.

Attach as a **variable set** to apply it across many workspaces at once.

Docs: <https://developer.hashicorp.com/terraform/cloud-docs/workspaces/dynamic-provider-credentials/aws-configuration>

---

## 10. Troubleshooting

These are the failures actually hit while building this demo.

| Symptom | Cause | Fix |
|---|---|---|
| `ExpiredToken: The security token included in the request is expired` | Temporary/assumed-role credentials have expired | Refresh them, then `set -a; source .env; set +a`. Verify with `aws sts get-caller-identity` |
| Credentials look right but Terraform still fails | Terraform doesn't read `.env`; it fell back to a stale `~/.aws/credentials` | Source `.env` explicitly. Remember env vars override the profile |
| `ParamValidation: Invalid bucket name "my-bucket "` | Trailing space inside the quotes | Remove the whitespace |
| Terraform reports the backend is `cloud` when `main.tf` says `s3` (or vice versa) | Stale backend pointer cached in `.terraform/terraform.tfstate` | `rm -f .terraform/terraform.tfstate` then `terraform init` |
| `terraform.tfstate` is 0 bytes after init | **Normal** after a successful migration to a remote backend | Real state is in the remote backend. Keep `terraform.tfstate.backup` until `terraform plan` says `No changes` |
| UI: **"Error starting plan — configuration version is missing"** | State-only migration uploads no configuration. A CLI-driven workspace gets its config from the first `terraform plan`/`apply` | Run `terraform plan` from the CLI once. The UI's *Start new run* works afterwards |
| Plan proposes **creating** a resource that already exists | State didn't upload; the workspace is empty | Check `resource-count` on the workspace. Restore from `terraform.tfstate.backup` and re-run `terraform init` |
| Remote plan: `No valid credential sources found` | Workspace has no AWS credentials | Add the environment variables (Part 4), or switch Execution Mode to Local |
| Plan wants to **destroy and recreate** the instance | The AMI data source resolved to a newer AMI | Pin it: replace `data.aws_ami.al2023.id` with the literal id from `terraform state show aws_instance.demo` |
| `Error acquiring the state lock` | A previous run is still open | Workspace → Runs → cancel/discard the stuck run |
| `VPCIdNotSpecified` on apply | No default VPC in the region | Add `subnet_id = "subnet-..."` to `aws_instance.demo` |

---

## 11. One-page command summary

```bash
# Every new terminal
set -a; source .env; set +a
aws sts get-caller-identity

# Pre-work: create the instance with the S3 backend
terraform init && terraform apply

# The migration: in main.tf, replace the `backend "s3"` block with a `cloud` block
terraform login
terraform init                       # answer "yes" to migrate state

# Add AWS credentials as workspace Environment Variables,
# or set Execution Mode to Local

# Prove it
terraform plan                       # -> "No changes" (also uploads the config)
terraform apply                      # runs remotely, streams to your terminal

# Cleanup
terraform destroy
```
