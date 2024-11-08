// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "lib/solady/src/tokens/ERC20.sol";
import "lib/solady/src/tokens/ERC4626.sol";

contract DecimalOffsetERC4626 is ERC4626 {

    string internal name_;
    string internal symbol_;
    uint8 internal decimals_;
    address internal asset_;

    constructor(ERC20 _asset) {
        name_ = "MockERC4626";
        symbol_ = "DOH";
        decimals_ = 18;
        asset_ = address(_asset);
    }

    function _decimalsOffset() internal view override returns (uint8) {
        return 12;
    }

    function name() public view override returns (string memory) {
        return name_;
    }

    function symbol() public view override returns (string memory) {
        return symbol_;
    }

    function decimals() public view override returns (uint8) {
        return decimals_;
    }

    function asset() public view override returns (address) {
        return asset_;
    }

    function totalAssets() public view override returns (uint256) {
        return ERC20(asset_).balanceOf(address(this));
    }
}
