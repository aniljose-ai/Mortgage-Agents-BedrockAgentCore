# AWS Bedrock AgentCore: Mortgage Pre-Qualification System

Production-ready mortgage pre-qualification system demonstrating AWS Bedrock AgentCore deployment with multi-agent architecture and CMHC/OSFI B-20 compliance.

## Overview

This project implements a Canadian mortgage pre-qualification system using AWS Bedrock AgentCore services. The system automates mortgage application evaluation using AI agents with built-in compliance for Canadian regulatory requirements.

## Screenshots

### AgentCore Console - Agent in Action
![Mortgage Pre-Approval Agent in Action](Screenshot_Mortgage_Pre-approval_agentCore.png)

*Agent successfully processing mortgage pre-qualification request with tool invocations and memory integration*

### Agent Runtime Invocation Examples

![Agent Runtime Invoke Example 1](Screenshot-agent-runtime-invoke-1.png)

*Demonstrating agent runtime invocation with tool calling and response generation*

![Agent Runtime Invoke Example 2](Screenshot-agent-runtime-invoke-2.png)

*Multi-tool workflow showing complex mortgage qualification analysis*

## Architecture

### Core Components

**AgentCore Runtime**
- Serverless agent execution with Claude Sonnet 4.5
- Consumption-based pricing model
- Auto-scaling support
- Session isolation

**AgentCore Gateway**
- MCP protocol implementation
- Single Lambda function with routing pattern (6 tool handlers)
- Cognito JWT authentication
- Tool schema validation

**AgentCore Memory**
- 30-day event persistence
- Multi-turn conversation support
- Session-based storage
- Configurable retrieval (top_k, relevance)

**Custom Lambda Tools**
- GDS/TDS ratio calculator
- OSFI B-20 stress test implementation
- Down payment calculator
- Credit threshold validation
- Math tool (extensibility demo)
- Code interpreter (extensibility demo)

### Lambda Architecture
Single Lambda function (`mcp/lambda/lambda_function.py`) implements multiple tool handlers using a routing pattern. The Gateway passes the tool name via context, and the Lambda dispatches to the appropriate handler function. This minimizes infrastructure while maintaining clear tool separation for the AI agent.

## Technology Stack

- **Infrastructure**: Terraform (IaC)
- **Runtime**: AWS Bedrock AgentCore
- **Models**: Claude Sonnet 4.5 (Global Inference Profile)
- **Authentication**: AWS Cognito (OAuth2 client credentials)
- **Tools**: AWS Lambda (Python 3.12) - Single function, multiple handlers
- **Agent Framework**: Strands Agents SDK
- **Containerization**: Docker + ECR
- **Build Automation**: AWS CodeBuild

## Compliance Implementation

### CMHC Guidelines
- Gross Debt Service (GDS) ratio: ≤ 39%
- Total Debt Service (TDS) ratio: ≤ 44%
- Down payment requirements by price tier
- CMHC insurance premium calculations

### OSFI B-20 Stress Testing
- Qualifying rate: Higher of (contract rate + 2%) or 5.25%
- Stress test applied to all mortgage applications
- Payment calculations at qualifying rate

## Deployment

### Prerequisites
- AWS Account with Bedrock access
- Terraform >= 1.2
- Docker
- AWS CLI configured

### Quick Start
```bash
# Clone repository
git clone https://github.com/aniljose-ai/Mortgage-Agents-BedrockAgentCore.git
cd Mortgage-Agents-BedrockAgentCore

# Configure Terraform variables
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your settings

# Configure AgentCore
cd ..
cp .bedrock_agentcore.yaml.example .bedrock_agentcore.yaml
# Update with your local paths

# Deploy infrastructure
cd terraform
terraform init
terraform apply

# Test deployment
agentcore invoke '{"prompt": "what can you do?"}'
```

## Infrastructure

### Resources Created
- AgentCore Runtime (mortgageAgents_Agent)
- AgentCore Gateway (MCP protocol)
- AgentCore Memory (30-day retention)
- ECR Repository (container images)
- Single Lambda Function (6 MCP tool handlers)
- Gateway Targets (4 mortgage tools + 2 general tools)
- Cognito User Pool (authentication)
- CloudWatch Log Groups (observability)
- CodeBuild Project (automated Docker builds)

### Cost Optimization
- Consumption-based Runtime pricing
- Pay-per-use Lambda execution
- Single Lambda for multiple tools (minimizes infrastructure)
- Minimal idle costs
- Auto-scaling based on demand

## Usage Examples

### Simple Invocation
```bash
agentcore invoke '{"prompt": "what can you do?"}'
```

### Mortgage Pre-Qualification
```bash
agentcore invoke '{
  "prompt": "I make $85,000/year with a credit score of 680. Can I get pre-approved for a $650,000 condo with $50,000 down payment? Monthly housing costs are $2,500, other debts are $450/month, 5.0% interest rate, 25-year amortization."
}'
```

### Math Tool Example
```bash
agentcore invoke '{"prompt": "Calculate the square root of 144 and then multiply it by 25"}'
```

### Code Interpreter Example
```bash
agentcore invoke '{"prompt": "Use Python to calculate the compound interest on $10,000 at 5% annual rate over 10 years"}'
```

### Multi-Turn Conversation (Memory)
```bash
agentcore invoke '{"prompt": "My name is John and my income is $100,000"}'
agentcore invoke '{"prompt": "What is my name and income?"}'
```

## Project Structure
```
.
├── src/                    # Runtime agent code
│   ├── main.py            # AgentCore entrypoint
│   ├── mcp_client/        # Gateway MCP client
│   └── model/             # Bedrock model configuration
├── mcp/                   # Lambda MCP tools
│   └── lambda/
│       ├── lambda_function.py  # Single Lambda with routing
│       └── requirements.txt    # Dependencies
├── terraform/             # Infrastructure as Code
│   ├── main.tf           # Provider configuration
│   ├── bedrock_agentcore.tf  # AgentCore resources
│   ├── variables.tf      # Variable definitions
│   ├── outputs.tf        # Output values
│   ├── terraform.tfvars.example  # Example configuration
│   └── scripts/
│       └── build-image.sh # CodeBuild trigger script
├── .bedrock_agentcore.yaml.example  # AgentCore CLI config
├── Dockerfile            # Container definition
├── buildspec.yml         # CodeBuild specification
└── README.md            # Documentation
```

## Observability

### CloudWatch Logs
- Runtime execution logs: `/aws/bedrock-agentcore/runtimes/mortgageAgents_Agent`
- Lambda tool logs: `/aws/lambda/mortgageAgents-McpLambda`
- CodeBuild logs: `/aws/codebuild/mortgageAgents-agent-build`

### Metrics
- Invocation count
- Token usage
- Latency measurements
- Error rates

## Development Notes

### Local Testing
Use the included `test_simple.py` script for testing:
```bash
# Update runtime ARN in test_simple.py
python test_simple.py
```

### Extending Tools
1. Add new handler function in `mcp/lambda/lambda_function.py`
2. Add tool routing logic in `lambda_handler`
3. Create new Gateway target in `terraform/bedrock_agentcore.tf` pointing to same Lambda
4. Define tool schema in Gateway target configuration
5. Run `terraform apply`

### Memory Configuration
Adjust retrieval settings in `src/main.py` for different use cases:
- `top_k`: Number of memories to retrieve
- `relevance_threshold`: Minimum relevance score

### Agent System Prompt
The agent system prompt is configured in `src/main.py`. Modify to adjust agent behavior, role, or capabilities.

## Production Checklist

- [x] Security: Secrets managed via AWS Cognito (client credentials flow)
- [x] Build Environment: CodeBuild configured for automated Docker builds
- [x] Memory: 30-day event retention configured
- [ ] Observability: Enable AgentCore observability for CloudWatch metrics
- [ ] CI/CD: Integrate with AWS CodePipeline for automated deployments
- [ ] Access Control: Configure access policies for production endpoints
- [ ] Testing: Add comprehensive unit and E2E tests
- [ ] Error Handling: Implement graceful error handling throughout

## Technical Learnings

This project demonstrates:
- Production AgentCore deployment patterns
- MCP protocol implementation with single Lambda routing
- Multi-agent system architecture
- Compliance automation for regulated industries
- Infrastructure as Code best practices
- Serverless agent scaling
- Efficient tool handler pattern (6 tools in 1 Lambda)

## Key Architectural Decisions

**Single Lambda Pattern**: One Lambda function handles all tools using routing logic. This approach:
- Minimizes infrastructure costs
- Simplifies deployment and maintenance
- Maintains clear tool separation for AI agents
- Reduces cold start overhead
- Centralizes business logic

**Gateway Targets**: Multiple Gateway targets point to the same Lambda, each defining a different tool schema. The Lambda routes based on tool name from context.

## License

This project was generated using the AWS Bedrock AgentCore CLI tool.

## Support

For issues or questions:
- AWS Bedrock AgentCore Documentation: https://docs.aws.amazon.com/bedrock-agentcore/
- Create an issue in this repository

## References

- [AWS Bedrock AgentCore Documentation](https://docs.aws.amazon.com/bedrock-agentcore/)
- [Model Context Protocol (MCP)](https://modelcontextprotocol.io/)
- [CMHC Mortgage Guidelines](https://www.cmhc-schl.gc.ca/)
- [OSFI B-20 Guidelines](https://www.osfi-bsif.gc.ca/)
