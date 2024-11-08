// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { ERC20 } from "lib/solady/src/tokens/ERC20.sol";

contract MockERC20 is ERC20 {

    string internal name_;
    string internal symbol_;
    uint8 internal decimals_;

    function name() public view override returns (string memory) {
        return name_;
    }

    function symbol() public view override returns (string memory) {
        return symbol_;
    }

    function decimals() public view override returns (uint8) {
        return decimals_;
    }

    constructor(string memory _name, string memory _symbol) {
        name_ = _name;
        symbol_ = _symbol;
        decimals_ = 18;
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function burn(address to, uint256 amount) public {
        _burn(to, amount);
    }
}
