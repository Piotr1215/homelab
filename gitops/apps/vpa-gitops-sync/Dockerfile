FROM flant/shell-operator:latest

# Install yq for YAML manipulation
RUN apk add --no-cache yq git

COPY --chmod=755 hooks /hooks
