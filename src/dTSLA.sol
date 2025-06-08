// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/dev/v1_X/libraries/FunctionsRequest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract dTSLA is FunctionsClient, ConfirmedOwner, Pausable, ERC20 {
    using FunctionsRequest for FunctionsRequest.Request;
    using Strings for uint256;

    error dTSLA__NotEnoughTSLA();
    error dTSLA__InsufficientWithdrawalAmount();

    enum mintOrRedeem {
        MINT,
        REDEEM
    }

    struct dTslaRequest {
        uint256 amountOfToken;
        address requester;
        mintOrRedeem action; // MINT or REDEEM
    }

    /*//////////////////////////////////////////////////////////////
                           STORAGE VARIABLES
    //////////////////////////////////////////////////////////////*/

    uint256 public constant PRECISION = 1e18;
    uint256 public constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 public constant COLLATERAL_RATIO = 200; // 200% collateral ratio 
    // If there is $2 tsla in the brokerage account, we can mint $1 dTSLA
    uint256 public constant COLLATERAL_RATIO_PRECISION = 100;
    uint256 public constant MIN_WITHDRAWAL_AMOUNT = 100e6; // USDC has 6 decimals, so this is $100
    address public constant SEPOLIA_FUNCTIONS_ROUTER =
        0xb83E47C2bC239B3bf370bc41e1459A34b41238D0;
    address public constant SEPOLIA_TSLA_PRICE_FEED =
        0xc59E3633BAAC79493d908e63626716e204A45EdF; // This is LINK/USD price feed on Sepolia for demo
    bytes32 public s_lastRequestId;
    uint64 immutable i_subId;
    uint32 public constant MAX_GAS_LIMIT = 500_000; // Maximum gas limit for the mint request
    bytes32 public constant DON_ID =
        hex"66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000";

    string public s_mintSourceCode;
    string public s_redeemSource;
    mapping(bytes32 requestId => dTslaRequest request)
        private s_requestIdToRequest;

    event Mint(address indexed requester, uint256 amount);
    event UnexpectedRequestID(bytes32 indexed requestId);

    constructor(
        string memory _mintSourceCode,
        uint64 _subId,
        string memory _redeemSource
    )
        ConfirmedOwner(msg.sender)
        FunctionsClient(SEPOLIA_FUNCTIONS_ROUTER)
        ERC20("dTSLA", "dTSLA")
    {
        // Initialization logic
        s_mintSourceCode = _mintSourceCode;
        i_subId = _subId;
        s_redeemSource = _redeemSource;
    }

    /// @notice Sends a mint request for the dTSLA token.
    /// @dev This function interacts with an external service to verify TSLA purchase and mints tokens accordingly.
    /// Steps:
    /// 1. Sends an HTTP request to check how much TSLA has been bought.
    /// 2. Verifies if there is enough TSLA in the alpaca account by interacting with the oracle or external service.
    /// 3. Mints dTSLA tokens if the conditions are met.
    function sendMintRequest(
        uint256 amount
    ) external onlyOwner returns (bytes32) {
        FunctionsRequest.Request memory req;
        req._initializeRequestForInlineJavaScript(s_mintSourceCode); // Initialize the request with JS code

        // Send the request and store the request ID
        s_lastRequestId = _sendRequest(
            req._encodeCBOR(),
            i_subId,
            MAX_GAS_LIMIT,
            DON_ID
        );
        s_requestIdToRequest[s_lastRequestId] = dTslaRequest({
            amountOfToken: amount,
            requester: msg.sender,
            action: mintOrRedeem.MINT
        });

        emit Mint(msg.sender, amount); // Emit the Mint event

        return s_lastRequestId;
    }

    /// @notice Internal function to fulfill the mint request.
    /// Chainlink functions the amount of TSLA value (in USD) stored in our brokerage account.
    /// If the amount is sufficient, it mints the dTSLA tokens to the requester.
    function _mintFulfillRequest(
        bytes32 requestId,
        bytes memory response
    ) internal {
        uint256 amountToMint = s_requestIdToRequest[requestId].amountOfToken;
        uint256 portfolioBalance = uint256(bytes32(response));

        // If TSLA balance > dTSLA to mint, then mint dTSLA tokens
        // How much TSLA in USD is in the brokerage account?
        // How much dTSLA in USD is requested to mint?
        if (_getCollateralRatioAdjustedTotalBalance(amountToMint) > portfolioBalance) {
            revert dTSLA__NotEnoughTSLA();
        }

        if (amountToMint != 0) {
            _mint(
                s_requestIdToRequest[requestId].requester,
                amountToMint
            ); // Mint the dTSLA tokens to the requester
            emit Mint(s_requestIdToRequest[requestId].requester, amountToMint);
        }
    }

    /// @notice Sends a redeem request to sell TSLA for USDC.
    /// This function have the chainlink oracle to:
    /// 1. Sell TSLA on the brokerage
    /// 2. Buy USDC on the brokerage and send it to the dTSLA contract
    function sendRedeemRequest(uint256 amountOfDTsla) external {
        uint256 amountTslaInUsdc = (amountOfDTsla * getTslaPrice()) / PRECISION;
        // Makesure the amount is greater than the minimum withdrawal amount
        if (amountTslaInUsdc < MIN_WITHDRAWAL_AMOUNT) {
            revert dTSLA__InsufficientWithdrawalAmount();
        }

        FunctionsRequest.Request memory req;
        req._initializeRequestForInlineJavaScript(s_redeemSource); 
        string[] memory args = new string[](2);
        args[0] = amountOfDTsla.toString();
        req._setArgs(args);

        // Send the request and store the request ID
        s_lastRequestId = _sendRequest(
            req._encodeCBOR(),
            i_subId,
            MAX_GAS_LIMIT,
            DON_ID
        );
        s_requestIdToRequest[s_lastRequestId] = dTslaRequest({
            amountOfToken: amountOfDTsla,
            requester: msg.sender,
            action: mintOrRedeem.REDEEM
        });

        // External Interactions
        _burn(msg.sender, amountOfDTsla);
    }

    function _redeemFulfillRequest(bytes32 requestId, bytes memory response) internal {

    }

    /**
     * @notice Callback function for fulfilling a request
     * @param requestId The ID of the request to fulfill
     * @param response The HTTP response data
     * @param err Any errors from the Functions request
     */
    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal override {
        // if (s_lastRequestId != requestId) {
        //     revert UnexpectedRequestID(requestId); // Check if request IDs match
        // }
        dTslaRequest memory request = s_requestIdToRequest[requestId];
        if (request.action == mintOrRedeem.MINT) {
            _mintFulfillRequest(requestId, response);
        } else if (request.action == mintOrRedeem.REDEEM) {
            _redeemFulfillRequest(requestId, response);
        } else {
            revert("Unknown action type");
        }
    }

    function _getCollateralRatioAdjustedTotalBalance(
        uint256 amountToMint
    ) internal view returns (uint256) {
        uint256 calculatedNewTotalValue = getCalculatedNewTotalValue(amountToMint);
        uint256 collateralRatioAdjustedValue = (calculatedNewTotalValue * COLLATERAL_RATIO) / COLLATERAL_RATIO_PRECISION;
        return collateralRatioAdjustedValue;
    }

    /// @notice Calculates the new expected total value in USD of all the dTSLA tokens after minting.
    /// @param amountToMint The amount of dTSLA tokens to mint
    function getCalculatedNewTotalValue(
        uint256 amountToMint
    ) internal view returns (uint256) {
        uint256 newTotalSupply = totalSupply() + amountToMint;
        return (newTotalSupply * getTslaPrice()) / PRECISION;
    }

    function getTslaPrice() internal view returns (uint256) {
        AggregatorV3Interface tslaPriceFeed = AggregatorV3Interface(
            SEPOLIA_TSLA_PRICE_FEED
        );
        (, int256 price, , , ) = tslaPriceFeed.latestRoundData();
        return uint256(price) * ADDITIONAL_FEED_PRECISION; // Convert to the same precision as dTSLA
    }
}
