// SPDX-Liense-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockERC4626 } from "test/mocks/MockERC4626.sol";
import { DecimalOffsetERC4626 } from "test/mocks/DecimalOffsetERC4626.sol";

import { ERC20 } from "lib/solady/src/tokens/ERC20.sol";
import { ERC4626 } from "lib/solady/src/tokens/ERC4626.sol";

import { WrappedVault } from "src/WrappedVault.sol";
import { WrappedVaultFactory } from "src/WrappedVaultFactory.sol";

import { FixedPointMathLib } from "lib/solmate/src/utils/FixedPointMathLib.sol";
import { Owned } from "lib/solmate/src/auth/Owned.sol";

import { PointsFactory } from "src/PointsFactory.sol";

import "lib/solidity-stringutils/strings.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import { Test, console } from "forge-std/Test.sol";

contract WrappedVaultDecimalOffsetTest is Test {
    using strings for *;
    using FixedPointMathLib for *;

    ERC20 token1 = ERC20(address(new MockERC20("Mock Token", "MOCK", 18)));
    ERC20 token2 = ERC20(address(new MockERC20("Mock Token", "MOCK", 6)));
    ERC20 token = token2;
    DecimalOffsetERC4626 testVault1 = DecimalOffsetERC4626(address(new MockERC4626(token)));
    DecimalOffsetERC4626 testVault2 = DecimalOffsetERC4626(address(new DecimalOffsetERC4626(token)));
    DecimalOffsetERC4626 testVault;
    WrappedVault testIncentivizedVault;

    MockERC20 rewardToken1 = new MockERC20("Reward Token 1", "RWD1", 18);
    MockERC20 rewardToken2 = new MockERC20("Reward Token 2", "RWD2", 6);
    MockERC20 rewardToken;

    PointsFactory pointsFactory = new PointsFactory(POINTS_FACTORY_OWNER);
    WrappedVaultFactory testFactory;
    uint256 constant WAD = 1e18;

    uint256 constant DEFAULT_REFERRAL_FEE = 0.025e18;
    uint256 constant DEFAULT_FRONTEND_FEE = 0.025e18;
    uint256 constant DEFAULT_PROTOCOL_FEE = 0.05e18;

    address constant DEFAULT_FEE_RECIPIENT = address(0xdead);

    address public constant POINTS_FACTORY_OWNER = address(0x1);
    address public constant REGULAR_USER = address(0xbeef);
    address public constant REFERRAL_USER = address(0x33f123);

    function displayDecimals(uint amount, uint decimals) public pure returns (string memory) {
        string memory integer = Strings.toString(amount / 10**decimals);
        string memory fractional = Strings.toString(amount % 10**decimals);
        while (fractional.toSlice().len() < decimals) fractional = "0".toSlice().concat(fractional.toSlice());
        return integer.toSlice().concat(",".toSlice()).toSlice().concat(fractional.toSlice());
    }

    function setUp() public {
        rewardToken = rewardToken1;
        testVault = testVault2;

        testFactory = new WrappedVaultFactory(DEFAULT_FEE_RECIPIENT, DEFAULT_PROTOCOL_FEE, DEFAULT_FRONTEND_FEE, address(this), address(pointsFactory));
        testIncentivizedVault = testFactory.wrapVault(testVault, address(this), "Incentivized Vault", DEFAULT_FRONTEND_FEE);


        vm.label(address(testIncentivizedVault), "IncentivizedVault");
        vm.label(address(rewardToken1), "RewardToken1");
        vm.label(address(rewardToken2), "RewardToken2");
        vm.label(REGULAR_USER, "RegularUser");
        vm.label(REFERRAL_USER, "ReferralUser");
    }


    function testClaim_Debug() public {
        // Breaking scenario
        // Deposit 627129793404660265672081267
        // Elapsed 2320009

        uint256 depositAmount = 1_000 * 10 ** token.decimals();
        uint32 timeElapsed = 15 days;

        // vm.assume(depositAmount > 1e6);
        // vm.assume(depositAmount <= type(uint96).max);
        // vm.assume(timeElapsed > 1e6);
        // vm.assume(timeElapsed <= 30 days);

        uint256 rewardAmount = 1_000 * 10 ** rewardToken.decimals();
        uint32 start = uint32(block.timestamp);
        uint32 duration = 30 days;

        testIncentivizedVault.addRewardsToken(address(rewardToken));
        rewardToken.mint(address(this), rewardAmount);
        rewardToken.approve(address(testIncentivizedVault), rewardAmount);
        testIncentivizedVault.setRewardsInterval(address(rewardToken), start, start + duration, rewardAmount, DEFAULT_FEE_RECIPIENT);

        uint256 frontendFee = rewardAmount.mulWadDown(testIncentivizedVault.frontendFee());
        uint256 protocolFee = rewardAmount.mulWadDown(testFactory.protocolFee());

        rewardAmount -= frontendFee + protocolFee;

        MockERC20(address(token)).mint(REGULAR_USER, depositAmount);

        vm.startPrank(REGULAR_USER);
        token.approve(address(testIncentivizedVault), depositAmount);
        uint256 shares = testIncentivizedVault.deposit(depositAmount, REGULAR_USER);
        vm.warp(timeElapsed);

        uint256 expectedRewards = (rewardAmount / duration) * shares / testIncentivizedVault.totalSupply() * timeElapsed;
        testIncentivizedVault.rewardToInterval(address(rewardToken));

        testIncentivizedVault.claim(REGULAR_USER);
        vm.stopPrank();

        console.log("Rewards %s", displayDecimals(rewardAmount, rewardToken.decimals()));
        console.log("Received %s", displayDecimals(rewardToken.balanceOf(REGULAR_USER), rewardToken.decimals()));
        console.log("Expected %s", displayDecimals(expectedRewards, rewardToken.decimals()));
        console.log("Deposit %s", displayDecimals(depositAmount, token.decimals()));
        console.log("Duration %s", duration);
        console.log("Elapsed %s", timeElapsed);
        console.log("Asset decimals %s", token.decimals());
        console.log("Vault decimals %s", testVault.decimals());
        console.log("Decimals offset %s", testVault.decimalsOffset());
        console.log("Reward decimals %s", rewardToken.decimals());


        assertApproxEqRel(rewardToken.balanceOf(REGULAR_USER), expectedRewards, 2e15); // Allow 0.2% deviation
    }
}
