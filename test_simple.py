#!/usr/bin/env python3
"""
Simple example demonstrating AWS Bedrock AgentCore agent invocation with memory
This script shows how to invoke an agent and maintain conversation context across prompts.
"""

import boto3
import json
import uuid
import time

# Configuration - Update these with your values
REGION = "YOUR AWS_REGION"
RUNTIME_ARN = "arn:aws:bedrock-agentcore:us-east-1:YOUR_ACCOUNT:runtime/YOUR_AGENT_NAME"
ENDPOINT_NAME = "DEV"  # or "PROD"
USER_ID = "john_doe"

# Initialize client
client = boto3.client('bedrock-agentcore', region_name=REGION)

# Session ID (same for all prompts to test memory)
SESSION_ID = str(uuid.uuid4())

print("\n" + "="*80)
print(f"AWS Bedrock AgentCore - Simple Example")
print(f"Session ID: {SESSION_ID}")
print(f"User ID: {USER_ID}")
print("="*80 + "\n")


def send_prompt(prompt_number, prompt_text):
    """Send a prompt to the agent and print the response"""

    print(f"\n{'='*80}")
    print(f"PROMPT {prompt_number}: {prompt_text}")
    print(f"{'='*80}\n")

    try:
        # Prepare payload
        payload = json.dumps({
            'prompt': prompt_text,
            'user_id': USER_ID
        })

        # Invoke the agent
        response = client.invoke_agent_runtime(
            agentRuntimeArn=RUNTIME_ARN,
            qualifier=ENDPOINT_NAME,
            runtimeSessionId=SESSION_ID,
            runtimeUserId=USER_ID,
            payload=payload,
            contentType='application/json'
        )

        print(f"Response received")

        # Parse response
        if 'response' in response:
            response_stream = response['response']
            full_response = ""

            print("AGENT RESPONSE:")
            print("-" * 80)

            # Read the response stream
            try:
                for event in response_stream:
                    # Handle different event types
                    if isinstance(event, dict):
                        if 'chunk' in event:
                            chunk = event['chunk']
                            if 'bytes' in chunk:
                                text = chunk['bytes'].decode('utf-8')
                                full_response += text
                                print(text, end='', flush=True)
                        elif 'bytes' in event:
                            text = event['bytes'].decode('utf-8')
                            full_response += text
                            print(text, end='', flush=True)
                    elif isinstance(event, bytes):
                        text = event.decode('utf-8')
                        full_response += text
                        print(text, end='', flush=True)
            except Exception as stream_error:
                print(f"\nStream parsing error: {stream_error}")
                try:
                    data = response_stream.read()
                    if isinstance(data, bytes):
                        full_response = data.decode('utf-8')
                        print(full_response)
                except Exception as read_error:
                    print(f"Could not read stream: {read_error}")

            print("\n" + "-" * 80)
            print(f"Total response length: {len(full_response)} characters\n")
            return full_response

        else:
            print(f"No 'response' in response object")
            print(f"Available keys: {list(response.keys())}")
            return None

    except Exception as e:
        print(f"ERROR: {type(e).__name__}: {e}")
        return None


# =============================================================================
# SAMPLE TEST PROMPTS - Demonstrating memory across conversation
# =============================================================================

# Prompt 1: Provide user information
send_prompt(
    1,
    "Hi, my name is John. I make $85,000 per year and my credit score is 680."
)

print("\nWaiting 2 seconds...\n")
time.sleep(2)

# Prompt 2: Test memory recall - credit score
send_prompt(
    2,
    "What is my credit score?"
)

print("\nWaiting 2 seconds...\n")
time.sleep(2)

# Prompt 3: Test memory recall - income
send_prompt(
    3,
    "What is my annual income?"
)

print("\nWaiting 2 seconds...\n")
time.sleep(2)

# Prompt 4: Test memory recall - name
send_prompt(
    4,
    "What is my name?"
)

# Prompt 5: Invoke tool call
send_prompt(
    4,
    "I'm applying to buy a condo for $650,000. I have down payment $50,000, monthly housing costs $2,500, other monthly debts $450, contract rate 5.0%, 25-year amortization. Please check if I qualify."
)

print("\n\n" + "="*80)
print("TEST COMPLETE")
print("="*80)
print("\nIf the agent remembered the credit score, income, and name from Prompt 1,")
print("then the memory integration is working correctly.\n")
