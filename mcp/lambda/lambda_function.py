import json
from typing import Any, Dict
import requests


def lambda_handler(event, context):
    """
    Generic Lambda handler for Bedrock AgentCore Gateway placeholder tool.

    Expected input:
        event: {
            # optional tool arguments
            "param_0": val0,
            "param_1": val1,
            ...
        }

    Context should contain:
        context.client_context.custom["bedrockAgentCoreToolName"]
        → e.g. "LambdaTarget___placeholder_tool"
    """
    try:
        extended_name = context.client_context.custom.get("bedrockAgentCoreToolName")
        tool_name = None

        # handle agentcore gateway tool naming convention
        # https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/gateway-tool-naming.html
        if extended_name and "___" in extended_name:
            tool_name = extended_name.split("___", 1)[1]

        if not tool_name:
            return _response(400, {"error": "Missing tool name"})

        # Canadian Mortgage Pre-Qualification Tools
        elif tool_name == "calculate_gds_tds":
            result = calculate_gds_tds(event)
            return _response(200, {"result": result})

        elif tool_name == "osfi_b20_stress_test":
            result = osfi_b20_stress_test(event)
            return _response(200, {"result": result})

        elif tool_name == "calculate_down_payment":
            result = calculate_down_payment(event)
            return _response(200, {"result": result})

        elif tool_name == "check_credit_threshold":
            result = check_credit_threshold(event)
            return _response(200, {"result": result})

        elif tool_name == "placeholder_tool":
            result = placeholder_tool(event)
            return _response(200, {"result": result})

        else:
            return _response(400, {"error": f"Unknown tool '{tool_name}'"})

    except Exception as e:
        return _response(500, {"system_error": str(e)})


def _response(status_code: int, body: Dict[str, Any]):
    """Consistent JSON response wrapper."""
    return {"statusCode": status_code, "body": json.dumps(body)}


def placeholder_tool(event: Dict[str, Any]):
    """
    no-op placeholder tool.

    Demonstrates argument passing from AgentCore Gateway.
    """
    return {
        "message": "Placeholder tool executed.",
        "string_param": event.get("string_param"),
        "int_param": event.get("int_param"),
        "float_array_param": event.get("float_array_param"),
        "event_args_received": event,
    }


################################################################################
# Canadian Mortgage Pre-Qualification Tools
################################################################################

def calculate_gds_tds(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Calculate GDS and TDS ratios for Canadian mortgage underwriting.

    GDS = (Mortgage Payment + Property Taxes + Heating + 50% Condo Fees) / Gross Income
    TDS = (GDS costs + Other Debts) / Gross Income

    CMHC limits: GDS ≤ 39%, TDS ≤ 44%
    """
    try:
        gross_income = float(event.get("gross_annual_income", 0))
        mortgage_payment = float(event.get("monthly_mortgage_payment", 0))
        property_taxes = float(event.get("monthly_property_taxes", 0))
        heating = float(event.get("monthly_heating", 0))
        condo_fees = float(event.get("monthly_condo_fees", 0))
        other_debts = float(event.get("monthly_other_debts", 0))

        if gross_income == 0:
            return {"error": "Gross annual income is required"}

        # Convert annual income to monthly
        monthly_income = gross_income / 12

        # Calculate GDS
        gds_costs = mortgage_payment + property_taxes + heating + (0.5 * condo_fees)
        gds_ratio = (gds_costs / monthly_income) * 100

        # Calculate TDS
        tds_costs = gds_costs + other_debts
        tds_ratio = (tds_costs / monthly_income) * 100

        # Check CMHC limits
        gds_pass = gds_ratio <= 39
        tds_pass = tds_ratio <= 44

        return {
            "gds_ratio": round(gds_ratio, 2),
            "tds_ratio": round(tds_ratio, 2),
            "gds_limit": 39,
            "tds_limit": 44,
            "gds_pass": gds_pass,
            "tds_pass": tds_pass,
            "overall_pass": gds_pass and tds_pass,
            "monthly_income": round(monthly_income, 2),
            "gds_costs": round(gds_costs, 2),
            "tds_costs": round(tds_costs, 2),
            "recommendation": "Approved - Debt ratios within CMHC limits" if (gds_pass and tds_pass) else "Denied - Debt ratios exceed CMHC limits"
        }
    except Exception as e:
        return {"error": f"GDS/TDS calculation failed: {str(e)}"}


def osfi_b20_stress_test(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Apply OSFI B-20 stress test to mortgage qualification.
    Borrower must qualify at the higher of:
    - Contract rate + 2%
    - 5.25% (minimum qualifying rate)
    """
    try:
        purchase_price = float(event.get("purchase_price", 0))
        down_payment = float(event.get("down_payment", 0))
        contract_rate = float(event.get("contract_interest_rate", 3.5))
        amortization = int(event.get("amortization_years", 25))

        if purchase_price == 0:
            return {"error": "Purchase price is required"}

        # Calculate loan amount
        loan_amount = purchase_price - down_payment

        # Determine qualifying rate
        stress_rate_1 = contract_rate + 2.0
        stress_rate_2 = 5.25
        qualifying_rate = max(stress_rate_1, stress_rate_2)

        # Calculate monthly payment at qualifying rate
        monthly_rate = qualifying_rate / 100 / 12
        num_payments = amortization * 12

        # Mortgage payment formula: P = L[c(1 + c)^n]/[(1 + c)^n - 1]
        if monthly_rate > 0:
            qualifying_payment = loan_amount * (
                monthly_rate * (1 + monthly_rate) ** num_payments
            ) / ((1 + monthly_rate) ** num_payments - 1)
        else:
            qualifying_payment = loan_amount / num_payments

        # Calculate actual payment at contract rate
        contract_monthly_rate = contract_rate / 100 / 12
        if contract_monthly_rate > 0:
            actual_payment = loan_amount * (
                contract_monthly_rate * (1 + contract_monthly_rate) ** num_payments
            ) / ((1 + contract_monthly_rate) ** num_payments - 1)
        else:
            actual_payment = loan_amount / num_payments

        return {
            "contract_rate": contract_rate,
            "qualifying_rate": qualifying_rate,
            "stress_test_applied": qualifying_rate > contract_rate,
            "qualifying_payment": round(qualifying_payment, 2),
            "actual_payment": round(actual_payment, 2),
            "additional_qualifying_amount": round(qualifying_payment - actual_payment, 2),
            "loan_amount": round(loan_amount, 2),
            "amortization_years": amortization,
            "message": f"Must qualify at {qualifying_rate}% per OSFI B-20 stress test (higher of contract rate + 2% or 5.25%)"
        }
    except Exception as e:
        return {"error": f"Stress test calculation failed: {str(e)}"}


def calculate_down_payment(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Calculate minimum down payment and CMHC insurance per Canadian rules.

    Rules:
    - <$500K: 5% minimum
    - $500K-$1M: 5% on first $500K, 10% on remainder
    - >$1M: 20% minimum (no CMHC insurance available)
    """
    try:
        purchase_price = float(event.get("purchase_price", 0))
        actual_down_payment = float(event.get("proposed_down_payment", 0))

        if purchase_price == 0:
            return {"error": "Purchase price is required"}

        # Calculate minimum down payment
        if purchase_price <= 500000:
            min_down_payment = purchase_price * 0.05
        elif purchase_price <= 1000000:
            min_down_payment = (500000 * 0.05) + ((purchase_price - 500000) * 0.10)
        else:
            min_down_payment = purchase_price * 0.20

        # Calculate down payment percentage
        down_payment_pct = (actual_down_payment / purchase_price) * 100

        # Check if CMHC insurance required
        cmhc_required = down_payment_pct < 20

        # Calculate CMHC insurance premium (if applicable)
        if cmhc_required and purchase_price < 1000000:
            # CMHC premium rates based on down payment percentage
            if down_payment_pct >= 20:
                cmhc_rate = 0
            elif down_payment_pct >= 15:
                cmhc_rate = 2.80
            elif down_payment_pct >= 10:
                cmhc_rate = 3.10
            elif down_payment_pct >= 5:
                cmhc_rate = 4.00
            else:
                cmhc_rate = 0  # Not eligible

            cmhc_premium = (purchase_price - actual_down_payment) * (cmhc_rate / 100)
        else:
            cmhc_premium = 0
            cmhc_rate = 0

        # Check if down payment is sufficient
        sufficient = actual_down_payment >= min_down_payment

        return {
            "purchase_price": round(purchase_price, 2),
            "min_down_payment": round(min_down_payment, 2),
            "actual_down_payment": round(actual_down_payment, 2),
            "down_payment_pct": round(down_payment_pct, 2),
            "sufficient": sufficient,
            "cmhc_insurance_required": cmhc_required,
            "cmhc_premium": round(cmhc_premium, 2),
            "cmhc_rate_pct": cmhc_rate,
            "total_loan_amount": round((purchase_price - actual_down_payment) + cmhc_premium, 2),
            "shortfall": round(max(0, min_down_payment - actual_down_payment), 2),
            "recommendation": "Approved - Down payment sufficient" if sufficient else f"Need ${round(min_down_payment - actual_down_payment, 2):,.2f} more for minimum down payment"
        }
    except Exception as e:
        return {"error": f"Down payment calculation failed: {str(e)}"}


def check_credit_threshold(event: Dict[str, Any]) -> Dict[str, Any]:
    """
    Check if credit score meets CMHC minimum requirements.

    CMHC insured mortgages (< 20% down): 600+ credit score
    Conventional mortgages (≥ 20% down): 650+ credit score
    """
    try:
        credit_score = int(event.get("credit_score", 0))
        down_payment_pct = float(event.get("down_payment_percentage", 5))

        if credit_score == 0:
            return {"error": "Credit score is required"}

        # Determine minimum score based on mortgage type
        if down_payment_pct >= 20:
            min_score = 650  # Conventional mortgage
            mortgage_type = "Conventional"
        else:
            min_score = 600  # CMHC insured
            mortgage_type = "CMHC Insured"

        approved = credit_score >= min_score

        # Credit score categories
        if credit_score >= 800:
            category = "Excellent"
        elif credit_score >= 720:
            category = "Very Good"
        elif credit_score >= 650:
            category = "Good"
        elif credit_score >= 600:
            category = "Fair"
        else:
            category = "Poor"

        return {
            "credit_score": credit_score,
            "category": category,
            "min_required_score": min_score,
            "mortgage_type": mortgage_type,
            "approved": approved,
            "points_above_minimum": credit_score - min_score,
            "recommendation": "Approved - Credit score meets requirements" if approved else f"Denied - Credit score too low (need {min_score}+ for {mortgage_type} mortgage)"
        }
    except Exception as e:
        return {"error": f"Credit check failed: {str(e)}"}