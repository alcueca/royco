// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { RecipeOrderbookBase, RewardStyle, WeirollWallet } from "src/base/RecipeOrderbookBase.sol";
import { ERC20 } from "lib/solmate/src/tokens/ERC20.sol";
import { ERC4626 } from "lib/solmate/src/tokens/ERC4626.sol";
import { ClonesWithImmutableArgs } from "lib/clones-with-immutable-args/src/ClonesWithImmutableArgs.sol";
import { Ownable } from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import { Owned } from "lib/solmate/src/auth/Owned.sol";
import { SafeTransferLib } from "lib/solmate/src/utils/SafeTransferLib.sol";
import { FixedPointMathLib } from "lib/solmate/src/utils/FixedPointMathLib.sol";
import { Points } from "src/Points.sol";
import { PointsFactory } from "src/PointsFactory.sol";

/// @title RecipeOrderbook
/// @author CopyPaste, corddry, ShivaanshK
/// @notice Orderbook Contract for Incentivizing AP/IPs to participate in "recipes" which perform arbitrary actions
contract RecipeOrderbook is RecipeOrderbookBase {
    using ClonesWithImmutableArgs for address;
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    /// @param _weirollWalletImplementation The address of the WeirollWallet implementation contract
    /// @param _protocolFee The percent deducted from the IP's incentive amount and claimable by protocolFeeClaimant
    /// @param _minimumFrontendFee The minimum frontend fee that a market can set
    /// @param _owner The address that will be set as the owner of the contract
    constructor(
        address _weirollWalletImplementation,
        uint256 _protocolFee,
        uint256 _minimumFrontendFee,
        address _owner,
        address _pointsFactory
    )
        payable
        Owned(_owner)
    {
        WEIROLL_WALLET_IMPLEMENTATION = _weirollWalletImplementation;
        POINTS_FACTORY = _pointsFactory;
        protocolFee = _protocolFee;
        protocolFeeClaimant = _owner;
        minimumFrontendFee = _minimumFrontendFee;
    }

    /// @notice Create a new recipe market
    /// @param inputToken The token that will be deposited into the user's weiroll wallet for use in the recipe
    /// @param lockupTime The time in seconds that the user's weiroll wallet will be locked up for after deposit
    /// @param frontendFee The fee that the frontend will take from the user's weiroll wallet, 1e18 == 100% fee
    /// @param depositRecipe The weiroll script that will be executed after the inputToken is transferred to the wallet
    /// @param withdrawRecipe The weiroll script that may be executed after lockupTime has passed to unwind a user's position
    /// @custom:field rewardStyle Whether the rewards are paid at the beginning, locked until the end, or forfeitable until the end
    /// @return marketID ID of the newly created market
    function createMarket(
        address inputToken,
        uint256 lockupTime,
        uint256 frontendFee,
        Recipe calldata depositRecipe,
        Recipe calldata withdrawRecipe,
        RewardStyle rewardStyle
    )
        external
        payable
        returns (uint256)
    {
        if (frontendFee < minimumFrontendFee) {
            revert FrontendFeeTooLow();
        } else if ((frontendFee + protocolFee) > 1e18) {
            // Sum of fees is too high
            revert TotalFeeTooHigh();
        }

        marketIDToWeirollMarket[numMarkets] = WeirollMarket(ERC20(inputToken), lockupTime, frontendFee, depositRecipe, withdrawRecipe, rewardStyle);

        emit MarketCreated(numMarkets, inputToken, lockupTime, frontendFee, rewardStyle);
        return (numMarkets++);
    }

    /// @notice Create a new AP order. Order params will be emitted in an event while only the hash of the order and order quantity is stored onchain
    /// @dev AP orders are funded via approvals to ensure multiple orders can be placed off of a single input
    /// @dev Setting an expiry of 0 means the order never expires
    /// @param targetMarketID The ID of the weiroll market which will be executed on fill
    /// @param fundingVault The address of the vault where the input tokens will be withdrawn from, if set to 0, the AP will deposit the base asset directly
    /// @param quantity The total amount of input tokens to be deposited
    /// @param expiry The timestamp after which the order is considered expired
    /// @param tokensRequested The incentive token addresses requested by the AP in order to satisfy the order
    /// @param tokenAmountsRequested The amount of each token requested by the AP in order to satisfy the order
    /// @return orderID ID of the newly created order
    function createAPOrder(
        uint256 targetMarketID,
        address fundingVault,
        uint256 quantity,
        uint256 expiry,
        address[] calldata tokensRequested,
        uint256[] calldata tokenAmountsRequested
    )
        external
        payable
        returns (uint256 orderID)
    {
        // Check market exists
        if (targetMarketID >= numMarkets) {
            revert MarketDoesNotExist();
        }
        // Check order isn't expired (expiries of 0 live forever)
        if (expiry != 0 && expiry < block.timestamp) {
            revert CannotPlaceExpiredOrder();
        }
        // Check order isn't empty
        if (quantity < 1e6) {
            revert CannotPlaceZeroQuantityOrder();
        }
        // Check token and price arrays are the same length
        if (tokensRequested.length != tokenAmountsRequested.length) {
            revert ArrayLengthMismatch();
        }

        // NOTE: The cool use of short-circuit means this call can't revert if fundingVault doesn't support asset()
        if (fundingVault != address(0) && marketIDToWeirollMarket[targetMarketID].inputToken != ERC4626(fundingVault).asset()) {
            revert MismatchedBaseAsset();
        }

        // Map the order hash to the order quantity
        APOrder memory order = APOrder(numAPOrders, targetMarketID, msg.sender, fundingVault, quantity, expiry, tokensRequested, tokenAmountsRequested);
        orderHashToRemainingQuantity[getOrderHash(order)] = quantity;

        /// @dev APOrder events are stored in events and do not exist onchain outside of the orderHashToRemainingQuantity mapping
        emit APOfferCreated(numAPOrders, targetMarketID, fundingVault, quantity, tokensRequested, tokenAmountsRequested, expiry);

        return (numAPOrders++);
    }

    /// @notice Create a new IP order, transferring the IP's incentives to the orderbook and putting all the order params in contract storage
    /// @dev IP must approve all tokens to be spent by the orderbook before calling this function
    /// @param targetMarketID The ID of the weiroll market which will be executed on fill
    /// @param quantity The total amount of input tokens to be deposited
    /// @param expiry The timestamp after which the order is considered expired
    /// @param tokensOffered The incentive token addresses offered by the IP
    /// @param tokenAmountsPaid The amount of each token paid by the IP (including fees)
    /// @return marketID ID of the newly created market
    function createIPOrder(
        uint256 targetMarketID,
        uint256 quantity,
        uint256 expiry,
        address[] calldata tokensOffered,
        uint256[] calldata tokenAmountsPaid
    )
        external
        payable
        nonReentrant
        returns (uint256 marketID)
    {
        // Check that the target market exists
        if (targetMarketID >= numMarkets) {
            revert MarketDoesNotExist();
        }
        // Check that the order isn't expired
        if (expiry != 0 && expiry < block.timestamp) {
            revert CannotPlaceExpiredOrder();
        }

        // Check that the token and price arrays are the same length
        if (tokensOffered.length != tokenAmountsPaid.length) {
            revert ArrayLengthMismatch();
        }
        // Check order isn't empty
        if (quantity < 1e6) {
            revert CannotPlaceZeroQuantityOrder();
        }

        address ip = msg.sender;

        // Create the order
        IPOrder storage order = orderIDToIPOrder[numIPOrders];
        order.targetMarketID = targetMarketID;
        order.ip = ip;
        order.quantity = quantity;
        order.remainingQuantity = quantity;
        order.expiry = expiry;
        order.tokensOffered = tokensOffered;

        // To keep track of incentive amounts and fees (per incentive) for event emission
        uint256[] memory incentivesAmountsToBePaid = new uint256[](tokensOffered.length);
        uint256[] memory protocolFeesToBePaid = new uint256[](tokensOffered.length);
        uint256[] memory frontendFeesToBePaid = new uint256[](tokensOffered.length);

        // Transfer the IP's incentives to the orderbook and set aside fees
        for (uint256 i = 0; i < tokensOffered.length; ++i) {
            // Get the incentive token offered and amount
            address token = tokensOffered[i];
            uint256 amount = tokenAmountsPaid[i];

            // Get the frontend fee for the target weiroll market
            uint256 frontendFee = marketIDToWeirollMarket[targetMarketID].frontendFee;

            // Calculate incentive and fee breakdown
            uint256 incentiveAmount = amount.divWadDown(1e18 + protocolFee + frontendFee);
            uint256 protocolFeeAmount = incentiveAmount.mulWadDown(protocolFee);
            uint256 frontendFeeAmount = incentiveAmount.mulWadDown(frontendFee);

            // Use a scoping block to avoid stack to deep errors
            {
                // Set appropriate amounts in order mappings
                order.tokenAmountsOffered[token] += incentiveAmount;
                order.tokenToProtocolFeeAmount[token] += protocolFeeAmount;
                order.tokenToFrontendFeeAmount[token] += frontendFeeAmount;

                // Track incentive amounts and fees (per incentive) for event emission
                incentivesAmountsToBePaid[i] = incentiveAmount;
                protocolFeesToBePaid[i] = protocolFeeAmount;
                frontendFeesToBePaid[i] = frontendFeeAmount;
            }

            // Check if incentive is a points program
            if (PointsFactory(POINTS_FACTORY).isPointsProgram(token)) {
                // If points incentive, make sure:
                // 1. The points factory used to create the program is the same as this orderbooks PF
                // 2. IP placing the order can award points
                // 3. Points factory has this orderbook marked as a valid RO - can be assumed true
                if (POINTS_FACTORY != address(Points(token).pointsFactory()) || !Points(token).allowedIPs(ip)) {
                    revert InvalidPointsProgram();
                }
            } else {
                // SafeTransferFrom does not check if a token address has any code, so we need to check it manually to prevent token deployment frontrunning
                if (token.code.length == 0) revert TokenDoesNotExist();
                // Transfer frontend fee + protocol fee + incentiveAmount of the incentive token to orderbook
                ERC20(token).safeTransferFrom(ip, address(this), incentiveAmount + protocolFeeAmount + frontendFeeAmount);
            }
        }

        // Emit IP offer creation event
        emit IPOfferCreated(numIPOrders, targetMarketID, quantity, tokensOffered, incentivesAmountsToBePaid, protocolFeesToBePaid, frontendFeesToBePaid, expiry);

        return (numIPOrders++);
    }

    /// @param token The token to claim fees for
    /// @param to The address to send fees claimed to
    function claimFees(address token, address to) external payable {
        uint256 amount = feeClaimantToTokenToAmount[msg.sender][token];
        delete feeClaimantToTokenToAmount[msg.sender][token];
        ERC20(token).safeTransfer(to, amount);
        emit FeesClaimed(msg.sender, token, amount);
    }

    /// @notice Filling multiple IP orders
    /// @param orderIDs The IDs of the IP orders to fill
    /// @param fillAmounts The amounts of input tokens to fill the corresponding orders with
    /// @param fundingVault The address of the vault where the input tokens will be withdrawn from (vault not used if set to address(0))
    /// @param frontendFeeRecipient The address that will receive the frontend fee
    function fillIPOrders(
        uint256[] calldata orderIDs,
        uint256[] calldata fillAmounts,
        address fundingVault,
        address frontendFeeRecipient
    )
        external
        payable
        nonReentrant
        ordersNotPaused
    {
        if (orderIDs.length != fillAmounts.length) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i = 0; i < orderIDs.length; ++i) {
            _fillIPOrder(orderIDs[i], fillAmounts[i], fundingVault, frontendFeeRecipient);
        }
    }

    /// @notice Fill an IP order, transferring the IP's incentives to the AP, withdrawing the AP from their funding vault into a fresh weiroll wallet, and
    /// executing the weiroll recipe
    /// @param orderID The ID of the IP order to fill
    /// @param fillAmount The amount of input tokens to fill the order with
    /// @param fundingVault The address of the vault where the input tokens will be withdrawn from (vault not used if set to address(0))
    /// @param frontendFeeRecipient The address that will receive the frontend fee
    function _fillIPOrder(uint256 orderID, uint256 fillAmount, address fundingVault, address frontendFeeRecipient) internal {
        // Retreive the IPOrder and WeirollMarket structs
        IPOrder storage order = orderIDToIPOrder[orderID];
        WeirollMarket storage market = marketIDToWeirollMarket[order.targetMarketID];

        // Check that the order isn't expired
        if (order.expiry != 0 && block.timestamp > order.expiry) {
            revert OrderExpired();
        }
        // Check that the order has enough remaining quantity
        if (order.remainingQuantity < fillAmount && fillAmount != type(uint256).max) {
            revert NotEnoughRemainingQuantity();
        }
        if (fillAmount == type(uint256).max) {
            fillAmount = order.remainingQuantity;
        }
        // Check that the order's base asset matches the market's base asset
        if (fundingVault != address(0) && market.inputToken != ERC4626(fundingVault).asset()) {
            revert MismatchedBaseAsset();
        }
        // Check that the order isn't empty
        if (fillAmount == 0) {
            revert CannotPlaceZeroQuantityOrder();
        }

        // Update the order's remaining quantity before interacting with external contracts
        order.remainingQuantity -= fillAmount;

        WeirollWallet wallet;
        {
            // Use a scoping block to avoid stack too deep
            bool forfeitable = market.rewardStyle == RewardStyle.Forfeitable;
            uint256 unlockTime = block.timestamp + market.lockupTime;

            // Create weiroll wallet to lock assets for recipe execution(s)
            wallet = WeirollWallet(
                payable(
                    WEIROLL_WALLET_IMPLEMENTATION.clone(abi.encodePacked(msg.sender, address(this), fillAmount, unlockTime, forfeitable, order.targetMarketID))
                )
            );
        }

        // Number of incentives offered by the IP
        uint256 numIncentives = order.tokensOffered.length;

        // Arrays to store incentives and fee amounts to be paid
        uint256[] memory incentiveAmountsPaid = new uint256[](numIncentives);
        uint256[] memory protocolFeesPaid = new uint256[](numIncentives);
        uint256[] memory frontendFeesPaid = new uint256[](numIncentives);

        // Calculate the percentage of the order the AP is filling
        uint256 fillPercentage = fillAmount.divWadDown(order.quantity);

        // Perform incentive accounting on a per incentive basis
        for (uint256 i = 0; i < numIncentives; ++i) {
            // Incentive token or points
            address token = order.tokensOffered[i];

            // Calculate fees to take based on percentage of fill
            protocolFeesPaid[i] = order.tokenToProtocolFeeAmount[token].mulWadDown(fillPercentage);
            frontendFeesPaid[i] = order.tokenToFrontendFeeAmount[token].mulWadDown(fillPercentage);

            // Calculate incentives to give based on percentage of fill
            incentiveAmountsPaid[i] = order.tokenAmountsOffered[token].mulWadDown(fillPercentage);

            if (market.rewardStyle == RewardStyle.Upfront) {
                // Push incentives to AP and account fees on fill in an upfront market
                _pushIncentivesOnIPFill(token, incentiveAmountsPaid[i], protocolFeesPaid[i], frontendFeesPaid[i], order.ip, frontendFeeRecipient);
            }
        }

        if (market.rewardStyle != RewardStyle.Upfront) {
            // If RewardStyle is either Forfeitable or Arrear
            // Create locked rewards params to account for payouts upon wallet unlocking
            LockedRewardParams storage params = weirollWalletToLockedRewardParams[address(wallet)];
            params.tokens = order.tokensOffered;
            params.amounts = incentiveAmountsPaid;
            params.ip = order.ip;
            params.frontendFeeRecipient = frontendFeeRecipient;
            params.wasIPOrder = true;
            params.orderID = orderID;
        }

        // Fund the weiroll wallet with the specified amount of the market's input token
        // Will use the funding vault if specified or will fund directly from the AP
        _fundWeirollWallet(fundingVault, msg.sender, market.inputToken, fillAmount, address(wallet));

        // Execute deposit recipe
        wallet.executeWeiroll(market.depositRecipe.weirollCommands, market.depositRecipe.weirollState);

        emit IPOfferFulfilled(orderID, fillAmount, address(wallet), incentiveAmountsPaid, protocolFeesPaid, frontendFeesPaid);
    }

    /// @dev Fill multiple AP orders
    /// @param orders The AP orders to fill
    /// @param fillAmounts The amount of input tokens to fill the corresponding order with
    /// @param frontendFeeRecipient The address that will receive the frontend fee
    function fillAPOrders(APOrder[] calldata orders, uint256[] calldata fillAmounts, address frontendFeeRecipient) external payable nonReentrant ordersNotPaused {
        if (orders.length != fillAmounts.length) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i = 0; i < orders.length; ++i) {
            _fillAPOrder(orders[i], fillAmounts[i], frontendFeeRecipient);
        }
    }

    /// @dev Fill an AP order
    /// @dev IP must approve all tokens to be spent (both fills + fees!) by the orderbook before calling this function.
    /// @param order The AP order to fill
    /// @param fillAmount The amount of input tokens to fill the order with
    /// @param frontendFeeRecipient The address that will receive the frontend fee
    function _fillAPOrder(APOrder calldata order, uint256 fillAmount, address frontendFeeRecipient) internal {
        if (order.expiry != 0 && block.timestamp > order.expiry) {
            revert OrderExpired();
        }

        bytes32 orderHash = getOrderHash(order);
        {
            // use a scoping block so solc knows `remaining` doesn't need to be kept around
            uint256 remaining = orderHashToRemainingQuantity[orderHash];
            if (fillAmount > remaining) {
                if (fillAmount != type(uint256).max) {
                    revert NotEnoughRemainingQuantity();
                }
                fillAmount = remaining;
            }
        }

        if (fillAmount == 0) {
            revert CannotFillZeroQuantityOrder();
        }

        // Adjust remaining order quantity by amount filled
        orderHashToRemainingQuantity[orderHash] -= fillAmount;

        // Calculate percentage of AP oder that IP is fulfilling (IP gets this percantage of the order quantity in a Weiroll wallet specified by the market)
        uint256 fillPercentage = fillAmount.divWadDown(order.quantity);

        if (fillPercentage < MIN_FILL_PERCENT) revert InsufficientFillPercent();

        // Get Weiroll market
        WeirollMarket storage market = marketIDToWeirollMarket[order.targetMarketID];

        WeirollWallet wallet;
        {
            // Create weiroll wallet to lock assets for recipe execution(s)
            uint256 unlockTime = block.timestamp + market.lockupTime;
            bool forfeitable = market.rewardStyle == RewardStyle.Forfeitable;
            wallet = WeirollWallet(
                payable(
                    WEIROLL_WALLET_IMPLEMENTATION.clone(abi.encodePacked(order.ap, address(this), fillAmount, unlockTime, forfeitable, order.targetMarketID))
                )
            );
        }

        // Number of incentives requested by the AP
        uint256 numIncentives = order.tokensRequested.length;

        // Arrays to store incentives and fee amounts to be paid
        uint256[] memory incentiveAmountsPaid = new uint256[](numIncentives);
        uint256[] memory protocolFeesPaid = new uint256[](numIncentives);
        uint256[] memory frontendFeesPaid = new uint256[](numIncentives);

        // Fees at the time of fill
        uint256 protocolFeeAtFulfillment = protocolFee;
        uint256 marketFrontendFee = market.frontendFee;

        for (uint256 i = 0; i < numIncentives; ++i) {
            // Incentive requested by AP
            address token = order.tokensRequested[i];

            // This is the incentive amount allocated to the AP
            uint256 incentiveAmount = order.tokenAmountsRequested[i].mulWadDown(fillPercentage);
            // Check that the incentives allocated to the AP are non-zero
            if (incentiveAmount == 0) {
                revert NoIncentivesPaidOnFill();
            }
            incentiveAmountsPaid[i] = incentiveAmount;

            // Calculate fees based on fill percentage. These fees will be taken on top of the AP's requested amount.
            protocolFeesPaid[i] = incentiveAmount.mulWadDown(protocolFeeAtFulfillment);
            frontendFeesPaid[i] = incentiveAmount.mulWadDown(marketFrontendFee);

            // Pull incentives from IP and account fees
            _pullIncentivesOnAPFill(token, incentiveAmount, protocolFeesPaid[i], frontendFeesPaid[i], order.ap, frontendFeeRecipient, market.rewardStyle);
        }

        if (market.rewardStyle != RewardStyle.Upfront) {
            // If RewardStyle is either Forfeitable or Arrear
            // Create locked rewards params to account for payouts upon wallet unlocking
            LockedRewardParams storage params = weirollWalletToLockedRewardParams[address(wallet)];
            params.tokens = order.tokensRequested;
            params.amounts = incentiveAmountsPaid;
            params.ip = msg.sender;
            params.frontendFeeRecipient = frontendFeeRecipient;
            params.protocolFeeAtFulfillment = protocolFeeAtFulfillment;
            // Redundant: Make sure this is set to false in case of a forfeit
            delete params.wasIPOrder;
        }

        // Fund the weiroll wallet with the specified amount of the market's input token
        // Will use the funding vault if specified or will fund directly from the AP
        _fundWeirollWallet(order.fundingVault, order.ap, market.inputToken, fillAmount, address(wallet));

        // Execute deposit recipe
        wallet.executeWeiroll(market.depositRecipe.weirollCommands, market.depositRecipe.weirollState);

        emit APOfferFulfilled(order.orderID, fillAmount, address(wallet), incentiveAmountsPaid, protocolFeesPaid, frontendFeesPaid);
    }

    /// @notice Cancel an AP order, setting the remaining quantity available to fill to 0
    function cancelAPOrder(APOrder calldata order) external payable {
        // Check that the cancelling party is the order's owner
        if (order.ap != msg.sender) revert NotOwner();

        // Check that the order doesn't have an indefinite expiry (cannot be cancelled)
        if (order.expiry == 0) revert OrderCannotExpire();

        // Check that the order isn't already filled, hasn't been cancelled already, or never existed
        bytes32 orderHash = getOrderHash(order);
        if (orderHashToRemainingQuantity[orderHash] == 0) {
            revert NotEnoughRemainingQuantity();
        }

        // Zero out the remaining quantity
        delete orderHashToRemainingQuantity[orderHash];

        emit APOfferCancelled(order.orderID);
    }

    /// @notice Cancel an IP order, setting the remaining quantity available to fill to 0 and returning the IP's incentives
    function cancelIPOrder(uint256 orderID) external payable nonReentrant {
        IPOrder storage order = orderIDToIPOrder[orderID];

        // Check that the cancelling party is the order's owner
        if (order.ip != msg.sender) revert NotOwner();

        // Check that the order doesn't have an indefinite expiry (cannot be cancelled)
        if (order.expiry == 0) revert OrderCannotExpire();

        // Check that the order isn't already filled, hasn't been cancelled already, or never existed
        if (order.remainingQuantity == 0) revert NotEnoughRemainingQuantity();

        RewardStyle marketRewardStyle = marketIDToWeirollMarket[order.targetMarketID].rewardStyle;
        // Check the percentage of the order not filled to calculate incentives to return
        uint256 percentNotFilled = order.remainingQuantity.divWadDown(order.quantity);

        // Transfer the remaining incentives back to the IP
        for (uint256 i = 0; i < order.tokensOffered.length; ++i) {
            address token = order.tokensOffered[i];
            if (!PointsFactory(POINTS_FACTORY).isPointsProgram(order.tokensOffered[i])) {
                // Calculate the incentives which are still available for takeback if its a token
                uint256 incentivesRemaining = order.tokenAmountsOffered[token].mulWadDown(percentNotFilled);

                // Calculate the unused fee amounts to reimburse to the IP
                uint256 unchargedFrontendFeeAmount = order.tokenToFrontendFeeAmount[token].mulWadDown(percentNotFilled);
                uint256 unchargedProtocolFeeAmount = order.tokenToProtocolFeeAmount[token].mulWadDown(percentNotFilled);

                // Transfer reimbursements to the IP
                ERC20(token).safeTransfer(order.ip, (incentivesRemaining + unchargedFrontendFeeAmount + unchargedProtocolFeeAmount));
            }

            /// Delete cancelled fields of dynamic arrays and mappings
            delete order.tokensOffered[i];
            delete order.tokenAmountsOffered[token];

            if (marketRewardStyle == RewardStyle.Upfront) {
                // Need these on forfeit and claim for forfeitable and arrear markets
                // Safe to delete for Upfront markets
                delete order.tokenToProtocolFeeAmount[token];
                delete order.tokenToFrontendFeeAmount[token];
            }
        }

        if (marketRewardStyle != RewardStyle.Upfront) {
            // Need quantity to take the fees on forfeit and claim - don't delete
            // Need expiry to check order expiry status on forfeit - don't delete
            // Delete the rest of the fields to indicate the order was cancelled on forfeit
            delete orderIDToIPOrder[orderID].targetMarketID;
            delete orderIDToIPOrder[orderID].ip;
            delete orderIDToIPOrder[orderID].remainingQuantity;
        } else {
            // Delete cancelled order completely from mapping if the market's RewardStyle is Upfront
            delete orderIDToIPOrder[orderID];
        }

        emit IPOfferCancelled(orderID);
    }

    /// @notice For wallets of Forfeitable markets, an AP can call this function to forgo their rewards and unlock their wallet
    function forfeit(address weirollWallet, bool executeWithdrawal) external payable isWeirollOwner(weirollWallet) nonReentrant {
        // Instantiate a weiroll wallet for the specified address
        WeirollWallet wallet = WeirollWallet(payable(weirollWallet));

        // Forfeit wallet
        wallet.forfeit();

        // Setting this option to false allows the AP to be able to forfeit even when the withdrawal script is reverting
        if (executeWithdrawal) {
            // Execute the withdrawal script if flag set to true
            _executeWithdrawalScript(weirollWallet);
        }

        // Get locked reward params
        LockedRewardParams storage params = weirollWalletToLockedRewardParams[weirollWallet];

        // Check if IP offer
        // If not, the forfeited amount won't be replenished to the offer
        if (params.wasIPOrder) {
            // Retrieve IP offer if it was one
            IPOrder storage order = orderIDToIPOrder[params.orderID];

            // Get amount filled by AP
            uint256 filledAmount = wallet.amount();

            // If IP address is 0, order has been cancelled
            if (order.ip == address(0) || (order.expiry != 0 && order.expiry < block.timestamp)) {
                // Cancelled or expired order - return incentives that were originally held for the AP to the IP and take the fees
                uint256 fillPercentage = filledAmount.divWadDown(order.quantity);

                // Get the ip from locked reward params
                address ip = params.ip;

                for (uint256 i = 0; i < params.tokens.length; ++i) {
                    address token = params.tokens[i];

                    // Calculate protocol fee to take based on percentage of fill
                    uint256 protocolFeeAmount = order.tokenToProtocolFeeAmount[token].mulWadDown(fillPercentage);
                    // Take protocol fee
                    _accountFee(protocolFeeClaimant, token, protocolFeeAmount, ip);

                    if (!PointsFactory(POINTS_FACTORY).isPointsProgram(token)) {
                        // Calculate frontend fee to refund to the IP on forfeit
                        uint256 frontendFeeAmount = order.tokenToFrontendFeeAmount[token].mulWadDown(fillPercentage);
                        // Refund token incentives and frontend fee to IP. Points don't need to be refunded.
                        ERC20(token).safeTransfer(ip, params.amounts[i] + frontendFeeAmount);
                    }

                    // Delete forfeited tokens and corresponding amounts from locked reward params
                    delete params.tokens[i];
                    delete params.amounts[i];

                    // Can't delete since there might be more forfeitable wallets still locked and we need to take fees on claim
                    // delete order.tokenToProtocolFeeAmount[token];
                    // delete order.tokenToFrontendFeeAmount[token];
                }
                // Can't delete since there might be more forfeitable wallets still locked
                // delete orderIDToIPOrder[params.orderID];
            } else {
                // If not cancelled, add the filledAmount back to remaining quantity
                // Correct incentive amounts are still in this contract
                order.remainingQuantity += filledAmount;

                // Delete forfeited tokens and corresponding amounts from locked reward params
                for (uint256 i = 0; i < params.tokens.length; ++i) {
                    delete params.tokens[i];
                    delete params.amounts[i];
                }
            }
        } else {
            // Get the protocol fee at fulfillment and market frontend fee
            uint256 protocolFeeAtFulfillment = params.protocolFeeAtFulfillment;
            uint256 marketFrontendFee = marketIDToWeirollMarket[wallet.marketId()].frontendFee;
            // Get the ip from locked reward params
            address ip = params.ip;

            // If order was an AP order, return the incentives to the IP and take the fee
            for (uint256 i = 0; i < params.tokens.length; ++i) {
                address token = params.tokens[i];
                uint256 amount = params.amounts[i];

                // Calculate fees to take based on percentage of fill
                uint256 protocolFeeAmount = amount.mulWadDown(protocolFeeAtFulfillment);
                // Take fees
                _accountFee(protocolFeeClaimant, token, protocolFeeAmount, ip);

                if (!PointsFactory(POINTS_FACTORY).isPointsProgram(token)) {
                    // Calculate frontend fee to refund to the IP on forfeit
                    uint256 frontendFeeAmount = amount.mulWadDown(marketFrontendFee);
                    // Refund token incentives and frontend fee to IP. Points don't need to be refunded.
                    ERC20(token).safeTransfer(ip, amount + frontendFeeAmount);
                }

                // Delete forfeited tokens and corresponding amounts from locked reward params
                delete params.tokens[i];
                delete params.amounts[i];
            }
        }

        // Zero out the mapping
        delete weirollWalletToLockedRewardParams[weirollWallet];

        emit WeirollWalletForfeited(weirollWallet);
    }

    /// @notice Execute the withdrawal script in the weiroll wallet
    function executeWithdrawalScript(address weirollWallet) external payable isWeirollOwner(weirollWallet) weirollIsUnlocked(weirollWallet) nonReentrant {
        _executeWithdrawalScript(weirollWallet);
    }

    /// @param weirollWallet The wallet to claim for
    /// @param to The address to send the incentive to
    function claim(address weirollWallet, address to) external payable isWeirollOwner(weirollWallet) weirollIsUnlocked(weirollWallet) nonReentrant {
        // Get locked reward details to facilitate claim
        LockedRewardParams storage params = weirollWalletToLockedRewardParams[weirollWallet];

        // Instantiate a weiroll wallet for the specified address
        WeirollWallet wallet = WeirollWallet(payable(weirollWallet));

        // Get the frontend fee recipient and ip from locked reward params
        address frontendFeeRecipient = params.frontendFeeRecipient;
        address ip = params.ip;

        if (params.wasIPOrder) {
            // If it was an iporder, get the order so we can retrieve the fee amounts and fill quantity
            IPOrder storage order = orderIDToIPOrder[params.orderID];

            uint256 fillAmount = wallet.amount();
            uint256 fillPercentage = fillAmount.divWadDown(order.quantity);

            for (uint256 i = 0; i < params.tokens.length; ++i) {
                address token = params.tokens[i];

                // Calculate fees to take based on percentage of fill
                uint256 protocolFeeAmount = order.tokenToProtocolFeeAmount[token].mulWadDown(fillPercentage);
                uint256 frontendFeeAmount = order.tokenToFrontendFeeAmount[token].mulWadDown(fillPercentage);

                // Take fees
                _accountFee(protocolFeeClaimant, token, protocolFeeAmount, ip);
                _accountFee(frontendFeeRecipient, token, frontendFeeAmount, ip);

                // Reward incentives to AP upon wallet unlock
                if (PointsFactory(POINTS_FACTORY).isPointsProgram(token)) {
                    Points(token).award(to, params.amounts[i], ip);
                } else {
                    ERC20(token).safeTransfer(to, params.amounts[i]);
                }

                emit WeirollWalletClaimedIncentive(weirollWallet, to, token);

                /// Delete fields of dynamic arrays and mappings
                delete params.tokens[i];
                delete params.amounts[i];
            }
        } else {
            // Get the protocol fee at fulfillment and market frontend fee
            uint256 protocolFeeAtFulfillment = params.protocolFeeAtFulfillment;
            uint256 marketFrontendFee = marketIDToWeirollMarket[wallet.marketId()].frontendFee;

            for (uint256 i = 0; i < params.tokens.length; ++i) {
                address token = params.tokens[i];
                uint256 amount = params.amounts[i];

                // Calculate fees to take based on percentage of fill
                uint256 protocolFeeAmount = amount.mulWadDown(protocolFeeAtFulfillment);
                uint256 frontendFeeAmount = amount.mulWadDown(marketFrontendFee);

                // Take fees
                _accountFee(protocolFeeClaimant, token, protocolFeeAmount, ip);
                _accountFee(params.frontendFeeRecipient, token, frontendFeeAmount, ip);

                // Reward incentives to AP upon wallet unlock
                // Don't need to take fees. Taken from IP upon filling an AP order
                if (PointsFactory(POINTS_FACTORY).isPointsProgram(token)) {
                    Points(params.tokens[i]).award(to, amount, ip);
                } else {
                    ERC20(params.tokens[i]).safeTransfer(to, amount);
                }

                emit WeirollWalletClaimedIncentive(weirollWallet, to, token);

                /// Delete fields of dynamic arrays and mappings
                delete params.tokens[i];
                delete params.amounts[i];
            }
        }

        // Zero out the mapping
        delete weirollWalletToLockedRewardParams[weirollWallet];
    }

    /// @param weirollWallet The wallet to claim for
    /// @param incentiveToken The incentiveToken to claim
    /// @param to The address to send the incentive to
    function claim(
        address weirollWallet,
        address incentiveToken,
        address to
    )
        external
        payable
        isWeirollOwner(weirollWallet)
        weirollIsUnlocked(weirollWallet)
        nonReentrant
    {
        // Get locked reward details to facilitate claim
        LockedRewardParams storage params = weirollWalletToLockedRewardParams[weirollWallet];

        // Instantiate a weiroll wallet for the specified address
        WeirollWallet wallet = WeirollWallet(payable(weirollWallet));

        // Get the frontend fee recipient and ip from locked reward params
        address frontendFeeRecipient = params.frontendFeeRecipient;
        address ip = params.ip;

        if (params.wasIPOrder) {
            // If it was an iporder, get the order so we can retrieve the fee amounts and fill quantity
            IPOrder storage order = orderIDToIPOrder[params.orderID];

            // Calculate percentage of order quantity this order fulfilled
            uint256 fillAmount = wallet.amount();
            uint256 fillPercentage = fillAmount.divWadDown(order.quantity);

            for (uint256 i = 0; i < params.tokens.length; ++i) {
                address token = params.tokens[i];
                if (incentiveToken == token) {
                    // Calculate fees to take based on percentage of fill
                    uint256 protocolFeeAmount = order.tokenToProtocolFeeAmount[token].mulWadDown(fillPercentage);
                    uint256 frontendFeeAmount = order.tokenToFrontendFeeAmount[token].mulWadDown(fillPercentage);

                    // Take fees
                    _accountFee(protocolFeeClaimant, token, protocolFeeAmount, ip);
                    _accountFee(frontendFeeRecipient, token, frontendFeeAmount, ip);

                    // Reward incentives to AP upon wallet unlock
                    if (PointsFactory(POINTS_FACTORY).isPointsProgram(token)) {
                        Points(token).award(to, params.amounts[i], ip);
                    } else {
                        ERC20(token).safeTransfer(to, params.amounts[i]);
                    }

                    emit WeirollWalletClaimedIncentive(weirollWallet, to, incentiveToken);

                    /// Delete fields of dynamic arrays and mappings once claimed
                    delete params.tokens[i];
                    delete params.amounts[i];

                    // Return upon claiming the incentive
                    return;
                }
            }
        } else {
            // Get the market frontend fee
            uint256 marketFrontendFee = marketIDToWeirollMarket[wallet.marketId()].frontendFee;

            for (uint256 i = 0; i < params.tokens.length; ++i) {
                address token = params.tokens[i];
                if (incentiveToken == token) {
                    uint256 amount = params.amounts[i];

                    // Calculate fees to take based on percentage of fill
                    uint256 protocolFeeAmount = amount.mulWadDown(params.protocolFeeAtFulfillment);
                    uint256 frontendFeeAmount = amount.mulWadDown(marketFrontendFee);

                    // Take fees
                    _accountFee(protocolFeeClaimant, token, protocolFeeAmount, ip);
                    _accountFee(frontendFeeRecipient, token, frontendFeeAmount, ip);

                    // Reward incentives to AP upon wallet unlock
                    // Don't need to take fees. Taken from IP upon filling an AP order
                    if (PointsFactory(POINTS_FACTORY).isPointsProgram(token)) {
                        Points(params.tokens[i]).award(to, amount, ip);
                    } else {
                        ERC20(params.tokens[i]).safeTransfer(to, amount);
                    }

                    emit WeirollWalletClaimedIncentive(weirollWallet, to, incentiveToken);

                    /// Delete fields of dynamic arrays and mappings
                    delete params.tokens[i];
                    delete params.amounts[i];

                    // Return upon claiming the incentive
                    return;
                }
            }
        }

        // This block will never get hit since array size doesn't get updated on delete
        // if (params.tokens.length == 0) {
        //     // Zero out the mapping if no more locked incentives to claim
        //     delete weirollWalletToLockedRewardParams[weirollWallet];
        // }
    }

    /// @param recipient The address to send fees to
    /// @param token The token address where fees are accrued in
    /// @param amount The amount of fees to award
    /// @param ip The incentive provider if awarding points
    function _accountFee(address recipient, address token, uint256 amount, address ip) internal {
        //check to see the token is actually a points campaign
        if (PointsFactory(POINTS_FACTORY).isPointsProgram(token)) {
            // Points cannot be claimed and are rather directly awarded
            Points(token).award(recipient, amount, ip);
        } else {
            feeClaimantToTokenToAmount[recipient][token] += amount;
        }
    }

    /// @param fundingVault The ERC4626 vault to fund the weiroll wallet with - if address(0) fund directly via AP
    /// @param ap The address of the AP to fund the weiroll wallet if no funding vault specified
    /// @param token The market input token to fund the weiroll wallet with
    /// @param amount The amount of market input token to fund the weiroll wallet with
    /// @param weirollWallet The weiroll wallet to fund with the specified amount of the market input token
    function _fundWeirollWallet(address fundingVault, address ap, ERC20 token, uint256 amount, address weirollWallet) internal {
        if (fundingVault == address(0)) {
            // If no fundingVault specified, fund the wallet directly from AP
            token.safeTransferFrom(ap, weirollWallet, amount);
        } else {
            // Withdraw the tokens from the funding vault into the wallet
            ERC4626(fundingVault).withdraw(amount, weirollWallet, ap);
            // Ensure that the Weiroll wallet received at least fillAmount of the inputToken from the AP provided vault
            if (token.balanceOf(weirollWallet) < amount) {
                revert WeirollWalletFundingFailed();
            }
        }
    }

    /**
     * @notice Handles the transfer and accounting of fees incentives for an IP order fill in an Upfront market.
     * @dev This function is called internally by `fillIPOrder` to manage the fees and incentives for an Upfront market.
     * @param token The address of the incentive token.
     * @param incentiveAmount The amount of the incentive token to be transferred.
     * @param protocolFeeAmount The protocol fee amount taken at fulfillment.
     * @param frontendFeeAmount The frontend fee amount taken for this market.
     * @param ip The address of the action provider.
     * @param frontendFeeRecipient The address that will receive the frontend fee.
     */
    function _pushIncentivesOnIPFill(
        address token,
        uint256 incentiveAmount,
        uint256 protocolFeeAmount,
        uint256 frontendFeeAmount,
        address ip,
        address frontendFeeRecipient
    )
        internal
    {
        // msg.sender will always be AP
        // Take fees immediately in an Upfront market
        _accountFee(protocolFeeClaimant, token, protocolFeeAmount, ip);
        _accountFee(frontendFeeRecipient, token, frontendFeeAmount, ip);

        // Give incentives to AP immediately in an Upfront market
        if (PointsFactory(POINTS_FACTORY).isPointsProgram(token)) {
            Points(token).award(msg.sender, incentiveAmount, ip);
        } else {
            ERC20(token).safeTransfer(msg.sender, incentiveAmount);
        }
    }

    /**
     * @notice Handles the transfer and accounting of fees and incentives for an AP order fill.
     * @dev This function is called internally by `fillAPOrder` to manage the incentives.
     * @param token The address of the incentive token.
     * @param incentiveAmount The amount of the incentive token to be transferred.
     * @param protocolFeeAmount The protocol fee amount taken at fulfillment.
     * @param frontendFeeAmount The frontend fee amount taken for this market.
     * @param ap The address of the action provider.
     * @param frontendFeeRecipient The address that will receive the frontend fee.
     * @param rewardStyle The style of reward distribution (Upfront, Arrear, Forfeitable).
     */
    function _pullIncentivesOnAPFill(
        address token,
        uint256 incentiveAmount,
        uint256 protocolFeeAmount,
        uint256 frontendFeeAmount,
        address ap,
        address frontendFeeRecipient,
        RewardStyle rewardStyle
    )
        internal
    {
        // msg.sender will always be IP
        if (rewardStyle == RewardStyle.Upfront) {
            // Take fees immediately from IP upon filling AP orders
            _accountFee(protocolFeeClaimant, token, protocolFeeAmount, msg.sender);
            _accountFee(frontendFeeRecipient, token, frontendFeeAmount, msg.sender);

            // Give incentives to AP immediately in an Upfront market
            if (PointsFactory(POINTS_FACTORY).isPointsProgram(token)) {
                // Award points on fill
                Points(token).award(ap, incentiveAmount, msg.sender);
            } else {
                // SafeTransferFrom does not check if a token address has any code, so we need to check it manually to prevent token deployment frontrunning
                if (token.code.length == 0) {
                    revert TokenDoesNotExist();
                }
                // Transfer protcol and frontend fees to orderbook for the claimants to withdraw them on-demand
                ERC20(token).safeTransferFrom(msg.sender, address(this), protocolFeeAmount + frontendFeeAmount);
                // Transfer AP's incentives to them on fill if token incentive
                ERC20(token).safeTransferFrom(msg.sender, ap, incentiveAmount);
            }
        } else {
            // RewardStyle is Forfeitable or Arrear
            // If incentives will be paid out later, only handle the token case. Points will be awarded on claim.
            if (PointsFactory(POINTS_FACTORY).isPointsProgram(token)) {
                // If points incentive, make sure:
                // 1. The points factory used to create the program is the same as this orderbooks PF
                // 2. IP placing the order can award points
                // 3. Points factory has this orderbook marked as a valid RO - can be assumed true
                if (POINTS_FACTORY != address(Points(token).pointsFactory()) || !Points(token).allowedIPs(msg.sender)) {
                    revert InvalidPointsProgram();
                }
            } else {
                // SafeTransferFrom does not check if a token address has any code, so we need to check it manually to prevent token deployment frontrunning
                if (token.code.length == 0) {
                    revert TokenDoesNotExist();
                }
                // If not a points program, transfer amount requested (based on fill percentage) to the orderbook in addition to protocol and frontend fees.
                ERC20(token).safeTransferFrom(msg.sender, address(this), incentiveAmount + protocolFeeAmount + frontendFeeAmount);
            }
        }
    }

    /// @notice executes the withdrawal script for the provided weiroll wallet
    function _executeWithdrawalScript(address weirollWallet) internal {
        // Instantiate the WeirollWallet from the wallet address
        WeirollWallet wallet = WeirollWallet(payable(weirollWallet));

        // Get the marketID associated with the weiroll wallet
        uint256 weirollMarketId = wallet.marketId();

        // Get the market in order to get the withdrawal recipe
        WeirollMarket storage market = marketIDToWeirollMarket[weirollMarketId];

        // Execute the withdrawal recipe
        wallet.executeWeiroll(market.withdrawRecipe.weirollCommands, market.withdrawRecipe.weirollState);

        emit WeirollWalletExecutedWithdrawal(weirollWallet);
    }
}
