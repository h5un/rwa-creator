.PHONY: install

install:
	@echo "Running install..."
	forge install smartcontractkit/chainlink-brownie-contracts --no-commit
	forge install OpenZeppelin/openzeppelin-contracts --no-commit