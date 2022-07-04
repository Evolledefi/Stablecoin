// Be name Khoda
// Bime Abolfazl

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.6.11;

interface IDEIPool {
    function minting_fee() external returns (uint256);
    function redemption_fee() external returns (uint256);
    function buyback_fee() external returns (uint256);
    function recollat_fee() external returns (uint256);
    function collatDollarBalance() external returns (uint256);
    function availableExcessCollatDV() external returns (uint256);
    function getCollateralPrice() external returns (uint256);
    function setCollatETHOracle(address _collateral_weth_oracle_address, address _weth_address) external;
    function mint1t1DEI(uint256 collateral_amount, uint256 DEI_out_min) external;
    function mintAlgorithmicDEI(uint256 deus_amount_d18, uint256 DEI_out_min) external;
    function mintFractionalDEI(uint256 collateral_amount, uint256 deus_amount, uint256 DEI_out_min) external;
    function redeem1t1DEI(uint256 DEI_amount, uint256 COLLATERAL_out_min) external;
    function redeemFractionalDEI(uint256 DEI_amount, uint256 DEUS_out_min, uint256 COLLATERAL_out_min) external;
    function redeemAlgorithmicDEI(uint256 DEI_amount, uint256 DEUS_out_min) external;
    function collectRedemption() external;
    function recollateralizeDEI(uint256 collateral_amount, uint256 DEUS_out_min) external;
    function buyBackDEUS(uint256 DEUS_amount, uint256 COLLATERAL_out_min) external;
    function toggleMinting() external;
    function toggleRedeeming() external;
    function toggleRecollateralize() external;
    function toggleBuyBack() external;
    function toggleCollateralPrice(uint256 _new_price) external;
    function setPoolParameters(uint256 new_ceiling, uint256 new_bonus_rate, uint256 new_redemption_delay, uint256 new_mint_fee, uint256 new_redeem_fee, uint256 new_buyback_fee, uint256 new_recollat_fee) external;
    function setTimelock(address new_timelock) external;
    function setOwner(address _owner_address) external;
}

//Dar panah khoda