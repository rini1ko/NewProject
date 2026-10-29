"""`make llm-hello`: the first call to Claude on Bedrock, from your laptop."""

from app.config import settings

QUESTION = "In one sentence: what is an ISO week?"

if settings.parser_api == "converse":
    import boto3

    client = boto3.client("bedrock-runtime", region_name=settings.bedrock_region)
    response = client.converse(
        modelId=settings.parser_model,
        messages=[{"role": "user", "content": [{"text": QUESTION}]}],
        inferenceConfig={"maxTokens": 300},
    )
    print(response["output"]["message"]["content"][0]["text"])
    print(response["stopReason"], response["usage"]["inputTokens"], response["usage"]["outputTokens"])
else:
    from anthropic import AnthropicBedrockMantle

    client = AnthropicBedrockMantle(aws_region=settings.bedrock_region)
    msg = client.messages.create(
        model=settings.parser_model,
        max_tokens=1024,
        output_config={"effort": "low"},  # short, cheap answers
        messages=[{"role": "user", "content": QUESTION}],
    )
    print(next(b.text for b in msg.content if b.type == "text"))
    print(msg.stop_reason, msg.usage.input_tokens, msg.usage.output_tokens)
