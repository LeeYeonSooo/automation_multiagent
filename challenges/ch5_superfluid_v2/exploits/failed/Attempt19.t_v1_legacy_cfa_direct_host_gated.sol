// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface ISuperAgreement {}

interface ISuperToken {
    function balanceOf(address account) external view returns (uint256);
    function getHost() external view returns (address);
}

interface ISETH is ISuperToken {
    function upgradeByETH() external payable;
}

interface ISuperfluidHost {
    function callAgreement(
        ISuperAgreement agreementClass,
        bytes calldata callData,
        bytes calldata userData
    ) external returns (bytes memory returnedData);
}

interface ILegacyCFA is ISuperAgreement {
    function getMaximumFlowRateFromDeposit(ISuperToken token, uint256 deposit) external view returns (int96);
    function getDepositRequiredForFlowRate(ISuperToken token, int96 flowRate) external view returns (uint256);
    function createFlow(
        ISuperToken token,
        address receiver,
        int96 flowRate,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);
    function updateFlow(
        ISuperToken token,
        address receiver,
        int96 flowRate,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);
    function getFlow(
        ISuperToken token,
        address sender,
        address receiver
    ) external view returns (uint256 timestamp, int96 flowRate, uint256 deposit, uint256 owedDeposit);
    function getFlowByID(ISuperToken token, bytes32 agreementId)
        external
        view
        returns (uint256 timestamp, int96 flowRate, uint256 deposit, uint256 owedDeposit);
    function getAccountFlowInfo(ISuperToken token, address account)
        external
        view
        returns (uint256 timestamp, int96 flowRate, uint256 deposit, uint256 owedDeposit);
    function getNetFlow(ISuperToken token, address account) external view returns (int96);
    function deleteFlow(
        ISuperToken token,
        address sender,
        address receiver,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);
    function agreementType() external pure returns (bytes32);
    function isPatricianPeriodNow(ISuperToken token, address account) external view returns (bool, uint256);
    function realtimeBalanceOf(ISuperToken token, address account, uint256 timestamp)
        external
        view
        returns (int256, uint256, uint256);
    function getCodeAddress() external view returns (address);
    function proxiableUUID() external view returns (bytes32);
    function updateCode(address newAddress) external;
    function isPatricianPeriod(ISuperToken token, address account, uint256 timestamp) external view returns (bool);
}

interface ICurrentCFAExtraSurface {
    function updateFlowOperatorPermissions(
        ISuperToken token,
        address flowOperator,
        uint8 permissions,
        int96 flowRateAllowance,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);
    function increaseFlowRateAllowance(ISuperToken token, address flowOperator, int96 addedFlowRateAllowance, bytes calldata ctx)
        external
        returns (bytes memory newCtx);
    function decreaseFlowRateAllowance(
        ISuperToken token,
        address flowOperator,
        int96 subtractedFlowRateAllowance,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);
    function increaseFlowRateAllowanceWithPermissions(
        ISuperToken token,
        address flowOperator,
        uint8 permissionsToAdd,
        int96 addedFlowRateAllowance,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);
    function decreaseFlowRateAllowanceWithPermissions(
        ISuperToken token,
        address flowOperator,
        uint8 permissionsToRemove,
        int96 subtractedFlowRateAllowance,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);
    function authorizeFlowOperatorWithFullControl(ISuperToken token, address flowOperator, bytes calldata ctx)
        external
        returns (bytes memory newCtx);
    function revokeFlowOperatorWithFullControl(ISuperToken token, address flowOperator, bytes calldata ctx)
        external
        returns (bytes memory newCtx);
    function getFlowOperatorData(ISuperToken token, address sender, address flowOperator)
        external
        view
        returns (bytes32 flowOperatorId, uint8 permissions, int96 flowRateAllowance);
    function getFlowOperatorDataByID(ISuperToken token, bytes32 flowOperatorId)
        external
        view
        returns (uint8 permissions, int96 flowRateAllowance);
    function createFlowByOperator(
        ISuperToken token,
        address sender,
        address receiver,
        int96 flowRate,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);
    function updateFlowByOperator(
        ISuperToken token,
        address sender,
        address receiver,
        int96 flowRate,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);
    function deleteFlowByOperator(
        ISuperToken token,
        address sender,
        address receiver,
        bytes calldata ctx
    ) external returns (bytes memory newCtx);
}

/// @title Attempt19
/// @notice Hypothesis: the live fork CFA is an older 16-selector legacy surface,
///         but no direct mutator path on that surface bypasses Host stamping.
///         The test systematically compares direct proxy calls against
///         `HOST.callAgreement(...)` controls for every live CFA mutator that
///         still exists on the fork runtime.
/// @dev Legacy live mutators are the old `createFlow`, `updateFlow`, and
///      `deleteFlow` entries archived at
///      `sources/ch5_superfluid_v2/0xcab28480.../IConstantFlowAgreementV1.sol`
///      lines 56-63, 84-91, and 185-192.
/// @dev The modern flow-operator surface that is absent on the fork is archived
///      at
///      `sources/ch5_superfluid_v2/0x85eb36.../IConstantFlowAgreementV1.sol`
///      lines 104-209, 220-247, 284-292, 332-340, and 454-461.
/// @dev The shared host/ctx gate expected for agreement implementations lives at
///      `sources/ch5_superfluid_v2/0xa99a19.../AgreementLibrary.sol:36-45`.
/// @dev The fork Host control path that should make the same calls succeed lives
///      at
///      `sources/ch5_superfluid_v2/0x513b7c.../Superfluid.sol:573-609`.
contract Attempt19 is Test {
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    uint256 constant FORK_BLOCK = 27_039_967;

    address constant CFA_PROXY = 0x6EeE6060f715257b970700bc2656De21dEdF074C;
    address constant CFA_IMPL = 0xf0ec6A8842Ca72Aec8A4D4573E731242389e18A8;
    bytes32 constant EIP1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    int96 constant FLOW_RATE_INITIAL = 1;
    int96 constant FLOW_RATE_UPDATED = 2;

    ISuperfluidHost constant HOST = ISuperfluidHost(0x3E14dC1b13c488a8d5D310918780c983bD5982E7);
    ILegacyCFA constant CFA = ILegacyCFA(CFA_PROXY);
    ISETH constant MATICX = ISETH(0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3);

    address internal receiverCreate;
    address internal receiverUpdate;
    address internal receiverDelete;

    function setUp() public {
        vm.createSelectFork("ch5", FORK_BLOCK);

        receiverCreate = makeAddr("receiverCreate");
        receiverUpdate = makeAddr("receiverUpdate");
        receiverDelete = makeAddr("receiverDelete");

        vm.label(ATTACKER, "Attacker");
        vm.label(CFA_PROXY, "CFAProxy");
        vm.label(CFA_IMPL, "CFAImplementation");
        vm.label(address(HOST), "SuperfluidHost");
        vm.label(address(MATICX), "MATICx");
        vm.label(receiverCreate, "ReceiverCreate");
        vm.label(receiverUpdate, "ReceiverUpdate");
        vm.label(receiverDelete, "ReceiverDelete");
    }

    function test_cfa_direct_surface_matrix() public {
        _prepareAttackerBalances();

        uint256 nativeBefore = ATTACKER.balance;
        uint256 tokenBefore = MATICX.balanceOf(ATTACKER);
        address implBefore = _implementationOf(CFA_PROXY);

        console.log("[start] attacker native:", nativeBefore);
        console.log("[start] attacker MATICx:", tokenBefore);
        console.log("[preflight] chain id:", block.chainid);
        console.log("[preflight] fork block:", block.number);
        console.log("[preflight] MATICx host:", MATICX.getHost());
        console.log("[preflight] CFA proxy impl:", implBefore);

        _assertSelectorSurface();

        uint256 requiredDeposit = CFA.getDepositRequiredForFlowRate(MATICX, FLOW_RATE_INITIAL);
        console.log("[preflight] deposit required for rate 1:", requiredDeposit);

        _probeCreateFlow();
        _probeUpdateFlow();
        _probeDeleteFlow();
        _probeUpdateCode(implBefore);

        uint256 nativeAfter = ATTACKER.balance;
        uint256 tokenAfter = MATICX.balanceOf(ATTACKER);
        uint256 expectedTokenAfter = tokenBefore - (requiredDeposit * 2);

        console.log("[end] attacker native:", nativeAfter);
        console.log("[end] attacker MATICx:", tokenAfter);
        assertEq(nativeAfter, nativeBefore, "Attempt19 is diagnostic only and should not change attacker native balance");
        assertEq(tokenAfter, expectedTokenAfter, "two live host-created flows should retain exactly two minimum CFA deposits");
    }

    function _assertSelectorSurface() internal view {
        bytes4[] memory runtimeSelectors = _extractDispatcherSelectors(CFA_IMPL.code);
        _sort(runtimeSelectors);

        console.log("[cfa] runtime selector count:", runtimeSelectors.length);
        assertEq(runtimeSelectors.length, 16, "fork CFA should expose the 16-selector legacy surface");

        assertTrue(_contains(runtimeSelectors, ILegacyCFA.createFlow.selector), "legacy createFlow must exist");
        assertTrue(_contains(runtimeSelectors, ILegacyCFA.updateFlow.selector), "legacy updateFlow must exist");
        assertTrue(_contains(runtimeSelectors, ILegacyCFA.deleteFlow.selector), "legacy deleteFlow must exist");
        assertTrue(_contains(runtimeSelectors, ILegacyCFA.updateCode.selector), "legacy updateCode must exist");

        assertFalse(
            _contains(runtimeSelectors, ICurrentCFAExtraSurface.updateFlowOperatorPermissions.selector),
            "modern updateFlowOperatorPermissions must not exist on fork CFA"
        );
        assertFalse(
            _contains(runtimeSelectors, ICurrentCFAExtraSurface.increaseFlowRateAllowance.selector),
            "modern increaseFlowRateAllowance must not exist on fork CFA"
        );
        assertFalse(
            _contains(runtimeSelectors, ICurrentCFAExtraSurface.decreaseFlowRateAllowance.selector),
            "modern decreaseFlowRateAllowance must not exist on fork CFA"
        );
        assertFalse(
            _contains(runtimeSelectors, ICurrentCFAExtraSurface.increaseFlowRateAllowanceWithPermissions.selector),
            "modern increaseFlowRateAllowanceWithPermissions must not exist on fork CFA"
        );
        assertFalse(
            _contains(runtimeSelectors, ICurrentCFAExtraSurface.decreaseFlowRateAllowanceWithPermissions.selector),
            "modern decreaseFlowRateAllowanceWithPermissions must not exist on fork CFA"
        );
        assertFalse(
            _contains(runtimeSelectors, ICurrentCFAExtraSurface.authorizeFlowOperatorWithFullControl.selector),
            "modern authorizeFlowOperatorWithFullControl must not exist on fork CFA"
        );
        assertFalse(
            _contains(runtimeSelectors, ICurrentCFAExtraSurface.revokeFlowOperatorWithFullControl.selector),
            "modern revokeFlowOperatorWithFullControl must not exist on fork CFA"
        );
        assertFalse(
            _contains(runtimeSelectors, ICurrentCFAExtraSurface.getFlowOperatorData.selector),
            "modern getFlowOperatorData must not exist on fork CFA"
        );
        assertFalse(
            _contains(runtimeSelectors, ICurrentCFAExtraSurface.getFlowOperatorDataByID.selector),
            "modern getFlowOperatorDataByID must not exist on fork CFA"
        );
        assertFalse(
            _contains(runtimeSelectors, ICurrentCFAExtraSurface.createFlowByOperator.selector),
            "modern createFlowByOperator must not exist on fork CFA"
        );
        assertFalse(
            _contains(runtimeSelectors, ICurrentCFAExtraSurface.updateFlowByOperator.selector),
            "modern updateFlowByOperator must not exist on fork CFA"
        );
        assertFalse(
            _contains(runtimeSelectors, ICurrentCFAExtraSurface.deleteFlowByOperator.selector),
            "modern deleteFlowByOperator must not exist on fork CFA"
        );
    }

    function _probeCreateFlow() internal {
        console.log("[probe] createFlow");

        vm.prank(ATTACKER);
        (bool directOk, bytes memory directRet) =
            address(CFA).call(abi.encodeCall(CFA.createFlow, (MATICX, receiverCreate, FLOW_RATE_INITIAL, new bytes(0))));
        _logCall("direct_createFlow", directOk, directRet);
        assertFalse(directOk, "direct createFlow unexpectedly succeeded");
        _assertUnauthorizedHost(directRet);

        vm.prank(ATTACKER);
        (bool hostOk, bytes memory hostRet) =
            _callHost(abi.encodeCall(CFA.createFlow, (MATICX, receiverCreate, FLOW_RATE_INITIAL, new bytes(0))));
        _logCall("host_createFlow", hostOk, hostRet);
        require(hostOk, string.concat("host createFlow failed: ", _decodeRevert(hostRet)));

        (, int96 flowRate,,) = CFA.getFlow(MATICX, ATTACKER, receiverCreate);
        console.log("  flowRate after host create:", flowRate);
        assertEq(flowRate, FLOW_RATE_INITIAL, "host createFlow must create the legacy flow");
    }

    function _probeUpdateFlow() internal {
        console.log("[probe] updateFlow");

        vm.prank(ATTACKER);
        (bool hostCreateOk, bytes memory hostCreateRet) =
            _callHost(abi.encodeCall(CFA.createFlow, (MATICX, receiverUpdate, FLOW_RATE_INITIAL, new bytes(0))));
        require(hostCreateOk, string.concat("host createFlow setup failed: ", _decodeRevert(hostCreateRet)));

        vm.prank(ATTACKER);
        (bool directOk, bytes memory directRet) =
            address(CFA).call(abi.encodeCall(CFA.updateFlow, (MATICX, receiverUpdate, FLOW_RATE_UPDATED, new bytes(0))));
        _logCall("direct_updateFlow", directOk, directRet);
        assertFalse(directOk, "direct updateFlow unexpectedly succeeded");
        _assertUnauthorizedHost(directRet);

        vm.prank(ATTACKER);
        (bool hostOk, bytes memory hostRet) =
            _callHost(abi.encodeCall(CFA.updateFlow, (MATICX, receiverUpdate, FLOW_RATE_UPDATED, new bytes(0))));
        _logCall("host_updateFlow", hostOk, hostRet);
        require(hostOk, string.concat("host updateFlow failed: ", _decodeRevert(hostRet)));

        (, int96 flowRate,,) = CFA.getFlow(MATICX, ATTACKER, receiverUpdate);
        console.log("  flowRate after host update:", flowRate);
        assertEq(flowRate, FLOW_RATE_UPDATED, "host updateFlow must update the legacy flow");
    }

    function _probeDeleteFlow() internal {
        console.log("[probe] deleteFlow");

        vm.prank(ATTACKER);
        (bool hostCreateOk, bytes memory hostCreateRet) =
            _callHost(abi.encodeCall(CFA.createFlow, (MATICX, receiverDelete, FLOW_RATE_INITIAL, new bytes(0))));
        require(hostCreateOk, string.concat("host createFlow delete-setup failed: ", _decodeRevert(hostCreateRet)));

        vm.prank(ATTACKER);
        (bool directSenderOk, bytes memory directSenderRet) = address(CFA).call(
            abi.encodeCall(CFA.deleteFlow, (MATICX, ATTACKER, receiverDelete, new bytes(0)))
        );
        _logCall("direct_deleteFlow_sender", directSenderOk, directSenderRet);
        assertFalse(directSenderOk, "direct sender deleteFlow unexpectedly succeeded");
        _assertUnauthorizedHost(directSenderRet);

        vm.prank(receiverDelete);
        (bool directReceiverOk, bytes memory directReceiverRet) = address(CFA).call(
            abi.encodeCall(CFA.deleteFlow, (MATICX, ATTACKER, receiverDelete, new bytes(0)))
        );
        _logCall("direct_deleteFlow_receiver", directReceiverOk, directReceiverRet);
        assertFalse(directReceiverOk, "direct receiver deleteFlow unexpectedly succeeded");
        _assertUnauthorizedHost(directReceiverRet);

        vm.prank(receiverDelete);
        (bool hostOk, bytes memory hostRet) =
            _callHost(abi.encodeCall(CFA.deleteFlow, (MATICX, ATTACKER, receiverDelete, new bytes(0))));
        _logCall("host_deleteFlow_receiver", hostOk, hostRet);
        require(hostOk, string.concat("host receiver deleteFlow failed: ", _decodeRevert(hostRet)));

        (, int96 flowRate,,) = CFA.getFlow(MATICX, ATTACKER, receiverDelete);
        console.log("  flowRate after host delete:", flowRate);
        assertEq(flowRate, 0, "host deleteFlow must terminate the legacy flow");
    }

    function _probeUpdateCode(address implBefore) internal {
        console.log("[probe] updateCode");

        vm.prank(ATTACKER);
        (bool ok, bytes memory ret) = address(CFA).call(abi.encodeCall(CFA.updateCode, (ATTACKER)));
        _logCall("direct_updateCode", ok, ret);
        assertFalse(ok, "direct updateCode unexpectedly succeeded");

        address implAfter = _implementationOf(CFA_PROXY);
        console.log("  impl after direct updateCode:", implAfter);
        assertEq(implAfter, implBefore, "implementation slot must remain unchanged");
    }

    function _callHost(bytes memory inner) internal returns (bool ok, bytes memory ret) {
        return address(HOST).call(abi.encodeCall(HOST.callAgreement, (CFA, inner, new bytes(0))));
    }

    function _prepareAttackerBalances() internal {
        vm.deal(ATTACKER, 20 ether);
        vm.prank(ATTACKER);
        MATICX.upgradeByETH{value: 10 ether}();
    }

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, EIP1967_IMPLEMENTATION_SLOT))));
    }

    function _extractDispatcherSelectors(bytes memory runtime) internal pure returns (bytes4[] memory selectors) {
        bytes4[] memory temp = new bytes4[](32);
        uint256 count;

        for (uint256 i = 0; i + 5 < runtime.length; ++i) {
            if (runtime[i] != 0x63 || runtime[i + 5] != 0x14) continue;

            bytes4 selector;
            assembly {
                selector := mload(add(add(runtime, 0x20), add(i, 1)))
            }

            if (_contains(temp, count, selector)) continue;
            temp[count] = selector;
            ++count;
        }

        selectors = new bytes4[](count);
        for (uint256 i = 0; i < count; ++i) {
            selectors[i] = temp[i];
        }
    }

    function _sort(bytes4[] memory selectors) internal pure {
        for (uint256 i = 0; i < selectors.length; ++i) {
            for (uint256 j = i + 1; j < selectors.length; ++j) {
                if (uint32(selectors[j]) < uint32(selectors[i])) {
                    bytes4 tmp = selectors[i];
                    selectors[i] = selectors[j];
                    selectors[j] = tmp;
                }
            }
        }
    }

    function _contains(bytes4[] memory selectors, bytes4 selector) internal pure returns (bool) {
        return _contains(selectors, selectors.length, selector);
    }

    function _contains(bytes4[] memory selectors, uint256 length, bytes4 selector) internal pure returns (bool) {
        for (uint256 i = 0; i < length; ++i) {
            if (selectors[i] == selector) return true;
        }
        return false;
    }

    function _assertUnauthorizedHost(bytes memory revertData) internal pure {
        string memory decoded = _decodeRevert(revertData);
        bool ok = _eq(decoded, "unauthorized host") || _eq(decoded, "AgreementLibrary: unauthorized host");
        require(ok, string.concat("expected unauthorized-host gate, got: ", decoded));
    }

    function _eq(string memory lhs, string memory rhs) internal pure returns (bool) {
        return keccak256(bytes(lhs)) == keccak256(bytes(rhs));
    }

    function _logCall(string memory label, bool ok, bytes memory ret) internal pure {
        console.log("[call]", label);
        console.log("  ok:", ok);
        if (ok) {
            if (ret.length > 0) {
                console.log("  return bytes:");
                console.logBytes(ret);
            }
        } else {
            console.log("  decoded:");
            console.log(_decodeRevert(ret));
            console.log("  raw:");
            console.logBytes(ret);
        }
    }

    function _decodeRevert(bytes memory revertData) internal pure returns (string memory) {
        if (revertData.length < 4) {
            if (revertData.length == 0) return "silent revert";
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
}
