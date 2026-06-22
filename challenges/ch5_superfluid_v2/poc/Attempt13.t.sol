// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface IForkIDAStaticViews {
    function MAX_NUM_SUBSCRIPTIONS() external view returns (uint256);
    function SLOTS_BITMAP_LIBRARY_ADDRESS() external view returns (address);
}

interface IPublicIDASurface {
    function MAX_NUM_SUBSCRIPTIONS() external;
    function SLOTS_BITMAP_LIBRARY_ADDRESS() external;
    function agreementType() external;
    function approveSubscription(address token, address publisher, uint32 indexId, bytes calldata ctx) external;
    function calculateDistribution(address token, address publisher, uint32 indexId, uint256 amount) external;
    function castrate() external;
    function claim(address token, address publisher, uint32 indexId, address subscriber, bytes calldata ctx) external;
    function createIndex(address token, uint32 indexId, bytes calldata ctx) external;
    function deleteSubscription(address token, address publisher, uint32 indexId, address subscriber, bytes calldata ctx)
        external;
    function distribute(address token, uint32 indexId, uint256 amount, bytes calldata ctx) external;
    function getCodeAddress() external;
    function getIndex(address token, address publisher, uint32 indexId) external;
    function getSubscription(address token, address publisher, uint32 indexId, address subscriber) external;
    function getSubscriptionByID(address token, bytes32 subscriptionId) external;
    function listSubscriptions(address token, address subscriber) external;
    function proxiableUUID() external;
    function realtimeBalanceOf(address token, address account, uint256 timestamp) external;
    function revokeSubscription(address token, address publisher, uint32 indexId, bytes calldata ctx) external;
    function updateCode(address newAddress) external;
    function updateIndex(address token, uint32 indexId, uint128 indexValue, bytes calldata ctx) external;
    function updateSubscription(address token, uint32 indexId, address subscriber, uint128 units, bytes calldata ctx)
        external;
}

/// @title Attempt13
/// @notice Hypothesis: the fork-only unverified IDA implementation at
///         `0x8484...19A7` may expose extra external selectors that do not
///         exist in the public verified IDA ABI, giving us a hidden surface
///         outside the conventional `claim()` path.
///
///         This probe reads the live fork implementation bytecode directly and
///         extracts dispatcher selectors using the standard `PUSH4 <selector> EQ`
///         pattern. It then compares that set against the full public IDA ABI
///         selector set. If the fork has no extra selectors, the "hidden
///         fork-only function" branch is closed.
contract Attempt13 is Test {
    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    uint256 constant FORK_BLOCK = 27_039_967;

    address constant IDA_PROXY = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant FORK_IDA_IMPL = 0x848497975f5757Aa1a48e13bbF46D330E62b19A7;
    address constant EXPECTED_SLOTS_BITMAP_LIBRARY = 0xA55632254Bc9F739bDe7191c8a4510aDdae3ef6D;

    function setUp() public {
        vm.createSelectFork("ch5", FORK_BLOCK);

        vm.label(ATTACKER, "Attacker");
        vm.label(IDA_PROXY, "IDAProxy");
        vm.label(FORK_IDA_IMPL, "ForkIDAImplementation");
        vm.label(EXPECTED_SLOTS_BITMAP_LIBRARY, "SlotsBitmapLibrary");
    }

    function test_fork_ida_has_no_hidden_extra_external_selectors() public {
        uint256 nativeBefore = ATTACKER.balance;
        console.log("[start] attacker native:", nativeBefore);
        console.log("[preflight] chain id:", block.chainid);
        console.log("[preflight] fork block:", block.number);
        console.log("[preflight] ida proxy:", IDA_PROXY);
        console.log("[preflight] ida implementation:", FORK_IDA_IMPL);

        bytes memory runtime = FORK_IDA_IMPL.code;
        console.log("[fork] runtime code size:", runtime.length);
        assertGt(runtime.length, 0, "fork IDA implementation must have runtime code");

        bytes4[] memory forkSelectors = _extractDispatcherSelectors(runtime);
        bytes4[] memory publicSelectors = _publicSelectors();
        _sort(forkSelectors);
        _sort(publicSelectors);

        console.log("[fork] extracted selector count:", forkSelectors.length);
        console.log("[public] ABI selector count:", publicSelectors.length);
        _logSelectors("[fork selectors]", forkSelectors);

        bytes4[] memory forkOnly = _difference(forkSelectors, publicSelectors);
        bytes4[] memory publicOnly = _difference(publicSelectors, forkSelectors);

        console.log("[fork only] count:", forkOnly.length);
        _logSelectors("[fork only]", forkOnly);
        console.log("[public only] count:", publicOnly.length);
        _logSelectors("[public only]", publicOnly);

        address slotsBitmapLibrary = IForkIDAStaticViews(FORK_IDA_IMPL).SLOTS_BITMAP_LIBRARY_ADDRESS();
        console.log("[control] SLOTS_BITMAP_LIBRARY_ADDRESS:", slotsBitmapLibrary);
        assertEq(
            slotsBitmapLibrary,
            EXPECTED_SLOTS_BITMAP_LIBRARY,
            "fork getter should still resolve the slots bitmap library"
        );

        (bool maxNumOk,) = address(FORK_IDA_IMPL).staticcall(
            abi.encodeWithSelector(IForkIDAStaticViews.MAX_NUM_SUBSCRIPTIONS.selector)
        );
        console.log("[control] MAX_NUM_SUBSCRIPTIONS present:", maxNumOk);
        assertFalse(maxNumOk, "fork implementation should not expose MAX_NUM_SUBSCRIPTIONS()");

        assertEq(forkOnly.length, 0, "fork implementation should not expose fork-only selectors");
        assertEq(publicOnly.length, 2, "fork/public mismatch should be limited to two public-only selectors");
        assertTrue(
            _contains(publicOnly, IPublicIDASurface.MAX_NUM_SUBSCRIPTIONS.selector),
            "fork should be missing MAX_NUM_SUBSCRIPTIONS()"
        );
        assertTrue(
            _contains(publicOnly, IPublicIDASurface.castrate.selector),
            "fork should be missing castrate()"
        );
        assertFalse(
            _contains(publicOnly, IPublicIDASurface.SLOTS_BITMAP_LIBRARY_ADDRESS.selector),
            "fork should still expose SLOTS_BITMAP_LIBRARY_ADDRESS()"
        );

        uint256 nativeAfter = ATTACKER.balance;
        console.log("[end] attacker native:", nativeAfter);
        console.logInt(int256(nativeAfter) - int256(nativeBefore));
    }

    function _publicSelectors() internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](21);
        selectors[0] = IPublicIDASurface.MAX_NUM_SUBSCRIPTIONS.selector;
        selectors[1] = IPublicIDASurface.SLOTS_BITMAP_LIBRARY_ADDRESS.selector;
        selectors[2] = IPublicIDASurface.agreementType.selector;
        selectors[3] = IPublicIDASurface.approveSubscription.selector;
        selectors[4] = IPublicIDASurface.calculateDistribution.selector;
        selectors[5] = IPublicIDASurface.castrate.selector;
        selectors[6] = IPublicIDASurface.claim.selector;
        selectors[7] = IPublicIDASurface.createIndex.selector;
        selectors[8] = IPublicIDASurface.deleteSubscription.selector;
        selectors[9] = IPublicIDASurface.distribute.selector;
        selectors[10] = IPublicIDASurface.getCodeAddress.selector;
        selectors[11] = IPublicIDASurface.getIndex.selector;
        selectors[12] = IPublicIDASurface.getSubscription.selector;
        selectors[13] = IPublicIDASurface.getSubscriptionByID.selector;
        selectors[14] = IPublicIDASurface.listSubscriptions.selector;
        selectors[15] = IPublicIDASurface.proxiableUUID.selector;
        selectors[16] = IPublicIDASurface.realtimeBalanceOf.selector;
        selectors[17] = IPublicIDASurface.revokeSubscription.selector;
        selectors[18] = IPublicIDASurface.updateCode.selector;
        selectors[19] = IPublicIDASurface.updateIndex.selector;
        selectors[20] = IPublicIDASurface.updateSubscription.selector;
    }

    function _extractDispatcherSelectors(bytes memory runtime) internal pure returns (bytes4[] memory selectors) {
        bytes4[] memory temp = new bytes4[](32);
        uint256 count;

        // The fork implementation uses a standard PUSH4/EQ dispatcher, so a
        // linear scan reproduces the same selector set as `cast selectors`.
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

    function _difference(bytes4[] memory left, bytes4[] memory right) internal pure returns (bytes4[] memory diff) {
        bytes4[] memory temp = new bytes4[](left.length);
        uint256 count;

        for (uint256 i = 0; i < left.length; ++i) {
            if (_contains(right, left[i])) continue;
            temp[count] = left[i];
            ++count;
        }

        diff = new bytes4[](count);
        for (uint256 i = 0; i < count; ++i) {
            diff[i] = temp[i];
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

    function _logSelectors(string memory label, bytes4[] memory selectors) internal view {
        console.log(label);
        for (uint256 i = 0; i < selectors.length; ++i) {
            console.log("  name:", _selectorName(selectors[i]));
            console.logBytes32(bytes32(selectors[i]));
        }
    }

    function _selectorName(bytes4 selector) internal pure returns (string memory) {
        if (selector == IPublicIDASurface.MAX_NUM_SUBSCRIPTIONS.selector) return "MAX_NUM_SUBSCRIPTIONS";
        if (selector == IPublicIDASurface.SLOTS_BITMAP_LIBRARY_ADDRESS.selector) return "SLOTS_BITMAP_LIBRARY_ADDRESS";
        if (selector == IPublicIDASurface.agreementType.selector) return "agreementType";
        if (selector == IPublicIDASurface.approveSubscription.selector) return "approveSubscription";
        if (selector == IPublicIDASurface.calculateDistribution.selector) return "calculateDistribution";
        if (selector == IPublicIDASurface.castrate.selector) return "castrate";
        if (selector == IPublicIDASurface.claim.selector) return "claim";
        if (selector == IPublicIDASurface.createIndex.selector) return "createIndex";
        if (selector == IPublicIDASurface.deleteSubscription.selector) return "deleteSubscription";
        if (selector == IPublicIDASurface.distribute.selector) return "distribute";
        if (selector == IPublicIDASurface.getCodeAddress.selector) return "getCodeAddress";
        if (selector == IPublicIDASurface.getIndex.selector) return "getIndex";
        if (selector == IPublicIDASurface.getSubscription.selector) return "getSubscription";
        if (selector == IPublicIDASurface.getSubscriptionByID.selector) return "getSubscriptionByID";
        if (selector == IPublicIDASurface.listSubscriptions.selector) return "listSubscriptions";
        if (selector == IPublicIDASurface.proxiableUUID.selector) return "proxiableUUID";
        if (selector == IPublicIDASurface.realtimeBalanceOf.selector) return "realtimeBalanceOf";
        if (selector == IPublicIDASurface.revokeSubscription.selector) return "revokeSubscription";
        if (selector == IPublicIDASurface.updateCode.selector) return "updateCode";
        if (selector == IPublicIDASurface.updateIndex.selector) return "updateIndex";
        if (selector == IPublicIDASurface.updateSubscription.selector) return "updateSubscription";
        return "unknown";
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
}
