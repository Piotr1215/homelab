.PHONY: build
build:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -o webhook cmd/webhook/main.go

.PHONY: docker-build
docker-build:
	docker build -t harbor.homelab.local/library/httproute-webhook:0.1.0 .

.PHONY: docker-push
docker-push:
	docker push harbor.homelab.local/library/httproute-webhook:0.1.0

.PHONY: harbor-login
harbor-login:
	@echo "Login to Harbor:"
	docker login harbor.homelab.local

.PHONY: deploy
deploy:
	helm upgrade --install httproute-webhook deploy/helm/httproute-webhook \
		--namespace httproute-webhook \
		--create-namespace

.PHONY: tidy
tidy:
	go mod tidy

.PHONY: fmt
fmt:
	go fmt ./...

.PHONY: vet
vet:
	go vet ./...
