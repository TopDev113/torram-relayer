DOCKER = $(shell which docker)
MOCKS_DIR=$(CURDIR)/testutil/mocks
MOCKGEN_REPO=github.com/golang/mock/mockgen
MOCKGEN_VERSION=v1.6.0
MOCKGEN_CMD=go run ${MOCKGEN_REPO}@${MOCKGEN_VERSION}
BUILDDIR ?= $(CURDIR)/build

#### PATH customization ####
BABYLON_PATH = /mnt/e/09_Product/vigilante-main/babylon
VIGILANTE_PATH = ./vigilant
TESTNET_PATH = ./test
BABYLON_PKG := github.com/babylonlabs-io/babylon/cmd/babylond
####
GO_BIN := ${GOPATH}/bin

ldflags := $(LDFLAGS)
build_tags := $(BUILD_TAGS)
build_args := $(BUILD_ARGS)

PACKAGES_E2E=$(shell go list ./... | grep '/e2e')

ifeq ($(LINK_STATICALLY),true)
	ldflags += -linkmode=external -extldflags "-Wl,-z,muldefs -static" -v
endif

ifeq ($(VERBOSE),true)
	build_args += -v
endif

BUILD_TARGETS := build install
BUILD_FLAGS := --tags "$(build_tags)" --ldflags '$(ldflags)'

# Update changelog vars
ifneq (,$(SINCE_TAG))
       sinceTag := --since-tag $(SINCE_TAG)
endif
ifneq (,$(UPCOMING_TAG))
       upcomingTag := --future-release $(UPCOMING_TAG)
endif

all: build install

build: BUILD_ARGS := $(build_args) -o $(BUILDDIR)

$(BUILD_TARGETS): go.sum $(BUILDDIR)/
	go $@ -mod=readonly $(BUILD_FLAGS) $(BUILD_ARGS) ./...

$(BUILDDIR)/:
	mkdir -p $(BUILDDIR)/

test:
	go test -race ./...

test-e2e:
	go test -mod=readonly -failfast -timeout=15m -v $(PACKAGES_E2E) -count=1 --parallel 12 --tags=e2e

build-docker:
	$(DOCKER) build --tag babylonlabs-io/vigilante -f Dockerfile \
		$(shell git rev-parse --show-toplevel)

rm-docker:
	$(DOCKER) rmi babylonlabs-io/vigilante 2>/dev/null; true

mocks:
	mkdir -p $(MOCKS_DIR)
	$(MOCKGEN_CMD) -source=btcclient/interface.go -package mocks -destination $(MOCKS_DIR)/btcclient.go
	$(MOCKGEN_CMD) -source=submitter/poller/expected_babylon_client.go -package poller -destination submitter/poller/mock_babylon_client.go
	$(MOCKGEN_CMD) -source=submitter/expected_babylon_client.go -package submitter -destination submitter/mock_babylon_client.go
	$(MOCKGEN_CMD) -source=reporter/expected_babylon_client.go -package reporter -destination reporter/mock_babylon_client.go
	$(MOCKGEN_CMD) -source=monitor/expected_babylon_client.go -package monitor -destination monitor/mock_babylon_client.go
	$(MOCKGEN_CMD) -source=btcstaking-tracker/btcslasher/expected_babylon_client.go -package btcslasher -destination btcstaking-tracker/btcslasher/mock_babylon_client.go
	$(MOCKGEN_CMD) -source=btcstaking-tracker/atomicslasher/expected_babylon_client.go -package atomicslasher -destination btcstaking-tracker/atomicslasher/mock_babylon_client.go
	$(MOCKGEN_CMD) -source=btcstaking-tracker/stakingeventwatcher/expected_babylon_client.go -package stakingeventwatcher -destination btcstaking-tracker/stakingeventwatcher/mock_babylon_client.go

update-changelog:
	@echo ./scripts/update_changelog.sh $(sinceTag) $(upcomingTag)
	./scripts/update_changelog.sh $(sinceTag) $(upcomingTag)

.PHONY: build test test-e2e build-docker rm-docker mocks update-changelog

proto-gen:
	@$(call print, "Compiling protos.")
	cd ./proto; ./gen_protos_docker.sh

.PHONY: proto-gen

############### our customized command ############
babylond-make:
	$(BABYLON_PATH)/build/babylond testnet \
    --v                     1 \
    --output-dir            $(TESTNET_PATH) \
    --starting-ip-address   192.168.10.2 \
    --keyring-backend       test \
    --chain-id              chain-test

babylond-start:
	$(BABYLON_PATH)/build/babylond start --home $(TESTNET_PATH)/node0/babylond
	
bitcoin-start:
	bitcoind -regtest \
			-txindex \
			-rpcuser=davis \
			-rpcpassword=aaa \
			-rpcbind=0.0.0.0:18443 \
			-datadir=/mnt/e/bitcoin-27.0 \
        	-zmqpubrawblock=tcp://0.0.0.0:28332 \
    		-zmqpubrawtx=tcp://0.0.0.0:28333 \
    		-zmqpubsequence=tcp://0.0.0.0:28334

wallet-start:
	bitcoin-cli -regtest \
		-rpcuser=davis \
		-rpcpassword=aaa \
		-named createwallet \
		wallet_name="torram" \
		passphrase="torram" \
		load_on_startup=true \
		descriptors=true

btc-create:
	bitcoin-cli -regtest \
    -rpcuser=davis \
    -rpcpassword=aaa \
    getnewaddress

blocks-create:
	bitcoin-cli -regtest \
      -rpcuser=davis\
      -rpcpassword=aaa \
      -generate 100

vigilante-reporter:
	go run ./cmd/vigilante/main.go reporter \
         --config ./vigilante.yml \
         --babylon-key-dir $(TESTNET_PATH)/node0/babylond

	go run ./cmd/vigilante/main.go submitter \
         --config ./vigilante.yml

vigilante-monitor:
	go run ./cmd/vigilante/main.go monitor \
         --genesis $(TESTNET_PATH)/node0/babylond/config/genesis.json \
         --config ./vigilante.yml

vigilante-tracker:
	go run ./cmd/vigilante/main.go bstracker \
         --config ./vigilante.yml


############	Torram		############



###############################################################################
###                                Gosec                                    ###
###############################################################################

gosec-local: ## Run local security checks
	gosec -exclude-generated -exclude-dir=$(CURDIR)/testutil -exclude-dir=$(CURDIR)/e2etest $(CURDIR)/...

.PHONY: gosec-local

###############################################################################
###                                Release                                  ###
###############################################################################

# The below is adapted from https://github.com/osmosis-labs/osmosis/blob/main/Makefile
GO_VERSION := $(shell grep -E '^go [0-9]+\.[0-9]+' go.mod | awk '{print $$2}')
GORELEASER_IMAGE := ghcr.io/goreleaser/goreleaser-cross:v$(GO_VERSION)
COSMWASM_VERSION := $(shell grep github.com/CosmWasm/wasmvm go.mod | cut -d' ' -f2)

.PHONY: release-dry-run release-snapshot release
release-dry-run:
	docker run \
		--rm \
		-e COSMWASM_VERSION=$(COSMWASM_VERSION) \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v `pwd`:/go/src/babylon \
		-w /go/src/babylon \
		$(GORELEASER_IMAGE) \
		release \
		--clean \
		--skip=publish

release-snapshot:
	docker run \
		--rm \
		-e COSMWASM_VERSION=$(COSMWASM_VERSION) \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v `pwd`:/go/src/babylon \
		-w /go/src/babylon \
		$(GORELEASER_IMAGE) \
		release \
		--clean \
		--snapshot \
		--skip=publish,validate \
		--verbose

# NOTE: By default, the CI will handle the release process.
# this is for manually releasing.
ifdef GITHUB_TOKEN
release:
	docker run \
		--rm \
		-e GITHUB_TOKEN=$(GITHUB_TOKEN) \
		-e COSMWASM_VERSION=$(COSMWASM_VERSION) \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v `pwd`:/go/src/babylon \
		-w /go/src/babylon \
		$(GORELEASER_IMAGE) \
		release \
		--clean
else
release:
	@echo "Error: GITHUB_TOKEN is not defined. Please define it before running 'make release'."
endif