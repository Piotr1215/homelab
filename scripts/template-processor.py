#!/usr/bin/env python3
"""
Simple template processor for K8s resource templates
Supports {{VAR}}, {{VAR|default:value}}, {{#VAR}}...{{/VAR}}, and {{^VAR}}...{{/VAR}}
"""

import sys
import re
import os


def process_template(template_content, variables):
    """Process template with variable substitution and conditionals."""
    result = template_content

    # First pass: Process conditional blocks (multiple passes for nested conditionals)
    # Handle {{#VAR}}...{{/VAR}} (include if variable is set and non-empty)
    def replace_conditional(match):
        var_name = match.group(1)
        content = match.group(2)
        var_value = variables.get(var_name, "")
        return content if var_value else ""

    # Process conditionals multiple times for nested blocks
    for _ in range(3):  # Handle up to 3 levels of nesting
        result = re.sub(
            r'\{\{#(\w+)\}\}(.*?)\{\{/\1\}\}',
            replace_conditional,
            result,
            flags=re.DOTALL
        )

    # Handle {{^VAR}}...{{/VAR}} (include if variable is NOT set or empty)
    def replace_inverted_conditional(match):
        var_name = match.group(1)
        content = match.group(2)
        var_value = variables.get(var_name, "")
        return content if not var_value else ""

    for _ in range(3):  # Handle up to 3 levels of nesting
        result = re.sub(
            r'\{\{\^(\w+)\}\}(.*?)\{\{/\1\}\}',
            replace_inverted_conditional,
            result,
            flags=re.DOTALL
        )

    # Second pass: Replace variables with defaults
    # Handle {{VAR|default:value}}
    def replace_with_default(match):
        var_name = match.group(1)
        default_value = match.group(2)
        return variables.get(var_name, default_value)

    result = re.sub(
        r'\{\{(\w+)\|default:([^}]+)\}\}',
        replace_with_default,
        result
    )

    # Third pass: Replace simple variables
    # Handle {{VAR}}
    def replace_simple(match):
        var_name = match.group(1)
        return variables.get(var_name, "")

    result = re.sub(r'\{\{(\w+)\}\}', replace_simple, result)

    return result


def load_variables_from_env():
    """Load variables from environment (uppercase only)."""
    return {k: v for k, v in os.environ.items() if k.isupper()}


def main():
    if len(sys.argv) < 2:
        print("Usage: template-processor.py <template-file>", file=sys.stderr)
        sys.exit(1)

    template_file = sys.argv[1]

    try:
        with open(template_file, 'r') as f:
            template_content = f.read()
    except FileNotFoundError:
        print(f"Error: Template file not found: {template_file}", file=sys.stderr)
        sys.exit(1)

    variables = load_variables_from_env()
    result = process_template(template_content, variables)
    print(result, end='')


if __name__ == "__main__":
    main()
