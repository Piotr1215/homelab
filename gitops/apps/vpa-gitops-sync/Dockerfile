FROM flant/shell-operator:latest

# Install tools for YAML/JSON manipulation and git
RUN apk add --no-cache yq jq git

COPY --chmod=755 hooks /hooks
