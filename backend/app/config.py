from typing import Annotated

from pydantic import field_validator
from pydantic_settings import BaseSettings, NoDecode, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    database_url: str = "postgresql+asyncpg://meetings:meetings@localhost:5432/meetings"
    # Lambda serves one request per instance at a time, so it runs with a pool of 1.
    db_pool_size: int = 5
    db_max_overflow: int = 10
    # Cognito user pool and app client whose ID tokens the API accepts (make deploy-auth).
    cognito_user_pool_id: str = ""
    cognito_client_id: str = ""
    # The pool's jwks.json. Set on AWS, where the function has no internet access; locally the
    # keys are downloaded on first use.
    cognito_jwks: str = ""
    # LLM agenda parser (app/ai). The model ID is configuration, never code.
    parser_model: str = "anthropic.claude-opus-5-5"
    # "messages" = Anthropic Messages API on Bedrock (bedrock-mantle, current Claude models);
    # "converse" = Converse API (bedrock-runtime): works with any Bedrock model your account can use.
    parser_api: str = "messages"
    parser_effort: str = "low"  # low | medium | high: how hard the model thinks (billed as output)
    bedrock_region: str = "us-east-1"

    cors_origins: Annotated[list[str], NoDecode] = [
        "http://localhost:5173",
        "http://localhost:3000",
    ]

    @field_validator("cors_origins", mode="before")
    @classmethod
    def split_origins(cls, value: object) -> object:
        if isinstance(value, str):
            return [origin.strip() for origin in value.split(",") if origin.strip()]
        return value


settings = Settings()
