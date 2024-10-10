// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Points } from "src/Points.sol";
import { RecipeKernel } from "src/RecipeKernel.sol";
import { Ownable2Step, Ownable } from "lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";


/// @title PointsFactory
/// @author CopyPaste, corddry, ShivaanshK
/// @dev A simple factory for creating Points Programs
contract PointsFactory is Ownable2Step {
    /// @notice Mapping of Points Program address => bool (indicator of if Points Program was deployed using this factory)
    mapping(address => bool) public isPointsProgram;

    /// @notice Mapping of RecipeKernel address => bool (indicator of if the address is of a Royco RecipeKernel)
    mapping(address => bool) public isRecipeKernel;

    /// @notice Emitted when creating a points program using this factory
    event NewPointsProgram(Points indexed points, string indexed name, string indexed symbol);

    /// @notice Emitted when adding an RecipeKernel to this Points Factory
    event RecipeKernelAdded(address indexed recipeKernel);

    /// @param _owner The owner of the points factory - responsible for adding valid RecipeKernel(s) to the PointsFactory
    constructor(address _owner) Ownable(_owner) {}

    /// @param _recipeKernel The RecipeKernel to mark as valid in the Points Factory
    function addRecipeKernel(address _recipeKernel) external onlyOwner {
        isRecipeKernel[_recipeKernel] = true;
        emit RecipeKernelAdded(_recipeKernel);
    }

    /// @param _name The name for the new points program
    /// @param _symbol The symbol for the new points program
    /// @param _decimals The amount of decimals per point
    /// @param _owner The owner of the new points program
    function createPointsProgram(
        string memory _name,
        string memory _symbol,
        uint256 _decimals,
        address _owner
    )
        external
        returns (Points points)
    {
        bytes32 salt = keccak256(abi.encodePacked(_name, _symbol, _decimals, _owner));
        points = new Points{salt: salt}(_name, _symbol, _decimals, _owner);
        isPointsProgram[address(points)] = true;

        emit NewPointsProgram(points, _name, _symbol);
    }
}
