// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import { WeirollWallet } from "src/WeirollWallet.sol";
import { ClonesWithImmutableArgs } from "lib/clones-with-immutable-args/src/ClonesWithImmutableArgs.sol";
import { Test } from "forge-std/Test.sol";
import { VM } from "lib/weiroll/contracts/VM.sol";

contract WeirollWalletTest is Test {
    using ClonesWithImmutableArgs for address;

    address public WEIROLL_WALLET_IMPLEMENTATION;
    WeirollWallet public wallet;
    MockRecipekernel public mockRecipekernel;
    address public owner;
    uint256 public constant AMOUNT = 1 ether;
    uint256 public lockedUntil;
    bytes32 public marketHash;

    receive() external payable { }

    function setUp() public {
        WEIROLL_WALLET_IMPLEMENTATION = address(new WeirollWallet());
        mockRecipekernel = new MockRecipekernel();
        owner = address(this);
        lockedUntil = block.timestamp + 1 days;
        marketHash = bytes32(hex"14beef");
        wallet = createWallet(owner, address(mockRecipekernel), AMOUNT, lockedUntil, true, marketHash);
    }

    function createWallet(
        address _owner,
        address _recipeKernel,
        uint256 _amount,
        uint256 _lockedUntil,
        bool _isForfeitable,
        bytes32 _marketHash
    )
        public
        returns (WeirollWallet)
    {
        return
            WeirollWallet(payable(WEIROLL_WALLET_IMPLEMENTATION.clone(abi.encodePacked(_owner, _recipeKernel, _amount, _lockedUntil, _isForfeitable, _marketHash))));
    }

    function testWalletInitialization() public view {
        assertEq(wallet.owner(), owner);
        assertEq(wallet.recipeKernel(), address(mockRecipekernel));
        assertEq(wallet.amount(), AMOUNT);
        assertEq(wallet.lockedUntil(), lockedUntil);
        assertTrue(wallet.isForfeitable());
        assertEq(wallet.marketHash(), marketHash);
        assertFalse(wallet.executed());
        assertFalse(wallet.forfeited());
    }

    function testOnlyOwnerModifier() public {
        vm.prank(address(0xdead));
        vm.expectRevert(WeirollWallet.NotOwner.selector);
        wallet.manualExecuteWeiroll(new bytes32[](0), new bytes[](0));
    }

    function testOnlyRecipekernelModifier() public {
        vm.prank(address(0xdead));
        vm.expectRevert(WeirollWallet.NotRecipeKernel.selector);
        wallet.executeWeiroll(new bytes32[](0), new bytes[](0));
    }

    function testNotLockedModifier() public {
        uint256 shortLockTime = block.timestamp + 1 hours;
        WeirollWallet lockedWallet = createWallet(owner, address(mockRecipekernel), AMOUNT, shortLockTime, true, marketHash);

        vm.expectRevert(WeirollWallet.WalletLocked.selector);
        lockedWallet.manualExecuteWeiroll(new bytes32[](0), new bytes[](0));

        // Test that it works after the lock period
        vm.warp(shortLockTime + 1);

        // Execute Weiroll to set executed to true
        vm.prank(address(mockRecipekernel));
        lockedWallet.executeWeiroll(new bytes32[](0), new bytes[](0));

        // This should now succeed as the wallet is unlocked and executed
        lockedWallet.manualExecuteWeiroll(new bytes32[](0), new bytes[](0));
    }

    function testManualExecuteWeiroll() public {
        bytes32[] memory commands = new bytes32[](1);
        bytes[] memory state = new bytes[](1);

        vm.expectRevert(WeirollWallet.WalletLocked.selector);
        wallet.manualExecuteWeiroll(commands, state);

        // Warp time to unlock the wallet
        vm.warp(lockedUntil + 1);

        // This should still fail because the wallet is not executed
        vm.expectRevert("Royco: Order unfilled");
        wallet.manualExecuteWeiroll(commands, state);
    }

    function testExecute() public {
        address target = address(0x1234);
        uint256 value = 0.1 ether;
        bytes memory data = abi.encodeWithSignature("someFunction()");

        vm.expectRevert(WeirollWallet.WalletLocked.selector);
        wallet.execute(target, value, data);

        // Warp time to unlock the wallet
        vm.warp(lockedUntil + 1);

        // Execute Weiroll to set executed to true
        vm.prank(address(mockRecipekernel));
        wallet.executeWeiroll(new bytes32[](0), new bytes[](0));

        // Check if the wallet is now executed
        assertTrue(wallet.executed());

        // Mock the target contract
        vm.etch(target, bytes("mock contract code"));
        vm.mockCall(target, value, data, abi.encode(true));

        // This should now succeed
        wallet.execute(target, value, data);

        // Test with a reverting call
        vm.mockCallRevert(target, value, data, "Mock revert");
        vm.expectRevert("Generic execute proxy failed");
        wallet.execute(target, value, data);
    }

    function testForfeit() public {
        assertFalse(wallet.forfeited());
        mockRecipekernel.forfeitWallet(wallet);
        assertTrue(wallet.forfeited());

        // Test non-forfeitable wallet
        WeirollWallet nonForfeitableWallet = createWallet(owner, address(mockRecipekernel), AMOUNT, lockedUntil, false, marketHash);
        vm.expectRevert(WeirollWallet.WalletNotForfeitable.selector);
        MockRecipekernel(mockRecipekernel).forfeitWallet(nonForfeitableWallet);
    }

    function testReceiveEther() public {
        uint256 initialBalance = address(wallet).balance;

        // Make sure the wallet can receive Ether
        vm.deal(address(this), 1 ether);
        (bool success,) = payable(address(wallet)).call{ value: 1 ether }("");
        assertTrue(success);

        // Check if the balance increased
        assertEq(address(wallet).balance, initialBalance + 1 ether);
    }
}

contract MockRecipekernel {
    function callWallet(WeirollWallet wallet, bytes32[] calldata commands, bytes[] calldata state) external payable returns (bytes[] memory) {
        return wallet.executeWeiroll(commands, state);
    }

    function forfeitWallet(WeirollWallet wallet) external {
        wallet.forfeit();
    }
}
