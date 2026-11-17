// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interfaces for the deployed Morpheus Inference Diamond on Base.
///         PoC runs as a MAINNET FORK against the real deployed bytecode —
///         per Bug Bounty v2 submission requirements (deployed bytecode only).
interface ISessionRouter {
    struct Pool {
        uint128 payoutStart;
        uint128 decreaseInterval;
        uint256 initialReward;
        uint256 rewardDecrease;
    }
    struct OnHold {
        uint256 amount;
        uint128 releaseAt;
    }

    function openSession(address user_, uint256 amount_, bool isDirectPaymentFromUser_, bytes calldata approvalEncoded_, bytes calldata signature_) external returns (bytes32);
    function closeSession(bytes calldata receiptEncoded_, bytes calldata signature_) external;
    function withdrawUserStakes(address user_, uint8 iterations_) external;
    function getUserStakesOnHold(address user_, uint8 iterations_) external view returns (uint256 available_, uint256 hold_);
    function claimForProvider(bytes32 sessionId_) external;
    function stakeToStipend(uint256 amount_, uint128 timestamp_) external view returns (uint256);
    function stipendToStake(uint256 stipend_, uint128 timestamp_) external view returns (uint256);
    function getSessionEnd(uint256 amount_, uint256 pricePerSecond_, uint128 openedAt_) external view returns (uint128);
    function setMaxSessionDuration(uint128 maxSessionDuration_) external;
    function startOfTheDay(uint128 timestamp_) external pure returns (uint128);
    function isBidActive(bytes32 bidId_) external view returns (bool);
}

interface IMarketplace {
    function postModelBid(address provider_, bytes32 modelId_, uint256 pricePerSecond_) external returns (bytes32 bidId);
    function getBidId(address provider_, bytes32 modelId_, uint256 nonce_) external pure returns (bytes32);
}

interface IModelRegistry {
    function modelRegister(address modelOwner_, bytes32 baseModelId_, bytes32 ipfsCID_, uint256 fee_, uint256 amount_, string calldata name_, string[] calldata tags_) external;
    function getModelId(address account_, bytes32 baseModelId_) external pure returns (bytes32);
}

interface IProviderRegistry {
    function providerRegister(address provider_, uint256 amount_, string calldata endpoint_) external;
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}
