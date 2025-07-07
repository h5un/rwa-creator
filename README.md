1. Only the owner of the contract can mint dTSLA.
2. Anyone can redeem dTSLA for USDC.
3. Once the redeem function is called, Chainlink functions will start a TSLA sell for USDC, and then send the USDC to the contract.
4. The user can then call `finishRedeem` to receive their USDC.

> **Note:** The redemption functions are still under development. Updates will be provided as progress is made. -- IGNORE --
> **Note:** The contract is undeployed. And the Chainlink functions subscription is not set up yet.