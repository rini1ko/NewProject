-include .env

COMPOSE := docker compose
DB_PORT ?= 5432
LOCAL_DATABASE_URL := $(subst @db:5432,@localhost:$(DB_PORT),$(DATABASE_URL))
s ?=

.DEFAULT_GOAL := help
.PHONY: help env build up down restart logs ps migrate migration seed psql test lint format \
	dev-backend dev-frontend install clean deploy deploy-auth deploy-backend deploy-frontend destroy-auth destroy-backend destroy-frontend add-domain remove-domain infra-lint deploy-reports report-now \
	llm-hello parse deploy-ai destroy-ai

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(firstword $(MAKEFILE_LIST)) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

env: ## Create .env from .env.example if missing
	@test -f .env || (cp .env.example .env && echo "Created .env")

build: env ## Build all images
	$(COMPOSE) build

up: env ## Build and start the whole stack
	$(COMPOSE) up -d --build
	@echo "App:      http://localhost:3000"
	@echo "API docs: http://localhost:8000/api/docs"

down: ## Stop the stack
	$(COMPOSE) down

restart: down up ## Restart the stack

logs: ## Follow logs (optionally: make logs s=backend)
	$(COMPOSE) logs -f $(s)

ps: ## Show running services
	$(COMPOSE) ps

migrate: ## Apply database migrations
	$(COMPOSE) exec backend alembic upgrade head

migration: ## Generate a migration: make migration m="add something" (db must be up)
	@test -n "$(m)" || (echo 'Usage: make migration m="message"' && exit 1)
	cd backend && DATABASE_URL=$(LOCAL_DATABASE_URL) uv run alembic revision --autogenerate -m "$(m)"

seed: ## Insert sample participants and meetings
	$(COMPOSE) exec backend python -m app.seed

psql: ## Open psql in the db container
	$(COMPOSE) exec db psql -U $(POSTGRES_USER) -d $(POSTGRES_DB)

test: ## Run backend tests (against the <db>_test database)
	$(COMPOSE) exec backend pytest -v

lint: ## Lint backend and frontend
	cd backend && uv run ruff check . && uv run ruff format --check .
	cd frontend && npm run lint && npx prettier --check .

format: ## Format backend and frontend
	cd backend && uv run ruff check --fix . && uv run ruff format .
	cd frontend && npm run format

install: ## Install local dev dependencies (uv + npm)
	cd backend && uv sync
	cd frontend && npm install

dev-backend: env ## Run backend locally with reload (db runs in Docker)
	$(COMPOSE) up -d db
	cd backend && DATABASE_URL=$(LOCAL_DATABASE_URL) uv run alembic upgrade head
	cd backend && DATABASE_URL=$(LOCAL_DATABASE_URL) uv run uvicorn app.main:app --reload --port 8000

dev-frontend: ## Run Vite dev server on http://localhost:5173 (proxies /api to :8000)
	cd frontend && npm run dev

clean: ## Stop the stack and delete the database volume
	$(COMPOSE) down -v

# AWS credentials and settings come from .env; export them only to the recipes below.
AWS_ENV := AWS_ACCESS_KEY_ID="$(AWS_ACCESS_KEY_ID)" AWS_SECRET_ACCESS_KEY="$(AWS_SECRET_ACCESS_KEY)" \
	AWS_SESSION_TOKEN="$(AWS_SESSION_TOKEN)" AWS_REGION="$(AWS_REGION)" \
	PROJECT_NAME="$(or $(PROJECT_NAME),$(APP_NAME))" CORS_ORIGINS_AWS="$(CORS_ORIGINS_AWS)" \
	LAMBDA_MEMORY="$(LAMBDA_MEMORY)" DOMAIN_NAME="$(DOMAIN_NAME)" HOSTED_ZONE_ID="$(HOSTED_ZONE_ID)" \
	GOOGLE_CLIENT_ID="$(GOOGLE_CLIENT_ID)" GOOGLE_CLIENT_SECRET="$(GOOGLE_CLIENT_SECRET)" \
	REPORT_EMAIL="$(REPORT_EMAIL)" REPORT_SCHEDULE_TARGET="$(REPORT_SCHEDULE_TARGET)" \
	REPORT_SCHEDULE_EXPRESSION="$(REPORT_SCHEDULE_EXPRESSION)" WEEK="$(WEEK)" \
	PARSER_MODEL="$(or $(PARSER_MODEL),anthropic.claude-opus-5-5)" PARSER_EFFORT="$(or $(PARSER_EFFORT),low)" \
	PARSER_API="$(or $(PARSER_API),messages)" BUDGET_EMAIL="$(BUDGET_EMAIL)"

deploy: deploy-backend deploy-frontend ## Deploy the whole app to AWS (after make deploy-auth)

deploy-reports: env ## Deploy the weekly report: S3, SQS, Scheduler, builder + mailer Lambdas, SES (after deploy-backend)
	@$(AWS_ENV) ./infra/deploy-reports.sh

report-now: env ## Build a report now: make report-now WEEK=2026-W39 (default: previous week)
	@$(AWS_ENV) ./infra/report-now.sh

# Laptop runs of the parser: same credentials, but unset values are not exported (an empty
# AWS_SESSION_TOKEN would break signing) and the model has a default.
LLM_ENV := AWS_ACCESS_KEY_ID="$(AWS_ACCESS_KEY_ID)" AWS_SECRET_ACCESS_KEY="$(AWS_SECRET_ACCESS_KEY)" \
	$(if $(AWS_SESSION_TOKEN),AWS_SESSION_TOKEN="$(AWS_SESSION_TOKEN)") \
	PARSER_MODEL="$(or $(PARSER_MODEL),anthropic.claude-opus-5-5)" PARSER_EFFORT="$(or $(PARSER_EFFORT),low)" \
	PARSER_API="$(or $(PARSER_API),messages)"

deploy-ai: env ## Deploy "Paste an agenda": parser Lambda + function URL + $5 budget alarm (after deploy-backend)
	@$(AWS_ENV) ./infra/deploy-ai.sh

destroy-ai: env ## Delete the parser stack
	@$(AWS_ENV) ./infra/destroy-ai.sh

llm-hello: env ## First call to Claude on Bedrock from your laptop (uses AWS_* and PARSER_MODEL from .env)
	@cd backend && $(LLM_ENV) uv run python -m app.ai.hello

parse: env ## Run the agenda parser locally: make parse TEXT="Пн 10:00, синк ..."
	@test -n "$(TEXT)" || (echo 'Usage: make parse TEXT="..."' && exit 1)
	@cd backend && $(LLM_ENV) uv run python -m app.ai.agenda "$(TEXT)"

deploy-auth: env ## Deploy Cognito (user pool + app client), print its settings and write them to .env
	@$(AWS_ENV) ./infra/deploy-auth.sh

deploy-backend: env ## Deploy backend (Lambda) + database (Aurora Serverless) to AWS, see infra/
	@$(AWS_ENV) ./infra/deploy-backend.sh

deploy-frontend: env ## Deploy frontend to S3 + CloudFront, wired to the Lambda URL (after deploy-backend)
	@$(AWS_ENV) ./infra/deploy-frontend.sh

add-domain: env ## Attach DOMAIN_NAME from .env to the deployed frontend
	@$(AWS_ENV) ./infra/add-domain.sh

remove-domain: env ## Detach the custom domain and delete its certificate
	@$(AWS_ENV) ./infra/remove-domain.sh

destroy-auth: env ## Delete the Cognito stack (the user pool and its accounts are kept)
	@$(AWS_ENV) ./infra/destroy-auth.sh

destroy-backend: env ## Delete the AWS backend stacks (keeps a final DB snapshot)
	@$(AWS_ENV) ./infra/destroy-backend.sh

destroy-frontend: env ## Delete the S3 bucket, CloudFront distribution and domain certificate
	@$(AWS_ENV) ./infra/destroy-frontend.sh

infra-lint: ## Lint the CloudFormation templates
	uvx cfn-lint infra/*.yaml infra/*.yml
