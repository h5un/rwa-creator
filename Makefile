.PHONY: install

install:
	@echo "Running install..."
	forge install smartcontractkit/chainlink-brownie-contracts --no-commit
	forge install OpenZeppelin/openzeppelin-contracts --no-commit

install-deno:
	curl -fsSL https://deno.land/install.sh | sh

install-toolkit:
	npm i @chainlink/functions-toolkit
