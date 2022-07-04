// Be name Khoda
// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

// =================================================================================================================
//  _|_|_|    _|_|_|_|  _|    _|    _|_|_|      _|_|_|_|  _|                                                       |
//  _|    _|  _|        _|    _|  _|            _|            _|_|_|      _|_|_|  _|_|_|      _|_|_|    _|_|       |
//  _|    _|  _|_|_|    _|    _|    _|_|        _|_|_|    _|  _|    _|  _|    _|  _|    _|  _|        _|_|_|_|     |
//  _|    _|  _|        _|    _|        _|      _|        _|  _|    _|  _|    _|  _|    _|  _|        _|           |
//  _|_|_|    _|_|_|_|    _|_|    _|_|_|        _|        _|  _|    _|    _|_|_|  _|    _|    _|_|_|    _|_|_|     |
// =================================================================================================================
// ========================= Multi Sender =========================
// ================================================================
// DEUS Finance: https://github.com/DeusFinance

// Primary Author(s)
// Vahid: https://github.com/vahid-dev

import "./interfaces/Ive.sol";

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @title Multi Sender
/// @author DEUS Finance
/// @notice veDEUS multi sender
contract MultiSender {
    address public veDeus;
    address public owner;

    constructor(address veDeus_) {
        veDeus = veDeus_;
        owner = msg.sender;
        address deus = Ive(veDeus).token();
        IERC20(deus).approve(veDeus_, type(uint256).max);
    }

    function ERC721send(address[] calldata users, uint256[] calldata amounts, uint256[] calldata lock_time) external {
        require(msg.sender == owner, "Only owner can send");
        for (uint256 i = 0; i < users.length; i++) {
            Ive(veDeus).create_lock_for(amounts[i], lock_time[i], users[i]);
        }
    }

    function ERC20send(address token, address[] calldata users, uint256[] calldata amounts) external {
        require(msg.sender == owner, "Only owner can send");
        for (uint256 i = 0; i < users.length; i++) {
            IERC20(token).transfer(users[i], amounts[i]);
        }
    }

    function withdrawERC20(address token, uint256 amount) external {
        require(msg.sender == owner, "Only owner can withdraw");
        require(IERC20(token).transfer(msg.sender, amount), "Failed to transfer");
    }

    function approve(address token, address to, uint256 amount) external {
        require(msg.sender == owner, "Only owner can approve");
        require(IERC20(token).approve(to, amount), "Failed to approve");
    }

    function setOwner(address owner_) external {
        require(msg.sender == owner, "Only owner can set owner");
        owner = owner_;
    }
}

//Dar panah khoda
