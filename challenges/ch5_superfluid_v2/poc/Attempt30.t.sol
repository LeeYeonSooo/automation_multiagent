// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface IREXPublisherLike {
    function owner() external view returns (address);

    function transferOwnership(address newOwner) external;

    function emergencyDrain() external;

    function getTotalInflow() external view returns (int96);
}

interface IGnosisSafeProxyLike {
    function masterCopy() external view returns (address);
}

interface IGnosisSafeLike {
    function getThreshold() external view returns (uint256);

    function nonce() external view returns (uint256);

    function getOwners() external view returns (address[] memory);

    function isOwner(address owner) external view returns (bool);

    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes calldata signatures
    ) external payable returns (bool success);
}

/// @title Attempt30
/// @notice Hypothesis: the live REX publisher ownership chain is hijackable
///         because `publisher.owner()` points at a tiny forwarding proxy whose
///         target is an uninitialized Gnosis Safe-like singleton.
/// @dev The concrete chain requested in the task is:
///      1. call `proxy.execTransaction(... transferOwnership(attacker) ...)`
///         using the `v=1, r=attacker` approved-hash signature path,
///      2. if that fails, call `proxy.transferOwnership(attacker)` directly,
///      3. if ownership moves, call `publisher.emergencyDrain()`,
///      4. additionally probe whether the proxy target in slot `0` is mutable
///         through obvious admin selectors.
/// @dev Live fork inspection already suggests the premise is wrong: `0x9C6B...`
///      is indeed a 171-byte Safe proxy, but its storage is a live 2-of-4 Safe
///      with nonce `295`, not an ownerless threshold-1 shell. This PoC turns
///      that into direct runtime checks and archives the branch cleanly if the
///      takeover path is closed.
contract Attempt30 is Test {
    uint256 internal constant FORK_BLOCK = 27_039_967;

    address internal constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address internal constant PUBLISHER = 0xcaB28480ab5c1E133e9B7FC67E030B8DCC2A1d24;
    address internal constant OWNER_PROXY = 0x9C6B5FdC145912dfe6eE13A667aF3C5Eb07CbB89;
    address internal constant SAFE_SINGLETON = 0x3E5c63644E683549055b9Be8653de26E0B4CD36E;

    address internal constant SAFE_OWNER_0 = 0x5eb449B88Ff8f03cD0C736A72ac70B76258E4B10;
    address internal constant SAFE_OWNER_1 = 0xd964aB7E202Bab8Fbaa28d5cA2B2269A5497Cf68;
    address internal constant SAFE_OWNER_2 = 0xfcDc6352821B3e72a724117d5b56e275327D5FE6;
    address internal constant SAFE_OWNER_3 = 0x9d7254F07b4De4643B409B5971eE2888E279417F;

    bytes4 internal constant EXEC_TRANSACTION_SELECTOR = 0x6a761202;
    bytes4 internal constant CHANGE_MASTER_COPY_SELECTOR = 0x7de7edef;
    bytes4 internal constant CHANGE_IMPLEMENTATION_SELECTOR = 0x17a68dd8;
    bytes4 internal constant UPGRADE_TO_SELECTOR = 0x3659cfe6;

    IREXPublisherLike internal constant publisher = IREXPublisherLike(PUBLISHER);
    IGnosisSafeProxyLike internal constant ownerProxy = IGnosisSafeProxyLike(OWNER_PROXY);
    IGnosisSafeLike internal constant safe = IGnosisSafeLike(OWNER_PROXY);

    function setUp() public {
        vm.createSelectFork("ch5", FORK_BLOCK);

        vm.label(ATTACKER, "Attacker");
        vm.label(PUBLISHER, "REXPublisher");
        vm.label(OWNER_PROXY, "PublisherOwnerProxy");
        vm.label(SAFE_SINGLETON, "ProxyMasterCopy");
        vm.label(SAFE_OWNER_0, "SafeOwner0");
        vm.label(SAFE_OWNER_1, "SafeOwner1");
        vm.label(SAFE_OWNER_2, "SafeOwner2");
        vm.label(SAFE_OWNER_3, "SafeOwner3");
    }

    function test_live_owner_chain_is_initialized_safe_not_ownerless_shell() public {
        address[] memory owners = safe.getOwners();
        bytes32 slot0 = vm.load(OWNER_PROXY, bytes32(uint256(0)));
        int96 inflow = publisher.getTotalInflow();

        console.log("[owner chain] publisher.owner():", publisher.owner());
        console.log("[owner chain] proxy code length:", OWNER_PROXY.code.length);
        console.log("[owner chain] singleton code length:", SAFE_SINGLETON.code.length);
        console.log("[owner chain] threshold:", safe.getThreshold());
        console.log("[owner chain] nonce:", safe.nonce());
        console.log("[owner chain] owners length:", owners.length);
        console.logInt(int256(inflow));
        console.logAddress(owners[0]);
        console.logAddress(owners[1]);
        console.logAddress(owners[2]);
        console.logAddress(owners[3]);

        assertEq(publisher.owner(), OWNER_PROXY, "publisher owner chain changed unexpectedly");
        assertEq(OWNER_PROXY.code.length, 171, "proxy is no longer the expected 171-byte runtime");
        assertEq(SAFE_SINGLETON.code.length, 23800, "singleton code length changed unexpectedly");
        assertEq(ownerProxy.masterCopy(), SAFE_SINGLETON, "proxy masterCopy no longer matches slot0");
        assertEq(address(uint160(uint256(slot0))), SAFE_SINGLETON, "slot0 should hold the proxy target");

        assertEq(owners.length, 4, "proxy Safe is not ownerless");
        assertEq(safe.getThreshold(), 2, "proxy Safe threshold is not the claimed broken value");
        assertEq(safe.nonce(), 295, "proxy Safe nonce changed unexpectedly");
        assertEq(owners[0], SAFE_OWNER_0, "owner[0] mismatch");
        assertEq(owners[1], SAFE_OWNER_1, "owner[1] mismatch");
        assertEq(owners[2], SAFE_OWNER_2, "owner[2] mismatch");
        assertEq(owners[3], SAFE_OWNER_3, "owner[3] mismatch");
        assertFalse(safe.isOwner(ATTACKER), "attacker must not already be an owner");
        assertGt(int256(inflow), 0, "publisher inflow unexpectedly zero");
    }

    function test_execTransaction_with_v1_attacker_signature_path_reverts_GS026() public {
        bytes memory transferOwnershipData = abi.encodeCall(publisher.transferOwnership, (ATTACKER));
        bytes memory signatures = bytes.concat(_approvedHashSignature(ATTACKER), new bytes(65));

        assertEq(signatures.length, 130, "threshold-2 call needs two 65-byte signature slots");
        assertEq(publisher.owner(), OWNER_PROXY, "precondition: proxy must still own publisher");

        vm.prank(ATTACKER);
        (bool ok, bytes memory ret) = OWNER_PROXY.call(
            abi.encodeWithSelector(
                EXEC_TRANSACTION_SELECTOR,
                PUBLISHER,
                0,
                transferOwnershipData,
                uint8(0),
                0,
                0,
                0,
                address(0),
                payable(address(0)),
                signatures
            )
        );

        console.log("[execTransaction] ok:", ok);
        console.log("[execTransaction] revert:", _decodeRevert(ret));
        console.log("[execTransaction] publisher.owner() after:", publisher.owner());

        assertFalse(ok, "single-attacker approved-hash path must not execute the Safe tx");
        assertEq(_decodeRevert(ret), "GS026", "expected owner-check failure for non-owner attacker path");
        assertEq(publisher.owner(), OWNER_PROXY, "publisher owner must remain unchanged after failed execTransaction");
    }

    function test_direct_proxy_transferOwnership_and_admin_probes_do_not_mutate_target_or_owner() public {
        bytes32 slot0Before = vm.load(OWNER_PROXY, bytes32(uint256(0)));

        vm.startPrank(ATTACKER);

        (bool transferOk, bytes memory transferRet) =
            OWNER_PROXY.call(abi.encodeCall(publisher.transferOwnership, (ATTACKER)));
        (bool changeMasterCopyOk, bytes memory changeMasterCopyRet) =
            OWNER_PROXY.call(abi.encodeWithSelector(CHANGE_MASTER_COPY_SELECTOR, ATTACKER));
        (bool changeImplementationOk, bytes memory changeImplementationRet) =
            OWNER_PROXY.call(abi.encodeWithSelector(CHANGE_IMPLEMENTATION_SELECTOR, ATTACKER));
        (bool upgradeToOk, bytes memory upgradeToRet) =
            OWNER_PROXY.call(abi.encodeWithSelector(UPGRADE_TO_SELECTOR, ATTACKER));

        vm.stopPrank();

        bytes32 slot0After = vm.load(OWNER_PROXY, bytes32(uint256(0)));

        console.log("[proxy.transferOwnership] ok:", transferOk);
        console.log("[proxy.transferOwnership] revert:", _decodeRevert(transferRet));
        console.log("[changeMasterCopy] ok:", changeMasterCopyOk);
        console.log("[changeMasterCopy] revert:", _decodeRevert(changeMasterCopyRet));
        console.log("[changeImplementation] ok:", changeImplementationOk);
        console.log("[changeImplementation] revert:", _decodeRevert(changeImplementationRet));
        console.log("[upgradeTo] ok:", upgradeToOk);
        console.log("[upgradeTo] revert:", _decodeRevert(upgradeToRet));

        assertFalse(transferOk, "proxy direct transferOwnership should not be a live admin surface");
        assertFalse(changeMasterCopyOk, "changeMasterCopy must not be attacker-callable");
        assertFalse(changeImplementationOk, "changeImplementation must not be attacker-callable");
        assertFalse(upgradeToOk, "upgradeTo must not be attacker-callable");

        assertEq(slot0After, slot0Before, "slot0 target changed unexpectedly");
        assertEq(address(uint160(uint256(slot0After))), SAFE_SINGLETON, "proxy target should remain the Safe singleton");
        assertEq(ownerProxy.masterCopy(), SAFE_SINGLETON, "masterCopy should remain unchanged");
        assertEq(publisher.owner(), OWNER_PROXY, "publisher owner must remain unchanged");
    }

    function test_emergencyDrain_control_still_fails_on_zero_streamers_guard() public {
        assertGt(int256(publisher.getTotalInflow()), 0, "control only makes sense with a live inflow");

        vm.prank(OWNER_PROXY);
        vm.expectRevert(bytes("!zeroStreamers"));
        publisher.emergencyDrain();
    }

    function _approvedHashSignature(address currentOwner) internal pure returns (bytes memory sig) {
        bytes32 r = bytes32(uint256(uint160(currentOwner)));
        sig = abi.encodePacked(r, bytes32(0), bytes1(uint8(1)));
    }

    function _decodeRevert(bytes memory revertData) internal pure returns (string memory) {
        if (revertData.length == 0) return "<empty>";
        if (revertData.length >= 68 && _selector(revertData) == 0x08c379a0) {
            bytes memory reasonData = new bytes(revertData.length - 4);
            for (uint256 i = 4; i < revertData.length; ++i) {
                reasonData[i - 4] = revertData[i];
            }
            string memory reason = abi.decode(reasonData, (string));
            return reason;
        }
        return "<non-Error(string)>";
    }

    function _selector(bytes memory data) internal pure returns (bytes4 sel) {
        if (data.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(data, 0x20))
        }
    }
}
