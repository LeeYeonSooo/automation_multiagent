// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface ICEtherLike {
    function getCash() external view returns (uint256);
}

/// @notice Hypothesis: the current live challenge RPC no longer matches the task
/// input. The student EOA is already far past the "only pool146 drained" state,
/// and the requested follow-up steps target markets that are already dusted out.
contract Attempt2 is Test {
    address constant STUDENT = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    uint256 constant EXPECTED_CHAIN_ID = 2401;
    uint256 constant FORK_BLOCK = 14_684_686;
    uint256 constant TARGET_FINAL_BALANCE = 6_936 ether;
    uint256 constant MIN_LIVE_BALANCE = 6_600 ether;

    ICEtherLike constant FETH_146 = ICEtherLike(0xfbD8Aaf46Ab3C2732FA930e5B343cd67cEA5054C);
    ICEtherLike constant FETH_8 = ICEtherLike(0xbB025D470162CC5eA24daF7d4566064EE7f5F111);
    ICEtherLike constant FETH_182 = ICEtherLike(0xe3dd0202611F3430cFE75959e310342549D64554);

    receive() external payable {}

    function setUp() public {
        vm.createSelectFork("ch3", FORK_BLOCK);
    }

    function test_task_input_is_stale_on_current_rpc() public {
        console.log("CHAIN_ID:", block.chainid);
        console.log("FORK_BLOCK:", block.number);
        console.log("STUDENT_NATIVE_BALANCE:", STUDENT.balance);
        console.log("POOL146_CASH:", FETH_146.getCash());
        console.log("POOL8_CASH:", FETH_8.getCash());
        console.log("POOL182_CASH:", FETH_182.getCash());

        assertEq(block.chainid, EXPECTED_CHAIN_ID, "unexpected challenge chain id");
        assertEq(block.number, FORK_BLOCK, "unexpected fork block");
        assertGt(STUDENT.balance, MIN_LIVE_BALANCE, "student balance is still too low; task input may still be current");
        assertLt(STUDENT.balance, TARGET_FINAL_BALANCE, "target already met; follow-up scan should replace this task");
        assertLe(FETH_146.getCash(), 1, "pool146 is not drained on the current RPC");
        assertLe(FETH_8.getCash(), 1 ether, "pool8 is not yet in dust state on the current RPC");
        assertEq(FETH_182.getCash(), 0, "pool182 is not fully drained on the current RPC");
    }
}
