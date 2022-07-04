// SPDX-License-Identifier: MIT

struct Observation {
    uint256 timestamp;
    uint256 reserve0Cumulative;
    uint256 reserve1Cumulative;
}

interface IBaseV1Pair {
    function observations(uint256 index)
        external
        view
        returns (Observation calldata);

    function observationLength() external view returns (uint256);

    function token0() external view returns (address);

    function token1() external view returns (address);

    function stable() external view returns (bool);
}
