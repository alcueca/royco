// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "src/base/RecipeKernelBase.sol";
import "src/WrappedVault.sol";

import { MockERC20, ERC20 } from "../../mocks/MockERC20.sol";
import { RecipeKernelTestBase } from "../../utils/RecipeKernel/RecipeKernelTestBase.sol";

contract Test_Cancel_APOffer_RecipeKernelBaseBase is RecipeKernelTestBase {
    address AP_ADDRESS;
    address IP_ADDRESS;

    function setUp() external {
        uint256 protocolFee = 0.01e18; // 1% protocol fee
        uint256 minimumFrontendFee = 0.001e18; // 0.1% minimum frontend fee
        setUpRecipeKernelTests(protocolFee, minimumFrontendFee);

        AP_ADDRESS = ALICE_ADDRESS;
        IP_ADDRESS = DAN_ADDRESS;
    }

    function test_cancelAPOffer_WithTokens() external {
        bytes32 marketHash = createMarket();

        uint256 quantity = 100000e18; // The amount of input tokens to be deposited

        // Create the AP offer
        (bytes32 offerHash, RecipeKernelBase.APOffer memory offer) = createAPOffer_ForTokens(marketHash, address(0), quantity, AP_ADDRESS);

        uint256 initialQuantity = recipeKernel.offerHashToRemainingQuantity(recipeKernel.getOfferHash(offer));
        assertEq(initialQuantity, quantity);

        vm.expectEmit(true, false, false, true, address(recipeKernel));
        emit RecipeKernelBase.APOfferCancelled(offer.offerID);

        vm.startPrank(AP_ADDRESS);
        recipeKernel.cancelAPOffer(offer);
        vm.stopPrank();

        uint256 resultingQuantity = recipeKernel.offerHashToRemainingQuantity(recipeKernel.getOfferHash(offer));
        assertEq(resultingQuantity, 0);
    }

    function test_cancelAPOffer_WithPoints() external {
        bytes32 marketHash = createMarket();
        uint256 quantity = 100000e18; // The amount of input tokens to be deposited

        // Create the AP offer
        (bytes32 offerHash, RecipeKernelBase.APOffer memory offer,) = createAPOffer_ForPoints(marketHash, address(0), quantity, AP_ADDRESS, IP_ADDRESS);

        uint256 initialQuantity = recipeKernel.offerHashToRemainingQuantity(recipeKernel.getOfferHash(offer));
        assertEq(initialQuantity, quantity);

        vm.expectEmit(true, false, false, true, address(recipeKernel));
        emit RecipeKernelBase.APOfferCancelled(offer.offerID);

        vm.startPrank(AP_ADDRESS);
        recipeKernel.cancelAPOffer(offer);
        vm.stopPrank();

        uint256 resultingQuantity = recipeKernel.offerHashToRemainingQuantity(recipeKernel.getOfferHash(offer));
        assertEq(resultingQuantity, 0);
    }

    function test_RevertIf_cancelAPOffer_NotOwner() external {
        bytes32 marketHash = createMarket();
        uint256 quantity = 100000e18;

        (, RecipeKernelBase.APOffer memory offer) = createAPOffer_ForTokens(marketHash, address(0), quantity, AP_ADDRESS);

        vm.startPrank(IP_ADDRESS);
        vm.expectRevert(RecipeKernelBase.NotOwner.selector);
        recipeKernel.cancelAPOffer(offer);
        vm.stopPrank();
    }

    function test_RevertIf_cancelAPOffer_NoRemainingQuantity() external {
        bytes32 marketHash = createMarket();
        uint256 quantity = 100000e18;

        (, RecipeKernelBase.APOffer memory offer) = createAPOffer_ForTokens(marketHash, address(0), quantity, AP_ADDRESS);

        mockLiquidityToken.mint(AP_ADDRESS, quantity);
        vm.startPrank(AP_ADDRESS);
        mockLiquidityToken.approve(address(recipeKernel), quantity);
        vm.stopPrank();

        // Mint incentive tokens to IP and fill
        mockIncentiveToken.mint(IP_ADDRESS, 100000e18);
        vm.startPrank(IP_ADDRESS);
        mockIncentiveToken.approve(address(recipeKernel), 100000e18);

        recipeKernel.fillAPOffers(offer, quantity, DAN_ADDRESS);
        vm.stopPrank();

        // Should be completely filled and uncancellable
        uint256 resultingQuantity = recipeKernel.offerHashToRemainingQuantity(recipeKernel.getOfferHash(offer));
        assertEq(resultingQuantity, 0);

        vm.startPrank(AP_ADDRESS);
        vm.expectRevert(RecipeKernelBase.NotEnoughRemainingQuantity.selector);
        recipeKernel.cancelAPOffer(offer);
        vm.stopPrank();
    }
}
