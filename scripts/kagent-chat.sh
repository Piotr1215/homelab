#!/bin/bash
# Simple script to interact with KAgent k8s-agent via Ollama

# Use the Kubernetes Ollama service via port-forward
# Make sure port-forward is running: kubectl port-forward -n ollama service/ollama 11434:11434
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"

# To verify we're using the K8s Ollama, check if port-forward is active
if ! pgrep -f "port-forward.*ollama" > /dev/null; then
    echo "Warning: Ollama port-forward not detected. Starting it now..."
    kubectl port-forward -n ollama service/ollama 11434:11434 > /dev/null 2>&1 &
    sleep 2
fi
MODEL="llama3.2:1b"

echo "KAgent K8s Assistant (powered by Ollama llama3.2:1b)"
echo "Type 'exit' to quit"
echo "----------------------------------------"

while true; do
    echo -n "You: "
    read -r prompt
    
    if [[ "$prompt" == "exit" ]]; then
        echo "Goodbye!"
        break
    fi
    
    # Add K8s context to the prompt
    full_prompt="You are a Kubernetes expert assistant. Please help with this request: $prompt"
    
    echo -n "Assistant: "
    curl -s "$OLLAMA_HOST/api/generate" \
        -d "{\"model\": \"$MODEL\", \"prompt\": \"$full_prompt\", \"stream\": false}" \
        | jq -r '.response // "Error: Could not get response"'
    echo
done