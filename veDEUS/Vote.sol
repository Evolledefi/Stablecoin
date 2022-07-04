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
// ========================= Vote =========================
// ========================================================
// DEUS Finance: https://github.com/DeusFinance

// Primary Author(s)
// Vahid: https://github.com/vahid-dev

import "./interfaces/Ive.sol";

contract Vote {
    address public veDeus;

    constructor(address veDeus_) {
        veDeus = veDeus_;
    }

    function balanceOf(address user) public view returns (uint256 balance) {
        uint256 count = Ive(veDeus).balanceOf(user);
        for (uint256 index = 0; index < count; index++) {
            uint256 tokenId = Ive(veDeus).tokenOfOwnerByIndex(user, index);
            balance += Ive(veDeus).balanceOfNFT(tokenId);
        }
    }

    function balanceOfAt(address user, uint256 t) public view returns (uint256 balance) {
        uint256 count = Ive(veDeus).balanceOf(user);
        for (uint256 index = 0; index < count; index++) {
            uint256 tokenId = Ive(veDeus).tokenOfOwnerByIndex(user, index);
            balance += Ive(veDeus).balanceOfNFTAt(tokenId, t);
        }
    }
}

//Dar panah khoda
