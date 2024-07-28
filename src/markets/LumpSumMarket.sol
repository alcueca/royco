// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Market, MarketType} from "./interfaces/Market.sol";

import {OrderFactory} from "./interfaces/OrderFactory.sol";
import {Order} from "../Order.sol";

import {ERC20} from "../../lib/solmate/src/tokens/ERC20.sol";

/// @title Lump Sum Market
/// @author Royco
/// @notice Market contract for lump sum rewards.
contract LumpSumMarket is Market, OrderFactory {
    /*//////////////////////////////////////////////////////////////
                            INITIALIZE
    //////////////////////////////////////////////////////////////*/

    /// @notice Array of tokens utilized as rewards in the market.
    ERC20[] public tokens;

    /// @notice Array of weiroll commands representing the market action.
    bytes32[] public weirollCommands;

    /// @notice Returns the market type
    MarketType public constant override getMarketType = MarketType.LUMP_SUM;

    /// @notice Initializes the contract.
    /// @param _orderImplementation Address of the order implementation contract.
    /// @param _tokens Array of tokens utilized as rewards in the market.
    /// @param _weirollCommands Array of weiroll commands representing the market action.
    function initialize(
        address _orderImplementation,
        ERC20[] calldata _tokens,
        bytes32[] calldata _weirollCommands
    ) external {
        // TODO: The order implementation contract can be passed as an immutable argument.
        orderImplementation = _orderImplementation;
        tokens = _tokens;
        weirollCommands = _weirollCommands;
    }

    /*//////////////////////////////////////////////////////////////
                         ORDER CREATION LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice New order creation event.
    event OrderCreated(Order.Side indexed side, address indexed order, address indexed owner);

    /// @notice Deploy a new Action Order.
    /// @param tokenAmounts Array of token amounts requested as rewards.
    /// @param weirollState Array of weiroll state to passed into the market action.
    function createActionOrder(uint256[] calldata tokenAmounts, bytes[] calldata weirollState) external {
        // Deploy the clone.
        Order clone = Order(deployClone(msg.sender, address(this), uint256(Order.Side.ActionOrder)));

        // Initialize the order.
        clone.initialize(tokenAmounts, weirollState);

        // Emit the event.
        emit OrderCreated(Order.Side.ActionOrder, address(clone), msg.sender);
    }

    /// @notice Deploy a new Reward Order.
    /// @param tokenAmounts Array of token amounts to be utilized as rewards.
    /// @param weirollState Array of requested weiroll state to be passed into the market action.
    function createRewardOrder(uint256[] calldata tokenAmounts, bytes[] calldata weirollState) external {
        // Deploy the clone.
        Order clone = Order(deployClone(msg.sender, address(this), uint256(Order.Side.RewardOrder)));

        // Initialize the order.
        clone.initialize(tokenAmounts, weirollState);

        // Emit the event.
        emit OrderCreated(Order.Side.RewardOrder, address(clone), msg.sender);

        // Transfer the tokens to the order which will hold them until the order is executed.
        for (uint256 i = 0; i < tokens.length; i++) {
            tokens[i].transferFrom(msg.sender, address(clone), tokenAmounts[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          ORDER MATCHING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Match an Action Order with a Reward Order.
    /// @param rewardOrder Address of the Reward Order.
    /// @param actionOrder Address of the Action Order.
    /// @dev This function will fail if the orders belong to different markets so no need to check.
    function matchOrders(Order rewardOrder, Order actionOrder) external {
        // Ensure that the orders are matchable.
        validateOrders(rewardOrder, actionOrder);

        // Execute the weiroll commands.
        // This should fail if the Action Order is not executed successfully.
        actionOrder.executeWeiroll(weirollCommands);

        // Transfer the tokens to the action order owner.
        rewardOrder.distributeRewards(tokens, rewardOrder.owner());
    }

    /// @notice Ensure that two orders are matchable.
    /// @param rewardOrder Address of the Reward Order.
    /// @param actionOrder Address of the Action Order.
    /// TODO: THE CRIETERIA FOR MATCHING ORDERS NEEDS TO BE DEFINED.
    function validateOrders(Order rewardOrder, Order actionOrder) public view {
        // Ensure that the orders are of the correct sides.
        require(rewardOrder.side() == Order.Side.RewardOrder, "LumpSumMarket: reward order is not a Reward Order");
        require(actionOrder.side() == Order.Side.ActionOrder, "LumpSumMarket: action order is not an Action Order");

        // Store the length of the token amounts and weiroll state arrays.
        uint256 tokenAmountsLength = rewardOrder.getAmounts().length;
        uint256 weirollStateLength = rewardOrder.getWeirollState().length;

        // Ensure that the token amounts and weiroll state arrays are of the same length.
        require(tokenAmountsLength == actionOrder.getAmounts().length, "LumpSumMarket: token amounts length mismatch");
        require(
            weirollStateLength == actionOrder.getWeirollState().length,
            "LumpSumMarket: weiroll state length mismatch"
        );

        // Ensure that the values of the token amounts and weiroll state arrays are the same.
        for (uint256 i = 0; i < tokenAmountsLength; i++) {
            require(rewardOrder.amounts(i) == actionOrder.amounts(i), "LumpSumMarket: token amounts mismatch");
        }
        for (uint256 i = 0; i < weirollStateLength; i++) {
            require(
                compareBytes(rewardOrder.weirollState(i), actionOrder.weirollState(i)),
                "LumpSumMarket: weiroll state mismatch"
            );
        }
    }

    /// @notice Compare two bytes arrays.
    function compareBytes(bytes memory a, bytes memory b) internal pure returns (bool) {
        return keccak256(a) == keccak256(b);
    }

    /*//////////////////////////////////////////////////////////////
                        ORDER CANCELATION LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Cancel an order.
    /// @param order Address of the order to be cancelled.
    function cancelOrder(address order) external {
        // Cast the order to the Order contract.
        Order castedOrder = Order(order);

        // Ensure that the order is owned by the caller.
        require(castedOrder.owner() == msg.sender, "LumpSumMarket: caller is not the owner of the order");

        // Cancel the order.
        castedOrder.cancel(tokens);
    }
}