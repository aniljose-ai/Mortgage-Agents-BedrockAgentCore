import os
from strands import Agent, tool
from strands_tools.code_interpreter import AgentCoreCodeInterpreter
from bedrock_agentcore import BedrockAgentCoreApp
from bedrock_agentcore.memory.integrations.strands.config import AgentCoreMemoryConfig, RetrievalConfig
from bedrock_agentcore.memory.integrations.strands.session_manager import AgentCoreMemorySessionManager
from .mcp_client.client import get_streamable_http_mcp_client
from .model.load import load_model

MEMORY_ID = os.getenv("BEDROCK_AGENTCORE_MEMORY_ID")
REGION = os.getenv("AWS_REGION")

if os.getenv("LOCAL_DEV") == "1":
    # In local dev, instantiate dummy MCP client so the code runs without deploying
    #Import current Lambda function as dummy MCP client

    from contextlib import nullcontext
    from types import SimpleNamespace
    strands_mcp_client = nullcontext(SimpleNamespace(list_tools_sync=lambda: []))
else:
    # Import AgentCore Gateway as Streamable HTTP MCP Client
    strands_mcp_client = get_streamable_http_mcp_client()

# Define a simple function tool
@tool
def add_numbers(a: int, b: int) -> int:
    """Return the sum of two numbers"""
    return a+b

# Integrate with Bedrock AgentCore
app = BedrockAgentCoreApp()
log = app.logger

@app.entrypoint
async def invoke(payload, context):
    # Extract session_id from context (auto-managed by BedrockAgentCore)
    session_id = getattr(context, 'session_id', 'default')

    # Extract user_id from payload, or use default
    user_id = payload.get('user_id', 'default-user')

    log.info(f"Processing request for user: {user_id}, session: {session_id}")

    # Configure memory if available
    session_manager = None
    if MEMORY_ID:
        session_manager = AgentCoreMemorySessionManager(
            AgentCoreMemoryConfig(
                memory_id=MEMORY_ID,
                session_id=session_id,
                actor_id=user_id,  # Dynamic user ID
                retrieval_config={
                    f"/users/{user_id}/facts": RetrievalConfig(top_k=3, relevance_score=0.5),
                    f"/users/{user_id}/preferences": RetrievalConfig(top_k=3, relevance_score=0.5)
                }
            ),
            REGION
        )
        log.info(f"Memory enabled for user: {user_id}, session: {session_id}")
    else:
        log.warning("MEMORY_ID is not set. Skipping memory session manager initialization.")


    # Create code interpreter
    code_interpreter = AgentCoreCodeInterpreter(
        region=REGION,
        session_name=session_id,
        auto_create=True,
        persist_sessions=True
    )

    with strands_mcp_client as client:
        # Get MCP Tools
        tools = client.list_tools_sync()

        # Create agent
        agent = Agent(
            model=load_model(),
            session_manager=session_manager,
            system_prompt="""
                You are a Canadian mortgage pre-qualification specialist with expertise in CMHC guidelines and OSFI regulations.

                **IMPORTANT - Memory & Session Continuity:**
                - You have access to conversation memory across sessions with the same user
                - Remember user details (income, credit score, property info) from previous conversations
                - Reference past qualification attempts when relevant
                - If a user returns, acknowledge their previous interaction
                - Track changes in their financial situation over time

                Your role is to help applicants understand if they qualify for a Canadian mortgage by:

                1. **CMHC Guidelines** (Canada Mortgage and Housing Corporation):
                   - GDS ratio ≤ 39% (Gross Debt Service: housing costs / income)
                   - TDS ratio ≤ 44% (Total Debt Service: all debts / income)
                   - Minimum credit scores: 600+ for CMHC insured, 650+ for conventional

                2. **OSFI B-20 Regulations** (Office of the Superintendent of Financial Institutions):
                   - Stress test: Qualify at higher of (contract rate + 2%) or 5.25%
                   - Applies to all mortgages since June 2021

                3. **Down Payment Rules**:
                   - <$500K: 5% minimum
                   - $500K-$1M: 5% on first $500K, 10% on remainder
                   - >$1M: 20% minimum (no CMHC insurance available)

                4. **CMHC Insurance Premiums** (when down payment < 20%):
                   - 5-9.99% down: 4.00% premium
                   - 10-14.99% down: 3.10% premium
                   - 15-19.99% down: 2.80% premium

                **Available Tools:**
                - calculate_gds_tds: Calculate debt service ratios
                - osfi_b20_stress_test: Apply OSFI B-20 stress test
                - calculate_down_payment: Check down payment and CMHC insurance
                - check_credit_threshold: Verify credit score eligibility
                - code_interpreter: For complex calculations
                - add_numbers: For simple arithmetic

                **Process:**
                1. Check if this is a returning user and reference their previous interactions
                2. Gather all required information from the user
                3. Use ALL relevant tools to evaluate their application
                4. Provide clear APPROVED or DENIED decision with specific ratios
                5. If denied, explain exactly why and what needs to improve
                6. If approved, summarize the qualification details

                Always be professional, accurate, and cite specific Canadian regulations.
                Show your calculations and reasoning clearly.
            """,
            tools=[code_interpreter.code_interpreter, add_numbers] + tools
        )

        # ========================================================================
        # DEMO MODE: Set DEMO_MODE=1 in environment to disable streaming
        # This makes it easier to capture full responses for screenshots/demos
        # ========================================================================
        DEMO_MODE = os.getenv("DEMO_MODE", "0") == "1"

        if DEMO_MODE:
            # NON-STREAMING MODE (Better for demos/screenshots)
            # Returns complete response in one message
            log.info("Running in DEMO MODE (non-streaming)")
            response = agent(payload.get("prompt"))

            # Extract the full text response
            if hasattr(response, 'message') and 'content' in response.message:
                # Yield the complete response as a single chunk
                yield response.message['content'][0]['text']
            else:
                yield str(response)

        else:
            # STREAMING MODE (Production - shows real-time progress)
            log.info("Running in STREAMING MODE")
            stream = agent.stream_async(payload.get("prompt"))

            async for event in stream:
                # Handle Text parts of the response
                if "data" in event and isinstance(event["data"], str):
                    yield event["data"]

                # Implement additional handling for other events
                # if "toolUse" in event:
                #   # Process toolUse

                # Handle end of stream
                # if "result" in event:
                #    yield(format_response(event["result"]))

def format_response(result) -> str:
    """Extract code from metrics and format with LLM response."""
    parts = []

    # Extract executed code from metrics
    try:
        tool_metrics = result.metrics.tool_metrics.get('code_interpreter')
        if tool_metrics and hasattr(tool_metrics, 'tool'):
            action = tool_metrics.tool['input']['code_interpreter_input']['action']
            if 'code' in action:
                parts.append(f"## Executed Code:\n```{action.get('language', 'python')}\n{action['code']}\n```\n---\n")
    except (AttributeError, KeyError):
        pass  # No code to extract

    # Add LLM response
    parts.append(f"## 📊 Result:\n{str(result)}")
    return "\n".join(parts)

if __name__ == "__main__":
    app.run()