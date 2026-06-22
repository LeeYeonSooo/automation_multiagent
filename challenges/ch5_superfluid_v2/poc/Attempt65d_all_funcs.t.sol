// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

interface IIDA {
    function claim(address, address, uint32, address, bytes calldata) external returns (bytes memory);
    function createIndex(address, uint32, bytes calldata) external returns (bytes memory);
    function updateSubscription(address, uint32, address, uint128, bytes calldata) external returns (bytes memory);
    function updateIndex(address, uint32, uint128, bytes calldata) external returns (bytes memory);
    function approveSubscription(address, address, uint32, bytes calldata) external returns (bytes memory);
    function revokeSubscription(address, address, uint32, bytes calldata) external returns (bytes memory);
    function deleteSubscription(address, address, uint32, address, bytes calldata) external returns (bytes memory);
    function distribute(address, uint32, uint256, bytes calldata) external returns (bytes memory);
}

contract Attempt65d_AllFuncs is Test {
    address constant HOST = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address constant IDA  = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant MATICx = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"), 27039967);
    }

    /// @dev Test ALL IDA external functions directly (not through Host)
    /// to see which ones have authorizeTokenAccess and which don't
    function test_all_ida_functions_direct() public {
        bytes memory fakeCtx = hex"00";

        console.log("=== Testing ALL IDA functions for authorizeTokenAccess ===");

        // 1. createIndex
        vm.prank(ATTACKER);
        try IIDA(IDA).createIndex(MATICx, 999, fakeCtx) {
            console.log("createIndex: NO auth (SUCCESS)");
        } catch Error(string memory r) {
            console.log("createIndex:", r);
        } catch { console.log("createIndex: custom error"); }

        // 2. updateIndex
        vm.prank(ATTACKER);
        try IIDA(IDA).updateIndex(MATICx, 999, 1, fakeCtx) {
            console.log("updateIndex: NO auth (SUCCESS)");
        } catch Error(string memory r) {
            console.log("updateIndex:", r);
        } catch { console.log("updateIndex: custom error"); }

        // 3. distribute
        vm.prank(ATTACKER);
        try IIDA(IDA).distribute(MATICx, 999, 100, fakeCtx) {
            console.log("distribute: NO auth (SUCCESS)");
        } catch Error(string memory r) {
            console.log("distribute:", r);
        } catch { console.log("distribute: custom error"); }

        // 4. updateSubscription
        vm.prank(ATTACKER);
        try IIDA(IDA).updateSubscription(MATICx, 999, address(1), 1, fakeCtx) {
            console.log("updateSubscription: NO auth (SUCCESS)");
        } catch Error(string memory r) {
            console.log("updateSubscription:", r);
        } catch { console.log("updateSubscription: custom error"); }

        // 5. approveSubscription
        vm.prank(ATTACKER);
        try IIDA(IDA).approveSubscription(MATICx, address(1), 999, fakeCtx) {
            console.log("approveSubscription: NO auth (SUCCESS)");
        } catch Error(string memory r) {
            console.log("approveSubscription:", r);
        } catch { console.log("approveSubscription: custom error"); }

        // 6. revokeSubscription
        vm.prank(ATTACKER);
        try IIDA(IDA).revokeSubscription(MATICx, address(1), 999, fakeCtx) {
            console.log("revokeSubscription: NO auth (SUCCESS)");
        } catch Error(string memory r) {
            console.log("revokeSubscription:", r);
        } catch { console.log("revokeSubscription: custom error"); }

        // 7. deleteSubscription
        vm.prank(ATTACKER);
        try IIDA(IDA).deleteSubscription(MATICx, address(1), 999, address(2), fakeCtx) {
            console.log("deleteSubscription: NO auth (SUCCESS)");
        } catch Error(string memory r) {
            console.log("deleteSubscription:", r);
        } catch { console.log("deleteSubscription: custom error"); }

        // 8. claim - this one we know lacks auth
        vm.prank(ATTACKER);
        try IIDA(IDA).claim(MATICx, address(1), 999, address(2), fakeCtx) {
            console.log("claim: NO auth (SUCCESS)");
        } catch Error(string memory r) {
            console.log("claim:", r);
        } catch { console.log("claim: custom error"); }

        // Now test from HOST address to distinguish auth checks
        console.log("");
        console.log("=== Same tests from HOST address (to pass token.getHost() check) ===");

        vm.prank(HOST);
        try IIDA(IDA).createIndex(MATICx, 999, fakeCtx) {
            console.log("createIndex from HOST: NO auth (SUCCESS)");
        } catch Error(string memory r) {
            console.log("createIndex from HOST:", r);
        } catch { console.log("createIndex from HOST: custom error"); }

        vm.prank(HOST);
        try IIDA(IDA).updateIndex(MATICx, 999, 1, fakeCtx) {
            console.log("updateIndex from HOST: NO auth (SUCCESS)");
        } catch Error(string memory r) {
            console.log("updateIndex from HOST:", r);
        } catch { console.log("updateIndex from HOST: custom error"); }

        vm.prank(HOST);
        try IIDA(IDA).distribute(MATICx, 999, 100, fakeCtx) {
            console.log("distribute from HOST: NO auth (SUCCESS)");
        } catch Error(string memory r) {
            console.log("distribute from HOST:", r);
        } catch { console.log("distribute from HOST: custom error"); }

        vm.prank(HOST);
        try IIDA(IDA).updateSubscription(MATICx, 999, address(1), 1, fakeCtx) {
            console.log("updateSubscription from HOST: NO auth (SUCCESS)");
        } catch Error(string memory r) {
            console.log("updateSubscription from HOST:", r);
        } catch { console.log("updateSubscription from HOST: custom error"); }

        vm.prank(HOST);
        try IIDA(IDA).approveSubscription(MATICx, address(1), 999, fakeCtx) {
            console.log("approveSubscription from HOST: NO auth (SUCCESS)");
        } catch Error(string memory r) {
            console.log("approveSubscription from HOST:", r);
        } catch { console.log("approveSubscription from HOST: custom error"); }

        vm.prank(HOST);
        try IIDA(IDA).revokeSubscription(MATICx, address(1), 999, fakeCtx) {
            console.log("revokeSubscription from HOST: NO auth (SUCCESS)");
        } catch Error(string memory r) {
            console.log("revokeSubscription from HOST:", r);
        } catch { console.log("revokeSubscription from HOST: custom error"); }

        vm.prank(HOST);
        try IIDA(IDA).deleteSubscription(MATICx, address(1), 999, address(2), fakeCtx) {
            console.log("deleteSubscription from HOST: NO auth (SUCCESS)");
        } catch Error(string memory r) {
            console.log("deleteSubscription from HOST:", r);
        } catch { console.log("deleteSubscription from HOST: custom error"); }

        vm.prank(HOST);
        try IIDA(IDA).claim(MATICx, address(1), 999, address(2), fakeCtx) {
            console.log("claim from HOST: NO auth (SUCCESS)");
        } catch Error(string memory r) {
            console.log("claim from HOST:", r);
        } catch { console.log("claim from HOST: custom error"); }
    }
}
