# FastAPI Project

A simple FastAPI project that returns JSON responses.

## Endpoints

- `GET /health` - Returns `{"status": "ok"}`
- `GET /chat?name=myname` - Returns `{"reply": "hello myname"}`

## Run Locally

```bash
pip install -r requirements.txt
uvicorn main:app --reload
```

The server runs at `http://localhost:8000`.

### Test

```bash
curl http://localhost:8000/health
curl "http://localhost:8000/chat?name=myname"
```

## Run with Docker

```bash
docker build -t fastapi-app .
docker run -d -p 8000:8000 fastapi-app
```

## Deploy to AWS ECS (Fargate + ALB)

### Manually (from your machine)

```bash
bash deploy.sh
```

The script is idempotent: it creates the ECR repo, IAM roles, ECS cluster,
task definition, security groups, ALB, target group, and service if they are
missing, then pushes a new image and re-deploys the service. It prints the
public ALB URL when done.

### Automated with GitHub Actions

A workflow in `.github/workflows/deploy.yml` runs on every push to `main`
(or manually via **Actions** -> **Deploy to ECS** -> **Run workflow**).

Before it can run, set up two things:

1. **GitHub OIDC IAM role** so the workflow can assume AWS credentials:
   - Create an IAM OIDC provider with URL
     `https://token.actions.githubusercontent.com` and audience
     `sts.amazonaws.com`. The provider must exist in the AWS account that owns
     the deployment role.
   - Create an IAM role with this trust policy, replacing the account ID with
     the account that owns the role:
     ```json
     {
       "Version": "2012-10-17",
       "Statement": [
         {
           "Effect": "Allow",
           "Principal": {
             "Federated": "arn:aws:iam::<AWS_ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
           },
           "Action": "sts:AssumeRoleWithWebIdentity",
           "Condition": {
             "StringEquals": {
               "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
               "token.actions.githubusercontent.com:sub": "repo:sourav301@3865547/myagent@1357366158:ref:refs/heads/main"
             }
           }
         }
       ]
     }
     ```
   - Replace any broad managed policies with the least-privilege policy in
     [`iam/github-actions-deploy-policy.json`](iam/github-actions-deploy-policy.json).
     It permits deployment of this ECS service and creation of only the two
     ECS task roles required by `deploy.sh`; it does not grant general IAM,
     EC2, ECS, or ECR administration.
   - Add the full ARN of this role as a repository secret named
     `AWS_DEPLOY_ROLE_ARN`. The ARN must belong to the same AWS account as the
     OIDC provider and trust policy.

   The repository uses GitHub's immutable OIDC subject format because it was
   created after July 15, 2026. The workflow is authorized for pushes to
   `main`. A manually dispatched run
   from another branch has a different OIDC subject and is not authorized by
   the trust policy above; add an explicit subject only if that is required.

2. Ensure Docker is available on the runner (default `ubuntu-latest` includes it).

After the first run, the workflow prints the app URL in the job log:
`http://<alb-dns>.elb.amazonaws.com/chat?name=myname`.
