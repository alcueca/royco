// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "../../../src/RecipeOrderbook.sol";
import "../../../src/ERC4626i.sol";

import { MockERC20, ERC20 } from "../../mocks/MockERC20.sol";
import { RecipeOrderbookTestBase } from "../../utils/RecipeOrderbook/RecipeOrderbookTestBase.sol";
import { FixedPointMathLib } from "lib/solmate/src/utils/FixedPointMathLib.sol";

contract Test_Fill_IPOrder_RecipeOrderbook is RecipeOrderbookTestBase {
    using FixedPointMathLib for uint256;

    address IP_ADDRESS = ALICE_ADDRESS;
    address FRONTEND_FEE_RECIPIENT = CHARLIE_ADDRESS;

    function setUp() external {
        uint256 protocolFee = 0.01e18; // 1% protocol fee
        uint256 minimumFrontendFee = 0.001e18; // 0.1% minimum frontend fee
        setUpRecipeOrderbookTests(protocolFee, minimumFrontendFee);
    }

    function test_DirectFill_Upfront_IPOrder_ForTokens() external {
        uint256 frontendFee = orderbook.minimumFrontendFee();
        uint256 marketId = orderbook.createMarket(address(mockLiquidityToken), 30 days, frontendFee, NULL_RECIPE, NULL_RECIPE, RewardStyle.Upfront);

        uint256 orderAmount = 1000e18; // Order amount requested
        uint256 fillAmount = 100e18; // Fill amount

        // Create a fillable IP order
        uint256 orderId = createIPOrder_WithTokens(marketId, orderAmount, IP_ADDRESS);

        // Mint liquidity tokens to the LP to fill the order
        mockLiquidityToken.mint(BOB_ADDRESS, fillAmount);
        vm.startPrank(BOB_ADDRESS);
        mockLiquidityToken.approve(address(orderbook), fillAmount);
        vm.stopPrank();

        (, uint256 expectedFrontendFeeAmount, uint256 expectedIncentiveAmount) =
            calculateIPOrderExpectedIncentiveAndFrontendFee(orderId, orderAmount, fillAmount, address(mockIncentiveToken));

        // Expect events for transfers
        vm.expectEmit(true, true, false, true, address(mockIncentiveToken));
        emit ERC20.Transfer(address(orderbook), BOB_ADDRESS, expectedIncentiveAmount);

        vm.expectEmit(true, false, false, true, address(mockLiquidityToken));
        emit ERC20.Transfer(BOB_ADDRESS, address(0), fillAmount);

        // Record the logs to capture Transfer events to get Weiroll wallet address
        vm.recordLogs();
        // Fill the order
        vm.startPrank(BOB_ADDRESS);
        orderbook.fillIPOrder(orderId, fillAmount, address(0), FRONTEND_FEE_RECIPIENT);
        vm.stopPrank();

        // Extract the Weiroll wallet address (the 'to' address from the second Transfer event)
        address weirollWallet = address(uint160(uint256(vm.getRecordedLogs()[1].topics[2])));

        // Ensure there is a weirollWallet at the expected address
        assertGt(weirollWallet.code.length, 0);

        // Ensure the LP received the correct incentive amount
        assertEq(mockIncentiveToken.balanceOf(BOB_ADDRESS), expectedIncentiveAmount);

        // Ensure the weiroll wallet got the liquidity
        assertEq(mockLiquidityToken.balanceOf(weirollWallet), fillAmount);

        // Check the frontend fee recipient received the correct fee
        assertEq(orderbook.feeClaimantToTokenToAmount(FRONTEND_FEE_RECIPIENT, address(mockIncentiveToken)), expectedFrontendFeeAmount);
    }

    function test_DirectFill_Upfront_IPOrder_ForPoints() external {
        uint256 frontendFee = orderbook.minimumFrontendFee();
        uint256 marketId = orderbook.createMarket(address(mockLiquidityToken), 30 days, frontendFee, NULL_RECIPE, NULL_RECIPE, RewardStyle.Upfront);

        uint256 orderAmount = 1000e18; // Order amount requested
        uint256 fillAmount = 100e18; // Fill amount

        // Mint liquidity tokens to the LP to fill the order
        mockLiquidityToken.mint(BOB_ADDRESS, fillAmount);
        vm.startPrank(BOB_ADDRESS);
        mockLiquidityToken.approve(address(orderbook), fillAmount);
        vm.stopPrank();

        // Create a fillable IP order
        (uint256 orderId, Points points) = createIPOrder_WithPoints(marketId, orderAmount, IP_ADDRESS);

        (, uint256 expectedFrontendFeeAmount, uint256 expectedIncentiveAmount) =
            calculateIPOrderExpectedIncentiveAndFrontendFee(orderId, orderAmount, fillAmount, address(points));

        // Expect events for transfers
        vm.expectEmit(true, true, false, true, address(points));
        emit Points.Award(BOB_ADDRESS, expectedIncentiveAmount);

        vm.expectEmit(true, true, false, true, address(points));
        emit Points.Award(FRONTEND_FEE_RECIPIENT, expectedFrontendFeeAmount);

        vm.expectEmit(true, false, false, true, address(mockLiquidityToken));
        emit ERC20.Transfer(BOB_ADDRESS, address(0), fillAmount);

        // Record the logs to capture Transfer events to get Weiroll wallet address
        vm.recordLogs();
        // Fill the order
        vm.startPrank(BOB_ADDRESS);
        orderbook.fillIPOrder(orderId, fillAmount, address(0), FRONTEND_FEE_RECIPIENT);
        vm.stopPrank();

        // Extract the Weiroll wallet address (the 'to' address from the Transfer event - third event in logs)
        address weirollWallet = address(uint160(uint256(vm.getRecordedLogs()[2].topics[2])));

        // Ensure there is a weirollWallet at the expected address
        assertGt(weirollWallet.code.length, 0);

        // Ensure the weiroll wallet got the liquidity
        assertEq(mockLiquidityToken.balanceOf(weirollWallet), fillAmount);
    }

    function test_VaultFill_Upfront_IPOrder_ForTokens() external {
        uint256 frontendFee = orderbook.minimumFrontendFee();
        uint256 marketId = orderbook.createMarket(address(mockLiquidityToken), 30 days, frontendFee, NULL_RECIPE, NULL_RECIPE, RewardStyle.Upfront);

        uint256 orderAmount = 1000e18; // Order amount requested
        uint256 fillAmount = 100e18; // Fill amount

        // Create a fillable IP order
        uint256 orderId = createIPOrder_WithTokens(marketId, orderAmount, IP_ADDRESS);

        // Mint liquidity tokens to deposit into the vault
        mockLiquidityToken.mint(BOB_ADDRESS, fillAmount);
        vm.startPrank(BOB_ADDRESS);
        mockLiquidityToken.approve(address(mockVault), fillAmount);

        // Deposit tokens into the vault and approve orderbook to spend them
        mockVault.deposit(fillAmount, BOB_ADDRESS);
        mockVault.approve(address(orderbook), fillAmount);

        vm.stopPrank();

        (, uint256 expectedFrontendFeeAmount, uint256 expectedIncentiveAmount) =
            calculateIPOrderExpectedIncentiveAndFrontendFee(orderId, orderAmount, fillAmount, address(mockIncentiveToken));

        // Expect events for transfers
        vm.expectEmit(true, true, false, true, address(mockIncentiveToken));
        emit ERC20.Transfer(address(orderbook), BOB_ADDRESS, expectedIncentiveAmount);

        // burn shares
        vm.expectEmit(true, true, false, false, address(mockVault));
        emit ERC20.Transfer(BOB_ADDRESS, address(0), 0);

        vm.expectEmit(true, false, true, false, address(mockVault));
        emit ERC4626.Withdraw(address(orderbook), address(0), BOB_ADDRESS, fillAmount, 0);

        vm.expectEmit(true, false, false, true, address(mockLiquidityToken));
        emit ERC20.Transfer(address(mockVault), address(0), fillAmount);

        // Record the logs to capture Transfer events to get Weiroll wallet address
        vm.recordLogs();
        // Fill the order
        vm.startPrank(BOB_ADDRESS);
        orderbook.fillIPOrder(orderId, fillAmount, address(mockVault), FRONTEND_FEE_RECIPIENT);
        vm.stopPrank();

        // Extract the Weiroll wallet address (the 'to' address from the third Transfer event)
        address weirollWallet = address(uint160(uint256(vm.getRecordedLogs()[3].topics[2])));

        // Ensure there is a weirollWallet at the expected address
        assertGt(weirollWallet.code.length, 0);

        // Ensure the LP received the correct incentive amount
        assertEq(mockIncentiveToken.balanceOf(BOB_ADDRESS), expectedIncentiveAmount);

        // Ensure the weiroll wallet got the liquidity
        assertEq(mockLiquidityToken.balanceOf(weirollWallet), fillAmount);

        // Check the frontend fee recipient received the correct fee
        assertEq(orderbook.feeClaimantToTokenToAmount(FRONTEND_FEE_RECIPIENT, address(mockIncentiveToken)), expectedFrontendFeeAmount);
    }

    function test_VaultFill_Upfront_IPOrder_ForPoints() external {
        uint256 frontendFee = orderbook.minimumFrontendFee();
        uint256 marketId = orderbook.createMarket(address(mockLiquidityToken), 30 days, frontendFee, NULL_RECIPE, NULL_RECIPE, RewardStyle.Upfront);

        uint256 orderAmount = 1000e18; // Order amount requested
        uint256 fillAmount = 100e18; // Fill amount

        // Mint liquidity tokens to deposit into the vault
        mockLiquidityToken.mint(BOB_ADDRESS, fillAmount);
        vm.startPrank(BOB_ADDRESS);
        mockLiquidityToken.approve(address(mockVault), fillAmount);

        // Deposit tokens into the vault and approve orderbook to spend them
        mockVault.deposit(fillAmount, BOB_ADDRESS);
        mockVault.approve(address(orderbook), fillAmount);
        vm.stopPrank();

        // Create a fillable IP order
        (uint256 orderId, Points points) = createIPOrder_WithPoints(marketId, orderAmount, IP_ADDRESS);

        (, uint256 expectedFrontendFeeAmount, uint256 expectedIncentiveAmount) =
            calculateIPOrderExpectedIncentiveAndFrontendFee(orderId, orderAmount, fillAmount, address(points));

        // Expect events for transfers
        vm.expectEmit(true, true, false, true, address(points));
        emit Points.Award(BOB_ADDRESS, expectedIncentiveAmount);

        vm.expectEmit(true, true, false, true, address(points));
        emit Points.Award(FRONTEND_FEE_RECIPIENT, expectedFrontendFeeAmount);

        // burn shares
        vm.expectEmit(true, true, false, false, address(mockVault));
        emit ERC20.Transfer(BOB_ADDRESS, address(0), 0);

        vm.expectEmit(true, false, true, false, address(mockVault));
        emit ERC4626.Withdraw(address(orderbook), address(0), BOB_ADDRESS, fillAmount, 0);

        vm.expectEmit(true, false, false, true, address(mockLiquidityToken));
        emit ERC20.Transfer(BOB_ADDRESS, address(0), fillAmount);

        // Record the logs to capture Transfer events to get Weiroll wallet address
        vm.recordLogs();
        // Fill the order
        vm.startPrank(BOB_ADDRESS);
        orderbook.fillIPOrder(orderId, fillAmount, address(0), FRONTEND_FEE_RECIPIENT);
        vm.stopPrank();

        // Extract the Weiroll wallet address (the 'to' address from the Transfer event - third event in logs)
        address weirollWallet = address(uint160(uint256(vm.getRecordedLogs()[2].topics[2])));

        // Ensure there is a weirollWallet at the expected address
        assertGt(weirollWallet.code.length, 0);

        // Ensure the weiroll wallet got the liquidity
        assertEq(mockLiquidityToken.balanceOf(weirollWallet), fillAmount);
    }
}
